{
  pkgs,
  config,
  lib,
  ...
}:

{
  systemd.sysupdate = {
    enable = true;

    transfers =
      let
        commonSource = {
          Path = "http://localhost/";
          Type = "url-file";
        };

        # Downloaded images need to be verified against a GPG signature by default
        Transfer.Verify = "no";
      in
      {
        "10-nix-store" = {
          Source = commonSource // {
            MatchPattern = [ "${config.system.image.id}_@v.nix-store.raw" ];
          };

          Target = {
            InstancesMax = 2;

            Path = "auto";
            MatchPattern = "nix-store_@v";
            Type = "partition";
            ReadOnly = "yes";
          };

          inherit Transfer;
        };

        "20-boot-image" = {
          Source = commonSource // {
            MatchPattern = [ "${config.boot.uki.name}_@v.efi" ];
          };
          Target = {
            InstancesMax = 2;
            MatchPattern = [ "${config.boot.uki.name}_@v.efi" ];

            Mode = "0444";
            Path = "/EFI/Linux";
            PathRelativeTo = "boot";

            Type = "regular-file";
          };
          inherit Transfer;
        };
      };
  };

  environment.systemPackages = [
    # this is only for running `systemd-sysupdate vacuum -m 1` becasue
    # `updatectl vacuum` does not support the parameter `-m 1`
    (pkgs.runCommand "systemd-extratools" { } ''
      mkdir -p $out
      ln -s ${config.systemd.package}/lib/systemd $out/bin
    '')
  ];
}
