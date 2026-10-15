//! `getattrlistbulk(2)`: returns many directory entries *with* their
//! attributes per system call, instead of readdir + one lstat per entry.
//!
//! Buffer layout per entry (see the man page's example):
//!   u32 length · attribute_set_t returned · [u32 error] · attrreference_t name
//!   · u32 objtype · timespec modtime · u32 flags · u64 fileid · [i64 datalength]
//! Common attributes appear in bit order; file attributes follow. Fields not
//! in `returned` are absent, so parsing is driven by the returned bitmap.

use std::ffi::{CString, c_int, c_void};
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

use crate::listing::{Kind, RawEntry};

const ATTR_BIT_MAP_COUNT: u16 = 5;

const ATTR_CMN_NAME: u32 = 0x0000_0001;
const ATTR_CMN_OBJTYPE: u32 = 0x0000_0008;
const ATTR_CMN_MODTIME: u32 = 0x0000_0400;
const ATTR_CMN_FLAGS: u32 = 0x0004_0000;
const ATTR_CMN_FILEID: u32 = 0x0200_0000;
const ATTR_CMN_ERROR: u32 = 0x2000_0000;
const ATTR_CMN_RETURNED_ATTRS: u32 = 0x8000_0000;
const ATTR_FILE_DATALENGTH: u32 = 0x0000_0200;

// vnode types (sys/vnode.h)
const VREG: u32 = 1;
const VDIR: u32 = 2;
const VLNK: u32 = 5;

const BUF_SIZE: usize = 256 * 1024;

#[repr(C)]
struct AttrList {
    bitmapcount: u16,
    reserved: u16,
    commonattr: u32,
    volattr: u32,
    dirattr: u32,
    fileattr: u32,
    forkattr: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct AttributeSet {
    commonattr: u32,
    volattr: u32,
    dirattr: u32,
    fileattr: u32,
    forkattr: u32,
}

unsafe extern "C" {
    fn getattrlistbulk(dirfd: c_int, attr_list: *mut c_void, attr_buf: *mut c_void, attr_buf_size: usize, options: u64) -> c_int;
}

/// Reads a `T` at `*pos` (unaligned) and advances `pos`.
fn take<T: Copy>(buf: &[u8], pos: &mut usize) -> Option<T> {
    let size = std::mem::size_of::<T>();
    let bytes = buf.get(*pos..*pos + size)?;
    *pos += size;
    // SAFETY: bounds checked above; T is plain-old-data.
    Some(unsafe { std::ptr::read_unaligned(bytes.as_ptr() as *const T) })
}

struct Fd(c_int);

impl Drop for Fd {
    fn drop(&mut self) {
        // SAFETY: we own this descriptor.
        unsafe { libc::close(self.0) };
    }
}

pub(crate) fn read_with_bulk(dir: &Path, sink: &mut dyn FnMut(RawEntry), unreadable: &mut u32) -> io::Result<()> {
    let cpath = CString::new(dir.as_os_str().as_bytes()).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    // SAFETY: valid NUL-terminated path.
    let fd = unsafe { libc::open(cpath.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let fd = Fd(fd);

    let mut attrs = AttrList {
        bitmapcount: ATTR_BIT_MAP_COUNT,
        reserved: 0,
        commonattr: ATTR_CMN_RETURNED_ATTRS
            | ATTR_CMN_NAME
            | ATTR_CMN_ERROR
            | ATTR_CMN_OBJTYPE
            | ATTR_CMN_MODTIME
            | ATTR_CMN_FLAGS
            | ATTR_CMN_FILEID,
        volattr: 0,
        dirattr: 0,
        fileattr: ATTR_FILE_DATALENGTH,
        forkattr: 0,
    };
    let mut buf = vec![0u8; BUF_SIZE];

    loop {
        // SAFETY: attrs and buf are valid for the duration of the call.
        let count = unsafe {
            getattrlistbulk(fd.0, &mut attrs as *mut _ as *mut c_void, buf.as_mut_ptr() as *mut c_void, buf.len(), 0)
        };
        if count < 0 {
            let e = io::Error::last_os_error();
            if e.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(e);
        }
        if count == 0 {
            return Ok(());
        }

        let mut entry_start = 0usize;
        for _ in 0..count {
            let mut pos = entry_start;
            let Some(len) = take::<u32>(&buf, &mut pos) else { break };
            let next = entry_start + len as usize;
            match parse_entry(&buf, pos) {
                Some(e) => sink(e),
                None => *unreadable += 1,
            }
            entry_start = next;
        }
    }
}

fn parse_entry(buf: &[u8], mut pos: usize) -> Option<RawEntry> {
    let returned: AttributeSet = take(buf, &mut pos)?;
    let common = returned.commonattr;

    if common & ATTR_CMN_ERROR != 0 {
        let error: u32 = take(buf, &mut pos)?;
        if error != 0 {
            return None;
        }
    }

    let mut name = String::new();
    if common & ATTR_CMN_NAME != 0 {
        let ref_pos = pos;
        let offset: i32 = take(buf, &mut pos)?;
        let length: u32 = take(buf, &mut pos)?;
        let start = (ref_pos as isize + offset as isize) as usize;
        // length includes the trailing NUL.
        let bytes = buf.get(start..start + length.saturating_sub(1) as usize)?;
        name = String::from_utf8_lossy(bytes).into_owned();
    }

    let mut kind = Kind::Other;
    if common & ATTR_CMN_OBJTYPE != 0 {
        kind = match take::<u32>(buf, &mut pos)? {
            VREG => Kind::File,
            VDIR => Kind::Dir,
            VLNK => Kind::Symlink,
            _ => Kind::Other,
        };
    }

    let mut modified_ms = 0i64;
    if common & ATTR_CMN_MODTIME != 0 {
        let ts: libc::timespec = take(buf, &mut pos)?;
        modified_ms = ts.tv_sec * 1000 + ts.tv_nsec / 1_000_000;
    }

    let mut flags = 0u32;
    if common & ATTR_CMN_FLAGS != 0 {
        flags = take(buf, &mut pos)?;
    }

    let mut file_id = 0u64;
    if common & ATTR_CMN_FILEID != 0 {
        file_id = take(buf, &mut pos)?;
    }

    let mut size = 0u64;
    if returned.fileattr & ATTR_FILE_DATALENGTH != 0 {
        size = take::<i64>(buf, &mut pos)?.max(0) as u64;
    }

    if name.is_empty() {
        return None;
    }
    Some(RawEntry { name, kind, size, modified_ms, flags, file_id })
}
