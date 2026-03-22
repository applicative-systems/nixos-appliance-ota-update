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

      rugix-ctrl system info          Show system info
      rugix-ctrl update install URL   Install update from URL
      rugix-ctrl system commit        Commit current boot group
      parted -l                       Show partition layout
  '';
  services.getty.autologinUser = "root";
  users.users.root.initialPassword = "";

  environment.systemPackages = [
    pkgs.parted
  ];

  system.image.version = lib.mkDefault "1";
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
