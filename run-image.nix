{
  writeShellApplication,
  qemu,
  OVMF,
  stdenv,
  lib,
  targetArch ? stdenv.hostPlatform.qemuArch,
}:

let
  accel =
    if stdenv.isDarwin && targetArch == "aarch64" then
      "-accel hvf"
    else if targetArch == stdenv.hostPlatform.qemuArch then
      "-accel kvm"
    else
      "";

  qemuParams = {
    x86_64 = ''
      --machine q35 ${accel} \
      -bios "${OVMF.fd}/FV/OVMF.fd" \
      -hda "$image" \
    '';
    aarch64 = ''
      -machine virt ${accel} -cpu max \
      -drive if=pflash,format=raw,file="$qemuFiles"/efi,readonly=on \
      -drive if=pflash,format=raw,file="$qemuFiles"/vars \
      -drive if=none,file="$image",id=hd,snapshot=on \
      -device virtio-blk-device,drive=hd \
      -device VGA \
    '';
  };
in

writeShellApplication {
  name = "run-image";

  runtimeInputs = [ qemu ];

  text = ''
    set -euo pipefail

    image=$1
    shift;

    ${lib.optionalString (targetArch == "aarch64") ''
      qemuFiles="$(mktemp -d)"
      trap 'rm -rf -- "$qemuFiles"' EXIT

      install -m755 ${OVMF.fd}/FV/QEMU_EFI.fd "$qemuFiles"/efi
      install -m755 ${OVMF.fd}/FV/QEMU_VARS.fd "$qemuFiles"/vars
      truncate -s 64M "$qemuFiles"/*
    ''}

    qemu-system-${targetArch} \
      ${
        qemuParams.${targetArch} or (builtins.throw "Supported platforms right now: x86_64 and aarch64")
      } \
      -smp 4 \
      -m 2048 \
      -snapshot \
      -serial mon:stdio \
      -display gtk \
      -device qemu-xhci -device usb-tablet -device usb-kbd \
      "$@"
  '';
}
