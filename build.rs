//! Bakes the target Boot#### number (as a u16) into the binary at compile time.
//!
//! Set it via the `BOOTNEXT` environment variable, as the 16-bit hex id you read
//! from `efibootmgr` (with or without a `0x` prefix), e.g. `BOOTNEXT=0003`.
//! Defaults to `0000` if unset. One `.efi` is built per target OS.

use std::{env, fs, path::Path};

fn main() {
    let raw = env::var("BOOTNEXT").unwrap_or_else(|_| "0000".to_string());
    let trimmed = raw.trim();
    let hex = trimmed
        .strip_prefix("0x")
        .or_else(|| trimmed.strip_prefix("0X"))
        .unwrap_or(trimmed);

    let value: u16 = u16::from_str_radix(hex, 16).unwrap_or_else(|e| {
        panic!("BOOTNEXT must be a 16-bit hex Boot#### id (e.g. 0003); got {raw:?}: {e}")
    });

    let out_dir = env::var("OUT_DIR").expect("OUT_DIR not set");
    let dest = Path::new(&out_dir).join("bootnext.rs");
    fs::write(
        &dest,
        format!("/// Baked BootNext target (a UEFI Boot#### id as a u16).\npub const BOOTNEXT: u16 = 0x{value:04x};\n"),
    )
    .expect("failed to write bootnext.rs");

    println!("cargo:rerun-if-env-changed=BOOTNEXT");
}
