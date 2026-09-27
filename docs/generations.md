# generations

on a btrfs root, `os` can keep generations: whole copies of the system that
you can boot from the boot menu. this page covers how they work, what they
don't do yet, and what's planned.

generations are new. try them on a machine you can reinstall first.

## turning them on

```
sudo os enable-rollback
```

`enable-rollback` checks the machine, lists every step, and asks before it
changes anything. `--yes` skips the question; without a terminal, it's
required. the machine needs:

- a btrfs root, either in the top level of the filesystem (like arch's
  cloud image) or in archinstall's `@` subvolume
- uefi, with the esp mounted at `/efi`, `/boot/efi`, or `/boot`
- grub

it takes one snapshot of the running root and builds generation 1 from it.
`/var`, `/home`, `/root`, `/srv`, and `/usr/local` each become a subvolume
of their own, unless they're mounted separately already. the pacman
database moves into `/usr/lib/sysimage/pacman`, and grub is reinstalled on
the esp with a menu that `os` maintains. after a reboot, the machine runs
generation 1, and the boot menu still offers the system as it was before.

changes you make between running `enable-rollback` and rebooting stay in
the old root, because generation 1 comes from the snapshot. that includes
files in `/home`, so reboot right away. the old root is still in the menu
as "the system before generations" if you need something from it.

if a step fails, `enable-rollback` undoes the steps before it and says
whether the machine is back as it was. grub's files are installed last, so
until then the machine boots the way it always did.

## how they work

everything lives in the btrfs top level:

| path | what it is |
| --- | --- |
| `@roots/<n>` | a writable root; the machine runs one of these |
| `@gens/<n>` | a read-only record of generation n |
| `@roots/boot-<n>` | a fresh writable copy of generation n, for its menu entry |
| `@var`, `@home`, `@root`, `@srv`, `@usrlocal` | data, which no generation holds |

every `os apply`, `add`, `remove`, `enable`, `disable`, or `update` that
changes the machine records the result as the next generation, labeled
with what made it:

```
yoq 3 · 2026-09-27 · update packages to 2026-09-27
yoq 2 · 2026-09-26 · add tree
yoq 1 · 2026-09-26 · enable-rollback
the system before generations
```

the top entry is the system you run. picking an older entry boots a fresh
copy of that generation, so looking around can't change its record. data
directories stay as they are either way, and so does the machine's own
state: every new root, and every copy the menu boots, gets the running
system's passwords, ssh host keys, machine id, clock setting, id ranges,
and pacman keyring. users and everything else in `/etc` belong to the
generation.

when the esp is `/boot`, as archinstall sets it up, the kernel and
initramfs live on the esp, outside every root. each generation therefore
keeps copies of its own in its root's `/boot` directory, underneath the
esp's mount point, where grub can read them. the top entry boots from the
esp itself, so a kernel that `pacman` installs directly is the one it
boots. rolling back puts that generation's kernel back on the esp.

## going back

```
$ sudo os rollback
generation 2 (2026-09-26 · add tree) becomes generation 4, and the next boot runs it.
/var and /home stay as they are.

roll back? [y/N] y
generation 4 is ready. reboot to start it.
```

`os rollback` starts a new generation from the one before the newest, and
`os rollback 2` starts one from generation 2. either way, the machine
switches at the next boot. history only grows: a rollback is itself a new
generation, so running `os rollback` again takes you forward. `--yes` skips
the question; without a terminal, it's required.

until that reboot, `os apply` refuses to run, since its changes would land
on the root you're leaving. a rollback also ends any trial that's waiting
(see below).

the config goes back too. `/etc/yoq` lives in `/var/lib/yoq/config`,
outside every generation, and a rollback writes back the config and lock
that generation had, as a new commit, so its history stays whole.

if you booted an older generation from the menu and want to stay on it,
`os rollback --to-booted` makes it the newest generation.

`os history` lists the generations, with a `*` on the one running:

```
    1  2026-09-26  enable-rollback
    2  2026-09-26  add tree
*   3  2026-09-26  rollback to 1: enable-rollback
```

## updates that need a reboot

a change that needs a reboot, like a new kernel, systemd, microcode, or a
different display manager, boots once on trial:

```
reboot to finish. the next boot tries generation 5 once; if it doesn't come up healthy, the machine goes back to generation 4.
```

the next boot runs the new generation, while the menu's default stays on
the one before. once the machine is up, `yoq-health.service` checks it:
systemd isn't in maintenance or shutting down, the display manager is
running if there is one, and every service the config turns on is running.
a oneshot service that ran and finished counts as running. if the check
passes, the new generation becomes the default; if not, the machine reboots
into the generation before.

a trial boot that hangs without panicking, for example on a service that
never finishes starting, gets five minutes. then `yoq-watchdog.timer`
reboots it, and grub picks the generation before.

if the new generation can't boot at all, grub falls back to the default by
itself, and a kernel panic reboots into it after 10 seconds. either way,
`os` notices on that boot, makes it the newest generation with its config,
and `os status` explains what happened:

```
note: generation 7 didn't come up healthy, so this machine went back to generation 6. it's generation 8 now, with its config. `os rollback 7` tries 7 again.
```

two changes that need a reboot, applied before rebooting, make one trial:
the next boot tries the newest, and falls back to the generation that last
booted. if you pick an older entry from the menu before the trial has run,
that doesn't count as a failure; the next boot tries the new generation
again.

## keeping and cleaning up

after each new generation, `os` keeps the newest five, generation 1, any
you pin, and the fallback of a trial that's waiting. it removes the rest,
meaning their records, snapshots, boot copies, and any writable root that
nothing else uses, and it lists which ones went.

```
os pin 3             # keep generation 3 however old it gets
os pin --remove 3    # stop keeping it
os gc --keep 2       # clean up now, keeping the newest two
```

`--keep` is at least 1, since the newest generation always stays. `os
history` marks pinned generations.

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
- state is carried at the moment of the rollback. a password you change
  after `os rollback` but before the reboot stays behind. carrying it again
  at shutdown is planned.
- an older generation booted from the menu is only for looking around.
  `os apply` refuses to run there, and anything else you change is thrown
  away the next time `os` writes the menu. `os rollback --to-booted` keeps
  it.
- running `pacman -Syu` directly while a rollback is waiting for its
  reboot, or on an older generation booted from the menu, changes the
  kernel on a `/boot` esp that the next boot shares. use `os` for kernel
  updates there, or reboot first.
- grub only, and only the two root layouts above.

## later

- carrying state again at shutdown, and the uid map for system users
- a network check for configs that declare one
- systemd-boot, limine, and refind
- more root layouts
- building the next generation apart from the running system, so a bad
  update never touches the session you're in
- a clean build of a root from the lock alone, and an installer built on it
