{
  pkgs,
  image-test,
  v2-bundle,
  v3-delta-bundle,
  ...
}:

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
  name = "rugix-ota-update";

  globalTimeout = 1800;

  nodes = {
    server = {
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

    # allow_reboot=True is required because the appliance reboots itself
    # after an update install; the default -no-reboot would terminate qemu.
    appliance.start(allow_reboot=True)
    server.start()

    server.wait_for_unit("multi-user.target")
    server.wait_for_unit("nginx.service")
    server.wait_for_unit("dnsmasq.service")
    server.wait_for_open_port(80)

    server.succeed("install -m 600 ${./test-key} /root/test-key")

    def ssh(cmd, timeout=120):
        return server.succeed(f"ssh-to-appliance -- {cmd}", timeout=timeout)

    def wait_ssh(timeout=300):
        server.wait_until_succeeds("ssh-to-appliance -- true", timeout=timeout)

    def reboot_spare():
        # sshd dies mid-reboot, so this exits non-zero — ignore and wait.
        server.execute("ssh-to-appliance -- rugix-ctrl system reboot --spare", timeout=20)
        server.sleep(15)
        wait_ssh()

    def boot_info():
        return json.loads(ssh("rugix-ctrl system info"))["boot"]

    def install_update(url):
        ssh(
            f"rugix-ctrl update install {url} "
            "  --insecure-skip-bundle-verification --reboot no",
            timeout=900,
        )

    def reboot_and_commit(expect_active):
        reboot_spare()
        assert boot_info()["activeGroup"] == expect_active
        ssh("mount | grep -q squashfs")
        ssh("rugix-ctrl system commit")
        assert boot_info()["defaultGroup"] == expect_active

    with subtest("server hosts the v2 and v3-delta bundles"):
        server.succeed("curl -fsSI http://localhost/update.rugixb")
        server.succeed("curl -fsSI http://localhost/update-delta.rugixb")

    with subtest("v1: appliance boots into group a"):
        wait_ssh()
        info = boot_info()
        assert info["activeGroup"] == "a" and info["defaultGroup"] == "a", info
        ssh("test -f /boot/EFI/Linux/nixos-a.efi")

    with subtest("v2: install full bundle, switch to group b"):
        install_update("http://192.168.1.2/update.rugixb")
        ssh("test -f /boot/EFI/Linux/nixos-b.efi")
        reboot_and_commit(expect_active="b")

    with subtest("v3: install delta bundle, switch to group a"):
        install_update("http://192.168.1.2/update-delta.rugixb")
        reboot_and_commit(expect_active="a")
  '';
}
