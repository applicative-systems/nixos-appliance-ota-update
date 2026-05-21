{
  image-test,
  v2-bundle,
  v3-delta-bundle,
  ...
}:

{
  name = "rugix-ota-update";

  globalTimeout = 1800;

  nodes = {
    # `pkgs` here is the server node's own package set, so the
    # `ssh-to-appliance` wrapper is built for the server's platform.
    # Pulling it from a top-level argument would wrongly use the build
    # platform's packages in a cross-compilation scenario.
    server =
      { pkgs, ... }:
      let
        ssh-to-appliance = pkgs.writeShellScriptBin "ssh-to-appliance" ''
          exec ${pkgs.openssh}/bin/ssh \
            -i /root/test-key \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            -o ConnectTimeout=10 \
            root@192.168.1.100 \
            "$@"
        '';
      in
      {
        environment.systemPackages = [ ssh-to-appliance ];

        services.nginx = {
          enable = true;
          virtualHosts."default" = {
            default = true;
            # we're serving essentially the next updates.
            root = pkgs.runCommand "rugix-www" { } ''
              mkdir -p $out
              ln -s ${v2-bundle}/update.rugixb       $out/update.rugixb
              ln -s ${v3-delta-bundle}/update.rugixb $out/update-delta.rugixb
            '';
          };
        };

        # our embedded system assumes DHCP
        services.dnsmasq = {
          enable = true;
          settings = {
            interface = [ "eth1" ];
            bind-interfaces = true;
            dhcp-range = [ "192.168.1.100,192.168.1.150,12h" ];
            # Pin the appliance to a known IP. The NixOS test driver assigns
            # MACs as 52:54:00:12:<net>:<node>; eth0 on the appliance (node 1
            # on the test network) gets 52:54:00:12:01:01.
            dhcp-host = [ "52:54:00:12:01:01,192.168.1.100" ];
            # Resolve `update-server` to the server's IP so the appliance
            # doesn't need to know the address.
            address = [ "/update-server/192.168.1.2" ];
            dhcp-option = [
              "option:router,192.168.1.2"
              "option:dns-server,192.168.1.2"
            ];
            log-dhcp = true;
          };
        };

        networking.firewall.allowedTCPPorts = [
          53
          80
        ];
        networking.firewall.allowedUDPPorts = [
          53
          67
          68
        ];

        virtualisation.diskSize = 4096;
      };

    appliance = {
      # turn off everything with test instrumentation etc. and just boot
      # the image.
      virtualisation.directBoot.enable = false;
      virtualisation.useEFIBoot = true;
      virtualisation.diskImage = null;

      boot.loader.grub.enable = false;
      boot.loader.systemd-boot.enable = false;

      virtualisation.qemu.guestAgent.enable = false;
      virtualisation.memorySize = 2048;
      virtualisation.cores = 2;

      virtualisation.qemu.options = [
        "-drive"
        "file=${image-test}/appliance_1.raw,format=raw,snapshot=on,index=0"
      ];
    };
  };

  testScript = ''
    import json

    # ════════════════════════════════════════════════════════════════════
    # Prologue: a small Python helper library
    #
    # The appliance is a headless production A/B image with no NixOS test
    # instrumentation of its own, so the driver cannot run commands on it
    # directly. Everything below reaches it over SSH *from the server*,
    # which shares the appliance's private DHCP network. These helpers hide
    # that indirection so the real test (further down) reads like English.
    # ════════════════════════════════════════════════════════════════════

    def ssh(command, timeout=120):
        """Run a shell command on the appliance and return its stdout."""
        return server.succeed(f"ssh-to-appliance -- {command}", timeout=timeout)

    def wait_ssh(timeout=300):
        """Block until the appliance accepts SSH logins again."""
        server.wait_until_succeeds("ssh-to-appliance -- true", timeout=timeout)

    def boot_info():
        """Return rugix's view of the A/B groups.

        The "boot" object of `rugix-ctrl system info` carries:
          activeGroup  - the group we are running right now
          defaultGroup - the group the firmware boots normally next time
        """
        return json.loads(ssh("rugix-ctrl system info"))["boot"]

    def install_update(url):
        """Download a bundle and write it into the *inactive* A/B slot.

        `--reboot no` leaves the reboot to us. The bundle is unsigned and
        served over a trusted private network, hence skip-verification.
        """
        ssh(
            f"rugix-ctrl update install {url} "
            "--insecure-skip-bundle-verification --reboot no",
            timeout=900,
        )

    def reboot_into_spare():
        """Reboot once into the freshly-updated 'spare' group.

        rugix arms a *one-shot* systemd-boot entry, so the spare group boots
        exactly once; if it never reaches `system commit`, the firmware falls
        back to the committed default — that is the automatic rollback. SSH
        drops while the appliance reboots, so the command returns non-zero;
        we ignore that and wait for SSH to come back.
        """
        server.execute("ssh-to-appliance -- rugix-ctrl system reboot --spare", timeout=20)
        server.sleep(15)
        wait_ssh()

    def reboot_and_commit(expected_group):
        """Reboot into the spare group, sanity-check it, and make it permanent."""
        reboot_into_spare()
        assert boot_info()["activeGroup"] == expected_group
        ssh("mount | grep -q squashfs")  # the store really is the squashfs slot
        ssh("rugix-ctrl system commit")
        assert boot_info()["defaultGroup"] == expected_group


    # ════════════════════════════════════════════════════════════════════
    # The real test follows here.
    #
    # It walks the full A/B lifecycle, committing after each successful boot:
    #
    #   v1 (group a) --full bundle--> v2 (group b) --delta bundle--> v3 (group a)
    # ════════════════════════════════════════════════════════════════════

    def test_server_hosts_both_bundles():
        with subtest("server hosts the v2 full and v3 delta bundles"):
            server.succeed("curl -fsSI http://localhost/update.rugixb")
            server.succeed("curl -fsSI http://localhost/update-delta.rugixb")

    def test_initial_image_boots_into_group_a():
        with subtest("v1: the initial image boots into group a"):
            wait_ssh()
            info = boot_info()
            assert info["activeGroup"] == "a" and info["defaultGroup"] == "a", info
            ssh("test -f /boot/EFI/Linux/nixos-a.efi")

    def test_full_bundle_switches_to_group_b():
        with subtest("v2: installing the full bundle switches to group b"):
            install_update("http://update-server/update.rugixb")
            ssh("test -f /boot/EFI/Linux/nixos-b.efi")  # spare slot now populated
            reboot_and_commit(expected_group="b")

    def test_delta_bundle_switches_back_to_group_a():
        with subtest("v3: installing the delta bundle switches back to group a"):
            install_update("http://update-server/update-delta.rugixb")
            reboot_and_commit(expected_group="a")


    # ── Bring the VMs up and run the scenario ───────────────────────────
    # allow_reboot=True: the appliance reboots itself during the lifecycle;
    # without it the driver's default -no-reboot would terminate qemu.
    appliance.start(allow_reboot=True)
    server.start()

    server.wait_for_unit("multi-user.target")
    server.wait_for_unit("nginx.service")
    server.wait_for_unit("dnsmasq.service")
    server.wait_for_open_port(80)

    # The SSH helper key only lives in the test's nix store, so push it onto
    # the server — the only machine that talks to the appliance.
    server.succeed("install -m 600 ${./test-key} /root/test-key")

    test_server_hosts_both_bundles()
    test_initial_image_boots_into_group_a()
    test_full_bundle_switches_to_group_b()
    test_delta_bundle_switches_back_to_group_a()
  '';
}
