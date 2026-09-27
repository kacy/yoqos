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
- uefi, with the esp mounted at `/efi`, `/boot/efi`, or `/boot`
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

every `os apply`, `add`, `remove`, `enable`, `disable`, or `update` that
changes the machine records the result as the next generation, with what
made it:

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

when the esp is `/boot`, as archinstall sets it up, the kernel and
initramfs live on the esp, outside every root. so each generation keeps
copies of its own in its root's `/boot` directory, under the esp's mount,
where grub can read them. the top entry boots from the esp itself, so a
kernel that `pacman` installs directly is the one it boots. going back to
an older generation puts that generation's kernel back on the esp.

## going back

```
$ sudo os rollback
generation 2 (2026-09-26 · add tree) becomes generation 4, and the next boot runs it.
/var and /home stay as they are.

roll back? [y/N] y
generation 4 is ready. reboot to start it.
```

`os rollback` starts a new generation from the one before the newest, and
`os rollback 2` from generation 2. either way the machine switches at the
next boot, and history only grows: rolling back is a new generation, so
`os rollback` again takes you forward. `--yes` skips the question, and
without a terminal it's needed.

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

## updates that need a reboot

a change that needs a reboot, like a new kernel, systemd, or microcode,
boots once on trial:

```
reboot to finish. the next boot tries generation 5 once; if it doesn't come up healthy, the machine goes back to generation 4.
```

the next boot runs the new generation, and the boot menu's default stays
on the one before. once the machine is up, `yoq-health.service` checks
it: systemd isn't in maintenance or on its way down, the display manager
started if there is one, and every service the config turns on is
running. healthy, and the new
generation becomes the default. not healthy, and it reboots into the
generation before.

a trial boot that hangs without panicking, say on a service that never
finishes starting, gets five minutes. then `yoq-watchdog.timer` reboots
it, and grub picks the generation before.

two changes that need a reboot, applied before rebooting, make one trial:
the next boot tries the newest, and falls back to the generation that last
booted.

if the new generation can't boot at all, grub falls back to the default on
its own, and a kernel panic reboots after 10 seconds into it. either way,
`os` notices on that boot, makes it the newest generation with its config,
and `os status` says what happened:

```
note: generation 7 didn't come up healthy, so this machine went back to generation 6. it's generation 8 now, with its config. `os rollback 7` tries 7 again.
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

- changes happen live. an update changes the running system first, and the
  result becomes a generation afterwards. if an update breaks something,
  the previous generation is one pick away in the boot menu, but the
  session you were in has the broken update. building the next generation
  separately, and booting it once to check it, is planned.
- the health check is simple. it looks at systemd's state, the display
  manager, and the config's services. a network that doesn't come up
  passes unless a service the config turns on needs it, and so does a
  desktop that starts but shows nothing useful.
- state carries at the moment of the rollback. a password you change after
  `os rollback` but before the reboot stays behind. carrying again at
  shutdown is planned.
- an older generation booted from the menu is only for looking around.
  `os apply` refuses there, and anything else you change is thrown away the
  next time `os` writes the menu. `os rollback --to-booted` keeps it for
  real.
- grub only, and only the two root layouts above.

## later

- carrying state again at shutdown, and the uid map for system users
- a network check for configs that declare one
- systemd-boot, limine, and refind
- more root layouts
- building the next generation apart from the running system, so a bad
  update never touches the session you're in
- a clean build of a root from the lock alone, and an installer built on it
