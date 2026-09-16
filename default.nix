# Standalone, callPackage-friendly build of the UEFI BootNext trampoline.
#
# The firmware target x86_64-unknown-uefi needs a rust-std that stock nixpkgs
# rustc does not ship, so fenix is pinned and fetched *here* (via fetchTarball)
# rather than as a flake input — that way a consumer (e.g. nornpkgs) can just
# `pkgs.callPackage ./default.nix { }` with no fenix input/overlay of its own.
#
# `bootId` is the 16-bit UEFI Boot#### id baked into BootNext at compile time:
#   pkgs.callPackage ./default.nix { bootId = 2; }      # -> boots Boot0002
#   (pkgs.callPackage ./default.nix { }).override { bootId = 4; }
#
# Output is an UNSIGNED EFI application at $out/lib/uefi-trampoline/BOOTX64.EFI.
# Secure Boot signing + the hybrid ISO are user-side steps (see the Makefile);
# signing keys never enter the build sandbox.
{
  lib,
  pkgs,
  stdenv,
  rustPlatform,
  bootId ? 0,
  # fenix pinned to the rev from the original flake.lock; bump url+hash together.
  fenixSrc ? builtins.fetchTarball {
    url = "https://github.com/nix-community/fenix/archive/164c596ab50b2354f1dc0e8ee3a16b50420a17c4.tar.gz";
    sha256 = "sha256-0Zd4uniuWmAECxgh/VqU8/BRDYXwQn+n0gDxpgitGP8=";
  },
}:
let
  # fenix's default.nix defaults `system`/`pkgs` via builtins.currentSystem +
  # <nixpkgs>, neither of which exists in pure/flake eval — pass them explicitly.
  fenix = import fenixSrc {
    system = pkgs.stdenv.hostPlatform.system;
    inherit pkgs;
  };
  toolchain = fenix.combine [
    fenix.stable.rustc
    fenix.stable.cargo
    fenix.targets.x86_64-unknown-uefi.stable.rust-std
  ];
in
stdenv.mkDerivation (finalAttrs: {
  pname = "uefi-trampoline";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./build.rs
      ./src
      ./.cargo
    ];
  };

  # Offline-vendor the crate deps from the committed lockfile.
  cargoDeps = rustPlatform.importCargoLock { lockFile = ./Cargo.lock; };

  nativeBuildInputs = [
    toolchain
    rustPlatform.cargoSetupHook
  ];

  # Bake the target Boot#### id (build.rs reads $BOOTNEXT as hex).
  BOOTNEXT = lib.toHexString bootId;

  buildPhase = ''
    runHook preBuild
    cargo build --release --frozen --target x86_64-unknown-uefi
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 target/x86_64-unknown-uefi/release/trampoline.efi \
      "$out/lib/uefi-trampoline/BOOTX64.EFI"
    runHook postInstall
  '';

  # The artifact is a PE/COFF .efi, not an ELF — skip ELF fixups.
  dontStrip = true;
  dontPatchELF = true;

  meta = {
    description = "Tiny UEFI app that sets one-shot BootNext = 0x${lib.toHexString bootId} and warm-resets";
    homepage = "https://github.com/warmdarksea/uefi_trampoline";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
  };
})
