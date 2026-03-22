# most of the complexity in this file is only to support cross compilation,
# running the demo on macOS, etc.
# To learn how to build appliance images and use Rugix for A/B OTA updates,
# look into ./system-configuration/
{
  description = "NixOS A/B appliance image with Rugix OTA updates";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    rugix-src = {
      url = "git+file:../rugix";
      flake = false;
    };
  };

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
      rugix-bundle = p: p.config.system.build.rugix-bundle;

      # Overlay that provides the rugix package (rugix-ctrl and rugix-bundler
      # binaries) built from source.
      rugixOverlay = final: _prev: {
        rugix = final.rustPlatform.buildRustPackage {
          name = "rugix";
          src = inputs.rugix-src;
          cargoLock = {
            lockFile = "${inputs.rugix-src}/Cargo.lock";
            allowBuiltinFetchGit = true;
          };
          nativeBuildInputs = [ final.pkg-config ];
          buildInputs = [ final.xz ];
          doCheck = false;
        };
      };
    in
    {
      packages = forEachSystem (
        system: pkgs:
        let
          # all these images build on macOS, too.
          # macOS however needs linux-builder setup:
          # https://nixcademy.com/posts/macos-linux-builder/
          linuxSystem = toLinux system;
          defaultImage = extendConfiguration inputs.self.nixosConfigurations.appliance (
            { lib, ... }:
            {
              nixpkgs = {
                buildPlatform = lib.mkDefault linuxSystem;
                hostPlatform = lib.mkDefault linuxSystem;
              };
              system.image.version = lib.mkDefault "1";
            }
          );
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
          image-v1-x86_64 = image (
            extendConfiguration defaultImage {
              nixpkgs.hostPlatform = "x86_64-linux";
            }
          );
          image-v1-aarch64 = image (
            extendConfiguration defaultImage {
              nixpkgs.hostPlatform = "aarch64-linux";
            }
          );

          update-v2 = rugix-bundle defaultImage2;
          update-v2-x86_64 = rugix-bundle (
            extendConfiguration defaultImage2 {
              nixpkgs.hostPlatform = "x86_64-linux";
            }
          );
          update-v2-aarch64 = rugix-bundle (
            extendConfiguration defaultImage2 {
              nixpkgs.hostPlatform = "aarch64-linux";
            }
          );
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
        let
          # Automated headless test for the Rugix A/B update flow.
          # Builds the demo image, boots it in QEMU, and runs the full lifecycle.
          test-vm =
            let
              demoSystem = "${pkgs.stdenv.hostPlatform.qemuArch}-linux";
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
            {
              type = "app";
              program =
                builtins.toString (
                  pkgs.callPackage ./test-vm.nix {
                    image = image appl;
                    OVMF = inputs.nixpkgs.legacyPackages.${demoSystem}.OVMF;
                  }
                )
                + "/bin/test-vm";
            };
        in
        {
          inherit test-vm;
          default = inputs.self.apps.${system}."vm-demo-${pkgs.stdenv.hostPlatform.qemuArch}";
          vm-demo-x86_64 = vm-demo "x86_64";
          vm-demo-aarch64 = vm-demo "aarch64";
        }
      );

      # debug image size on this as shown in:
      # https://nixcademy.com/posts/minimizing-nixos-images/
      nixosConfigurations.appliance = inputs.nixpkgs.lib.nixosSystem {
        modules = [
          ./system-configuration/configuration.nix
          { nixpkgs.overlays = [ rugixOverlay ]; }
        ];
      };
    };
}
