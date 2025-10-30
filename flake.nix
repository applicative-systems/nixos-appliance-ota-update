# most of the complexity in this file is only to support cross compilation,
# running the demo on macOS, etc.
# To learn how to build appliance images and use systemd-repart and
# systemd-sysupdate on them, look into ./system-configuration/
{
  description = "NixOS A/B appliance image example";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forEachSystem =
        f:
        builtins.mapAttrs (system: g: g inputs.nixpkgs.legacyPackages.${system}) (lib.genAttrs systems f);

      toLinux = builtins.replaceStrings [ "darwin" ] [ "linux" ];
      extendConfiguration = c: module: c.extendModules { modules = [ module ]; };

      image = p: p.config.system.build.image;
      sysupdate-package = p: p.config.system.build.sysupdate-package;
    in
    {
      packages = forEachSystem (
        system: pkgs:
        let
          # all these images build on macOS, too.
          # macOS however needs linux-builder setup:
          # https://nixcademy.com/posts/macos-linux-builder/
          linuxSystem = toLinux system;
          defaultImage = extendConfiguration inputs.self.nixosConfigurations.appliance ({ lib, ... }: {
            nixpkgs = {
              buildPlatform = lib.mkDefault linuxSystem;
              hostPlatform = lib.mkDefault linuxSystem;
            };
            system.image.version = lib.mkDefault "1";
          });
          defaultImage2 = extendConfiguration defaultImage {
            system.image.version = "2";
          };

        in
        {
          run-image = pkgs.callPackage ./run-image.nix {
            # macOS: Use linux-builder to build OVMF
            OVMF =
              if pkgs.stdenv.isLinux then
                pkgs.OVMF
              else
                (import inputs.nixpkgs { system = toLinux system; }).OVMF;
          };

          image-v1 = image defaultImage;
          image-v1-x86_64 = image (extendConfiguration defaultImage {
            nixpkgs.hostPlatform = "x86_64-linux";
          });
          image-v1-aarch64 = image (extendConfiguration defaultImage {
            nixpkgs.hostPlatform = "aarch64-linux";
          });

          update-v2 = sysupdate-package defaultImage2;
          update-v2-x86_64 = sysupdate-package (extendConfiguration defaultImage2 {
            nixpkgs.hostPlatform = "x86_64-linux";
          });
          update-v2-aarch64 = sysupdate-package (extendConfiguration defaultImage2 {
            nixpkgs.hostPlatform = "aarch64-linux";
          });
        }
      );

      checks = inputs.self.packages;

      apps = forEachSystem (
        system: pkgs:
        let
          inherit (inputs.self.packages.${system}) run-image;

          vm-demo =
            arch:
            let
              demoSystem = "${arch}-linux";
              inherit (inputs.nixpkgs.legacyPackages.${demoSystem}) OVMF;
            in
            {
              type = "app";
              program =
                let
                  appl = extendConfiguration inputs.self.nixosConfigurations.appliance {
                    nixpkgs = {
                      buildPlatform = toLinux system;
                      hostPlatform = demoSystem;
                    };
                    system.image.version = "1";
                    services.lighttpd = {
                      enable = true;
                      document-root = inputs.self.packages.${system}.update-v2;
                    };
                  };

                in
                builtins.toString (
                  pkgs.writeShellScript "vm-demo" ''
                    ${
                      run-image.override {
                        targetArch = arch;
                        inherit OVMF;
                      }
                    }/bin/run-image ${image appl}/appliance_1.raw
                  ''
                );
            };
        in
        {
          default = inputs.self.apps.${system}."vm-demo-${pkgs.stdenv.hostPlatform.qemuArch}";
          vm-demo-x86_64 = vm-demo "x86_64";
          vm-demo-aarch64 = vm-demo "aarch64";
        }
      );

      # debug image size on this as shown in:
      # https://nixcademy.com/posts/minimizing-nixos-images/
      nixosConfigurations.appliance = inputs.nixpkgs.lib.nixosSystem {
        modules = [ ./system-configuration/configuration.nix ];
      };
    };
}
