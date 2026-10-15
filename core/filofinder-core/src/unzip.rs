//! ZIP extraction (PLAN §7): parallel, clean, and safe.
//!
//! - Clean: macOS/Windows junk (`.DS_Store`, `__MACOSX/`, AppleDouble `._X`,
//!   `Thumbs.db`, …) is never extracted. Real dotfiles (`.env`, `.gitignore`)
//!   are kept.
//! - Safe: no path escapes the destination (zip-slip), symlinks may only
//!   point inside it, free space is checked first, and no entry may write
//!   more than it declares (zip bombs).
//! - Atomic: everything is extracted into a hidden partial folder, which is
//!   renamed into place only when finished — a failure leaves nothing behind.
//! - Finder-like result: an archive with a single top-level folder becomes
//!   that folder; otherwise a folder named after the archive.

use std::collections::HashSet;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rayon::prelude::*;
use zip::ZipArchive;

use crate::ops::{OpError, OpResult, unique_name};

#[derive(Debug, Default)]
pub struct ExtractReport {
    /// The folder that now holds the extracted files.
    pub output: PathBuf,
    pub files: u64,
    pub folders: u64,
    pub bytes: u64,
    /// System junk skipped (".DS_Store", "__MACOSX/…").
    pub skipped_junk: u64,
    /// Entries refused for safety (escaping paths, unsafe links).
    pub skipped_unsafe: u64,
    pub failed: Vec<String>,
}

const JUNK_NAMES: &[&str] = &[
    ".DS_Store", "Icon\r", ".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems", "Thumbs.db", "desktop.ini",
];

/// Junk by path component. `._X` (AppleDouble) is junk only when `X` is in
/// the same folder of the archive, so a genuine file named "._config" survives.
fn is_junk(path: &Path, names: &HashSet<PathBuf>) -> bool {
    let mut comps = path.components().filter_map(|c| match c {
        Component::Normal(s) => s.to_str(),
        _ => None,
    });
    if comps.any(|c| c == "__MACOSX" || JUNK_NAMES.contains(&c)) {
        return true;
    }
    let Some(name) = path.file_name().and_then(|n| n.to_str()) else { return false };
    if let Some(real) = name.strip_prefix("._") {
        return names.contains(&path.with_file_name(real));
    }
    false
}

fn err(p: &Path) -> impl FnOnce(io::Error) -> OpError + '_ {
    move |e| OpError::Io(p.to_path_buf(), e)
}

/// The archive's "local" DOS time → system time (DOS stamps are local time).
fn to_system_time(dt: zip::DateTime) -> Option<SystemTime> {
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    tm.tm_year = dt.year() as i32 - 1900;
    tm.tm_mon = dt.month() as i32 - 1;
    tm.tm_mday = dt.day() as i32;
    tm.tm_hour = dt.hour() as i32;
    tm.tm_min = dt.minute() as i32;
    tm.tm_sec = dt.second() as i32;
    tm.tm_isdst = -1;
    // SAFETY: tm is a valid, initialised struct.
    let secs = unsafe { libc::mktime(&mut tm) };
    (secs > 0).then(|| UNIX_EPOCH + Duration::from_secs(secs as u64))
}

fn free_space(dir: &Path) -> Option<u64> {
    let c = std::ffi::CString::new(dir.as_os_str().as_encoded_bytes()).ok()?;
    let mut st: libc::statfs = unsafe { std::mem::zeroed() };
    // SAFETY: valid path and out-pointer.
    (unsafe { libc::statfs(c.as_ptr(), &mut st) } == 0).then(|| st.f_bavail * st.f_bsize as u64)
}

struct Plan {
    files: Vec<(usize, PathBuf, u64)>,
    dirs: Vec<PathBuf>,
    links: Vec<(usize, PathBuf)>,
    skipped_junk: u64,
    skipped_unsafe: u64,
    total_bytes: u64,
}

fn plan(archive: &mut ZipArchive<File>) -> Plan {
    // First pass: every entry name, for the AppleDouble rule.
    let mut names = HashSet::new();
    for i in 0..archive.len() {
        if let Ok(f) = archive.by_index_raw(i) {
            if let Some(p) = f.enclosed_name() {
                names.insert(p);
            }
        }
    }
    let mut p = Plan { files: vec![], dirs: vec![], links: vec![], skipped_junk: 0, skipped_unsafe: 0, total_bytes: 0 };
    let mut seen = HashSet::new();
    for i in 0..archive.len() {
        let Ok(f) = archive.by_index_raw(i) else { p.skipped_unsafe += 1; continue };
        // enclosed_name() rejects absolute paths and anything escaping via "..".
        let Some(rel) = f.enclosed_name() else { p.skipped_unsafe += 1; continue };
        if rel.as_os_str().is_empty() {
            continue;
        }
        if is_junk(&rel, &names) {
            p.skipped_junk += 1;
            continue;
        }
        if !seen.insert(rel.clone()) {
            p.skipped_unsafe += 1; // duplicate / overlapping entry
            continue;
        }
        if f.is_dir() {
            p.dirs.push(rel);
        } else if f.is_symlink() {
            p.links.push((i, rel));
        } else {
            p.total_bytes += f.size();
            p.files.push((i, rel, f.size()));
        }
    }
    // Parent folders of every file must exist too.
    for (_, rel, _) in &p.files {
        if let Some(parent) = rel.parent().filter(|x| !x.as_os_str().is_empty()) {
            p.dirs.push(parent.to_path_buf());
        }
    }
    p.dirs.sort();
    p.dirs.dedup();
    // Largest files first keeps all cores busy until the end.
    p.files.sort_by(|a, b| b.2.cmp(&a.2));
    p
}

/// Extracts `archive` into `dest_dir` (normally the folder containing it).
pub fn extract_zip(archive_path: &Path, dest_dir: &Path) -> OpResult<ExtractReport> {
    let file = File::open(archive_path).map_err(err(archive_path))?;
    let mut archive = ZipArchive::new(file)
        .map_err(|e| OpError::Io(archive_path.to_path_buf(), io::Error::new(io::ErrorKind::InvalidData, e.to_string())))?;
    let plan = plan(&mut archive);

    if let Some(free) = free_space(dest_dir) {
        if plan.total_bytes > free {
            return Err(OpError::Io(
                dest_dir.to_path_buf(),
                io::Error::other(format!("not enough space: needs {} MB, {} MB free",
                                         plan.total_bytes / 1_000_000, free / 1_000_000)),
            ));
        }
    }

    let stem = archive_path.file_stem().map_or_else(|| "Archive".into(), |s| s.to_string_lossy().into_owned());
    let partial = dest_dir.join(format!(".{stem}.ffpartial-{}", std::process::id()));
    let _ = fs::remove_dir_all(&partial);
    fs::create_dir(&partial).map_err(err(&partial))?;

    let result = (|| -> OpResult<ExtractReport> {
        for d in &plan.dirs {
            let p = partial.join(d);
            fs::create_dir_all(&p).map_err(err(&p))?;
        }

        // Files in parallel; one archive reader per worker thread.
        let failures: Vec<String> = plan
            .files
            .par_iter()
            .map_init(
                || File::open(archive_path).ok().and_then(|f| ZipArchive::new(f).ok()),
                |reader, (index, rel, declared)| {
                    let Some(reader) = reader.as_mut() else { return Some(format!("{}: can't reopen archive", rel.display())) };
                    extract_file(reader, *index, &partial.join(rel), *declared)
                        .err()
                        .map(|e| format!("{}: {e}", rel.display()))
                },
            )
            .flatten()
            .collect();

        // Symlinks last, and only if they stay inside the destination.
        let mut unsafe_links = 0;
        for (index, rel) in &plan.links {
            let mut target = String::new();
            let ok = archive.by_index(*index).ok().and_then(|mut f| f.read_to_string(&mut target).ok()).is_some();
            let inside = ok && !target.starts_with('/') && {
                let resolved = rel.parent().unwrap_or(Path::new("")).join(&target);
                let mut depth: i32 = 0;
                resolved.components().all(|c| {
                    match c {
                        Component::ParentDir => depth -= 1,
                        Component::Normal(_) => depth += 1,
                        _ => {}
                    }
                    depth >= 0
                })
            };
            if inside && symlink(&target, partial.join(rel)).is_ok() { continue }
            unsafe_links += 1;
        }

        Ok(ExtractReport {
            files: (plan.files.len() - failures.len()) as u64,
            folders: plan.dirs.len() as u64,
            bytes: plan.total_bytes,
            skipped_junk: plan.skipped_junk,
            skipped_unsafe: plan.skipped_unsafe + unsafe_links,
            failed: failures,
            ..Default::default()
        })
    })();

    let mut report = match result {
        Ok(r) => r,
        Err(e) => {
            let _ = fs::remove_dir_all(&partial);
            return Err(e);
        }
    };

    // Finder-like placement: a single top-level folder becomes the result.
    let top: Vec<_> = fs::read_dir(&partial).map_err(err(&partial))?.filter_map(Result::ok).collect();
    let output = if top.len() == 1 && top[0].file_type().is_ok_and(|t| t.is_dir()) {
        let inner = top[0].path();
        let name = unique_name(dest_dir, &top[0].file_name().to_string_lossy());
        let out = dest_dir.join(name);
        fs::rename(&inner, &out).map_err(err(&out))?;
        let _ = fs::remove_dir(&partial);
        out
    } else {
        let out = dest_dir.join(unique_name(dest_dir, &stem));
        fs::rename(&partial, &out).map_err(err(&out))?;
        out
    };
    report.output = output;
    Ok(report)
}

fn extract_file(archive: &mut ZipArchive<File>, index: usize, out: &Path, declared: u64) -> io::Result<()> {
    let mut entry = archive.by_index(index).map_err(io::Error::other)?;
    let mode = entry.unix_mode();
    let mtime = entry.last_modified().and_then(to_system_time);
    let mut file = fs::OpenOptions::new().write(true).create_new(true).open(out)?;
    // Zip-bomb guard: never write more than the entry declares.
    let mut limited = (&mut entry).take(declared + 1);
    let written = io::copy(&mut limited, &mut io::BufWriter::with_capacity(1 << 20, &mut file))?;
    if written > declared {
        drop(file);
        let _ = fs::remove_file(out);
        return Err(io::Error::other("entry is larger than it declares (possible zip bomb)"));
    }
    file.flush()?;
    if let Some(mode) = mode.map(|m| m & 0o777).filter(|m| *m != 0) {
        fs::set_permissions(out, fs::Permissions::from_mode(mode | 0o600))?;
    }
    if let Some(t) = mtime {
        let _ = file.set_modified(t);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use zip::write::SimpleFileOptions;

    fn tmp(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("ff-unzip-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    fn make_zip(path: &Path, entries: &[(&str, &[u8])]) {
        let mut w = zip::ZipWriter::new(File::create(path).unwrap());
        for (name, data) in entries {
            if name.ends_with('/') {
                w.add_directory(*name, SimpleFileOptions::default()).unwrap();
            } else {
                w.start_file(*name, SimpleFileOptions::default().unix_permissions(0o755)).unwrap();
                w.write_all(data).unwrap();
            }
        }
        w.finish().unwrap();
    }

    #[test]
    fn extracts_clean_into_named_folder() {
        let d = tmp("clean");
        let zip = d.join("photos.zip");
        make_zip(&zip, &[
            ("a.jpg", b"A"),
            ("sub/b.jpg", b"BB"),
            (".DS_Store", b"x"),
            ("__MACOSX/._a.jpg", b"x"),
            ("._a.jpg", b"x"),
            ("._real", b"keep me"),
            (".env", b"SECRET=1"),
        ]);
        let r = extract_zip(&zip, &d).unwrap();
        assert_eq!(r.output, d.join("photos"));
        assert_eq!(fs::read(d.join("photos/sub/b.jpg")).unwrap(), b"BB");
        assert!(d.join("photos/.env").exists(), "real dotfiles are kept");
        assert!(d.join("photos/._real").exists(), "._X without X is not AppleDouble");
        assert!(!d.join("photos/.DS_Store").exists());
        assert!(!d.join("photos/._a.jpg").exists());
        assert!(!d.join("photos/__MACOSX").exists());
        assert_eq!(r.skipped_junk, 3);
        assert!(r.failed.is_empty());
        // executable bit kept
        assert_eq!(fs::metadata(d.join("photos/a.jpg")).unwrap().permissions().mode() & 0o111, 0o111);
        // second extraction never overwrites: "photos 2"
        assert_eq!(extract_zip(&zip, &d).unwrap().output, d.join("photos 2"));
        assert!(fs::read_dir(&d).unwrap().all(|e| !e.unwrap().file_name().to_string_lossy().contains("ffpartial")));
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn single_top_folder_becomes_the_result() {
        let d = tmp("single");
        let zip = d.join("download.zip");
        make_zip(&zip, &[("Project/", b""), ("Project/readme.md", b"hi")]);
        let r = extract_zip(&zip, &d).unwrap();
        assert_eq!(r.output, d.join("Project"));
        assert_eq!(fs::read(d.join("Project/readme.md")).unwrap(), b"hi");
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn junk_rules() {
        let names: HashSet<PathBuf> = ["a/x.txt"].iter().map(PathBuf::from).collect();
        assert!(is_junk(Path::new("a/._x.txt"), &names));
        assert!(!is_junk(Path::new("a/._y.txt"), &names));
        assert!(is_junk(Path::new("deep/.DS_Store"), &names));
        assert!(!is_junk(Path::new(".gitignore"), &names));
        assert!(!is_junk(Path::new(".git/config"), &names));
    }
}
