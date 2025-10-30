{
  config,
  pkgs,
  lib,
  ...
}:

{
  system.stateVersion = config.system.nixos.release;
  networking.hostName = "appliance";

  imports = [
    ./desktop.nix
    ./image.nix
    ./size-reduction.nix
    ./update.nix
    ./update-package.nix
  ];

  boot.plymouth = {
    enable = true;
    logo = ./plymouth.png;
  };

  services.getty.helpLine = ''
    ███╗   ██╗██╗██╗  ██╗ ██████╗ █████╗ ██████╗ ███████╗███╗   ███╗██╗   ██╗
    ████╗  ██║██║╚██╗██╔╝██╔════╝██╔══██╗██╔══██╗██╔════╝████╗ ████║╚██╗ ██╔╝
    ██╔██╗ ██║██║ ╚███╔╝ ██║     ███████║██║  ██║█████╗  ██╔████╔██║ ╚████╔╝
    ██║╚██╗██║██║ ██╔██╗ ██║     ██╔══██║██║  ██║██╔══╝  ██║╚██╔╝██║  ╚██╔╝
    ██║ ╚████║██║██╔╝ ██╗╚██████╗██║  ██║██████╔╝███████╗██║ ╚═╝ ██║   ██║
    ╚═╝  ╚═══╝╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝╚═════╝ ╚══════╝╚═╝     ╚═╝   ╚═╝

          -={ Applicance version ${config.system.image.version} }=-
  '';
  services.getty.autologinUser = "root";
  users.users.root.initialPassword = "";

  environment.systemPackages = [
    pkgs.parted
  ];

  system.image.version = lib.mkDefault "1";
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
