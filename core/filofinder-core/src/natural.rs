//! Finder-style name ordering: case-insensitive, numbers compared by value
//! ("file2" < "file10"). ICU-aware collation is a later upgrade (PLAN §8).
//!
//! Allocation-free: it runs ~1.7M times when sorting a 100k-entry folder.

use std::cmp::Ordering;

pub fn natural_cmp(a: &str, b: &str) -> Ordering {
    let (ab, bb) = (a.as_bytes(), b.as_bytes());
    let (mut i, mut j) = (0usize, 0usize);
    while i < ab.len() && j < bb.len() {
        let (x, y) = (ab[i], bb[j]);
        if x.is_ascii_digit() && y.is_ascii_digit() {
            let (si, sj) = (i, j);
            while i < ab.len() && ab[i].is_ascii_digit() {
                i += 1;
            }
            while j < bb.len() && bb[j].is_ascii_digit() {
                j += 1;
            }
            let na = trim_zeros(&ab[si..i]);
            let nb = trim_zeros(&bb[sj..j]);
            let ord = na.len().cmp(&nb.len()).then_with(|| na.cmp(nb));
            if ord != Ordering::Equal {
                return ord;
            }
        } else if x.is_ascii() && y.is_ascii() {
            let ord = x.to_ascii_lowercase().cmp(&y.to_ascii_lowercase());
            if ord != Ordering::Equal {
                return ord;
            }
            i += 1;
            j += 1;
        } else {
            // Non-ASCII: compare one char each, lowercased, without allocating.
            let ca = a[i..].chars().next().unwrap_or('\0');
            let cb = b[j..].chars().next().unwrap_or('\0');
            let ord = ca.to_lowercase().cmp(cb.to_lowercase());
            if ord != Ordering::Equal {
                return ord;
            }
            i += ca.len_utf8();
            j += cb.len_utf8();
        }
    }
    (ab.len() - i).cmp(&(bb.len() - j))
}

fn trim_zeros(digits: &[u8]) -> &[u8] {
    let n = digits.iter().take_while(|&&d| d == b'0').count();
    &digits[n..]
}

#[cfg(test)]
mod tests {
    use super::natural_cmp;
    use std::cmp::Ordering::*;

    #[test]
    fn orders_like_finder() {
        assert_eq!(natural_cmp("file2", "file10"), Less);
        assert_eq!(natural_cmp("File", "file"), Equal);
        assert_eq!(natural_cmp("a", "ab"), Less);
        assert_eq!(natural_cmp("img007", "img7"), Equal);
        assert_eq!(natural_cmp("b1", "a2"), Greater);
        assert_eq!(natural_cmp("Ä", "ä"), Equal);
        assert_eq!(natural_cmp("été", "Zoo"), Greater); // byte order until ICU collation
        assert_eq!(natural_cmp("x9", "x10y"), Less);
        assert_eq!(natural_cmp("", "a"), Less);
    }
}
