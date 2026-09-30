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
- grub, limine, refind, or systemd-boot. `os` works with the one you have
  and never switches it

it takes one snapshot of the running root and builds generation 1 from it.
`/var`, `/home`, `/root`, `/srv`, and `/usr/local` each become a subvolume
of their own, unless they're mounted separately already. the pacman
database moves into `/usr/lib/sysimage/pacman`, and the boot menu gets an
entry for generation 1 (see [bootloaders](#bootloaders)). on a machine with
snapper, snap-pac stops taking snapshots of the root around each pacman
run, since each change is a generation already; snapper's other configs,
like one for `/home`, keep working. after a reboot, the machine runs
generation 1, and the boot menu still offers the system as it was before.

changes you make between running `enable-rollback` and rebooting stay in
the old root, because generation 1 comes from the snapshot. `os apply` and
`os uninstall` know that and refuse until the reboot, but anything else you
change, like files in `/home`, is left behind too, so reboot right away. the old root is still in the menu
as "the system before generations" if you need something from it.

if a step fails, `enable-rollback` undoes the steps before it and says
whether the machine is back as it was. the step that changes what the
machine boots comes last: reinstalling grub, or adding entries to limine's
or refind's config. until then, the machine boots the way it always did.

## bootloaders

every bootloader gets the same entries: the newest generation first, then
the older ones, then the system from before generations.

### grub

`os` writes the whole `grub.cfg` on the esp, and `enable-rollback`
reinstalls grub to read it there. grub can write to fat, so trial boots
(below) are kept in an env file beside it.

### limine

limine reads only fat, so each generation's kernel, microcode, and
initramfs get copied into `yoq/boot` on the esp, named by their content.
generations with the same kernel share one copy.

`os` keeps its entries in a marked section at the top of the `limine.conf`
that limine reads. it leaves the rest of the file alone, except for
`default_entry` and `remember_last_entry`, which it removes: either one
would override a trial's fallback. trial boots use limine's one-shot
entry, set with `bootctl`, so this needs limine 11.4 or newer.

tools that rewrite `limine.conf` themselves, like omarchy's
`limine-entry-tool`, `limine-snapper-sync`, and `omarchy-refresh-limine`,
can drop `os`'s section. `os status` notices, and `os gc`, or the next
change that makes a generation, writes it again.

### systemd-boot

like limine, systemd-boot reads only fat, so generations' kernels and
initramfs images get copied into `yoq/boot` on the esp by content. `os`
writes one entry file per generation into `loader/entries`, named
`yoq-head.conf`, `yoq-gen-<n>.conf`, and so on, and leaves your own
entries and `loader.conf` alone. it makes `yoq-head.conf` the default
with `bootctl set-default`, which outranks `loader.conf`'s own default.
trial boots use systemd-boot's one-shot entry, the same way they do on
limine.

### refind

refind reads btrfs through its driver, which `os` installs if it's
missing, so every generation boots the kernel in its own root. the entries
go in `yoq.conf`, beside `refind.conf`, and `refind.conf` gets an `include
yoq.conf` line at the end.

the driver starts its paths at the btrfs default subvolume, so that has to
be the top level. it is, unless something like a snapper rollback changed
it.

refind can't boot an entry just once, but the firmware can. for a trial,
`os` puts a copy of refind in `EFI/yoq-trial` on the esp, with its
drivers and a `refind.conf` whose default is the trial, adds a firmware
boot entry for that copy without changing the boot order, and makes it
the next boot with `BootNext`. refind's own default meanwhile moves to the
generation before, so the boot after a failed trial lands there. when the
trial ends, the firmware entry and the copy go. this needs `efibootmgr`,
and firmware that honors `BootNext`, which most does.

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
generation, with one exception: system accounts that packages make, like
`postgres` or `chrony`, come along into every root os makes, as they are.
an older generation then has accounts for packages it doesn't have, but an
id given out once is never given to anyone else, and a package installed
again gets its old id back, along with the files in `/var` it owns. `os
status` says if a system account's id ever changes anyway. a generation waiting for the next boot gets them once more as the
machine shuts down, from `yoq-carry.service`, so a password you change
between `os rollback` and the reboot comes along too.

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
different display manager, isn't made to the running system at all. `os`
builds it into the next root instead: a snapshot of the running one, with
the change applied to it the way a clean build is made, and `/var` bound
in as it is. the session you're in keeps its kernel, libraries, and
services, and the next boot runs the new generation once, on trial:

```
building generation 5 beside the running system, which doesn't change.
...
reboot to finish. the next boot tries generation 5 once; if it doesn't come up healthy, the machine goes back to generation 4.
```

with `/boot` as the esp, a staged generation boots the kernel in its own
root until it has come up healthy, and only then moves it onto the esp, so
the kernel the running system booted stays where it was. changes that
don't need a reboot, like a new command-line tool, still apply to the
running system right away.

the next boot runs the new generation, while the menu's default stays on
the one before. once the machine is up, `yoq-health.service` checks it:
systemd isn't in maintenance or shutting down, the display manager is
running if there is one, and every service the config turns on is running.
a oneshot service that ran and finished counts as running. when the config
turns on something that brings up a network, like networkmanager,
systemd-networkd, or iwd, the machine also has to get a default route
within a minute; it doesn't need to reach the internet. if the check
passes, the new generation becomes the default; if not, the machine reboots
into the generation before.

a trial boot that hangs without panicking, for example on a service that
never finishes starting, gets five minutes. then `yoq-watchdog.timer`
reboots it, and the bootloader picks the generation before.

if the new generation can't boot at all, grub falls back to the default by
itself, and on either bootloader a kernel panic reboots into it after 10
seconds. either way,
`os` notices on that boot, makes it the newest generation with its config,
and `os status` explains what happened:

```
note: generation 7 didn't come up healthy, so this machine went back to generation 6. it's generation 8 now, with its config. `os rollback 7` tries 7 again.
```

until that reboot, the machine can't hibernate. resuming goes through the
bootloader, which would start the new generation's kernel with the memory
of the one running now, so `os` turns hibernation off in `/run`, which the
next boot clears. suspending to memory still works.

two changes that need a reboot, applied before rebooting, make one trial:
the next boot tries the newest, and falls back to the generation that last
booted. on grub, if you pick an older entry from the menu before the trial
has run, that doesn't count as a failure; the next boot tries the new
generation again. limine, systemd-boot, and the firmware for refind forget
the trial as soon as they read it, so there, picking an older entry counts
as the trial failing.

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
history` marks pinned generations. `os gc` doesn't run from an older
generation booted from the menu, since that generation's record is what
`os rollback --to-booted` needs.

## what this doesn't do yet

- changes that don't need a reboot still apply live. if one of those
  breaks something, the previous generation is one pick away in the boot
  menu, but the session you're in has it.
- changes you make to the running system between a staged apply and the
  reboot, besides passwords and the like, stay in the old root. `os
  status` lists the files in `/etc` and the pacman runs it sees since the
  build, so you can make them in the config instead, or again afterwards.
- the health check is simple. it looks at systemd's state, the display
  manager, the config's services, and whether a networked machine got a
  route. a desktop that starts but shows nothing useful still passes.
- an older generation booted from the menu is only for looking around.
  `os apply` refuses to run there, and anything else you change is thrown
  away the next time `os` writes the menu. `os rollback --to-booted` keeps
  it.
- running `pacman -Syu` directly while a rollback is waiting for its
  reboot, or on an older generation booted from the menu, changes the
  kernel on a `/boot` esp that the next boot shares. use `os` for kernel
  updates there, or reboot first.
- only the two root layouts above.
- generations with limine are tested on archinstall's layout with snapper,
  not on a real omarchy install. omarchy builds unified kernel images, and
  `os` boots the kernel and initramfs files in `/boot` instead.

## later

- more root layouts, like one snapper has rolled back
- system accounts with the same ids on every machine a config repository
  describes, so restoring a backup onto a new machine keeps ownership
