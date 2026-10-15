//! Folder listings, stored column-wise so a 1M-entry folder stays compact
//! and the UI can fetch only the rows it shows (PLAN §4.1).

use std::fs;
use std::os::macos::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::{Instant, UNIX_EPOCH};

use crate::natural::natural_cmp;

/// `UF_HIDDEN` from <sys/stat.h> (`chflags hidden`).
pub(crate) const UF_HIDDEN: u32 = 0x8000;

/// Directories macOS presents as a single document.
const PACKAGE_EXTS: &[&str] = &[
    "app", "bundle", "framework", "plugin", "kext", "photoslibrary", "musiclibrary",
    "rtfd", "xcodeproj", "xcworkspace", "playground", "pages", "numbers", "key",
    "scptd", "appex", "prefpane", "saver", "qlgenerator", "mdimporter",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Kind {
    Dir = 0,
    File = 1,
    Package = 2,
    Symlink = 3,
    Other = 4,
}

/// Which system calls produce the listing. Both exist so Phase 0 can
/// measure them against each other on real folders.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Backend {
    /// `readdir` + one `lstat` per entry.
    Readdir,
    /// `getattrlistbulk`: names and attributes in batches.
    Bulk,
}

#[derive(Debug)]
pub struct ListError {
    pub path: String,
    pub message: String,
}

impl std::fmt::Display for ListError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.path, self.message)
    }
}

impl std::error::Error for ListError {}

/// One raw entry as produced by a backend, before columnar packing.
pub(crate) struct RawEntry {
    pub name: String,
    pub kind: Kind,
    pub size: u64,
    pub modified_ms: i64,
    pub flags: u32,
    pub file_id: u64,
}

pub struct Row<'a> {
    pub name: &'a str,
    pub kind: Kind,
    pub size: u64,
    pub modified_ms: i64,
    pub hidden: bool,
    pub file_id: u64,
}

#[derive(Default)]
pub struct Listing {
    pub path: String,
    pub parent: Option<String>,
    names: String,
    name_ends: Vec<u32>,
    kinds: Vec<Kind>,
    sizes: Vec<u64>,
    modified: Vec<i64>,
    hidden: Vec<bool>,
    file_ids: Vec<u64>,
    /// Display order: indexes into the columns above.
    order: Vec<u32>,
    /// Entries the OS refused to describe (permissions, races).
    pub unreadable: u32,
    pub list_micros: u64,
    pub sort_micros: u64,
}

pub(crate) fn is_package(name: &str) -> bool {
    Path::new(name)
        .extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| PACKAGE_EXTS.iter().any(|p| p.eq_ignore_ascii_case(e)))
}

impl Listing {
    pub fn len(&self) -> usize {
        self.order.len()
    }

    pub fn is_empty(&self) -> bool {
        self.order.is_empty()
    }

    fn name_at(&self, col: usize) -> &str {
        let start = if col == 0 { 0 } else { self.name_ends[col - 1] as usize };
        &self.names[start..self.name_ends[col] as usize]
    }

    /// Row `i` in display order.
    pub fn row(&self, i: usize) -> Option<Row<'_>> {
        let col = *self.order.get(i)? as usize;
        Some(Row {
            name: self.name_at(col),
            kind: self.kinds[col],
            size: self.sizes[col],
            modified_ms: self.modified[col],
            hidden: self.hidden[col],
            file_id: self.file_ids[col],
        })
    }

    fn push(&mut self, e: RawEntry, show_hidden: bool) {
        let hidden = e.name.starts_with('.') || e.flags & UF_HIDDEN != 0;
        if hidden && !show_hidden {
            return;
        }
        let kind = if e.kind == Kind::Dir && is_package(&e.name) { Kind::Package } else { e.kind };
        self.names.push_str(&e.name);
        self.name_ends.push(self.names.len() as u32);
        self.kinds.push(kind);
        self.sizes.push(if kind == Kind::File { e.size } else { 0 });
        self.modified.push(e.modified_ms);
        self.hidden.push(hidden);
        self.file_ids.push(e.file_id);
    }

    fn ext_at(&self, col: usize) -> &str {
        let name = self.name_at(col);
        match name.rfind('.') {
            Some(i) if i > 0 => &name[i + 1..],
            _ => "",
        }
    }

    /// Recomputes the visible rows: filter by name (case-insensitive
    /// substring, like captools), then sort. Folders always come first.
    pub fn set_view(&mut self, field: SortField, descending: bool, query: &str) {
        let t = Instant::now();
        let q = query.trim().to_lowercase();
        let mut order: Vec<u32> = (0..self.kinds.len() as u32)
            .filter(|&c| q.is_empty() || self.name_at(c as usize).to_lowercase().contains(&q))
            .collect();
        order.sort_unstable_by(|&a, &b| {
            let (a, b) = (a as usize, b as usize);
            let (da, db) = (self.kinds[a] == Kind::Dir, self.kinds[b] == Kind::Dir);
            let by_field = match field {
                SortField::Name => natural_cmp(self.name_at(a), self.name_at(b)),
                SortField::Kind => natural_cmp(self.ext_at(a), self.ext_at(b)),
                SortField::Size => self.sizes[a].cmp(&self.sizes[b]),
            };
            let by_field = if descending { by_field.reverse() } else { by_field };
            db.cmp(&da).then(by_field).then_with(|| natural_cmp(self.name_at(a), self.name_at(b)))
        });
        self.order = order;
        self.sort_micros = t.elapsed().as_micros() as u64;
    }

    fn sort(&mut self) {
        self.set_view(SortField::Name, false, "");
    }

    /// Total entries, ignoring the filter.
    pub fn total(&self) -> usize {
        self.kinds.len()
    }

    /// Image / other-file / folder counts over the visible rows.
    pub fn counts(&self) -> (u32, u32, u32) {
        let (mut images, mut files, mut folders) = (0, 0, 0);
        for &c in &self.order {
            let c = c as usize;
            match self.kinds[c] {
                Kind::Dir => folders += 1,
                _ if is_image_ext(self.ext_at(c)) => images += 1,
                _ => files += 1,
            }
        }
        (images, files, folders)
    }

    /// Display index of `name`, if visible.
    pub fn index_of(&self, name: &str) -> Option<usize> {
        self.order.iter().position(|&c| self.name_at(c as usize) == name)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SortField {
    Name,
    /// File type (extension), like captools' "Type" column.
    Kind,
    Size,
}

/// Image types the UI thumbnails and counts as images.
pub fn is_image_ext(ext: &str) -> bool {
    const IMAGES: &[&str] = &[
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "svg", "ico", "avif", "heic", "heif", "tif", "tiff",
    ];
    IMAGES.iter().any(|e| e.eq_ignore_ascii_case(ext))
}

/// Never shown regardless of the hidden-files toggle (PLAN §3).
fn is_always_skipped(name: &str) -> bool {
    name == "Icon\r"
}

pub fn list_dir(path: &str, show_hidden: bool, backend: Backend) -> Result<Listing, ListError> {
    let err = |message: String| ListError { path: path.to_string(), message };
    let dir: PathBuf = fs::canonicalize(path).map_err(|e| err(e.to_string()))?;
    if !dir.is_dir() {
        return Err(err("not a folder".into()));
    }

    let mut listing = Listing {
        path: dir.to_string_lossy().into_owned(),
        parent: dir.parent().map(|p| p.to_string_lossy().into_owned()),
        ..Default::default()
    };

    let t = Instant::now();
    let mut unreadable = 0u32;
    let mut sink = |e: RawEntry| {
        if !is_always_skipped(&e.name) {
            listing.push(e, show_hidden);
        }
    };
    match backend {
        Backend::Readdir => read_with_readdir(&dir, &mut sink, &mut unreadable),
        Backend::Bulk => crate::bulk::read_with_bulk(&dir, &mut sink, &mut unreadable),
    }
    .map_err(|e| err(e.to_string()))?;
    listing.unreadable = unreadable;
    listing.list_micros = t.elapsed().as_micros() as u64;

    listing.sort();
    Ok(listing)
}

/// A "virtual folder" of arbitrary items (search or tag results). Each
/// row's name is its absolute path; `title` becomes the listing's path.
pub fn list_paths(paths: &[String], title: &str, show_hidden: bool) -> Listing {
    let t = Instant::now();
    let mut listing = Listing { path: title.to_string(), parent: None, ..Default::default() };
    for p in paths {
        let Ok(meta) = fs::symlink_metadata(p) else { listing.unreadable += 1; continue };
        let ft = meta.file_type();
        let kind = if ft.is_symlink() { Kind::Symlink } else if ft.is_dir() { Kind::Dir } else if ft.is_file() { Kind::File } else { Kind::Other };
        let modified_ms = meta.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map_or(0, |d| d.as_millis() as i64);
        let base = Path::new(p).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let hidden = base.starts_with('.') || meta.st_flags() & UF_HIDDEN != 0;
        if hidden && !show_hidden { continue; }
        let kind = if kind == Kind::Dir && is_package(&base) { Kind::Package } else { kind };
        listing.names.push_str(p);
        listing.name_ends.push(listing.names.len() as u32);
        listing.kinds.push(kind);
        listing.sizes.push(if kind == Kind::File { meta.len() } else { 0 });
        listing.modified.push(modified_ms);
        listing.hidden.push(hidden);
        listing.file_ids.push(meta.st_ino());
    }
    listing.list_micros = t.elapsed().as_micros() as u64;
    listing.sort();
    listing
}

fn read_with_readdir(dir: &Path, sink: &mut dyn FnMut(RawEntry), unreadable: &mut u32) -> std::io::Result<()> {
    for item in fs::read_dir(dir)? {
        let Ok(item) = item else { *unreadable += 1; continue };
        let name = item.file_name().to_string_lossy().into_owned();
        // symlink_metadata: describe links themselves, never their targets.
        let Ok(meta) = fs::symlink_metadata(item.path()) else { *unreadable += 1; continue };
        let ft = meta.file_type();
        let kind = if ft.is_symlink() {
            Kind::Symlink
        } else if ft.is_dir() {
            Kind::Dir
        } else if ft.is_file() {
            Kind::File
        } else {
            Kind::Other
        };
        let modified_ms = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map_or(0, |d| d.as_millis() as i64);
        sink(RawEntry { name, kind, size: meta.len(), modified_ms, flags: meta.st_flags(), file_id: meta.st_ino() });
    }
    Ok(())
}
