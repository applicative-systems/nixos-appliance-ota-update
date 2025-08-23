{ modulesPath, lib, ... }:

{
  imports = [
    (modulesPath + "/profiles/minimal.nix")
    (modulesPath + "/profiles/perlless.nix")
  ];

  systemd.sysusers.enable = true;
  services.userborn.enable = lib.mkForce false; # perlless.nix sets this
  system.disableInstallerTools = true;
  programs.nano.enable = false;
  programs.fuse.enable = false;
  security.sudo.enable = false;
}
