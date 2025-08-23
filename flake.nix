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
      appliance = lib.makeOverridable (
        {
          hostPlatform,
          buildPlatform,
          version,
          extraModules ? [ ],
        }:
        import (inputs.nixpkgs + "/nixos") {
          configuration = {
            imports = [ ./system-configuration/configuration.nix ] ++ extraModules;
            system.image.version = builtins.toString version;
            nixpkgs = { inherit buildPlatform hostPlatform; };
          };
          system = null;
        }
      );
    in
    {
      packages = forEachSystem (
        system: pkgs:
        let
          # all these images build on macOS, too.
          # macOS however needs linux-builder setup:
          # https://nixcademy.com/posts/macos-linux-builder/
          linuxSystem = toLinux system;
          defaultImage = appliance {
            buildPlatform = linuxSystem;
            hostPlatform = linuxSystem;
            version = 1;
          };
          defaultImage2 = defaultImage.override { version = 2; };
          image = p: p.config.system.build.image;
          sysupdate-package = p: p.config.system.build.sysupdate-package;
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
          image-v1-x86_64 = image (defaultImage.override { hostPlatform = "x86_64-linux"; });
          image-v1-aarch64 = image (defaultImage.override { hostPlatform = "aarch64-linux"; });

          update-v2 = sysupdate-package defaultImage2;
          update-v2-x86_64 = sysupdate-package (defaultImage2.override { hostPlatform = "x86_64-linux"; });
          update-v2-aarch64 = sysupdate-package (defaultImage2.override { hostPlatform = "aarch64-linux"; });
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
                  appl = appliance {
                    buildPlatform = toLinux system;
                    hostPlatform = demoSystem;
                    version = 1;
                    extraModules = [
                      {
                        services.lighttpd = {
                          enable = true;
                          document-root = inputs.self.packages.${system}.update-v2;
                        };
                      }
                    ];
                  };

                in
                builtins.toString (
                  pkgs.writeShellScript "vm-demo" ''
                    ${
                      run-image.override {
                        targetArch = arch;
                        inherit OVMF;
                      }
                    }/bin/run-image \
                      ${appl.config.system.build.image}/appliance_1.raw
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

      # this only exists for running `nixos-rebuild build-vm --flake .#appliance`
      # and for running `nix-store -q -R $(nix build .#appliance --print-out-paths)`
      # not for demo purposes
      nixosConfigurations.appliance = inputs.nixpkgs.lib.nixosSystem {
        modules = [
          ./system-configuration/configuration.nix
          {
            system.image.version = "1";
            nixpkgs.hostPlatform = "x86_64-linux";
          }
        ];
      };


    };
}
