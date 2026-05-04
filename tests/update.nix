{
  pkgs,
  image-test,
  v2-bundle,
  v3-delta-bundle,
  ...
}:

let
  sshOpts = "-i /root/test-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR";

  www = pkgs.runCommand "rugix-www" { } ''
    mkdir -p $out
    ln -s ${v2-bundle}/update.rugixb       $out/update.rugixb
    ln -s ${v3-delta-bundle}/update.rugixb $out/update-delta.rugixb
  '';
in

{
  name = "rugix-ota-update";

  globalTimeout = 1800;

  nodes = {
    server = {
      services.nginx = {
        enable = true;
        virtualHosts."default" = {
          default = true;
          root = www;
        };
      };

      services.dnsmasq = {
        enable = true;
        settings = {
          interface = [ "eth1" ];
          bind-interfaces = true;
          dhcp-range = [ "192.168.1.100,192.168.1.150,12h" ];
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
    import queue

    # The appliance reboots on update install. Default start_all() would pass
    # allow_reboot=False, which adds qemu -no-reboot — a guest-initiated reboot
    # then exits qemu, leaving the dhcp lease but no live VM (looks exactly
    # like "lease present, no route to host"). Start it explicitly.
    appliance.start(allow_reboot=True)
    server.start()

    # Drain whatever has accumulated on the appliance serial port (last_lines
    # is a Queue that the driver fills from qemu's -serial stdio).
    def appliance_console_tail(n=200):
        lines = []
        try:
            while True:
                lines.append(appliance.last_lines.get(block=False))
        except queue.Empty:
            pass
        return "\n".join(lines[-n:])

    server.wait_for_unit("multi-user.target")
    server.wait_for_unit("nginx.service")
    server.wait_for_unit("dnsmasq.service")
    server.wait_for_open_port(80)

    server.succeed("install -m 600 ${./test-key} /root/test-key")

    with subtest("server hosts the v2 and v3-delta bundles"):
        server.succeed("curl -fsSI http://localhost/update.rugixb")
        server.succeed("curl -fsSI http://localhost/update-delta.rugixb")

    def appliance_ip():
        out = server.wait_until_succeeds(
            "awk 'END{print $3}' /var/lib/dnsmasq/dnsmasq.leases "
            "  | grep -E '^192\\.168\\.1\\.'",
            timeout=300,
        ).strip()
        return out

    def ssh(cmd, timeout=120):
        ip = appliance_ip()
        return server.succeed(
            f"ssh ${sshOpts} -o ConnectTimeout=10 root@{ip} -- {cmd}",
            timeout=timeout,
        )

    def wait_ssh(timeout=300):
        import time
        deadline = time.monotonic() + timeout
        attempt = 0
        while time.monotonic() < deadline:
            ip = appliance_ip()
            status, _ = server.execute(
                f"ssh ${sshOpts} -o ConnectTimeout=5 root@{ip} -- true",
                timeout=15,
            )
            if status == 0:
                return ip
            attempt += 1
            if attempt % 6 == 0:
                print(f"--- waiting for appliance ssh (attempt {attempt}) ---")
                print(server.execute("cat /var/lib/dnsmasq/dnsmasq.leases", timeout=5)[1])
                print(server.execute("ip neigh show dev eth1", timeout=5)[1])
                print("--- appliance serial console tail ---")
                print(appliance_console_tail())
            time.sleep(5)
        raise Exception(f"appliance ssh never came up within {timeout}s")

    def reboot_spare():
        ip = appliance_ip()
        # The reboot tears down sshd, so the ssh exits non-zero — ignore.
        server.execute(
            f"ssh ${sshOpts} -o ConnectTimeout=10 -o ServerAliveInterval=2 "
            f"  root@{ip} -- 'rugix-ctrl system reboot --spare' >/dev/null 2>&1",
            timeout=20,
        )
        server.sleep(15)
        wait_ssh()

    def rugix_info():
        return json.loads(ssh("rugix-ctrl system info"))

    with subtest("appliance boots, picks up DHCP, accepts SSH"):
        wait_ssh()

    with subtest("v1 boot: active=a, default=a, nixos-a.efi present"):
        info = rugix_info()
        assert info["boot"]["activeGroup"] == "a", info
        assert info["boot"]["defaultGroup"] == "a", info
        ssh("test -f /boot/EFI/Linux/nixos-a.efi")

    with subtest("install v2 (full bundle) over HTTP from server"):
        ssh(
            "rugix-ctrl update install http://192.168.1.2/update.rugixb "
            "  --insecure-skip-bundle-verification --reboot no",
            timeout=900,
        )
        ssh("test -f /boot/EFI/Linux/nixos-b.efi")
        # Diagnostic: confirm rugix saw the new boot entry before reboot.
        print(ssh("bootctl status 2>&1 | head -40"))

    with subtest("reboot into spare (group b)"):
        reboot_spare()

    with subtest("v2 boot: active=b, nix-store mounted as squashfs"):
        info = rugix_info()
        assert info["boot"]["activeGroup"] == "b", info
        ssh("mount | grep -q squashfs")
        ssh("rugix-ctrl system commit")
        info = rugix_info()
        assert info["boot"]["defaultGroup"] == "b", info

    with subtest("install v3 (delta bundle) over HTTP"):
        ssh(
            "rugix-ctrl update install http://192.168.1.2/update-delta.rugixb "
            "  --insecure-skip-bundle-verification --reboot no",
            timeout=900,
        )

    with subtest("reboot into spare (group a, version 3)"):
        reboot_spare()

    with subtest("v3 boot: active=a, commit promotes default to a"):
        info = rugix_info()
        assert info["boot"]["activeGroup"] == "a", info
        ssh("mount | grep -q squashfs")
        ssh("rugix-ctrl system commit")
        info = rugix_info()
        assert info["boot"]["defaultGroup"] == "a", info
  '';
}
