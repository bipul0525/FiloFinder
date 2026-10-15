//! Filofinder core: every filesystem operation lives here (PLAN §4).

mod bulk;
pub mod listing;
pub mod natural;
pub mod ops;
pub mod unzip;

pub use listing::{Backend, Kind, ListError, Listing, Row, SortField, is_image_ext, list_dir, list_paths};

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::symlink;

    fn fixture() -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("ff-test-{}-{}", std::process::id(), rand_suffix()));
        fs::create_dir_all(dir.join("sub")).unwrap();
        fs::create_dir_all(dir.join("Tool.app")).unwrap();
        fs::write(dir.join("file10.txt"), b"0123456789").unwrap();
        fs::write(dir.join("file2.txt"), b"ab").unwrap();
        fs::write(dir.join(".hidden"), b"").unwrap();
        fs::write(dir.join("Icon\r"), b"").unwrap();
        symlink(dir.join("sub"), dir.join("link")).unwrap();
        dir
    }

    fn rand_suffix() -> u128 {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    }

    fn names(l: &Listing) -> Vec<String> {
        (0..l.len()).map(|i| l.row(i).unwrap().name.to_string()).collect()
    }

    #[test]
    fn backends_agree() {
        let dir = fixture();
        for show_hidden in [false, true] {
            let a = list_dir(dir.to_str().unwrap(), show_hidden, Backend::Readdir).unwrap();
            let b = list_dir(dir.to_str().unwrap(), show_hidden, Backend::Bulk).unwrap();
            assert_eq!(names(&a), names(&b));
            for i in 0..a.len() {
                let (ra, rb) = (a.row(i).unwrap(), b.row(i).unwrap());
                assert_eq!(ra.kind, rb.kind, "{}", ra.name);
                assert_eq!(ra.size, rb.size, "{}", ra.name);
                assert_eq!(ra.modified_ms / 1000, rb.modified_ms / 1000, "{}", ra.name);
                assert_eq!(ra.file_id, rb.file_id, "{}", ra.name);
            }
        }
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn folders_first_natural_order_and_kinds() {
        let dir = fixture();
        let l = list_dir(dir.to_str().unwrap(), false, Backend::Bulk).unwrap();
        // Packages sort with files, like Finder; links are not followed.
        assert_eq!(names(&l), ["sub", "file2.txt", "file10.txt", "link", "Tool.app"]);
        assert_eq!(l.row(4).unwrap().kind, Kind::Package);
        assert_eq!(l.row(3).unwrap().kind, Kind::Symlink);
        assert_eq!(l.row(2).unwrap().size, 10);
        let all = list_dir(dir.to_str().unwrap(), true, Backend::Bulk).unwrap();
        assert!(names(&all).contains(&".hidden".to_string()));
        assert!(!names(&all).contains(&"Icon\r".to_string()));
        fs::remove_dir_all(dir).unwrap();
    }
}

#[cfg(test)]
mod view_tests {
    use super::*;
    use std::fs;

    #[test]
    fn filter_sort_and_counts() {
        let dir = std::env::temp_dir().join(format!("ff-view-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("Zeta")).unwrap();
        fs::write(dir.join("b.png"), b"12345").unwrap();
        fs::write(dir.join("a.txt"), b"1").unwrap();
        fs::write(dir.join("c.jpg"), b"123").unwrap();
        let mut l = list_dir(dir.to_str().unwrap(), false, Backend::Bulk).unwrap();
        let names = |l: &Listing| (0..l.len()).map(|i| l.row(i).unwrap().name.to_string()).collect::<Vec<_>>();

        l.set_view(SortField::Size, true, "");
        assert_eq!(names(&l), ["Zeta", "b.png", "c.jpg", "a.txt"]); // folders stay first
        l.set_view(SortField::Kind, false, "");
        assert_eq!(names(&l), ["Zeta", "c.jpg", "b.png", "a.txt"]);
        l.set_view(SortField::Name, false, "PNG");
        assert_eq!(names(&l), ["b.png"]);
        assert_eq!(l.total(), 4);
        l.set_view(SortField::Name, false, "");
        assert_eq!(l.counts(), (2, 1, 1));
        assert_eq!(l.index_of("c.jpg"), Some(3));
        fs::remove_dir_all(dir).unwrap();
    }
}
