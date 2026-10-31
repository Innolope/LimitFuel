//! Acceptance tests written from SPEC.md only; production bodies were not inspected.
//!
//! Plan / What can go wrong (W12, W15): enforce byte boundaries and exact manifest
//! grammar, then reject missing, stale, reordered and partially written chunks.
//! Pure serialization has no timers, retries, auth, concurrency or migration effects.
//! Credential Manager write ordering and in-memory fallback need app-level seams.

use limitfuel_core::credential::{join, split, CHUNK_BYTES, MAX_CHUNKS};
use sha2::{Digest, Sha256};

fn manifest(secret: &[u8], count: usize) -> Vec<u8> {
    let hash: String = Sha256::digest(secret).iter().map(|b| format!("{b:02x}")).collect();
    format!("limitfuel-chunks:1:{count}:{hash}").into_bytes()
}

fn secret(size: usize) -> Vec<u8> {
    (0..size).map(|i| ((i * 73 + i / 251) % 256) as u8).collect()
}

#[test]
fn split_and_join_round_trip_byte_boundaries_with_exact_manifest() {
    assert_eq!(CHUNK_BYTES, 2560);
    assert_eq!(MAX_CHUNKS, 8);
    for size in [1, 2559, 2560, 2561, 16384, 20480] {
        let input = secret(size);
        let expected: Vec<_> = input.chunks(2560).map(<[u8]>::to_vec).collect();
        let (actual_manifest, chunks) = split(&input).expect("in-range secret");
        assert_eq!(chunks, expected, "size {size}: consecutive byte slices");
        assert_eq!(actual_manifest, manifest(&input, expected.len()), "size {size}");
        assert_eq!(join(&actual_manifest, &chunks), Some(input), "size {size}");
    }
    // A fixed external SHA-256 vector also pins the manifest's literal spelling.
    let (m, _) = split(b"abc").unwrap();
    assert_eq!(m, b"limitfuel-chunks:1:1:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
}

#[test]
fn split_rejects_empty_and_over_eight_chunks() {
    for input in [vec![], secret(20481)] {
        assert_eq!(split(&input), None, "size {}", input.len());
    }
}

#[test]
fn join_rejects_noncanonical_or_tampered_manifests() {
    let input = secret(2561);
    let chunks: Vec<_> = input.chunks(2560).map(<[u8]>::to_vec).collect();
    let good = String::from_utf8(manifest(&input, 2)).unwrap();
    let hash = good.rsplit(':').next().unwrap();
    let mut wrong_hash = hash.to_string();
    wrong_hash.replace_range(0..1, if &hash[0..1] == "0" { "1" } else { "0" });
    for (why, m) in [
        ("wrong hash", format!("limitfuel-chunks:1:2:{wrong_hash}")),
        ("uppercase hex", format!("limitfuel-chunks:1:2:{}", hash.to_uppercase())),
        ("count mismatch", format!("limitfuel-chunks:1:1:{hash}")),
        ("leading zero", format!("limitfuel-chunks:1:02:{hash}")),
        ("zero count", format!("limitfuel-chunks:1:0:{hash}")),
        ("nine chunks", format!("limitfuel-chunks:1:9:{hash}")),
        ("trailing space", format!("{good} ")),
        ("trailing newline", format!("{good}\n")),
        ("leading space", format!(" {good}")),
        ("different version", format!("limitfuel-chunks:2:2:{hash}")),
        ("version leading zero", format!("limitfuel-chunks:01:2:{hash}")),
        ("extra field", format!("{good}:extra")),
        ("short hash", format!("limitfuel-chunks:1:2:{}", &hash[..63])),
        ("nonhex hash", format!("limitfuel-chunks:1:2:{}g", &hash[..63])),
        ("empty manifest", String::new()),
    ] {
        assert_eq!(join(m.as_bytes(), &chunks), None, "{why}");
    }
    assert_eq!(join(&[0xff, 0xfe], &chunks), None);
}

#[test]
fn join_rejects_invalid_chunk_shapes_even_with_matching_hashes() {
    for (why, chunks) in [
        ("short non-final chunk", vec![vec![1; 2559], vec![2]]),
        ("oversized non-final chunk", vec![vec![1; 2561], vec![2]]),
        ("empty last chunk", vec![vec![1; 2560], vec![]]),
        ("oversized last chunk", vec![vec![1; 2560], vec![2; 2561]]),
        ("only empty chunk", vec![vec![]]),
        ("no chunks", vec![]),
        ("nine full chunks", vec![vec![1; 2560]; 9]),
    ] {
        let combined = chunks.concat();
        assert_eq!(join(&manifest(&combined, chunks.len()), &chunks), None, "{why}");
    }
}

#[test]
fn join_rejects_incomplete_or_stale_writes_and_reordered_chunks() {
    let input = secret(6000);
    let good: Vec<_> = input.chunks(2560).map(<[u8]>::to_vec).collect();
    let m = manifest(&input, 3);
    let mut extra = good.clone();
    extra.push(vec![1]);
    let mut changed = good.clone();
    changed[1][123] ^= 1;
    let mut reordered = good.clone();
    reordered.swap(0, 1);
    for (why, chunks) in [
        ("missing chunk after interrupted write", good[..2].to_vec()),
        ("extra chunk", extra),
        ("old chunk with same length", changed),
        ("reordered chunks", reordered),
    ] {
        assert_eq!(join(&m, &chunks), None, "{why}");
    }
}
