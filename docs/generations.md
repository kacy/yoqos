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
behind, because generation 1 comes from the snapshot. if a step fails, `enable-rollback` takes back the steps before it and says
whether the machine is as it was. grub's files go in last, so until then
the machine boots the way it always did.

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
`/var` and `/home` stay as they are either way, and so does the machine's
own state: every new root, and every copy the menu boots, gets the running
system's passwords, ssh host keys, machine id, clock setting, id ranges,
and pacman keyring. users and everything else in `/etc` are the
generation's own.

## going back

```
$ sudo os rollback
generation 2 (2026-09-26 · add tree) becomes generation 4, and the next boot runs it.
/var and /home stay as they are.
```

`os rollback` starts a new generation from the one before the newest, and
`os rollback 2` from generation 2. either way the machine switches at the
next boot, and history only grows: rolling back is a new generation, so
`os rollback` again takes you forward.

the config goes back with it. `/etc/yoq` lives in `/var/lib/yoq/config`,
outside every generation, and a rollback writes back the config and lock
that generation had, as a new commit. its history stays whole.

if you booted an older generation from the menu and want to stay there,
`os rollback --to-booted` makes it the newest generation.

`os history` lists the generations, with a `*` on the one running:

```
    1  2026-09-26  enable-rollback
    2  2026-09-26  add tree
*   3  2026-09-26  rollback to 1: enable-rollback
```

## keeping and cleaning up

after each new generation, `os` keeps the newest five, generation 1, and
any you pin, and removes the rest: their records, snapshots, boot copies,
and any writable root nothing else uses. it says which ones went.

```
os pin 3             # keep generation 3 however old it gets
os pin --remove 3    # stop keeping it
os gc --keep 2       # clean up now, keeping the newest two
```

`os history` marks pinned generations.

## what this doesn't do yet

- **changes happen live.** an update changes the running system first, and
  the result becomes a generation afterwards. if an update breaks
  something, the previous generation is one pick away in the boot menu, but
  the session you were in has the broken update. building the next
  generation separately, and booting it once to check it, is planned.
- **no automatic fallback.** a generation that doesn't boot doesn't send
  you back to the one before on its own. you pick it in the menu.
- **state carries at the moment of the rollback.** a password you change
  after `os rollback` but before the reboot stays behind. carrying again at
  shutdown is planned.
- **a looked-at copy doesn't last.** changes you make while running an
  older generation's copy are thrown away the next time `os` writes the
  menu.
- **grub only**, and only the two root layouts above.

## later

- carrying state again at shutdown, and the uid map for system users
- automatic fallback: a new generation boots once, and falls back if its
  health check fails
- systemd-boot, limine, and refind
- more root layouts
- building the next generation apart from the running system, so a bad
  update never touches the session you're in
- a clean build of a root from the lock alone, and an installer built on it
