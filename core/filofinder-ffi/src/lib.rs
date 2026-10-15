//! The Swift-facing API. Kept thin: types are converted here, logic lives in
//! filofinder-core. Hot paths hand out one small record per *visible* row.

use std::sync::{Arc, Mutex, MutexGuard};

use filofinder_core as core;

uniffi::setup_scaffolding!();

#[derive(uniffi::Enum, Clone, Copy)]
pub enum EntryKind {
    Folder,
    File,
    Package,
    Symlink,
    Other,
}

impl From<core::Kind> for EntryKind {
    fn from(k: core::Kind) -> Self {
        match k {
            core::Kind::Dir => Self::Folder,
            core::Kind::File => Self::File,
            core::Kind::Package => Self::Package,
            core::Kind::Symlink => Self::Symlink,
            core::Kind::Other => Self::Other,
        }
    }
}

#[derive(uniffi::Enum, Clone, Copy)]
pub enum ListBackend {
    Readdir,
    Bulk,
}

#[derive(uniffi::Record)]
pub struct EntryRow {
    pub name: String,
    pub kind: EntryKind,
    pub size: u64,
    /// Milliseconds since the Unix epoch.
    pub modified_ms: i64,
    pub hidden: bool,
}

#[derive(uniffi::Record)]
pub struct ListingStats {
    pub count: u32,
    pub unreadable: u32,
    pub list_micros: u64,
    pub sort_micros: u64,
}

#[derive(Debug, uniffi::Error)]
pub enum FfiError {
    Io { message: String },
    /// The destination name is taken; nothing changed.
    Exists { message: String },
    /// Moving/copying a folder into itself.
    IntoItself { message: String },
    InvalidName { message: String },
}

impl std::fmt::Display for FfiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io { message } | Self::Exists { message } | Self::IntoItself { message } | Self::InvalidName { message } => {
                f.write_str(message)
            }
        }
    }
}

impl From<core::ops::OpError> for FfiError {
    fn from(e: core::ops::OpError) -> Self {
        let message = e.to_string();
        match e {
            core::ops::OpError::Exists(_) => Self::Exists { message },
            core::ops::OpError::IntoItself(_) => Self::IntoItself { message },
            core::ops::OpError::InvalidName(_) => Self::InvalidName { message },
            core::ops::OpError::Io(..) => Self::Io { message },
        }
    }
}

impl std::error::Error for FfiError {}

#[derive(uniffi::Enum, Clone, Copy)]
pub enum SortField {
    Name,
    Kind,
    Size,
}

#[derive(uniffi::Record)]
pub struct ListingCounts {
    pub images: u32,
    pub files: u32,
    pub folders: u32,
}

/// A finished folder listing. The data stays in Rust; Swift reads rows by
/// index. The visible view (filter + sort) can be changed in place.
#[derive(uniffi::Object)]
pub struct ListingHandle {
    inner: Mutex<core::Listing>,
}

impl ListingHandle {
    fn lock(&self) -> MutexGuard<'_, core::Listing> {
        self.inner.lock().unwrap_or_else(|p| p.into_inner())
    }
}

#[uniffi::export]
impl ListingHandle {
    /// Visible rows (after the filter).
    pub fn count(&self) -> u32 {
        self.lock().len() as u32
    }

    /// All entries, ignoring the filter.
    pub fn total(&self) -> u32 {
        self.lock().total() as u32
    }

    pub fn path(&self) -> String {
        self.lock().path.clone()
    }

    pub fn parent(&self) -> Option<String> {
        self.lock().parent.clone()
    }

    pub fn set_view(&self, field: SortField, descending: bool, query: String) {
        let field = match field {
            SortField::Name => core::SortField::Name,
            SortField::Kind => core::SortField::Kind,
            SortField::Size => core::SortField::Size,
        };
        self.lock().set_view(field, descending, &query);
    }

    pub fn counts(&self) -> ListingCounts {
        let (images, files, folders) = self.lock().counts();
        ListingCounts { images, files, folders }
    }

    pub fn index_of(&self, name: String) -> Option<u32> {
        self.lock().index_of(&name).map(|i| i as u32)
    }

    pub fn row(&self, index: u32) -> Option<EntryRow> {
        self.lock().row(index as usize).map(|r| EntryRow {
            name: r.name.to_string(),
            kind: r.kind.into(),
            size: r.size,
            modified_ms: r.modified_ms,
            hidden: r.hidden,
        })
    }

    pub fn stats(&self) -> ListingStats {
        let l = self.lock();
        ListingStats {
            count: l.len() as u32,
            unreadable: l.unreadable,
            list_micros: l.list_micros,
            sort_micros: l.sort_micros,
        }
    }
}

/// Lists a folder. Blocking: call it off the main thread.
#[uniffi::export]
pub fn list_dir(path: String, show_hidden: bool, backend: ListBackend) -> Result<Arc<ListingHandle>, FfiError> {
    let backend = match backend {
        ListBackend::Readdir => core::Backend::Readdir,
        ListBackend::Bulk => core::Backend::Bulk,
    };
    core::list_dir(&path, show_hidden, backend)
        .map(|l| Arc::new(ListingHandle { inner: Mutex::new(l) }))
        .map_err(|e| FfiError::Io { message: e.to_string() })
}

/// A virtual listing of arbitrary items (tag/search results); row names are
/// absolute paths and `title` is the listing's path (e.g. "tag:Red").
#[uniffi::export]
pub fn list_paths(paths: Vec<String>, title: String, show_hidden: bool) -> Arc<ListingHandle> {
    Arc::new(ListingHandle { inner: Mutex::new(core::list_paths(&paths, &title, show_hidden)) })
}

/// True for file types the UI treats as images (thumbnails, counts).
#[uniffi::export]
pub fn is_image_name(name: String) -> bool {
    name.rsplit_once('.').is_some_and(|(_, ext)| core::is_image_ext(ext))
}

// MARK: File operations (blocking — call off the main thread)

use std::path::Path;

/// Copies `src` into `dest_dir` as `name`; never overwrites. Returns the new path.
#[uniffi::export]
pub fn copy_item(src: String, dest_dir: String, name: String) -> Result<String, FfiError> {
    Ok(core::ops::copy_item(Path::new(&src), Path::new(&dest_dir), &name)?.to_string_lossy().into_owned())
}

/// Moves `src` into `dest_dir` as `name`; never overwrites. Returns the new path.
#[uniffi::export]
pub fn move_item(src: String, dest_dir: String, name: String) -> Result<String, FfiError> {
    Ok(core::ops::move_item(Path::new(&src), Path::new(&dest_dir), &name)?.to_string_lossy().into_owned())
}

#[uniffi::export]
pub fn rename_item(path: String, new_name: String) -> Result<String, FfiError> {
    Ok(core::ops::rename_item(Path::new(&path), &new_name)?.to_string_lossy().into_owned())
}

#[uniffi::export]
pub fn new_folder(dir: String) -> Result<String, FfiError> {
    Ok(core::ops::new_folder(Path::new(&dir))?.to_string_lossy().into_owned())
}

#[uniffi::export]
pub fn delete_permanently(path: String) -> Result<(), FfiError> {
    Ok(core::ops::delete_permanently(Path::new(&path))?)
}

/// Finder-style free name in `dir` ("photo.jpg" → "photo 2.jpg").
#[uniffi::export]
pub fn unique_name(dir: String, name: String) -> String {
    core::ops::unique_name(Path::new(&dir), &name)
}

#[uniffi::export]
pub fn validate_name(name: String) -> Result<(), FfiError> {
    Ok(core::ops::validate_name(&name)?)
}

#[derive(uniffi::Record)]
pub struct ExtractSummary {
    /// Folder holding the extracted files.
    pub output: String,
    pub files: u64,
    pub folders: u64,
    pub bytes: u64,
    pub skipped_junk: u64,
    pub skipped_unsafe: u64,
    pub failed: Vec<String>,
}

/// Extracts a ZIP next to it (Filofinder's own engine: parallel, clean, safe).
#[uniffi::export]
pub fn extract_zip(archive: String, dest_dir: String) -> Result<ExtractSummary, FfiError> {
    let r = core::unzip::extract_zip(Path::new(&archive), Path::new(&dest_dir))?;
    Ok(ExtractSummary {
        output: r.output.to_string_lossy().into_owned(),
        files: r.files,
        folders: r.folders,
        bytes: r.bytes,
        skipped_junk: r.skipped_junk,
        skipped_unsafe: r.skipped_unsafe,
        failed: r.failed,
    })
}

#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}
