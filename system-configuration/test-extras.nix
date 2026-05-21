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

  # --- Test/demo speed-ups (do not affect the production image) ---

  image.repart.partitions = {
    # The real image pads each A/B store partition to 2G for headroom, but
    # the test image is only ~320M. Shrinking the partitions makes the full
    # update bundle (and thus `rugix-ctrl update install`) a few hundred MB
    # instead of 2G, which dominates the test runtime.
    nix-store-a.repartConfig = {
      SizeMinBytes = lib.mkForce "512M";
      SizeMaxBytes = lib.mkForce "512M";
    };
    nix-store-b.repartConfig = {
      SizeMinBytes = lib.mkForce "512M";
      SizeMaxBytes = lib.mkForce "512M";
    };

    # Boot the default/one-shot entry immediately. Once a second UKI exists
    # (after the first update) systemd-boot otherwise sits at its menu for
    # the full 20s timeout on every subsequent boot — ~40s of the test.
    esp.contents."/loader/loader.conf".source = lib.mkForce (
      builtins.toFile "loader.conf" ''
        timeout 0
        default nixos-a.efi
      ''
    );
  };
}
