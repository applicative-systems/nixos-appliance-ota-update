{ lib, pkgs, ... }:
{
  # desktop size reduction
  hardware.graphics.enable = false;
  services.speechd.enable = false;
  services.pipewire.enable = false;
  services.libinput.enable = false;

  xdg.autostart.enable = lib.mkForce false;
  xdg.menus.enable = lib.mkForce false;
  xdg.mime.enable = lib.mkForce false;
  xdg.terminal-exec.enable = false;

  fonts.enableDefaultPackages = false;
  fonts.packages = lib.mkForce [ pkgs.dejavu_fonts ];

  nixpkgs.overlays = [
    (_final: prev: {
      # cheaply patch away these packages as the
      # NixOS modules don't make it easy for us
      xdg-utils = prev.bash;
      feh = prev.bash;
    })
  ];
}
