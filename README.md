# uefi_trampoline

🚨🤖 AI slopware alert, LLM-generated code/prose follow. sorry...! i'll hopefully rewrite at least the prose at some point. the program seems to work fine though. but i thought i should mention it.

A tiny UEFI application that, when booted, sets the firmware's one-shot `BootNext`
variable to a specific `Boot####` id and warm-resets — so the machine lands on a
chosen OS with no keystrokes or BIOS-menu automation. The target id is **baked at
build time** (one image per OS).

Pairs with [`nanokvmctl`](https://github.com/warmdarksea/nanokvmctl), which uploads
the trampoline image to a Sipeed NanoKVM, mounts it as boot media, resets the host,
and unmounts afterwards.

```
firmware boots the trampoline  →  it sets BootNext=0x####  →  warm reset
                                    └─ firmware honors BootNext (overrides BootOrder once) → boots that OS
```

`BootNext` is consumed by the firmware for exactly one boot and takes precedence
over `BootOrder`, so nothing needs to keep the trampoline permanently first — the
one-shot handles the redirect, and later reboots fall through to the normal default.

## Build

### With Nix (unsigned `.efi`)

The `default.nix` is a plain `callPackage` function; `bootId` is the 16-bit
`Boot####` id to bake in:

```sh
nix build .#                                   # bootId 0 (placeholder)
nix-build -E 'with import <nixpkgs> {}; callPackage ./default.nix { bootId = 2; }'
# -> result/lib/uefi-trampoline/BOOTX64.EFI
```

From another flake / nornpkgs, with no fenix input of its own:

```nix
uefi_trampoline = pkgs.callPackage "${src}/default.nix" { };   # .override { bootId = 2; }
```

fenix (which carries the `x86_64-unknown-uefi` rust-std that stock nixpkgs rustc
lacks) is pinned and fetched *inside* `default.nix`, so consumers need nothing extra.

### With the Makefile (signed hybrid ISO)

`nix build` gives you the raw `.efi`; the Makefile is the path for a Secure-Boot
**signed**, uploadable **hybrid ISO**. Find the target `Boot####` on the running
host first:

```sh
nix develop
sudo efibootmgr -v                       # note the Boot#### per OS (and BootCurrent)
make iso OS=nixos BOOTNEXT=0002          # -> build/trampoline-nixos.iso
```

The NanoKVM's HTTP upload requires a **valid ISO9660**, so the image is a **hybrid
ISO** (ISO9660 + an appended GPT/ESP) — it boots both as USB mass storage *and* as
CD-ROM. `Boot####` ids are stable across NixOS rebuilds (systemd-boot/lanzaboote
keep one firmware entry).

### Secure Boot (lanzaboote)

With Secure Boot on, the `.efi` must be signed by a key in your `db`. Signing runs
wherever `make` runs — do it on the machine that holds the keys (they never need to
leave it):

```sh
make iso OS=nixos BOOTNEXT=0002 SIGN=sbctl                       # auto-locate enrolled db key
make iso OS=nixos BOOTNEXT=0002 \
    SIGN_KEY=/path/to/db/db.key SIGN_CERT=/path/to/db/db.pem     # explicit key + cert
```

`make` signs `BOOTX64.EFI` with `sbsign` and checks it with `sbverify` before
wrapping it in the ISO.

## Verify offline (no hardware)

```sh
make qemu-test    OS=nixos BOOTNEXT=0002   # boots the hybrid ISO as a USB disk under OVMF
make qemu-test-cd OS=nixos BOOTNEXT=0002   # ...and as a CD-ROM
```

Both print `setting BootNext = 0x0002` on the serial console (the `no-reset` debug
build halts instead of resetting so you can read it).

## Boot priority (important)

The trampoline only runs if the firmware actually boots the NanoKVM media. Some
firmware (e.g. ASUS AMI on a PRIME Z790) **rebuilds `BootOrder` every POST**,
sorting by device class and demoting removable/CD entries below the internal disk —
so a manually-set order silently reverts. Two things make it stick:

- Disable **Fast Boot** in setup, then set the order from the running OS:
  `sudo efibootmgr -o <nanokvm>,<...>` (this is what held on the Z790).
- Or don't fight `BootOrder` at all — arm a single boot with
  `sudo efibootmgr -n <nanokvm-Boot####>` right before resetting; the firmware
  honors `BootNext` regardless of how it sorts `BootOrder`.

Watch the NanoKVM video console on the first run to confirm you see the trampoline's
`setting BootNext` line.

## How it works

- `build.rs` reads `$BOOTNEXT` (hex, `0x` optional) and emits
  `pub const BOOTNEXT: u16`.
- `src/main.rs` (`#![no_std]`/`#![no_main]`, uefi-rs 0.40) sets the `BootNext`
  global variable (`NON_VOLATILE | BOOTSERVICE_ACCESS | RUNTIME_ACCESS`) to that id
  as little-endian bytes, then `reset(WARM, ...)`. The `no-reset` cargo feature
  logs and halts instead (for QEMU inspection).

## Notes

- The ISO is a few MB: the ESP is a small FAT16 image (default 4 MB, `ESP_MB`),
  wrapped as ISO9660 + an appended GPT/ESP. Trampolines are static (build/upload once
  per OS). Bump `ESP_MB` if a firmware refuses the small/FAT16 image.
- If a firmware ignores `BootNext` on a *warm* reset, switch `ResetType::WARM` to
  `COLD` in `src/main.rs`.
