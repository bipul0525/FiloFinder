//! Phase 0 / S1: compare listing backends on a real folder.
//!
//!   cargo run --release --example list_bench -- gen <dir> <count>
//!   cargo run --release --example list_bench -- run <dir> [rounds]

use std::time::Instant;

use filofinder_core::{Backend, list_dir};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("gen") => generate(&args[2], args[3].parse().expect("count")),
        Some("run") => run(&args[2], args.get(3).map_or(7, |r| r.parse().expect("rounds"))),
        _ => eprintln!("usage: list_bench gen <dir> <count> | run <dir> [rounds]"),
    }
}

fn generate(dir: &str, count: usize) {
    std::fs::create_dir_all(dir).unwrap();
    for i in 0..count {
        // Mixed names exercise natural sorting; a few folders sort first.
        let name = if i % 500 == 0 { format!("{dir}/Folder {i}") } else { format!("{dir}/IMG_{i}.jpg") };
        if i % 500 == 0 {
            std::fs::create_dir_all(name).unwrap();
        } else {
            std::fs::write(name, i.to_le_bytes()).unwrap();
        }
    }
    println!("created {count} entries in {dir}");
}

fn run(dir: &str, rounds: usize) {
    for backend in [Backend::Readdir, Backend::Bulk] {
        let mut totals = Vec::new();
        let mut last = None;
        for _ in 0..rounds {
            let t = Instant::now();
            let l = list_dir(dir, false, backend).unwrap();
            totals.push(t.elapsed().as_secs_f64() * 1000.0);
            last = Some(l);
        }
        totals.sort_by(f64::total_cmp);
        let l = last.unwrap();
        println!(
            "{backend:?}: {} entries · median total {:.1} ms (list {:.1} ms + sort {:.1} ms) · min {:.1} ms",
            l.len(),
            totals[rounds / 2],
            l.list_micros as f64 / 1000.0,
            l.sort_micros as f64 / 1000.0,
            totals[0],
        );
    }
}
