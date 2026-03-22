# Automated VM test for the Rugix A/B update flow.
# Usage: nix run .#test-vm
#
# This builds the demo image (v1 with lighttpd serving the v2 update bundle),
# boots it in QEMU, and exercises the full Rugix update lifecycle:
#   1. Verify initial state (group a active)
#   2. Install the update bundle via HTTP
#   3. Verify the update wrote to group b slots
{
  writeShellApplication,
  writeText,
  expect,
  qemu,
  OVMF,
  image,
  ...
}:

let
  testScript = writeText "test-vm.expect" ''
    proc abort {msg} {
      puts stderr "\nFAIL: $msg"
      exit 1
    }

    # Run a shell command that outputs PASS or FAIL, then a unique marker.
    set test_id 0
    proc assert {cmd label} {
      global test_id
      incr test_id
      set m "_DONE_''${test_id}_"
      send "$cmd && echo PASS_$m || echo FAIL_$m\r"
      expect {
        "PASS_$m" {
          puts "✓ $label"
        }
        "FAIL_$m" {
          abort "$label"
        }
        timeout {
          abort "timeout: $label"
        }
      }
      sleep 0.5
    }

    # Run a command, wait for completion marker.
    proc run {cmd} {
      global test_id
      incr test_id
      set m "_DONE_''${test_id}_"
      send "$cmd; echo $m\r"
      expect {
        "$m" { }
        timeout { abort "timeout: $cmd" }
      }
      sleep 0.5
    }

    set timeout 240
    match_max 100000
    log_user 1

    set IMAGE [lindex $argv 0]
    set OVMF [lindex $argv 1]

    spawn qemu-system-x86_64 \
      --machine q35 -accel kvm \
      -bios $OVMF \
      -hda $IMAGE \
      -smp 4 -m 2048 -snapshot \
      -nographic \
      -serial mon:stdio \
      -device qemu-xhci -device usb-tablet -device usb-kbd

    # ── Wait for boot ───────────────────────────────────────────────────
    expect {
      -re "login:" { }
      -re "emergency" { abort "system dropped to emergency mode" }
      timeout { abort "boot timeout (240s)" }
    }
    puts "\n\n✓ System booted"

    sleep 3
    send "\r"
    sleep 3
    send "stty -echo\r"
    sleep 2

    set timeout 20

    # ── Tests ───────────────────────────────────────────────────────────
    assert "rugix-ctrl system info 2>&1 | grep -q activeGroup" \
      "rugix-ctrl system info works"

    assert "mount | grep -q squashfs" \
      "nix-store mounted as squashfs"

    assert "test -f /boot/EFI/Linux/nixos-a.efi" \
      "nixos-a.efi present on ESP"

    assert "grep -q a /boot/rugix/default-group" \
      "default group is a"

    assert "lsblk -o PARTLABEL | grep -q nix-store-a" \
      "nix-store-a partition exists"

    # ── Install the update ──────────────────────────────────────────────
    puts "\nInstalling update bundle..."
    set timeout 300
    # Run the update and capture output (don't assert, just run)
    run "rugix-ctrl update install http://localhost/update.bundle --insecure-skip-bundle-verification --reboot no 2>&1"
    set timeout 20

    # ── Verify update results ───────────────────────────────────────────
    # Debug: check what the update did
    run "ls -la /boot/EFI/Linux/ 2>&1"
    run "ls -la /boot/ 2>&1"
    run "df -h /boot 2>&1"

    assert "test -f /boot/EFI/Linux/nixos-b.efi" \
      "nixos-b.efi installed on ESP"

    assert "rugix-ctrl system info 2>&1 | grep -q activeGroup" \
      "system info still works after update"

    # ── Done ────────────────────────────────────────────────────────────
    puts "\n══════════════════════════════════════"
    puts "  All tests passed!"
    puts "══════════════════════════════════════\n"

    send "\001x"
    sleep 2
    exit 0
  '';
in

writeShellApplication {
  name = "test-vm";

  runtimeInputs = [
    expect
    qemu
  ];

  text = ''
    set -euo pipefail

    IMAGE="${image}/appliance_1.raw"
    OVMF="${OVMF.fd}/FV/OVMF.fd"

    echo "Image: $IMAGE"
    echo "OVMF:  $OVMF"
    echo ""

    expect ${testScript} "$IMAGE" "$OVMF"
  '';
}
