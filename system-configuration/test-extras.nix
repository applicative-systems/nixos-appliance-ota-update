{ lib, ... }:

{
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "yes";
      PasswordAuthentication = false;
    };
  };

  users.users.root.openssh.authorizedKeys.keys = [
    (builtins.readFile ../tests/test-key.pub)
  ];

  services.xserver.enable = lib.mkForce false;
  services.greetd.enable = lib.mkForce false;
  boot.plymouth.enable = lib.mkForce false;
}
