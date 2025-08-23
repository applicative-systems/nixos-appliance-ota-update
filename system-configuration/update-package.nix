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
  config.system.build.sysupdate-package =
    pkgs.runCommand "sysupdate-package-${config.system.image.version}" { }
      ''
        mkdir $out
        cp ${build.uki}/${config.system.boot.loader.ukiFile} $out/
        cp ${build.image}/${id}_${version}.nix-store.raw $out/
        cd $out
        sha256sum * > SHA256SUMS
      '';
}
