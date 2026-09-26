# generations

on a btrfs root, `os` can keep generations: whole copies of the system that
you can boot from the boot menu. this page covers how they work, what they
don't do yet, and what's planned.

generations are early. try them on a machine you can reinstall.

## turning them on

```
sudo os enable-rollback
```

it checks the machine, shows every step, and asks before doing anything.
it needs:

- a btrfs root, either in the top level of the filesystem (like arch's
  cloud image) or in archinstall's `@` subvolume
- uefi, with the esp mounted at `/efi` or `/boot/efi`
- grub

then it takes one snapshot of the running root and builds generation 1
from it. `/var` becomes a subvolume of its own, the pacman database moves
into `/usr/lib/sysimage/pacman`, and grub gets reinstalled onto the esp
with a menu that `os` keeps. after a reboot, the machine runs generation 1.
the boot menu also keeps the system as it was before, in case you want it.

anything you change between running `enable-rollback` and rebooting is left
behind, because generation 1 comes from the snapshot.

## how they work

everything lives in the btrfs top level:

| path | what it is |
| --- | --- |
| `@roots/<n>` | a writable root. the machine runs one of these |
| `@gens/<n>` | a read-only record of generation n |
| `@roots/boot-<n>` | a fresh writable copy of generation n, for its menu entry |
| `@var` | `/var`, which no generation touches |

every `os apply`, `add`, `remove`, `update`, or `rollback` that changes
the machine records the result as the next generation, with what made it:

```
yoq 3 · 2026-09-27 · update packages to 2026-09-27
yoq 2 · 2026-09-26 · add tree
yoq 1 · 2026-09-26 · enable-rollback
the system before generations
```

the top entry is the system you run. picking an older one in the menu
boots a fresh copy of it, so looking around can't change the record.
`/var` and `/home` stay as they are either way.

## what this doesn't do yet

- **changes happen live.** an update changes the running system first, and
  the result becomes a generation afterwards. if an update breaks
  something, the previous generation is one pick away in the boot menu, but
  the session you were in has the broken update. building the next
  generation separately, and booting it once to check it, is planned.
- **no automatic fallback.** a generation that doesn't boot doesn't send
  you back to the one before on its own. you pick it in the menu.
- **going back takes the menu.** there's no `os rollback --to-booted` yet
  to keep the older generation you booted, and `os rollback <n>` works on
  packages and the config, not the whole root.
- **no carried state.** an older generation boots with its own `/etc`, so
  its passwords, ssh host keys, and machine id are the ones it had then.
  the config in `/etc/yoq` goes back with it too.
- **a looked-at copy doesn't last.** changes you make while running an
  older generation's copy are thrown away the next time `os` writes the
  menu.
- **nothing gets cleaned up.** generations and their copies pile up until
  garbage collection exists.
- **a failed `enable-rollback` isn't undone.** if a step fails, what the
  steps before it made stays in the btrfs top level, and the message says
  so.
- **grub only**, and only the two root layouts above.

## later

- `os rollback <n>` and `os rollback --to-booted` for whole generations
- carried state: passwords, host keys, and the machine id copied into every
  generation, and the config kept outside it
- automatic fallback: a new generation boots once, and falls back if its
  health check fails
- garbage collection, keeping the last few generations and any you pin
- systemd-boot, limine, and refind
- more root layouts, and undoing a failed `enable-rollback`
- building the next generation apart from the running system, so a bad
  update never touches the session you're in
- a clean build of a root from the lock alone, and an installer built on it
