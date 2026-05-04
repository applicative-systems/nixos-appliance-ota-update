# most of the complexity in this file is only to support cross compilation,
# running the demo on macOS, etc.
# To learn how to build appliance images and use Rugix for A/B OTA updates,
# look into ./system-configuration/
{
  description = "NixOS A/B appliance image with Rugix OTA updates";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    rugix.url = "github:rugix/rugix";

    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
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

      rugixOverlay = inputs.rugix.overlays.default;

      treefmtEval =
        pkgs:
        inputs.treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";
          programs = {
            deadnix.enable = true;
            nixfmt.enable = true;
            prettier.enable = true;
            shfmt.enable = true;
            statix.enable = true;
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
          # v3: plain system, used as the final update target.
          defaultImage3 = extendConfiguration defaultImage {
            system.image.version = "3";
          };

          # Delta bundle from v2 → v3 (computed from both full bundles).
          v2-full-bundle = rugix-bundle (
            extendConfiguration defaultImage {
              system.image.version = "2";
            }
          );
          v3-full-bundle = rugix-bundle defaultImage3;
          v3-delta-bundle =
            pkgs.runCommand "rugix-delta-v2-v3"
              {
                nativeBuildInputs = [ inputs.rugix.packages.${linuxSystem}.rugix-bundler ];
              }
              ''
                mkdir -p $out
                rugix-bundler delta \
                  ${v2-full-bundle}/update.rugixb \
                  ${v3-full-bundle}/update.rugixb \
                  $out/update.rugixb
              '';

          # v2: serves the v3 delta bundle via lighttpd.
          defaultImage2 = extendConfiguration defaultImage {
            system.image.version = "2";
            services.lighttpd = {
              enable = true;
              document-root = v3-delta-bundle;
            };
          };

          # Test variants: same appliance, plus SSH + headless boot, so the
          # NixOS integration test can drive `rugix-ctrl` over the network.
          testImage = extendConfiguration defaultImage ./system-configuration/test-extras.nix;
          testImage3 = extendConfiguration testImage {
            system.image.version = "3";
          };
          testImage2 = extendConfiguration testImage {
            system.image.version = "2";
          };
          v2-full-bundle-test = rugix-bundle testImage2;
          v3-full-bundle-test = rugix-bundle testImage3;
          v3-delta-bundle-test =
            pkgs.runCommand "rugix-delta-v2-v3-test"
              {
                nativeBuildInputs = [ inputs.rugix.packages.${linuxSystem}.rugix-bundler ];
              }
              ''
                mkdir -p $out
                rugix-bundler delta \
                  ${v2-full-bundle-test}/update.rugixb \
                  ${v3-full-bundle-test}/update.rugixb \
                  $out/update.rugixb
              '';

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

          update-v3 = rugix-bundle defaultImage3;
          update-v3-delta = v3-delta-bundle;

          image-test = image testImage;
          update-v2-test = v2-full-bundle-test;
          update-v3-delta-test = v3-delta-bundle-test;
        }
      );

      formatter = forEachSystem (_system: pkgs: (treefmtEval pkgs).config.build.wrapper);

      checks = forEachSystem (
        system: pkgs:
        inputs.self.packages.${system}
        // {
          formatting = (treefmtEval pkgs).config.build.check inputs.self;
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          update-test = pkgs.testers.runNixOSTest (
            import ./tests/update.nix {
              inherit pkgs;
              inherit (inputs.self.packages.${system}) image-test;
              v2-bundle = inputs.self.packages.${system}.update-v2-test;
              v3-delta-bundle = inputs.self.packages.${system}.update-v3-delta-test;
            }
          );
        }
      );

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
                    inherit (inputs.nixpkgs.legacyPackages.${demoSystem}) OVMF;
                    v2-bundle = inputs.self.packages.${system}.update-v2;
                    v3-delta-bundle = inputs.self.packages.${system}.update-v3-delta;
                    v3-full-bundle = inputs.self.packages.${system}.update-v3;
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
