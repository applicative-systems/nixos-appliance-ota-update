{
  config,
  pkgs,
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
}
