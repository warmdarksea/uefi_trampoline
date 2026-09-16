# uefi_trampoline
#
# Build the UEFI BootNext trampoline .efi, wrap it in a bootable hybrid ISO for
# the NanoKVM's HTTP upload, and (optionally) sign it for Secure Boot.
#
# `nix build .#` produces the unsigned .efi directly; this Makefile is the path
# for the *signed* hybrid ISO and offline QEMU verification.
#
# Use `>` as the recipe prefix so the file is robust to tab handling.
.RECIPEPREFIX = >
.DEFAULT_GOAL := all

# --- configuration ----------------------------------------------------------
# logical name; produces trampoline-$(OS).{efi,img,iso}
OS       ?= nixos
# target Boot#### id in hex, from `efibootmgr`
BOOTNEXT ?= 0000

# Secure Boot signing (optional, for lanzaboote/sbctl setups). `make image` signs
# the trampoline so it boots with Secure Boot on. Two ways:
#   1) let sbctl find your enrolled db key automatically:
#        make iso OS=nixos BOOTNEXT=0002 SIGN=sbctl
#   2) point sbsign at an explicit db key+cert:
#        make iso OS=nixos BOOTNEXT=0002 \
#          SIGN_KEY=/etc/secureboot/keys/db/db.key SIGN_CERT=/etc/secureboot/keys/db/db.pem
SIGN       ?=
SIGN_KEY   ?=
SIGN_CERT  ?=

CARGO        ?= cargo
TARGET       := x86_64-unknown-uefi
BUILD        := build
EFI          := $(BUILD)/trampoline-$(OS).efi
IMG          := $(BUILD)/trampoline-$(OS).img
DEBUG_EFI    := $(BUILD)/trampoline-$(OS)-debug.efi
DEBUG_IMG    := $(BUILD)/trampoline-$(OS)-debug.img
ISO          := $(BUILD)/trampoline-$(OS).iso
DEBUG_ISO    := $(BUILD)/trampoline-$(OS)-debug.iso
SIGNED_EFI   := $(BUILD)/trampoline-$(OS).signed.efi
CARGO_OUT    := target/$(TARGET)/release/trampoline.efi

export MTOOLS_SKIP_CHECK := 1

.PHONY: all trampoline trampoline-debug image image-debug iso iso-debug qemu-test qemu-test-cd clean

all: iso

$(BUILD):
> mkdir -p $(BUILD)

# --- trampoline (Rust UEFI app) ---------------------------------------------
trampoline: | $(BUILD)
> BOOTNEXT=$(BOOTNEXT) $(CARGO) build --release --target $(TARGET)
> cp $(CARGO_OUT) $(EFI)
> @echo "built $(EFI) (BootNext=0x$(BOOTNEXT))"

trampoline-debug: | $(BUILD)
> BOOTNEXT=$(BOOTNEXT) $(CARGO) build --release --target $(TARGET) --features no-reset
> cp $(CARGO_OUT) $(DEBUG_EFI)
> @echo "built $(DEBUG_EFI) (BootNext=0x$(BOOTNEXT), no-reset)"

# --- bootable FAT image (an ESP mounted on the NanoKVM as USB mass storage) --
# mtools builds the FAT filesystem without needing root or loop mounts.
image: trampoline
> rm -f $(IMG)
> dd if=/dev/zero of=$(IMG) bs=1M count=48 status=none
> mformat -i $(IMG) -F ::
> mmd -i $(IMG) ::/EFI ::/EFI/BOOT
> if [ "$(SIGN)" = "sbctl" ]; then \
>   echo "signing $(EFI) with sbctl (auto-locating enrolled db key)"; \
>   sbctl sign -o $(SIGNED_EFI) $(EFI); \
>   mcopy -i $(IMG) $(SIGNED_EFI) ::/EFI/BOOT/BOOTX64.EFI; \
> elif [ -n "$(SIGN_KEY)" ]; then \
>   echo "signing $(EFI) with $(SIGN_KEY)"; \
>   sbsign --key "$(SIGN_KEY)" --cert "$(SIGN_CERT)" --output $(SIGNED_EFI) $(EFI); \
>   sbverify --cert "$(SIGN_CERT)" $(SIGNED_EFI); \
>   mcopy -i $(IMG) $(SIGNED_EFI) ::/EFI/BOOT/BOOTX64.EFI; \
> else \
>   echo "NOTE: unsigned image (set SIGN=sbctl or SIGN_KEY/SIGN_CERT for Secure Boot)"; \
>   mcopy -i $(IMG) $(EFI) ::/EFI/BOOT/BOOTX64.EFI; \
> fi
> @echo "assembled $(IMG)"

image-debug: trampoline-debug
> rm -f $(DEBUG_IMG)
> dd if=/dev/zero of=$(DEBUG_IMG) bs=1M count=48 status=none
> mformat -i $(DEBUG_IMG) -F ::
> mmd -i $(DEBUG_IMG) ::/EFI ::/EFI/BOOT
> mcopy -i $(DEBUG_IMG) $(DEBUG_EFI) ::/EFI/BOOT/BOOTX64.EFI
> @echo "assembled $(DEBUG_IMG)"

# --- hybrid bootable ISO (ISO9660 + appended GPT/ESP) -----------------------
# The NanoKVM's HTTP upload (POST /api/download/file) requires a *valid ISO*, so
# we wrap the FAT ESP in an ISO9660 that is also USB-bootable (appended EF
# partition). Upload it, then mount cdrom=false to match the "USB Mass Storage"
# firmware boot entry.
iso: image
> rm -rf $(BUILD)/isoroot && mkdir -p $(BUILD)/isoroot
> cp $(IMG) $(BUILD)/isoroot/efiboot.img
> xorriso -as mkisofs -V TRAMP_$(OS) \
>   -e efiboot.img -no-emul-boot \
>   -append_partition 2 0xef $(BUILD)/isoroot/efiboot.img \
>   -partition_offset 16 \
>   -o $(ISO) $(BUILD)/isoroot
> @echo "assembled $(ISO)"

iso-debug: image-debug
> rm -rf $(BUILD)/isoroot-debug && mkdir -p $(BUILD)/isoroot-debug
> cp $(DEBUG_IMG) $(BUILD)/isoroot-debug/efiboot.img
> xorriso -as mkisofs -V TRAMP_$(OS)_DBG \
>   -e efiboot.img -no-emul-boot \
>   -append_partition 2 0xef $(BUILD)/isoroot-debug/efiboot.img \
>   -partition_offset 16 \
>   -o $(DEBUG_ISO) $(BUILD)/isoroot-debug
> @echo "assembled $(DEBUG_ISO)"

# --- offline verification: boot the hybrid ISO under OVMF and confirm BootNext -
# qemu-test boots the ISO as a USB/SATA disk (how the NanoKVM presents it with
# cdrom=false); qemu-test-cd boots it as a CD-ROM. Both should print the BootNext
# line from the trampoline (debug build halts instead of resetting).
qemu-test: iso-debug
> @test -n "$$OVMF_CODE" || { echo "OVMF_CODE unset; run inside 'nix develop'"; exit 1; }
> cp "$$OVMF_VARS" $(BUILD)/OVMF_VARS.test.fd
> chmod +w $(BUILD)/OVMF_VARS.test.fd
> @echo "booting $(DEBUG_ISO) as USB disk under OVMF; look for 'setting BootNext = 0x$(BOOTNEXT)'"
> qemu-system-x86_64 -machine q35 -m 256 \
>   -drive if=pflash,format=raw,readonly=on,file="$$OVMF_CODE" \
>   -drive if=pflash,format=raw,file=$(BUILD)/OVMF_VARS.test.fd \
>   -drive format=raw,file=$(DEBUG_ISO),if=none,id=usbstick \
>   -device qemu-xhci -device usb-storage,drive=usbstick \
>   -nographic -serial mon:stdio -no-reboot -rtc base=utc

qemu-test-cd: iso-debug
> @test -n "$$OVMF_CODE" || { echo "OVMF_CODE unset; run inside 'nix develop'"; exit 1; }
> cp "$$OVMF_VARS" $(BUILD)/OVMF_VARS.test.fd
> chmod +w $(BUILD)/OVMF_VARS.test.fd
> @echo "booting $(DEBUG_ISO) as CD-ROM under OVMF"
> qemu-system-x86_64 -machine q35 -m 256 \
>   -drive if=pflash,format=raw,readonly=on,file="$$OVMF_CODE" \
>   -drive if=pflash,format=raw,file=$(BUILD)/OVMF_VARS.test.fd \
>   -cdrom $(DEBUG_ISO) \
>   -nographic -serial mon:stdio -no-reboot -rtc base=utc

clean:
> rm -rf $(BUILD) target
