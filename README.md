# NixOS Appliance Images with Rugix A/B Over-the-Air (OTA) Updates

This repository demonstrates building NixOS appliance images with atomic A/B
over-the-air updates powered by [Rugix](https://rugix.org/):

- Creating bootable NixOS images with [systemd-repart](https://www.freedesktop.org/software/systemd/man/systemd-repart.html) and [systemd-boot](https://www.freedesktop.org/software/systemd/man/systemd-boot.html) (UKI)
- Atomic A/B system updates with [Rugix](https://rugix.org/) including automatic rollback
- Full and delta update bundles (delta updates can be up to 90% smaller)
- Dynamic nix-store partition selection via EFI variables
- Minimizing a NixOS system (with minimal desktop to ~350MB)
- Cross-compiling NixOS from x86_64 to aarch64 and the other way around

## Architecture

The system uses an A/B partition scheme with group-agnostic UKIs:

| Partition | Label       | Format     | Purpose                                            |
| --------- | ----------- | ---------- | -------------------------------------------------- |
| 1         | boot        | vfat (ESP) | systemd-boot + UKIs (`nixos-a.efi`, `nixos-b.efi`) |
| 2         | nix-store-a | squashfs   | NixOS store slot A                                 |
| 3         | nix-store-b | squashfs   | NixOS store slot B                                 |
| 4         | root        | ext4       | Persistent root filesystem                         |

**Boot flow:** systemd-boot selects a UKI. A systemd generator in the initrd
reads the `LoaderEntrySelected` EFI variable to determine which group booted,
then mounts the corresponding nix-store partition. This makes UKIs
group-agnostic — a single update bundle works for either slot.

**Update flow:** Rugix uses the `systemd-boot` boot flow which manages boot
entries via atomic EFI variable writes (`bootctl set-oneshot` for try-next,
`bootctl set-default` for commit). Failed boots automatically revert to the
previous default.

## Run the demo

You can run the demo VM which updates itself through a full A/B cycle:

```console
nix run
```

In the VM, you can run the following commands:

```console
# Show Rugix system info (active group, default group, slots)
rugix-ctrl system info

# Install an update from the built-in HTTP server
rugix-ctrl update install http://localhost/update.rugixb \
  --insecure-skip-bundle-verification --reboot yes

# After rebooting, commit the new group as the default
rugix-ctrl system commit

# Show partition layout
parted -l
```

## Run the automated test

The test exercises a complete A/B cycle with three boots:

1. Boot v1 (group a) → install v2 full update → reboot
2. Boot v2 (group b) → commit → install v3 delta update → reboot
3. Boot v3 (group a) → commit → verify

```console
nix run .#test-vm
```

Example output:

```
v2 full bundle:    2.1G
v3 full bundle:    2.1G
v3 delta bundle:   37M
```

## Run the demo for other architectures

These demos will run on x86_64 and aarch64 host systems:

```console
nix run .#vm-demo-aarch64
nix run .#vm-demo-x86_64
```

Please note that emulating the other platform is slower than running the demo on the same platform.

## Just build the images

### Full system image

Build the image as it could be copied to a disk using `dd`:

```console
# for the same platform
nix build .#image-v1

# for other platforms
nix build .#image-v1-aarch64
nix build .#image-v1-x86_64
```

### Update bundles

Build the Rugix update bundles:

```console
# v2 full update bundle
nix build .#update-v2

# v3 full update bundle
nix build .#update-v3

# v3 delta update bundle (v2 → v3, much smaller)
nix build .#update-v3-delta
```

## Understanding the code

### Describing NixOS appliance images and updates

For this part, ignore `flake.nix`, it is mostly relevant for cross compilation.

#### [`system-configuration/configuration.nix`](./system-configuration/configuration.nix)

Top-level system configuration.
The idea here is that the settings in the top-level configuration file are very much
application specific, while other important modules are platform specific.

#### [`system-configuration/image.nix`](./system-configuration/image.nix)

Definition of the systemd-repart image and the boot process. Defines:

- The A/B partition layout (ESP, nix-store-a, nix-store-b, root)
- A systemd generator in the initrd that reads the `LoaderEntrySelected` EFI variable
  and dynamically mounts the correct nix-store partition
- The squashfs kernel module and initrd tools needed for the mount

#### [`system-configuration/update.nix`](./system-configuration/update.nix)

Rugix configuration. Defines:

- `/etc/rugix/system.toml` with the `systemd-boot` boot flow, slots, and boot groups
- Installs `rugix-ctrl` on the system

#### [`system-configuration/update-package.nix`](./system-configuration/update-package.nix)

Creates Rugix update bundles (`.rugixb` files) containing the squashfs nix-store
image and the UKI as payloads.

#### [`system-configuration/desktop.nix`](./system-configuration/desktop.nix)

Minimal desktop setup with auto login and automatic X start.

#### [`system-configuration/size-reduction.nix`](./system-configuration/size-reduction.nix)

General size reduction for NixOS appliance images without Nix, Perl, etc.
(Might be too minimal for production systems.)

#### [`test-vm.nix`](./test-vm.nix)

Automated VM test that boots the appliance in QEMU, installs updates,
reboots, and verifies the full A/B lifecycle.

### Cross compilation and demo scripts

These are described in [`flake.nix`](./flake.nix).
The majority of its complexity stems from setting up the NixOS configuration for cross compilation and later running the images in Qemu.

In general, NixOS systems can be set up for cross compilation inside the NixOS configuration.

This example snippet would be part of a bigger NixOS configuration that runs on ARM CPUs and builds on Intel/AMD CPUs:

```nix
{
  nixpkgs = {
    buildPlatform = "x86_64-linux";
    hostPlatform = "aarch64-linux";
  };
}
```

Other platforms like e.g. `riscv64-linux` are possible, too.
Please note that not all but many packages from nixpkgs cross-compile.

## References

### Rugix

- https://rugix.org/
- https://github.com/rugix/rugix

### systemd Documentation

- https://www.freedesktop.org/software/systemd/man/latest/systemd-repart.html
- https://www.freedesktop.org/software/systemd/man/latest/repart.d.html
- https://www.freedesktop.org/software/systemd/man/latest/systemd-boot.html
- https://www.freedesktop.org/software/systemd/man/latest/bootctl.html

### Existing NixOS integration tests

- https://github.com/NixOS/nixpkgs/blob/master/nixos/tests/appliance-repart-image-verity-store.nix
- https://github.com/NixOS/nixpkgs/blob/master/nixos/tests/appliance-repart-image.nix

## Consulting

Would you like help, a potential analysis for your products, or training for your team?
Contact us, we do this every day for many organizations worldwide: hello@nixcademy.com
