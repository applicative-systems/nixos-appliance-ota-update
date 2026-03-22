{
  config,
  pkgs,
  ...
}:

let
  inherit (config.system) build;
  inherit (config.system.image) version id;
in

{
  config.system.build.rugix-bundle =
    pkgs.runCommand "rugix-bundle-${version}"
      {
        nativeBuildInputs = [ pkgs.buildPackages.rugix-bundler ];
      }
      ''
        mkdir -p bundle/payloads

        cat > bundle/rugix-bundle.toml << 'TOML'
        update-type = "full"

        [[payloads]]
        filename = "system.img"
        [payloads.delivery]
        type = "slot"
        slot = "system"

        [[payloads]]
        filename = "boot.efi"
        [payloads.delivery]
        type = "slot"
        slot = "boot"
        TOML

        cp ${build.image}/${id}_${version}.nix-store.raw bundle/payloads/system.img
        cp ${build.uki}/${config.system.boot.loader.ukiFile} bundle/payloads/boot.efi

        mkdir -p $out
        rugix-bundler bundle bundle $out/update.rugixb
      '';
}
