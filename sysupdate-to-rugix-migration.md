# From systemd-sysupdate to Rugix: migrating a NixOS A/B appliance to delta OTA updates

This is a follow-up to our series on building immutable A/B NixOS appliance
images with [`systemd-sysupdate`][sysupdate-post]. It assumes you have read
those articles and are comfortable with the sysupdate setup: the versioned
`nix-store_@v` partitions, the `systemd.sysupdate.transfers`, and how
`systemd-boot` picks the newest UKI.

[sysupdate-post]: https://nixcademy.com/posts/immutable-ab-system-partitions-with-nixos-for-ota-updates-with-systemd-sysupdate/

We keep almost everything from that setup — `systemd-repart` to build the
image, `systemd-boot` + UKIs to boot it, a read-only squashfs `/nix/store`, a
persistent `ext4` root. We only swap out the _update mechanism_. The reward is
substantial:

- **Delta updates.** Rugix can ship the binary difference between two image
  versions. For a NixOS image where most of the store is unchanged between
  releases, the delta bundle is routinely **up to ~90% smaller** than a full
  image. `systemd-sysupdate` can only ever transfer whole partition images.
- **Transactional install + automatic rollback.** Rugix installs into the
  inactive slot, boots it _once_, and only makes it permanent after an explicit
  commit. A failed boot rolls back to the previous system with no action from
  you.

This document is a migration guide, structured as a diff against the sysupdate
configuration. Each section is "what you had → what you change → why".

---

## 1. The mental model shift

This is the single most important section, and the source of most confusion
when reading the two configurations side by side. The rest of the changes
follow mechanically from it.

### sysupdate: versioned artifacts, "highest version wins"

In the sysupdate world, _everything is versioned and the newest version wins_:

- The store partition is labelled `nix-store_1`, `nix-store_2`, …
- Each image build bakes a UKI whose kernel command line **statically pins its
  own store partition** (the v2 UKI mounts `nix-store_2`, and so on).
- `systemd-sysupdate` downloads a new versioned store partition into a free
  slot and a new versioned UKI into the ESP.
- `systemd-boot` sorts the UKIs by version and boots the highest one. Because
  that UKI already knows which store partition belongs to it, the right store
  is mounted.

There is no concept of "A" and "B" here — there is only "version N" and a free
slot to drop "version N+1" into. Rollback means "an older versioned UKI happens
to still be on the ESP", and cleanup is a manual `systemd-sysupdate vacuum`.

### Rugix: two fixed slots, one group-agnostic image, runtime store selection

Rugix uses a classic **A/B** scheme. There are exactly two slots that never get
renamed: group **a** and group **b**. One is active, the other is the spare.
An update is always written into the spare; a commit swaps which one is the
default.

The crucial consequence — and the part of "his image setup" that looks most
different from yours — is this:

> **The UKI can no longer pin its own store partition.**

Why? Because the _same_ image must be installable into _either_ slot, and
because delta updates patch whatever happens to be in the spare slot. A bundle
that hard-coded "mount `nix-store_2`" could not be applied to slot A. So the
UKI becomes **group-agnostic**: a single `nixos.efi` that contains no reference
to a specific store partition.

If the UKI doesn't know which store to mount, who does? **The initrd decides at
boot time**, by asking systemd-boot which entry it just booted. systemd-boot
records its choice in the `LoaderEntrySelected` EFI variable. A small generator
in the initrd reads that variable and mounts `nix-store-a` or `nix-store-b`
accordingly.

|                  | sysupdate                          | Rugix                                     |
| ---------------- | ---------------------------------- | ----------------------------------------- |
| Slot identity    | versioned (`nix-store_1`, `_2`, …) | fixed (`nix-store-a`, `nix-store-b`)      |
| Free slot        | a single `_empty` placeholder      | the other group, always present           |
| UKI              | version-suffixed, store baked in   | one group-agnostic `nixos.efi`            |
| Boot selection   | systemd-boot picks newest version  | rugix sets the default/oneshot entry      |
| Store selection  | baked into each UKI                | chosen at boot from `LoaderEntrySelected` |
| Update transport | pull versioned files, newest wins  | install a bundle into the spare slot      |
| Rollback         | leftover old UKI, manual vacuum    | automatic on failed boot                  |
| Delta updates    | impossible                         | first-class                               |

Hold this table in mind; everything below is a concrete realization of it.

---

## 2. Image layout (`image.nix`)

### 2.1 Two fixed store partitions instead of "versioned + empty"

**Before (sysupdate):** one versioned store partition plus an `_empty`
placeholder that sysupdate later claims and relabels.

```nix
nix-store = {
  storePaths = [ config.system.build.toplevel ];
  stripNixStorePrefix = true;
  repartConfig = {
    Label = "nix-store_${config.system.image.version}";  # versioned!
    Format = "squashfs";
    # ...
  };
};

empty.repartConfig = {
  Label = "_empty";   # free slot, sysupdate fills + relabels it
  # ...
};
```

**After (Rugix):** two store partitions with stable labels. The initial image
populates slot A; slot B is left empty for the first update to land in.

```nix
nix-store-a = {
  storePaths = [ config.system.build.toplevel ];
  stripNixStorePrefix = true;
  repartConfig = {
    Label = "nix-store-a";   # stable, never renamed
    Format = "squashfs";
    ReadOnly = "yes";
    # ...
  };
};

nix-store-b.repartConfig = {
  Label = "nix-store-b";     # stable spare, filled by the first update
  # ...
};
```

The `root` (ext4) and `esp` partitions are unchanged.

### 2.2 The group-agnostic UKI

We force a fixed, version-less UKI filename so that the bundle is identical no
matter which slot it ends up in:

```nix
# Use a fixed UKI filename (no version suffix) so it's group-agnostic.
system.boot.loader.ukiFile = lib.mkForce "nixos.efi";
```

The initial image installs that one UKI as the group-A entry, and sets
systemd-boot's default to it:

```nix
esp.contents = {
  "/EFI/BOOT/BOOT${lib.toUpper efiArch}.EFI".source =
    "${pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";

  # Initial image installs the UKI as nixos-a.efi (group A).
  "/EFI/Linux/nixos-a.efi".source =
    "${config.system.build.uki}/${config.system.boot.loader.ukiFile}";

  "/loader/loader.conf".source = builtins.toFile "loader.conf" ''
    timeout 20
    default nixos-a.efi
  '';
};
```

Note the asymmetry: the build produces a generic `nixos.efi`, but it is
_installed_ under the group-specific name `nixos-a.efi`. The group-B entry
(`nixos-b.efi`) does not exist yet — the first update creates it. Rugix knows
these two names from its boot-flow configuration (Section 3).

### 2.3 Replacing the static mount with a runtime generator

This is the part that has no counterpart at all in the sysupdate setup, and it
is what makes the group-agnostic UKI possible.

**Before (sysupdate):** `/nix/store` was a normal, statically-declared mount.
The label was version-pinned, so the v2 UKI's initrd mounted `nix-store_2`:

```nix
fileSystems."/nix/store" = {
  device = "/dev/disk/by-partlabel/nix-store_${config.system.image.version}";
  fsType = "squashfs";
};
```

**After (Rugix):** we drop the static `/nix/store` mount and instead generate
it in the initrd, choosing the partition from the EFI variable that
systemd-boot set when it picked an entry:

```nix
# squashfs module + a couple of coreutils are needed in the initrd.
boot.initrd.kernelModules = [ "squashfs" ];
boot.initrd.systemd.extraBin = {
  dd = "${pkgs.coreutils}/bin/dd";
  tr = "${pkgs.coreutils}/bin/tr";
};

boot.initrd.systemd.contents."/etc/systemd/system-generators/mount-nix-store" = {
  source = pkgs.writeScript "mount-nix-store-generator" ''
    #!/bin/sh
    NORMAL_DIR="$1"

    # systemd-boot writes the booted entry into this EFI variable.
    EFI_VAR="/sys/firmware/efi/efivars/LoaderEntrySelected-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"
    GROUP="a"
    if [ -f "$EFI_VAR" ]; then
      # The variable has a 4-byte attribute prefix; skip it, strip NULs.
      ENTRY=$(dd if="$EFI_VAR" bs=1 skip=4 2>/dev/null | tr -d '\0')
      case "$ENTRY" in
        nixos-b.efi) GROUP="b" ;;
      esac
    fi

    cat > "$NORMAL_DIR/sysroot-nix-store.mount" << EOF
    [Unit]
    Description=Mount NixOS Store (group $GROUP)
    After=sysroot.mount
    Before=initrd-fs.target

    [Mount]
    What=/dev/disk/by-partlabel/nix-store-$GROUP
    Where=/sysroot/nix/store
    Type=squashfs
    Options=ro
    EOF

    mkdir -p "$NORMAL_DIR/initrd-fs.target.wants"
    ln -s ../sysroot-nix-store.mount "$NORMAL_DIR/initrd-fs.target.wants/"
  '';
};
```

Read this as the runtime equivalent of the version-pinned label you had before:
instead of _building_ a UKI that knows its store, you ship _one_ UKI that
_asks_ which store at boot.

---

## 3. The update mechanism (`update.nix`)

Here the sysupdate transfers disappear entirely and are replaced by Rugix's
declarative system description plus the `rugix-ctrl` CLI.

**Before (sysupdate):** transfers describing where to pull versioned artifacts
from and which partition / ESP file to drop them into.

```nix
systemd.sysupdate = {
  enable = true;
  transfers."10-nix-store" = {
    Source = { Path = "http://localhost/"; Type = "url-file";
               MatchPattern = [ "${config.system.image.id}_@v.nix-store.raw" ]; };
    Target = { Type = "partition"; MatchPattern = "nix-store_@v";
               InstancesMax = 2; ReadOnly = "yes"; Path = "auto"; };
    Transfer.Verify = "no";
  };
  transfers."20-boot-image" = { /* the versioned UKI */ };
};
```

**After (Rugix):** install the `rugix-ctrl` package and describe the A/B system
in `/etc/rugix/system.toml`.

```nix
{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.rugix-ctrl ];

  environment.etc."rugix/system.toml".text = ''
    # Rugix normally manages its own config/data partitions for state.
    # We let NixOS own the ext4 root instead, so disable both.
    [config-partition]
    disabled = true
    [data-partition]
    disabled = true

    # Boot flow: drive systemd-boot via EFI variables.
    # `a`/`b` are the two UKI filenames in /EFI/Linux.
    [boot-flow]
    type = "systemd-boot"
    [boot-flow.entries]
    a = "nixos-a.efi"
    b = "nixos-b.efi"

    # The squashfs store slots are whole block partitions, read-only.
    [slots.system-a]
    type = "block"
    partition = 2
    immutable = true
    [slots.system-b]
    type = "block"
    partition = 3
    immutable = true

    # The UKIs are plain files on the ESP.
    [slots.boot-a]
    type = "file"
    path = "/boot/EFI/Linux/nixos-a.efi"
    [slots.boot-b]
    type = "file"
    path = "/boot/EFI/Linux/nixos-b.efi"

    # A "group" bundles one system slot and one boot slot together.
    [boot-groups.a]
    slots = { system = "system-a", boot = "boot-a" }
    [boot-groups.b]
    slots = { system = "system-b", boot = "boot-b" }
  '';
}
```

Things worth pointing out for sysupdate veterans:

- **No URL lives in the system config.** With sysupdate, the download source
  (`Path = "http://localhost/"`) is baked into the image. With Rugix you pass
  the bundle URL to `rugix-ctrl update install <URL>` at update time, so the
  same image can be pointed at any server.
- **`config-partition`/`data-partition` disabled.** Rugix is built for embedded
  systems where it also manages a state/config partition. We don't use that —
  NixOS owns the persistent `ext4` root — so both are turned off.
- **The boot-flow is the `systemd-boot` flow.** Rugix manipulates the same EFI
  variables you already rely on: `bootctl set-oneshot` to try the spare once,
  `bootctl set-default` to commit. This is why the firmware's own fallback
  gives you automatic rollback for free.

---

## 4. The update artifact (`update-package.nix`)

**Before (sysupdate):** the "update" was just the raw files plus a checksum
manifest, served over HTTP, that the transfers matched by filename.

```nix
config.system.build.sysupdate-package =
  pkgs.runCommand "sysupdate-package-${version}" { } ''
    mkdir $out
    cp ${build.uki}/${config.system.boot.loader.ukiFile} $out/
    cp ${build.image}/${id}_${version}.nix-store.raw     $out/
    cd $out
    sha256sum * > SHA256SUMS
  '';
```

**After (Rugix):** a single self-describing `.rugixb` bundle whose payloads are
mapped onto the _slots_ declared in `system.toml`. Note "slot" here is the
logical group slot name (`system`, `boot`), not `system-a`/`system-b` — Rugix
resolves it to the spare group at install time.

```nix
config.system.build.rugix-bundle =
  pkgs.runCommand "rugix-bundle-${version}"
    { nativeBuildInputs = [ pkgs.buildPackages.rugix-bundler ]; }
    ''
      mkdir -p bundle/payloads

      cat > bundle/rugix-bundle.toml << 'TOML'
      update-type = "full"

      [[payloads]]
      filename = "system.img"
      [payloads.delivery]
      type = "slot"
      slot = "system"

      [[payloads]]
      filename = "boot.efi"
      [payloads.delivery]
      type = "slot"
      slot = "boot"
      TOML

      cp ${build.image}/${id}_${version}.nix-store.raw bundle/payloads/system.img
      cp ${build.uki}/${config.system.boot.loader.ukiFile} bundle/payloads/boot.efi

      mkdir -p $out
      rugix-bundler bundle bundle $out/update.rugixb
    '';
```

### Delta bundles

This is the payoff. A delta bundle is computed from two _full_ bundles — the
old one the device already has, and the new one you want to ship — entirely at
build time. The device never needs the old image as a file; the delta is
applied against the bytes already present in its active slot.

```nix
# in flake.nix
v3-delta-bundle =
  pkgs.runCommand "rugix-delta-v2-v3"
    { nativeBuildInputs = [ rugix-bundler ]; }
    ''
      mkdir -p $out
      rugix-bundler delta \
        ${v2-full-bundle}/update.rugixb \
        ${v3-full-bundle}/update.rugixb \
        $out/update.rugixb
    '';
```

You publish the full bundle for fresh installs (or large jumps) and small delta
bundles for routine updates. The device installs both with the exact same
command — it figures out from the bundle whether it's full or delta.

---

## 5. The update lifecycle, compared

**Before (sysupdate):** check, download, reboot. The newest version wins; there
is no commit step and no automatic rollback.

```console
updatectl update          # pulls the newest versioned artifacts
reboot                     # systemd-boot picks the highest-version UKI
systemd-sysupdate vacuum   # later: prune old versions by hand
```

**After (Rugix):** install into the spare, boot it _once_, then commit — or let
it roll back.

```console
# 1. Write the bundle into the inactive slot. Nothing else changes yet;
#    the current system is still the default.
rugix-ctrl update install http://my-server/update.rugixb

# 2. Reboot once into the freshly-written spare group. Rugix arms a
#    *one-shot* systemd-boot entry, so if this boot fails the firmware
#    falls back to the old default automatically — that's the rollback.
rugix-ctrl system reboot --spare

# 3. The new system is up and healthy → make it the permanent default.
#    Skip this and the next reboot returns to the old system.
rugix-ctrl system commit
```

`rugix-ctrl system info` reports the two groups you care about:

- `activeGroup` — the group you are running right now.
- `defaultGroup` — the group the firmware will boot normally next time.

A successful update walks `active=a, default=a` → install → `reboot --spare` →
`active=b, default=a` → commit → `active=b, default=b`. If the spare never
commits, the next reboot returns you to `active=a`.

---

## 6. Summary checklist

To migrate an existing sysupdate appliance:

1. **`image.nix`**
   - Replace the versioned `nix-store_@v` + `_empty` partitions with two stable
     `nix-store-a` / `nix-store-b` partitions.
   - Force a single group-agnostic UKI: `system.boot.loader.ukiFile = lib.mkForce "nixos.efi"`.
   - Install it as `nixos-a.efi` and set `default nixos-a.efi` in `loader.conf`.
   - Delete the static `/nix/store` mount; add the initrd generator that mounts
     `nix-store-$GROUP` based on `LoaderEntrySelected`.
2. **`update.nix`**
   - Remove `systemd.sysupdate`.
   - Add `pkgs.rugix-ctrl` and `/etc/rugix/system.toml` (boot-flow, slots,
     boot-groups; config/data partitions disabled).
3. **`update-package.nix`**
   - Replace the raw-files + `SHA256SUMS` package with a `.rugixb` bundle whose
     payloads map onto the `system` and `boot` slots.
   - Add a delta-bundle derivation (`rugix-bundler delta old new out`).
4. **Operations**
   - Replace `updatectl update; reboot` with
     `rugix-ctrl update install <URL>` → `reboot --spare` → `system commit`.

Everything else — `systemd-repart`, `systemd-boot`, the squashfs store, the
ext4 root, cross-compilation, the size-reduction tricks — carries over
unchanged from the sysupdate articles.
