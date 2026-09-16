{
  description = "UEFI BootNext trampoline (sets one-shot BootNext to a baked Boot#### id, then warm-resets)";

  inputs = {
    nixpkgs.url = "nixpkgs";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, fenix }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # Dev-only toolchain: adds clippy/rustfmt/rust-src on top of what the
      # package build (default.nix) needs. The package pins its own fenix.
      rustToolchain = fenix.packages.${system}.combine [
        fenix.packages.${system}.stable.rustc
        fenix.packages.${system}.stable.cargo
        fenix.packages.${system}.stable.clippy
        fenix.packages.${system}.stable.rustfmt
        fenix.packages.${system}.stable.rust-src
        fenix.packages.${system}.targets.x86_64-unknown-uefi.stable.rust-std
      ];
    in
    {
      # Unsigned .efi. Override the baked id with .override { bootId = N; }.
      packages.${system}.default = pkgs.callPackage ./default.nix { };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          rustToolchain
          pkgs.mtools
          pkgs.dosfstools
          pkgs.xorriso # hybrid (ISO9660 + GPT/ESP) bootable image for the NanoKVM upload
          pkgs.qemu
          pkgs.OVMF
          pkgs.sbsigntool # sbsign/sbverify — sign the trampoline for Secure Boot
          pkgs.sbctl # manage/inspect lanzaboote Secure Boot keys
        ];

        # Consumed by `make qemu-test`.
        OVMF_CODE = "${pkgs.OVMF.fd}/FV/OVMF_CODE.fd";
        OVMF_VARS = "${pkgs.OVMF.fd}/FV/OVMF_VARS.fd";

        shellHook = ''
          echo "uefi_trampoline devshell"
          echo "  nix build .#                              # build the unsigned .efi"
          echo "  make iso OS=nixos BOOTNEXT=0002 SIGN=sbctl  # signed hybrid ISO"
          echo "  make qemu-test OS=nixos BOOTNEXT=0002     # verify BootNext under OVMF"
        '';
      };
    };
}
