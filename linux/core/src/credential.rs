//! A secret split to fit Windows Credential Manager, which holds 2560 bytes per credential.

pub const CHUNK_BYTES: usize = 2560;
pub const MAX_CHUNKS: usize = 8;

pub fn split(secret: &[u8]) -> Option<(Vec<u8>, Vec<Vec<u8>>)> {
    let _ = secret;
    unimplemented!()
}

pub fn join(manifest: &[u8], chunks: &[Vec<u8>]) -> Option<Vec<u8>> {
    let _ = (manifest, chunks);
    unimplemented!()
}
