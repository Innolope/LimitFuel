//! A secret split to fit Windows Credential Manager, which holds 2560 bytes per credential.
//! The manifest is written last and carries a hash, so a half-finished write never loads.

use sha2::{Digest, Sha256};

pub const CHUNK_BYTES: usize = 2560;
pub const MAX_CHUNKS: usize = 8;

const PREFIX: &str = "limitfuel-chunks:1:";

fn hex_digest(data: &[u8]) -> String {
    Sha256::digest(data).iter().map(|b| format!("{b:02x}")).collect()
}

pub fn split(secret: &[u8]) -> Option<(Vec<u8>, Vec<Vec<u8>>)> {
    if secret.is_empty() || secret.len() > CHUNK_BYTES * MAX_CHUNKS {
        return None;
    }
    let chunks: Vec<Vec<u8>> = secret.chunks(CHUNK_BYTES).map(<[u8]>::to_vec).collect();
    let manifest = format!("{PREFIX}{}:{}", chunks.len(), hex_digest(secret));
    Some((manifest.into_bytes(), chunks))
}

pub fn join(manifest: &[u8], chunks: &[Vec<u8>]) -> Option<Vec<u8>> {
    let manifest = std::str::from_utf8(manifest).ok()?.strip_prefix(PREFIX)?;
    let (count, digest) = manifest.split_once(':')?;
    let well_formed_count = !count.is_empty() && count.bytes().all(|b| b.is_ascii_digit()) && !count.starts_with('0');
    let well_formed_digest = digest.len() == 64 && digest.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'));
    if !well_formed_count || !well_formed_digest {
        return None;
    }
    let count: usize = count.parse().ok()?;
    if !(1..=MAX_CHUNKS).contains(&count) || chunks.len() != count {
        return None;
    }
    let (last, rest) = chunks.split_last()?;
    if rest.iter().any(|chunk| chunk.len() != CHUNK_BYTES) || last.is_empty() || last.len() > CHUNK_BYTES {
        return None;
    }
    let secret = chunks.concat();
    (hex_digest(&secret) == digest).then_some(secret)
}
