# spikes

one-off experiments that answer a design question before code depends on
it. they print what happened instead of failing. both below are answered;
the workflow that ran them is gone, and the scripts stay as a record. a new
spike can borrow the vm job in `.github/workflows/ci.yml`.

## grub one-shot boot on a btrfs root (2026-09-26)

`tests/vm/spikes/grub-oneshot.sh`, on arch's cloud image: uefi, grub 2.14,
root and `/boot` on btrfs, the esp at `/efi`.

- `grub-reboot` keeps its `next_entry` in `/boot/grub/grubenv`. grub can't
  write that file on btrfs ("sparse file not allowed"), so the entry is
  never cleared: the "one-shot" entry boots every time. a broken
  generation would never fall back. don't use it on btrfs roots.
- an env file on the esp works. a script in `/etc/grub.d` loads
  `yoq_next` from `(esp)/yoq/grubenv`, boots it, and clears it with
  `save_env`. grub writes fat fine: the entry booted once, and the next
  boot was the default again.
- `/efi` may be an automount. `findmnt` lists the autofs mount first,
  without a uuid.

what shipped goes one step further: grub's files are reinstalled onto the
esp and `os` writes the whole `grub.cfg` there, with the env file beside
it, so no `/etc/grub.d` script is needed (`src/menu.zig`).

## packages into an alternate root (2026-09-26)

`tests/spikes/alt-root.sh`: `os apply` of 21 packages, 481 with
dependencies, 4.4 gb, into an empty root, in about 40 seconds.

- as a plain chroot, packages and most scripts work, and sysusers creates
  the system users. but `/boot` stays empty: mkinitcpio's hook needs
  `/proc`, `/sys`, and `/dev`.
- with `/proc`, `/sys`, `/dev`, and `/run` bind-mounted, as pacstrap does,
  the kernel and initramfs land in `/boot`. mkinitcpio's autodetect still
  can't find the root filesystem, because it looks at the host.
- in both, one package's install script trips over an arithmetic error,
  and systemd skips its "running in chroot" steps as designed.

what shipped: every root `os` builds into gets the api filesystems mounted
the way pacstrap mounts them, for a staged generation, a clean build, and
an install alike (`src/cmd/build.zig`). a clean build or an install leaves
autodetect out of its first initramfs. a staged root is a snapshot of the
running one, mounted as itself, so autodetect finds the right root there.
a clean build is seeded with the id map before any package installs, and
the system accounts packages make are carried into every new root
(`src/accounts.zig`).
