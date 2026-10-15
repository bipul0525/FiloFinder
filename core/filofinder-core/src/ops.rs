//! File operations with the safety rules of PLAN §5:
//! - never overwrite: every placement uses `renamex_np(RENAME_EXCL)`;
//! - copies are written under a hidden partial name, then renamed into
//!   place, so a crash never leaves a half-copied file under the real name;
//! - same-volume moves are one atomic `rename`; cross-volume moves copy,
//!   verify, and only then delete the source;
//! - a folder can never be moved or copied into itself.

use std::ffi::CString;
use std::fs;
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

#[derive(Debug)]
pub enum OpError {
    /// The destination name is taken; nothing was changed.
    Exists(PathBuf),
    /// Destination is the source itself or inside it.
    IntoItself(PathBuf),
    InvalidName(String),
    Io(PathBuf, io::Error),
}

impl std::fmt::Display for OpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Exists(p) => write!(f, "“{}” already exists", name_of(p)),
            Self::IntoItself(p) => write!(f, "“{}” can’t be moved or copied into itself", name_of(p)),
            Self::InvalidName(n) => write!(f, "“{n}” isn’t a valid name"),
            Self::Io(p, e) => write!(f, "{}: {e}", p.display()),
        }
    }
}

impl std::error::Error for OpError {}

pub type OpResult<T> = Result<T, OpError>;

fn name_of(p: &Path) -> String {
    p.file_name().map_or_else(|| p.display().to_string(), |n| n.to_string_lossy().into_owned())
}

fn cstr(p: &Path) -> OpResult<CString> {
    CString::new(p.as_os_str().as_bytes()).map_err(|_| OpError::InvalidName(p.display().to_string()))
}

fn io_err(p: &Path) -> impl FnOnce(io::Error) -> OpError + '_ {
    move |e| OpError::Io(p.to_path_buf(), e)
}

/// Validates a single path component typed by the user.
pub fn validate_name(name: &str) -> OpResult<()> {
    let bad = name.is_empty() || name == "." || name == ".." || name.contains('/') || name.contains('\0') || name.len() > 255;
    if bad { Err(OpError::InvalidName(name.to_string())) } else { Ok(()) }
}

/// Atomic rename that fails instead of replacing an existing item.
fn rename_excl(from: &Path, to: &Path) -> OpResult<()> {
    let (f, t) = (cstr(from)?, cstr(to)?);
    // SAFETY: valid NUL-terminated paths.
    let rc = unsafe { libc::renamex_np(f.as_ptr(), t.as_ptr(), libc::RENAME_EXCL) };
    if rc == 0 {
        return Ok(());
    }
    let e = io::Error::last_os_error();
    if e.raw_os_error() == Some(libc::EEXIST) { Err(OpError::Exists(to.to_path_buf())) } else { Err(OpError::Io(to.to_path_buf(), e)) }
}

fn same_device(a: &Path, b: &Path) -> OpResult<bool> {
    let da = fs::symlink_metadata(a).map_err(io_err(a))?.dev();
    let db = fs::metadata(b).map_err(io_err(b))?.dev();
    Ok(da == db)
}

/// Refuses `dest_dir` == `src` or anywhere inside `src`.
fn check_not_into_itself(src: &Path, dest_dir: &Path) -> OpResult<()> {
    let s = fs::canonicalize(src).map_err(io_err(src))?;
    let d = fs::canonicalize(dest_dir).map_err(io_err(dest_dir))?;
    if d == s || d.starts_with(&s) { Err(OpError::IntoItself(src.to_path_buf())) } else { Ok(()) }
}

/// Finder-style free name: "photo.jpg" → "photo 2.jpg" → "photo 3.jpg".
pub fn unique_name(dir: &Path, name: &str) -> String {
    if fs::symlink_metadata(dir.join(name)).is_err() {
        return name.to_string();
    }
    let (base, ext) = match name.rfind('.') {
        Some(i) if i > 0 => (&name[..i], &name[i..]),
        _ => (name, ""),
    };
    (2..)
        .map(|n| format!("{base} {n}{ext}"))
        .find(|candidate| fs::symlink_metadata(dir.join(candidate)).is_err())
        .expect("unbounded")
}

/// Hidden temporary name used while a copy is in flight.
fn partial_name(name: &str) -> String {
    format!(".{name}.ffpartial-{}", std::process::id())
}

/// Copies `src` into `dest_dir` as `name`. Folders are copied recursively;
/// metadata (xattrs, ACLs, tags, dates) is kept; same-volume copies use APFS
/// clones (instant, no extra space). Symlinks are copied as links.
pub fn copy_item(src: &Path, dest_dir: &Path, name: &str) -> OpResult<PathBuf> {
    validate_name(name)?;
    check_not_into_itself(src, dest_dir)?;
    let target = dest_dir.join(name);
    if fs::symlink_metadata(&target).is_ok() {
        return Err(OpError::Exists(target));
    }
    let partial = dest_dir.join(partial_name(name));
    let _ = remove_any(&partial); // stale leftover from a crash
    let flags = libc::COPYFILE_METADATA
        | libc::COPYFILE_DATA
        | libc::COPYFILE_RECURSIVE
        | libc::COPYFILE_CLONE
        | libc::COPYFILE_NOFOLLOW
        | libc::COPYFILE_DATA_SPARSE;
    let (s, p) = (cstr(src)?, cstr(&partial)?);
    // SAFETY: valid paths; null state = no progress callback.
    let rc = unsafe { libc::copyfile(s.as_ptr(), p.as_ptr(), std::ptr::null_mut(), flags) };
    if rc != 0 {
        let e = io::Error::last_os_error();
        let _ = remove_any(&partial);
        return Err(OpError::Io(src.to_path_buf(), e));
    }
    if let Err(e) = rename_excl(&partial, &target) {
        let _ = remove_any(&partial);
        return Err(e);
    }
    Ok(target)
}

/// Moves `src` into `dest_dir` as `name`.
pub fn move_item(src: &Path, dest_dir: &Path, name: &str) -> OpResult<PathBuf> {
    validate_name(name)?;
    check_not_into_itself(src, dest_dir)?;
    let target = dest_dir.join(name);
    if same_device(src, dest_dir)? {
        rename_excl(src, &target)?;
        return Ok(target);
    }
    // Different volume: copy fully, verify, then remove the source.
    let copied = copy_item(src, dest_dir, name)?;
    if !same_content_shape(src, &copied) {
        let _ = remove_any(&copied);
        return Err(OpError::Io(src.to_path_buf(), io::Error::other("copy verification failed; original kept")));
    }
    remove_any(src).map_err(io_err(src))?;
    Ok(copied)
}

/// Cheap verification: same kind, and for files the same byte size; for
/// folders the same number of entries at every level.
fn same_content_shape(a: &Path, b: &Path) -> bool {
    let (Ok(ma), Ok(mb)) = (fs::symlink_metadata(a), fs::symlink_metadata(b)) else { return false };
    if ma.file_type().is_dir() != mb.file_type().is_dir() {
        return false;
    }
    if !ma.file_type().is_dir() {
        return ma.file_type().is_symlink() || ma.len() == mb.len();
    }
    let names = |p: &Path| -> Option<Vec<std::ffi::OsString>> {
        let mut v: Vec<_> = fs::read_dir(p).ok()?.filter_map(|e| e.ok().map(|e| e.file_name())).collect();
        v.sort();
        Some(v)
    };
    match (names(a), names(b)) {
        (Some(na), Some(nb)) if na == nb => na.iter().all(|n| same_content_shape(&a.join(n), &b.join(n))),
        _ => false,
    }
}

/// Renames in place. Case-only renames ("a.txt" → "A.txt") are allowed on
/// case-insensitive volumes, where the new name "already exists".
pub fn rename_item(path: &Path, new_name: &str) -> OpResult<PathBuf> {
    validate_name(new_name)?;
    let dir = path.parent().unwrap_or(Path::new("/"));
    let target = dir.join(new_name);
    let old = name_of(path);
    if old == new_name {
        return Ok(target);
    }
    if old.to_lowercase() == new_name.to_lowercase() {
        fs::rename(path, &target).map_err(io_err(path))?;
        return Ok(target);
    }
    rename_excl(path, &target)?;
    Ok(target)
}

/// Creates "untitled folder" (or "untitled folder 2", …) in `dir`.
pub fn new_folder(dir: &Path) -> OpResult<PathBuf> {
    let name = unique_name(dir, "untitled folder");
    let path = dir.join(name);
    fs::create_dir(&path).map_err(io_err(&path))?;
    Ok(path)
}

/// Permanent delete (only after explicit confirmation in the UI).
pub fn delete_permanently(path: &Path) -> OpResult<()> {
    remove_any(path).map_err(io_err(path))
}

fn remove_any(path: &Path) -> io::Result<()> {
    let meta = fs::symlink_metadata(path)?;
    if meta.is_dir() { fs::remove_dir_all(path) } else { fs::remove_file(path) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    fn tmp(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("ff-ops-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn copy_never_overwrites_and_keeps_both_names() {
        let d = tmp("copy");
        fs::write(d.join("a.txt"), b"one").unwrap();
        fs::create_dir(d.join("out")).unwrap();
        fs::write(d.join("out/a.txt"), b"existing").unwrap();
        assert!(matches!(copy_item(&d.join("a.txt"), &d.join("out"), "a.txt"), Err(OpError::Exists(_))));
        assert_eq!(fs::read(d.join("out/a.txt")).unwrap(), b"existing");
        let free = unique_name(&d.join("out"), "a.txt");
        assert_eq!(free, "a 2.txt");
        copy_item(&d.join("a.txt"), &d.join("out"), &free).unwrap();
        assert_eq!(fs::read(d.join("out/a 2.txt")).unwrap(), b"one");
        // no partial leftovers
        assert!(fs::read_dir(d.join("out")).unwrap().all(|e| !e.unwrap().file_name().to_string_lossy().contains("ffpartial")));
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn copies_folders_recursively_and_links_as_links() {
        let d = tmp("tree");
        fs::create_dir_all(d.join("src/inner")).unwrap();
        fs::write(d.join("src/inner/f"), b"x").unwrap();
        symlink("/etc", d.join("src/link")).unwrap();
        fs::create_dir(d.join("dst")).unwrap();
        copy_item(&d.join("src"), &d.join("dst"), "src").unwrap();
        assert_eq!(fs::read(d.join("dst/src/inner/f")).unwrap(), b"x");
        assert!(fs::symlink_metadata(d.join("dst/src/link")).unwrap().file_type().is_symlink());
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn refuses_into_itself() {
        let d = tmp("self");
        fs::create_dir_all(d.join("a/b")).unwrap();
        assert!(matches!(move_item(&d.join("a"), &d.join("a/b"), "a"), Err(OpError::IntoItself(_))));
        assert!(matches!(copy_item(&d.join("a"), &d.join("a"), "a"), Err(OpError::IntoItself(_))));
        assert!(d.join("a/b").is_dir());
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn move_same_volume_and_conflict() {
        let d = tmp("move");
        fs::write(d.join("f"), b"1").unwrap();
        fs::create_dir(d.join("to")).unwrap();
        move_item(&d.join("f"), &d.join("to"), "f").unwrap();
        assert!(!d.join("f").exists() && d.join("to/f").exists());
        fs::write(d.join("f"), b"2").unwrap();
        assert!(matches!(move_item(&d.join("f"), &d.join("to"), "f"), Err(OpError::Exists(_))));
        assert_eq!(fs::read(d.join("to/f")).unwrap(), b"1");
        assert_eq!(fs::read(d.join("f")).unwrap(), b"2");
        fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn rename_rules() {
        let d = tmp("rename");
        fs::write(d.join("a.txt"), b"a").unwrap();
        fs::write(d.join("b.txt"), b"b").unwrap();
        assert!(matches!(rename_item(&d.join("a.txt"), "b.txt"), Err(OpError::Exists(_))));
        assert!(matches!(rename_item(&d.join("a.txt"), "x/y"), Err(OpError::InvalidName(_))));
        rename_item(&d.join("a.txt"), "A.txt").unwrap(); // case-only
        assert!(fs::read_dir(&d).unwrap().any(|e| e.unwrap().file_name() == "A.txt"));
        let f = new_folder(&d).unwrap();
        assert_eq!(name_of(&f), "untitled folder");
        assert_eq!(name_of(&new_folder(&d).unwrap()), "untitled folder 2");
        fs::remove_dir_all(d).unwrap();
    }
}
