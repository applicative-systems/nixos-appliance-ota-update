{
  modulesPath,
  pkgs,
  config,
  lib,
  ...
}:

{
  imports = [
    (modulesPath + "/image/repart.nix")
    (modulesPath + "/profiles/image-based-appliance.nix")
  ];

  # Mount root and boot statically. The nix-store is mounted dynamically
  # by a custom initrd service based on the selected boot entry.
  fileSystems = {
    "/" = {
      device = "/dev/disk/by-partlabel/root";
      fsType = "ext4";
    };
    "/boot" = {
      device = "/dev/disk/by-partlabel/boot";
      fsType = "vfat";
    };
  };

  # squashfs module is needed in the initrd for the nix-store partition.
  # (Normally NixOS auto-includes it when squashfs is in fileSystems.)
  boot.initrd.kernelModules = [ "squashfs" ];

  # Ensure dd and tr are available in the initrd for the generator.
  boot.initrd.systemd.extraBin = {
    dd = "${pkgs.coreutils}/bin/dd";
    tr = "${pkgs.coreutils}/bin/tr";
  };

  # Dynamic nix-store mount via a systemd generator.
  # The generator reads the LoaderEntrySelected EFI variable (set by
  # systemd-boot) to determine which A/B group was booted, then creates
  # a mount unit for the corresponding nix-store partition.
  boot.initrd.systemd.contents."/etc/systemd/system-generators/mount-nix-store" = {
    source = pkgs.writeScript "mount-nix-store-generator" ''
      #!/bin/sh
      NORMAL_DIR="$1"

      EFI_VAR="/sys/firmware/efi/efivars/LoaderEntrySelected-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"
      GROUP="a"
      if [ -f "$EFI_VAR" ]; then
        ENTRY=$(dd if="$EFI_VAR" bs=1 skip=4 2>/dev/null | tr -d '\0')
        case "$ENTRY" in
          nixos-b.efi) GROUP="b" ;;
        esac
      fi

      cat > "$NORMAL_DIR/sysroot-nix-store.mount" << EOF
      [Unit]
      Description=Mount NixOS Store (group $GROUP)
      After=sysroot.mount
      Before=initrd-fs.target

      [Mount]
      What=/dev/disk/by-partlabel/nix-store-$GROUP
      Where=/sysroot/nix/store
      Type=squashfs
      Options=ro
      EOF

      mkdir -p "$NORMAL_DIR/initrd-fs.target.wants"
      ln -s ../sysroot-nix-store.mount "$NORMAL_DIR/initrd-fs.target.wants/"
    '';
  };

  # Enable serial console for headless/QEMU testing.
  boot.kernelParams = [ "console=ttyS0,115200" ];

  system.image.id = "appliance";
  system.nixos.distroName = "NixcademyOS";

  # Use a fixed UKI filename (no version suffix) so it's group-agnostic.
  system.boot.loader.ukiFile = lib.mkForce "nixos.efi";

  # Image description. This is not used at boot.
  image.repart =
    let
      inherit (pkgs.stdenv.hostPlatform) efiArch;
      size = "2G";
    in
    {
      name = config.system.image.id;
      split = true;

      partitions = {
        esp = {
          contents = {
            "/EFI/BOOT/BOOT${lib.toUpper efiArch}.EFI".source =
              "${pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";

            # Initial image installs the UKI as nixos-a.efi (group A).
            "/EFI/Linux/nixos-a.efi".source = "${config.system.build.uki}/${config.system.boot.loader.ukiFile}";

            "/loader/loader.conf".source = builtins.toFile "loader.conf" ''
              timeout 20
              default nixos-a.efi
            '';

            # Boot flow controller state: default group is "a".
            "/rugix/default-group".source = builtins.toFile "default-group" "a";
          };
          repartConfig = {
            Type = "esp";
            Label = "boot";
            Format = "vfat";
            SizeMinBytes = "200M";
            SplitName = "-";
          };
        };

        nix-store-a = {
          storePaths = [ config.system.build.toplevel ];
          stripNixStorePrefix = true;
          repartConfig = {
            Type = "linux-generic";
            Label = "nix-store-a";
            Minimize = "off";
            SizeMinBytes = size;
            SizeMaxBytes = size;
            Format = "squashfs";
            ReadOnly = "yes";
            SplitName = "nix-store";
          };
        };

        nix-store-b.repartConfig = {
          Type = "linux-generic";
          Label = "nix-store-b";
          Minimize = "off";
          SizeMinBytes = size;
          SizeMaxBytes = size;
          SplitName = "-";
        };

        root.repartConfig = {
          Type = "root";
          Format = "ext4";
          Label = "root";
          Minimize = "off";

          SizeMinBytes = "5G";
          SizeMaxBytes = "5G";
          SplitName = "-";
        };
      };
    };
}
