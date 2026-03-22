{
  pkgs,
  ...
}:

{
  environment.systemPackages = [ pkgs.rugix ];

  # Rugix system configuration
  environment.etc."rugix/system.toml" = {
    text = ''
      [config-partition]
      path = "/boot"
      protected = false

      [data-partition]
      disabled = true

      [boot-flow]
      type = "custom"
      controller = "/etc/rugix/boot-flow-controller"

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

  # Custom boot flow controller for systemd-boot.
  # Uses bootctl set-oneshot for try-next (auto-reverts on failure)
  # and bootctl set-default for permanent commit.
  environment.etc."rugix/boot-flow-controller" = {
    mode = "0755";
    text = ''
      #!/bin/sh
      STATE_FILE="/boot/rugix/default-group"

      case "$1" in
        get_default)
          GROUP=$(cat "$STATE_FILE" 2>/dev/null || echo "a")
          printf '{"group":"%s"}\n' "$GROUP"
          ;;
        set_try_next)
          bootctl set-oneshot "nixos-$2.efi"
          printf '{}\n'
          ;;
        commit)
          mkdir -p /boot/rugix
          printf "%s" "$2" > "$STATE_FILE"
          bootctl set-default "nixos-$2.efi"
          printf '{}\n'
          ;;
        pre_install|post_install|mark_good|mark_bad)
          printf '{}\n'
          ;;
      esac
    '';
  };

  # Bind-mount /nix/store to /run/rugix/mounts/system so that rugix-ctrl
  # can detect which nix-store partition is the active one by matching
  # the block device against the configured slots.
  systemd.services.rugix-system-mount = {
    description = "Rugix System Mount";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /run/rugix/mounts/system";
      ExecStart = "${pkgs.util-linux}/bin/mount --bind /nix/store /run/rugix/mounts/system";
    };
  };
}
