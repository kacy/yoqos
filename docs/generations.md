# generations

on a btrfs root, `yos` can keep generations: whole copies of the system
that you can boot from the boot menu. every change becomes one, and a
change that needs a reboot boots once on trial, so a bad kernel or a
broken desktop costs you one reboot instead of an evening. this page
covers how that works, what it doesn't do yet, and what's planned. it
goes deeper than you need for daily use; [usage.md](usage.md) has the
everyday side.

generations are new. try them on a machine you can reinstall first.

## turning them on

```
sudo yos enable-rollback
```

`enable-rollback` checks the machine, lists every step, and asks before it
changes anything. `--yes` skips the question; without a terminal, it's
required. the machine needs:

- a btrfs root in one of three places: the top level of the filesystem
  (like arch's cloud image), archinstall's `@` subvolume, or a snapshot
  that `snapper rollback` made the root, like `@/.snapshots/2/snapshot`
- uefi, with the esp mounted at `/efi`, `/boot/efi`, or `/boot`
- grub, limine, refind, or systemd-boot. `yos` works with the one you have
  and never switches it

a root on luks works too, with the esp outside it, as archinstall's
encrypted layout has it. the initramfs has to unlock it, so mkinitcpio's
hooks need `encrypt` or `sd-encrypt`, or the config `[boot] encrypt =
true`; see [encrypted roots](#encrypted-roots).

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
the old root, because generation 1 comes from the snapshot. `yos apply` and
`yos uninstall` know that and refuse until the reboot, but anything else you
change, like files in `/home`, is left behind too, so reboot right away.
the old root is still in the menu as "the system before generations" if
you need something from it.

if a step fails, `enable-rollback` undoes the steps before it and says
whether the machine is back as it was. the step that changes what the
machine boots comes last: reinstalling grub, or adding entries to limine,
refind, or systemd-boot. until then, the machine boots the way it always did.

## bootloaders

every bootloader gets the same entries: the newest generation first, then
the older ones, then the system from before generations.

### grub

`yos` writes the whole `grub.cfg` on the esp, and `enable-rollback`
reinstalls grub to read it there. grub can write to fat, so trial boots
(below) are kept in an env file beside it. `yos` notes each trial in
`/var/lib/yos/trial` too, and only a trial noted there can make the
machine fall back: anything that can write the esp can write the env
file.

### limine

limine reads only fat, so each generation's kernel, microcode, and
initramfs get copied into `yos/boot` on the esp, named by their content.
generations with the same kernel share one copy.

`yos` keeps its entries in a marked section at the top of the `limine.conf`
that limine reads. it leaves the rest of the file alone, except for
`default_entry` and `remember_last_entry`, which it removes: either one
would override a trial's fallback. trial boots use limine's one-shot
entry, set with `bootctl`, so this needs limine 11.4 or newer.

tools that rewrite `limine.conf` themselves, like omarchy's
`limine-entry-tool`, `limine-snapper-sync`, and `omarchy-refresh-limine`,
can drop `yos`'s section. `yos status` notices, and `yos gc`, or the next
change that makes a generation, writes it again.

### systemd-boot

like limine, systemd-boot reads only fat, so generations' kernels and
initramfs images get copied into `yos/boot` on the esp by content. `yos`
writes one entry file per generation into `loader/entries`, named
`yos-head.conf`, `yos-gen-<n>.conf`, and so on, and leaves your own
entries and `loader.conf` alone. it makes `yos-head.conf` the default
with `bootctl set-default`, which outranks `loader.conf`'s own default.
trial boots use systemd-boot's one-shot entry, the same way they do on
limine.

### refind

refind reads btrfs through its driver, which `yos` installs if it's
missing, so every generation boots the kernel in its own root. the entries
go in `yos.conf`, beside `refind.conf`, and `refind.conf` gets an `include
yos.conf` line at the end.

the driver starts its paths at the btrfs default subvolume, and so does
grub's. `yos` names every root from the top level, so on a machine where
snapper's rollback moved the default, enable-rollback moves it back to the
top level for grub and refind. limine and systemd-boot only read the esp,
so they keep whatever default they had.

refind can't boot an entry just once, but the firmware can. for a trial,
`yos` puts a copy of refind in `EFI/yos-trial` on the esp, with its
drivers and a `refind.conf` whose default is the trial, adds a firmware
boot entry for that copy without changing the boot order, and makes it
the next boot with `BootNext`. refind's own default meanwhile moves to the
generation before, so the boot after a failed trial lands there. when the
trial ends, the firmware entry and the copy go. this needs `efibootmgr`,
and firmware that honors `BootNext`, which most does.

## encrypted roots

generations work on a btrfs root inside luks, with the esp outside it,
the way archinstall sets up an encrypted disk and `yos install --encrypt`
does.

nothing reads btrfs inside luks before the initramfs unlocks it, so there
every bootloader works the way limine does: each generation's kernel,
microcode, and initramfs are copied into `yos/boot` on the esp, named by
content, and generations with the same kernel share them. grub and refind
don't read the roots at all then. the copies take room on the esp, which
`yos plan` checks and `yos gc` frees.

every entry gets the arguments that unlock the root from the running
kernel's command line, the same way it gets the rest: `rd.luks.name=`,
`rd.luks.options=`, and the other `rd.luks.*` ones for sd-encrypt, or
`cryptdevice=` and `cryptkey=` for busybox's encrypt hook. `root=` names
the btrfs filesystem inside by its uuid, which shows up once the volume is
open, so it's the same for every generation.

the luks header, its passphrases, and a tpm key belong to the disk, not to
a generation. a rollback doesn't change them, and a passphrase you change
with cryptsetup works for every generation. a trial boot unlocks like any
other boot: by itself with a tpm key, or with someone typing the
passphrase. the watchdog's five minutes start once the root's systemd
does, so the time at the prompt doesn't count.

[examples/laptop](../examples/laptop/machine.toml) has a config with luks,
unified kernel images, and secure boot all on.

## unified kernel images

with `[boot] uki = true` in the config, generations boot unified kernel
images instead of a kernel and initramfs files. each image holds a
generation's kernel, microcode, and initramfs, with systemd's efi stub in
front. `yos` builds it with the generation's own ukify:

```
chroot <root> ukify build --config=/etc/kernel/yos-uki.conf \
    --linux=<kernel> --initrd=<microcode> --initrd=<initramfs> --output=<image>
```

it copies the boot files into `/tmp/yos-uki` inside the root first, since
the esp isn't there, and runs ukify through chroot, so it's the root's own
ukify and stub. that matters the first time: the root built for the
change that turns `uki` on has ukify, and the running system doesn't yet.
nothing gets mounted for it either. the image goes in `yos/boot` on the
esp, named by the content of the files in it and of the root's stub, like
`0123456789abcdef-yos.efi`, so generations with the same kernel,
initramfs, and stub share one. a new systemd brings a new stub, so the
next menu builds every image again, and `yos plan` counts the room for
them. `yos gc`, and every menu write, removes the images no entry uses any
more.

the files come from the root's own `/boot`, never from the esp. with the
esp at `/boot`, that's the copies `yos` keeps in each root's `/boot`
directory under the mount, which it makes as the generation is recorded,
so the newest generation's image doesn't come from files on the esp that
anything able to write there could have changed. those copies still come
from the esp when a generation is recorded, so an image that's signed
goes further (see [secure boot](#secure-boot)).

without secure boot, an image has no command line built in. each entry
passes its own, with the root, `rootflags=subvol=`, the console and luks
arguments, and `yos.trial` on a trial boot, and the stub hands it to the kernel:

| bootloader | entry |
| --- | --- |
| grub | `chainloader (esp)/yos/boot/<image> <command line>` |
| limine | `protocol: efi`, `path: boot():/yos/boot/<image>`, `cmdline: <command line>` |
| systemd-boot | `efi /yos/boot/<image>`, `options <command line>` |
| refind | `loader /yos/boot/<image>`, `options "<command line>"` |

the images are on the esp for every bootloader, grub and refind included,
so `yos plan` counts them against its free space: one per kernel, about as
big as that kernel, its initramfs, and microcode together. turning `uki`
on or off makes the next generation's boot files new, so it needs a
reboot, and the next boot tries it once. `/etc/kernel/yos-uki.conf` is
how `yos` knows a root boots an image. it's part of the generation, so a
rollback to a generation from before boots its kernel and initramfs files
as it always did.

`yos init` sets the key on a machine that boots unified kernel images
already: one whose mkinitcpio presets have a `default_uki=` or
`fallback_uki=`, or with images in `EFI/Linux` on the esp, like omarchy,
as long as ukify is installed. `yos` leaves the machine's own images alone
and builds its own from the kernel and initramfs files in `/boot`, so
mkinitcpio has to keep writing the initramfs files too (`default_image=`).

## secure boot

with `[boot] secure_boot = true` as well as `uki`, `yos` signs the images
with sbctl's db key. the steps that make and enroll the keys are in
[usage.md](usage.md#secure-boot); `yos` never runs them.

the key writes `/etc/kernel/yos-secure-boot.conf` into the generation, the
same way `uki` writes its ukify config. a menu written for a root that has
it, or written while the running root has it, signs. so does every menu
written while the firmware enforces secure boot and sbctl has keys,
whatever the config says. a generation without the key, like one rolled
back to, still starts then. signing covers:

- each new image, built in `/tmp/yos-uki` inside its root, with
  `sbctl sign <image>` run from the running system, before it's copied to
  the esp and renamed into place. the running system's sbctl and its keys
  in `/var/lib/sbctl` do the signing, so it doesn't matter whether the
  root being built has sbctl yet.
- each image the menu boots that's on the esp already without a
  signature from sbctl's db key, like the ones from before the key, or
  ones signed with keys sbctl made before: it's built again from its
  root's files, signed, and replaces the one there. `yos` never signs a
  file as it finds it on the esp, since anything that can write to the
  esp could have put it there. `yos` tells whose signature an image has
  by the issuer and serial number of `/var/lib/sbctl/keys/db/db.pem`,
  which every signature names.
- grub, on grub. `yos` installs it with `--modules=tpm
  --disable-shim-lock` every time, so it can start under secure boot
  without shim, and when the binary on the esp isn't the one it signed
  last, it runs `grub-install --no-nvram` again and signs the result in
  place, since grub-install writes only to the esp. the hash of what it
  signed goes in `/var/lib/yos/grub-signed`. a grub someone signed by
  hand can still be one built without those options, which wouldn't
  start, so a signature alone isn't enough. grub's lockdown loads nothing,
  not even `normal.mod`, until a verifier claims it, and the tpm module is
  the only one there without shim. it registers only when the firmware
  has a tpm 2.0, so `yos plan` refuses `secure_boot` on grub without one
  (E0136, from `facts.boot.tpm2`). kernels and images aren't modules:
  grub hands each one to the firmware, which checks its signature, so an
  entry added to grub.cfg can't start a kernel your keys didn't sign.
- refind's btrfs driver, which `yos` installs beside refind.conf. an
  unsigned one there is replaced by a signed copy of
  `/usr/share/refind/drivers_x64/btrfs_x64.efi`, signed in
  `/tmp/yos-sign` in the newest root.

an image that's signed doesn't use the copies in its root's `/boot` as
they are. with the esp at `/boot`, `yos` takes those from the esp each time
it records a generation, so an initramfs someone put on the esp while the
machine was off would end up signed. instead:

- the kernel is the one the root's package installed,
  `/usr/lib/modules/<version>/vmlinuz`, picked by the package name in
  that directory's `pkgbase` (linux for `vmlinuz-linux`). with more than
  one version of it, the one matching the copy wins, or else the newest.
- the initramfs is built for that version inside the root, through chroot,
  with the root bound on itself and `/proc`, `/sys`, `/dev`, and `/run`
  mounted in a mount namespace of its own: `mkinitcpio -k <version> -g
  /tmp/yos-uki/initramfs.img`. autodetect stays on. it looks at this
  machine's `/sys`, which is right, since a signed image is only built on
  the machine that boots it: `yos install` and clean builds refuse
  `secure_boot`. so the initramfs is about as big as the root's own, and
  `yos plan` counts it that way, with an eighth to spare.
- there's no separate microcode image: mkinitcpio's `microcode` hook puts
  early microcode in the initramfs from the root's `/usr/lib/firmware`.

the copies still name the image, so it's built again, with one mkinitcpio
run, only when they change, and an image already on the esp under its
name with sbctl's signature is reused. without signing, nothing here
changes: images are the copies as they are, and mkinitcpio never runs.

while a menu signs, images are per entry. each one is built with ukify's
`--cmdline=` set to its entry's command line, and its name covers that
command line too, so entries with different ones get different images and
identical ones share. the entries pass no command line: no `options` line
on systemd-boot or refind, no `cmdline:` on limine, nothing after grub's
`chainloader`. with secure boot on, systemd's stub ignores what the
bootloader passes to an image that has a command line, so a line added to
an entry on the esp never reaches the kernel. a trial needs `yos.trial`,
so the newest entry gets a twin with it built in: limine, systemd-boot,
and refind's trial entries start the twin, and grub's newest entry
chainloads it when `yos_trial_arg` is set. each recorded generation moves
the one before to an entry with a command line of its own, so it gets a
new image, and `yos plan` counts that room, the twin's, and, when signing
starts, a new image for every entry.

a signature only adds a few KiB. signing an image that's on the esp
already takes more, since its signed copy goes in beside it before it
replaces it, so when there's one without a signature, `yos plan` counts
room for an image that size.

`yos` doesn't rely on sbctl's own pacman hook: a staged generation's image
is signed before its trial boot. the hook still runs when packages
change on the running system, but not in a root `yos` builds, like a staged
one, a clean build, or an install. it signs files at their paths on the
esp, which isn't mounted there, so it would only fail. `yos` turns it off
for those transactions by linking `zz-sbctl.hook` to `/dev/null` in a hook
directory libalpm reads after the root's own.

when sbctl can't sign, say its keys are gone, `yos apply` and `yos update`
stop, but a rollback, a fallback, or `yos gc` goes on: the menu is written,
new images go on the esp unsigned, and so do images built again, while
ones that can't be built again stay as they are. a warning names them.

turning `secure_boot` on or off changes the file, so it waits for a
reboot, with "secure boot" as the reason, and the next boot tries it once.
the keys are in `/var`, which no generation holds, so a rollback keeps
them. `yos gc` signs images it finds unsigned when the running generation
has the key, or the firmware enforces secure boot, for example after the
keys were made late.

## how they work

everything lives in the btrfs top level:

| path | what it is |
| --- | --- |
| `@roots/<n>` | a writable root; the machine runs one of these |
| `@gens/<n>` | a read-only record of generation n |
| `@roots/boot-<n>` | a fresh writable copy of generation n, for its menu entry |
| `@var`, `@home`, `@root`, `@srv`, `@usrlocal` | data, which no generation holds |

every `yos apply`, `add`, `remove`, `enable`, `disable`, `edit`, `update`,
or `adopt` of a file that changes the machine records the result as the
next generation, labeled with what made it:

```
yos 3 · 2026-09-27 · update packages to 2026-09-27
yos 2 · 2026-09-26 · add tree
yos 1 · 2026-09-26 · enable-rollback
the system before generations
```

the top entry is the system you run. picking an older entry boots a fresh
copy of that generation, so looking around can't change its record. data
directories stay as they are either way, and so does the machine's own
state: every new root, and every copy the menu boots, gets the running
system's passwords, ssh host keys, machine id, clock setting, id ranges,
pacman keyring, and networkmanager's saved connections, so a wi-fi network
joined since stays joined. users and everything else in `/etc` belong to the
generation, with one exception: system accounts that packages make, like
`postgres` or `chrony`, come along into every root yos makes, as they are.
an older generation then has accounts for packages it doesn't have, but an
id given out once is never given to anyone else, and a package installed
again gets its old id back, along with the files in `/var` it owns. `yos
status` says if a system account's id ever changes anyway. a generation
waiting for the next boot gets them once more as the machine shuts down,
from `yos-carry.service`, so a password you change between `yos rollback`
and the reboot comes along too.

when the esp is `/boot`, as archinstall sets it up, the kernel and
initramfs live on the esp, outside every root. each generation therefore
keeps copies of its own in its root's `/boot` directory, underneath the
esp's mount point, where grub can read them. the top entry boots from the
esp itself, so a kernel that `pacman` installs directly is the one it
boots. rolling back puts that generation's kernel back on the esp, when it
fits (see below).

where the top entry boots copies on the esp instead, as on limine,
systemd-boot, or a luks root with the esp elsewhere, or an image with
`[boot] uki`, a kernel, microcode, or initramfs change that `pacman` makes
directly gets the menu written again by yos's pacman hook, the way `yos gc`
writes it, so the top entry boots the new files and not the old kernel,
whose modules pacman removed. it skips that while another yos is running,
or a generation waits for the next boot; `yos gc` does it then. running
`mkinitcpio` by hand isn't a pacman transaction, so nothing sees it: run
`yos gc` after it there.

## going back

```
$ sudo yos rollback
generation 2 (2026-09-26 · add tree) becomes generation 4, and the next boot runs it.
/var and /home stay as they are.

roll back? [y/N] y
generation 4 is ready. reboot to start it.
```

`yos rollback` starts a new generation from the one before the newest, and
`yos rollback 2` starts one from generation 2. either way, the machine
switches at the next boot. history only grows: a rollback is itself a new
generation, so running `yos rollback` again takes you forward. `--yes` skips
the question; without a terminal, it's required.

until that reboot, `yos apply` refuses to run, since its changes would land
on the root you're leaving. a rollback also ends any trial that's waiting
(see below).

the config goes back too. `/etc/yos` lives in `/var/lib/yos/config`,
outside every generation, and a rollback writes back the config and lock
that generation had, as a new commit, so its history stays whole. a
rollback cut off after it made the generation, but before that commit, has
the commit made by the health check at the next boot, before `yos apply`
can run again.

if you booted an older generation from the menu and want to stay on it,
`yos rollback --to-booted` makes it the newest generation.

`yos history` lists the generations, with a `*` on the one running:

```
    1  2026-09-26  enable-rollback
    2  2026-09-26  add tree
*   3  2026-09-26  rollback to 1: enable-rollback
```

## updates that need a reboot

a change that needs a reboot, like a new kernel, systemd, microcode, or a
different display manager, isn't made to the running system at all. `yos`
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

until that reboot, `yos apply` refuses to run, as it does after a rollback,
since a second change would start from the running root and leave the
first one behind. `yos add` and the like still edit the config and the
lock, and `yos apply` after the reboot makes the change.

the next boot runs the new generation, while the menu's default stays on
the one before. the menu that adds the new generation already keeps that
default, and the trial's one-shot boot is set up after it, so a power
cut in between boots the generation before, not one nothing has tried.
`yos` notes the trial in `/var/lib/yos/trial` before either, so that boot
knows the trial was never set up: it sets it up again, and the boot after
tries it. a trial that passes is noted as passed before it becomes the
default, so a power cut partway through that doesn't look like a failed
trial; the next boot finishes the job, whichever generation it runs. a
fallback cut off after it made its generation ends the trial at the next
boot without making another.
once the machine is up, `yos-health.service` checks it:
systemd isn't in maintenance or shutting down, the display manager is
running if there is one, and every service the config turns on is running.
a oneshot service that ran and finished counts as running. when the config
turns on something that brings up a network, like networkmanager,
systemd-networkd, or iwd, the machine also has to get a default route
within a minute; it doesn't need to reach the internet. if the check
passes, the new generation becomes the default; if not, the machine reboots
into the generation before.

a trial boot that hangs without panicking, for example on a service that
never finishes starting, gets five minutes. then `yos-watchdog.timer`
reboots it, and the bootloader picks the generation before. the timer
starts with the root's systemd, before `sysinit.target`, so a unit that
holds up early boot can't stop it. a trial that drops to an emergency
shell, because the initramfs can't mount the root or a mount in fstab
never comes, would wait there for a password. `yos-emergency.service`,
wanted by `emergency.target` and only on a trial boot, reboots it
instead, in the root and in a systemd initramfs, where mkinitcpio's
`yos-trial` hook puts it (`/etc/initcpio/install/yos-trial`, added by
`/etc/mkinitcpio.conf.d/95-yos-trial.conf`). a busybox initramfs gets a
runtime hook from it instead, `/etc/initcpio/hooks/yos-trial`, which on a
trial boot makes the shell a failed mount drops to a reboot.

if the new generation can't boot at all, the next boot lands on the default
by itself, since the trial entry was only for one boot. a kernel panic
reboots after 10 seconds, on every bootloader. a kernel or image the
bootloader can't load is different:

- grub falls back to the generation before by itself.
- systemd-boot, from 258, reboots when an entry with a boot counter
  fails to start, and the trial's entry has one,
  `yos-trial+1.conf`. the boot after gets the default.
- limine and refind stop at an error screen until someone presses a key,
  and so does an older systemd-boot. `yos` looks at the files the trial's
  entry loads right after it sets up the trial, and again at shutdown,
  from `yos-carry.service`: a missing file, a kernel or image cut short,
  or a copy whose content no longer matches the hash in its name. if one
  is broken, the trial isn't tried, and the next boot runs the generation
  before, which counts as the trial failing.

either way, `yos` notices on that boot, makes it the newest generation with
its config, and `yos status` explains what happened:

```
note: generation 7 didn't come up healthy, so this machine went back to generation 6. it's generation 8 now, with its config. `yos rollback 7` tries 7 again.
```

until that reboot, the machine can't hibernate. resuming goes through the
bootloader, which would start the new generation's kernel with the memory
of the one running now, so `yos` turns hibernation off in `/run`, which the
next boot clears. suspending to memory still works.

if you pick an older entry from the menu before the trial has run, that
doesn't count as a failure; the next boot tries the new generation again.
grub notes the trial entry starting in its env file. limine and
systemd-boot clear the trial's one-shot whatever boots, but name the
entry they booted, and `yos` compares that with the default, the
generation the trial falls back to. on refind, the trial starts its own
copy of refind from a firmware entry, and a pick there boots from that
entry. picking the generation the trial falls back to itself looks the
same as the trial failing, except on grub.

## keeping and cleaning up

after each new generation, `yos` keeps the newest five, the first one
(generation 1, or the number after the roots an earlier uninstall left), any
you pin, and the fallback of a trial that's waiting. it removes the rest,
meaning their records, snapshots, boot copies, and any writable root that
nothing else uses, and it lists which ones went.

```
yos pin 3             # keep generation 3 however old it gets
yos pin --remove 3    # stop keeping it
yos gc --keep 2       # clean up now, keeping the newest two
```

`--keep` is at least 1, since the newest generation always stays. `yos
history` marks pinned generations. `yos gc` doesn't run from an older
generation booted from the menu, since that generation's record is what
`yos rollback --to-booted` needs, or while a new generation waits for the
next boot.

limine and systemd-boot need copies of each generation's boot files on the
esp, and with the esp at `/boot` the running kernel lives there too. `yos
plan` and `yos apply` check the esp's free space before anything is built:
a change to a kernel, its initramfs, or microcode that won't fit stops with
E0131. the size is guessed from the running system's boot files, with a
little to spare. the error says which generations `yos gc --keep 1`
would remove to make room, or, with grub or refind, that the esp only
holds the running system's files and has to be cleared by hand. when a new
generation's real files still don't fit, `yos` doesn't record it, and the
running system stays as it was. a staged change that fails to build on a
nearly full disk also says the disk is the likely reason.

with the esp at `/boot`, a generation that has booted well, or one `yos
rollback` starts, gets its kernel put on the esp. if it doesn't fit there,
nothing is copied: the generation boots the kernel in its own root, `yos
rollback` or the health check says why, `yos status` shows a note, and the
next boot tries again once there's room.

## what this doesn't do yet

- changes that don't need a reboot still apply live. if one of those
  breaks something, the previous generation is one pick away in the boot
  menu, but the session you're in has it.
- changes you make to the running system between a staged apply and the
  reboot, besides passwords and the like, stay in the old root. `yos
  status` lists the files in `/etc` and the pacman runs it sees since the
  build, so you can make them in the config instead, or again afterwards.
- the health check is simple. it looks at systemd's state, the display
  manager, the config's services, and whether a networked machine got a
  route. a desktop that starts but shows nothing useful still passes.
- an older generation booted from the menu is only for looking around.
  `yos apply` refuses to run there, and anything else you change is thrown
  away the next time `yos` writes the menu. `yos rollback --to-booted` keeps
  it.
- running `pacman -Syu` directly while a rollback is waiting for its
  reboot, or on an older generation booted from the menu, changes the
  kernel on a `/boot` esp that the next boot shares. use `yos` for kernel
  updates there, or reboot first.
- only the three root layouts above, on a partition or right inside luks
  on one. a root on lvm, even lvm inside luks, or on another
  device-mapper volume, isn't supported yet, and `enable-rollback` says
  so.
- generations with limine are tested on archinstall's layout with snapper,
  not on a real omarchy install. omarchy builds its own unified kernel
  images, and `yos` doesn't boot those: it boots the kernel and initramfs
  files in `/boot`, or with `[boot] uki`, images it builds from them. the
  vm tests boot images on systemd-boot and limine so far.
- from an entry the firmware won't start, like an image signed with keys
  it doesn't have, grub falls back, but limine halts ("System halted.")
  and refind waits for a key, and both turn the firmware's watchdog off,
  so nothing reboots the machine. systemd-boot isn't tested there. a plan
  checks the firmware's db for sbctl's certificate before anything is
  signed (E0137), and while it's missing, a rollback, a fallback, gc, or
  the pacman hook leaves the esp's signed files as they are rather than
  sign them again with keys the firmware would refuse. that covers the
  likely way there. a file that went bad on the esp after that still
  hangs those two.
- secure boot is tested on all four bootloaders, and on luks with a tpm
  key. limine stops booting if its config's checksum was enrolled
  (`limine enroll-config`), since `yos` edits limine.conf. a generation from before `uki` boots a kernel
  without a signature, so on grub, systemd-boot, and refind the firmware
  refuses it while secure boot is on.
- pcr 7 isn't only the firmware's: a boot through systemd's stub, which
  every unified kernel image has, adds an os separator to it from the
  initramfs, and a plain kernel's boot doesn't. so a tpm key made while
  images boot doesn't open the root when a plain kernel boots, and the
  other way around: turning `uki` on, rolling back to a generation from
  before it, and `yos uninstall` each cost a passphrase and the key made
  again (`yos doctor` says so). systemd-pcrlock's policies are the way out,
  and yos doesn't use them yet.
- the tpm key that `yos install --tpm` adds is sealed to pcr 7, the secure
  boot state. on grub, systemd-boot, and refind that's enough: the
  firmware checks every kernel they start, and each signed image has its
  command line in it. limine without an enrolled config loads a kernel
  without that check, so a plain kernel someone adds to its menu gets the
  disk unlocked. a signed pcr 11 policy for `yos`'s images wouldn't help
  there, since a kernel nobody checked can extend pcr 11 to whatever the
  policy expects, so `yos` doesn't make one. a plain kernel signed with your
  keys, like arch's after `sbctl sign -s /boot/vmlinuz-linux`, takes any
  command line from grub or systemd-boot, so don't sign one you don't
  need.

## later

- system accounts with the same ids on every machine a config repository
  describes, so restoring a backup onto a new machine keeps ownership
