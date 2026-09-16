//! UEFI BootNext trampoline.
//!
//! When executed by the firmware, this app writes the one-shot `BootNext` global
//! variable to a compile-time-baked `Boot####` id (see `build.rs`) and then warm
//! resets. On that reset the firmware consumes `BootNext` — which overrides
//! `BootOrder` for exactly one boot — and boots the chosen OS.
//!
//! Intended use: the image carrying this app is the NanoKVM virtual-media device,
//! which is boot entry #1. Power on -> firmware boots this -> BootNext set -> reset
//! -> chosen OS boots. No keystrokes / BIOS-menu automation required.

#![no_main]
#![no_std]

use uefi::{
    cstr16, entry,
    runtime::{self, ResetType, VariableAttributes, VariableVendor},
    Status,
};

// Provides `pub const BOOTNEXT: u16`.
include!(concat!(env!("OUT_DIR"), "/bootnext.rs"));

#[entry]
fn main() -> Status {
    uefi::helpers::init().expect("failed to initialise uefi helpers");

    let name = cstr16!("BootNext");
    let data = BOOTNEXT.to_le_bytes();
    // Global boot variables must be non-volatile and accessible to both boot and
    // runtime services, matching how firmware and efibootmgr create them.
    let attributes = VariableAttributes::NON_VOLATILE
        | VariableAttributes::BOOTSERVICE_ACCESS
        | VariableAttributes::RUNTIME_ACCESS;

    log::info!("uefi-trampoline: setting BootNext = 0x{BOOTNEXT:04x}");

    match runtime::set_variable(name, &VariableVendor::GLOBAL_VARIABLE, attributes, &data) {
        Ok(()) => log::info!("BootNext set; firmware will honor it on the next boot"),
        Err(e) => {
            log::error!("failed to set BootNext: {e:?}");
            // Fall through: in a normal build we still reset (below) so the box
            // isn't left stuck; in a no-reset build we halt with the message above.
            #[cfg(not(feature = "no-reset"))]
            runtime::reset(ResetType::WARM, e.status(), None);
        }
    }

    #[cfg(feature = "no-reset")]
    {
        log::info!("[no-reset] halting instead of resetting; inspect with `dmpstore BootNext`");
        loop {
            core::hint::spin_loop();
        }
    }

    #[cfg(not(feature = "no-reset"))]
    {
        log::info!("resetting (warm) to boot the selected entry…");
        runtime::reset(ResetType::WARM, Status::SUCCESS, None);
    }
}
