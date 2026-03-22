{
  pkgs,
  ...
}:

{
  environment.systemPackages = [ pkgs.rugix-ctrl ];

  environment.etc."rugix/system.toml" = {
    text = ''
      [config-partition]
      disabled = true

      [data-partition]
      disabled = true

      [boot-flow]
      type = "systemd-boot"
      [boot-flow.entries]
      a = "nixos-a.efi"
      b = "nixos-b.efi"

      [slots.system-a]
      type = "block"
      partition = 2
      immutable = true

      [slots.system-b]
      type = "block"
      partition = 3
      immutable = true

      [slots.boot-a]
      type = "file"
      path = "/boot/EFI/Linux/nixos-a.efi"

      [slots.boot-b]
      type = "file"
      path = "/boot/EFI/Linux/nixos-b.efi"

      [boot-groups.a]
      slots = { system = "system-a", boot = "boot-a" }

      [boot-groups.b]
      slots = { system = "system-b", boot = "boot-b" }
    '';
  };

}
