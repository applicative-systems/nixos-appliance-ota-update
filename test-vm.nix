# Automated VM test for the Rugix A/B update flow.
# Usage: nix run .#test-vm
#
# This builds the demo image and exercises the full Rugix update lifecycle:
#   1. Boot v1 (group a) — verify initial state
#   2. Install v2 full update → reboot into group b
#   3. Install v3 delta update → reboot into group a
#   4. Commit group a as default
{
  writeShellApplication,
  writeText,
  expect,
  qemu,
  OVMF,
  image,
  v2-bundle,
  v3-full-bundle,
  v3-delta-bundle,
  ...
}:

let
  testScript = writeText "test-vm.expect" ''
    proc abort {msg} {
      puts stderr "\nFAIL: $msg"
      exit 1
    }

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

    proc wait_for_boot {} {
      set timeout 240
      expect {
        -re "login:" { }
        -re "emergency" { abort "system dropped to emergency mode" }
        timeout { abort "boot timeout (240s)" }
      }
      sleep 3
      send "\r"
      sleep 3
      send "stty -echo\r"
      sleep 2
      set timeout 20
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

    # ── Boot 1: group a (v1) ──────────────────────────────────────────
    puts "\n── Boot 1: group a (version 1) ──"
    wait_for_boot
    puts "✓ System booted"

    assert "rugix-ctrl system info 2>&1 | grep -q activeGroup.*a" \
      "active group is a"

    assert "rugix-ctrl system info 2>&1 | grep -q defaultGroup.*a" \
      "default group is a"

    assert "test -f /boot/EFI/Linux/nixos-a.efi" \
      "nixos-a.efi present on ESP"

    # ── Install v2 (full update) ──────────────────────────────────────
    puts "\n── Installing v2 full update... ──"
    set timeout 300
    run "rugix-ctrl update install http://localhost/update.rugixb --insecure-skip-bundle-verification --reboot no 2>&1"
    set timeout 20
    puts "✓ v2 update installed"

    assert "test -f /boot/EFI/Linux/nixos-b.efi" \
      "nixos-b.efi written to ESP"

    # ── Reboot into group b (v2) ──────────────────────────────────────
    puts "\n── Rebooting into group b... ──"
    run "rugix-ctrl system reboot --spare 2>&1 || reboot 2>&1"

    # ── Boot 2: group b (v2) ──────────────────────────────────────────
    puts "\n── Boot 2: group b (version 2) ──"
    wait_for_boot
    puts "✓ System rebooted"

    assert "rugix-ctrl system info 2>&1 | grep -q activeGroup.*b" \
      "active group is b"

    assert "mount | grep -q squashfs" \
      "nix-store mounted as squashfs"

    run "rugix-ctrl system commit 2>&1"
    puts "✓ Committed group b"

    assert "rugix-ctrl system info 2>&1 | grep -q defaultGroup.*b" \
      "default group is now b"

    # ── Install v3 (delta update) ─────────────────────────────────────
    puts "\n── Installing v3 delta update... ──"
    set timeout 300
    run "rugix-ctrl update install http://localhost/update.rugixb --insecure-skip-bundle-verification --reboot no 2>&1"
    set timeout 20
    puts "✓ v3 delta update installed"

    # ── Reboot into group a (v3) ──────────────────────────────────────
    puts "\n── Rebooting into group a... ──"
    run "rugix-ctrl system reboot --spare 2>&1 || reboot 2>&1"

    # ── Boot 3: group a (v3) ──────────────────────────────────────────
    puts "\n── Boot 3: group a (version 3) ──"
    wait_for_boot
    puts "✓ System rebooted"

    assert "rugix-ctrl system info 2>&1 | grep -q activeGroup.*a" \
      "active group is a again"

    assert "mount | grep -q squashfs" \
      "nix-store mounted as squashfs"

    run "rugix-ctrl system commit 2>&1"
    puts "✓ Committed group a"

    assert "rugix-ctrl system info 2>&1 | grep -q defaultGroup.*a" \
      "default group is now a"

    # ── Done ──────────────────────────────────────────────────────────
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

    V2_SIZE=$(du -sh "${v2-bundle}/update.rugixb" | cut -f1)
    V3_FULL_SIZE=$(du -sh "${v3-full-bundle}/update.rugixb" | cut -f1)
    V3_DELTA_SIZE=$(du -sh "${v3-delta-bundle}/update.rugixb" | cut -f1)

    echo "Image:             $IMAGE"
    echo "v2 full bundle:    $V2_SIZE"
    echo "v3 full bundle:    $V3_FULL_SIZE"
    echo "v3 delta bundle:   $V3_DELTA_SIZE"
    echo ""

    expect ${testScript} "$IMAGE" "$OVMF"
  '';
}
