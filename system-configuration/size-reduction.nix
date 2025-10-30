{ modulesPath, lib, ... }:

{
  imports = [
    (modulesPath + "/profiles/minimal.nix")
    (modulesPath + "/profiles/perlless.nix")
  ];

  system.disableInstallerTools = true;
  programs.nano.enable = false;
  programs.fuse.enable = false;
  security.sudo.enable = false;
}
