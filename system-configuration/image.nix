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

  # How to mount everything
  fileSystems =
    let
      configForLabel =
        _: label:
        let
          inherit (config.image.repart.partitions.${label}) repartConfig;
        in
        {
          device = "/dev/disk/by-partlabel/${repartConfig.Label}";
          fsType = repartConfig.Format;
        };
    in
    builtins.mapAttrs configForLabel {
      "/" = "root";
      "/boot" = "esp";
      "/nix/store" = "nix-store";
    };

  system.image.id = "appliance";
  system.nixos.distroName = "NixcademyOS";

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

            "/EFI/Linux/${config.system.boot.loader.ukiFile}".source =
              "${config.system.build.uki}/${config.system.boot.loader.ukiFile}";

            # Optional but we don't see the system selection w/o timeout
            "/loader/loader.conf".source = builtins.toFile "loader.conf" ''
              timeout 20
            '';
          };
          repartConfig = {
            Type = "esp";
            Label = "boot";
            Format = "vfat";
            SizeMinBytes = "200M";
            SplitName = "-";
          };
        };
        nix-store = {
          storePaths = [ config.system.build.toplevel ];
          stripNixStorePrefix = true;
          repartConfig = {
            Type = "linux-generic";
            Label = "nix-store_${config.system.image.version}";
            Minimize = "off";
            SizeMinBytes = size;
            SizeMaxBytes = size;
            Format = "squashfs";
            ReadOnly = "yes";
            SplitName = "nix-store";
          };
        };

        empty.repartConfig = {
          Type = "linux-generic";
          Label = "_empty";
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
