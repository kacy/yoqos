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

- a btrfs root in one of three places: the top level of the filesystem
  (like arch's cloud image), archinstall's `@` subvolume, or a snapshot
  that `snapper rollback` made the root, like `@/.snapshots/2/snapshot`
- uefi, with the esp mounted at `/efi`, `/boot/efi`, or `/boot`
- grub, limine, refind, or systemd-boot. `os` works with the one you have
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
the old root, because generation 1 comes from the snapshot. `os apply` and
`os uninstall` know that and refuse until the reboot, but anything else you
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

the driver starts its paths at the btrfs default subvolume, and so does
grub's. `os` names every root from the top level, so on a machine where
snapper's rollback moved the default, enable-rollback moves it back to the
top level for grub and refind. limine and systemd-boot only read the esp,
so they keep whatever default they had.

refind can't boot an entry just once, but the firmware can. for a trial,
`os` puts a copy of refind in `EFI/yoq-trial` on the esp, with its
drivers and a `refind.conf` whose default is the trial, adds a firmware
boot entry for that copy without changing the boot order, and makes it
the next boot with `BootNext`. refind's own default meanwhile moves to the
generation before, so the boot after a failed trial lands there. when the
trial ends, the firmware entry and the copy go. this needs `efibootmgr`,
and firmware that honors `BootNext`, which most does.

## encrypted roots

generations work on a btrfs root inside luks, with the esp outside it,
the way archinstall sets up an encrypted disk and `os install --encrypt`
does.

nothing reads btrfs inside luks before the initramfs unlocks it, so there
every bootloader works the way limine does: each generation's kernel,
microcode, and initramfs are copied into `yoq/boot` on the esp, named by
content, and generations with the same kernel share them. grub and refind
don't read the roots at all then. the copies take room on the esp, which
`os plan` checks and `os gc` frees.

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

## unified kernel images

with `[boot] uki = true` in the config, generations boot unified kernel
images instead of a kernel and initramfs files. each image holds a
generation's kernel, microcode, and initramfs, with systemd's efi stub in
front. `os` builds it with the generation's own ukify:

```
chroot <root> ukify build --config=/etc/kernel/yoq-uki.conf \
    --linux=<kernel> --initrd=<microcode> --initrd=<initramfs> --output=<image>
```

it copies the boot files into `/tmp/yoq-uki` inside the root first, since
the esp isn't there, and runs ukify through chroot, so it's the root's own
ukify and stub. that matters the first time: the root built for the
change that turns `uki` on has ukify, and the running system doesn't yet.
nothing gets mounted for it either. the image goes in `yoq/boot` on the
esp, named by the content of the files in it and of the root's stub, like
`0123456789abcdef-yoq.efi`, so generations with the same kernel,
initramfs, and stub share one. a new systemd brings a new stub, so the
next menu builds every image again, and `os plan` counts the room for
them. `os gc`, and every menu write, removes the images no entry uses any
more.

the files come from the root's own `/boot`, never from the esp. with the
esp at `/boot`, that's the copies `os` keeps in each root's `/boot`
directory under the mount, which it makes as the generation is recorded,
so the newest generation's image doesn't come from files on the esp that
anything able to write there could have changed. those copies still come
from the esp when a generation is recorded, so an image that's signed
goes further (see [secure boot](#secure-boot)).

without secure boot, an image has no command line built in. each entry
passes its own, with the root, `rootflags=subvol=`, the console and luks
arguments, and `yoq.trial` on a trial boot, and the stub hands it to the kernel:

| bootloader | entry |
| --- | --- |
| grub | `chainloader (esp)/yoq/boot/<image> <command line>` |
| limine | `protocol: efi`, `path: boot():/yoq/boot/<image>`, `cmdline: <command line>` |
| systemd-boot | `efi /yoq/boot/<image>`, `options <command line>` |
| refind | `loader /yoq/boot/<image>`, `options "<command line>"` |

the images are on the esp for every bootloader, grub and refind included,
so `os plan` counts them against its free space: one per kernel, about as
big as that kernel, its initramfs, and microcode together. turning `uki`
on or off makes the next generation's boot files new, so it needs a
reboot, and the next boot tries it once. `/etc/kernel/yoq-uki.conf` is
how `os` knows a root boots an image. it's part of the generation, so a
rollback to a generation from before boots its kernel and initramfs files
as it always did.

`os init` sets the key on a machine that boots unified kernel images
already: one whose mkinitcpio presets have a `default_uki=` or
`fallback_uki=`, or with images in `EFI/Linux` on the esp, like omarchy,
as long as ukify is installed. `os` leaves the machine's own images alone and builds its own from the
kernel and initramfs files in `/boot`, so mkinitcpio has to keep writing
the initramfs files too (`default_image=`).

## secure boot

with `[boot] secure_boot = true` as well as `uki`, `os` signs the images
with sbctl's db key. the steps that make and enroll the keys are in
[usage.md](usage.md#secure-boot); `os` never runs them.

the key writes `/etc/kernel/yoq-secure-boot.conf` into the generation, the
same way `uki` writes its ukify config. a menu written for a root that has
it, or written while the running root has it, signs. so does every menu
written while the firmware enforces secure boot and sbctl has keys,
whatever the config says. a generation without the key, like one rolled
back to, still starts then. signing covers:

- each new image, built in `/tmp/yoq-uki` inside its root, with
  `sbctl sign <image>` run from the running system, before it's copied to
  the esp and renamed into place. the running system's sbctl and its keys
  in `/var/lib/sbctl` do the signing, so it doesn't matter whether the
  root being built has sbctl yet.
- each image the menu boots that's on the esp already without a
  signature from sbctl's db key, like the ones from before the key, or
  ones signed with keys sbctl made before: it's built again from its
  root's files, signed, and replaces the one there. `os` never signs a
  file as it finds it on the esp, since anything that can write to the
  esp could have put it there. `os` tells whose signature an image has
  by the issuer and serial number of `/var/lib/sbctl/keys/db/db.pem`,
  which every signature names.
- refind's btrfs driver, which `os` installs beside refind.conf. an
  unsigned one there is replaced by a signed copy of
  `/usr/share/refind/drivers_x64/btrfs_x64.efi`, signed in
  `/tmp/yoq-sign` in the newest root.

an image that's signed doesn't use the copies in its root's `/boot` as
they are. with the esp at `/boot`, `os` takes those from the esp each time
it records a generation, so an initramfs someone put on the esp while the
machine was off would end up signed. instead:

- the kernel is the one the root's package installed,
  `/usr/lib/modules/<version>/vmlinuz`, picked by the package name in
  that directory's `pkgbase` (linux for `vmlinuz-linux`). with more than
  one version of it, the one matching the copy wins, or else the newest.
- the initramfs is built for that version inside the root, through chroot
  with `/proc`, `/sys`, `/dev`, and `/run` mounted in a mount namespace of
  its own: `mkinitcpio -k <version> -S autodetect -g
  /tmp/yoq-uki/initramfs.img`. autodetect stays out since it would look at
  the running machine, not the root. the image is about three times as
  big, and `os plan` counts it that way.
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
an entry on the esp never reaches the kernel. a trial needs `yoq.trial`,
so the newest entry gets a twin with it built in: limine, systemd-boot,
and refind's trial entries start the twin, and grub's newest entry
chainloads it when `yoq_trial_arg` is set. each recorded generation moves
the one before to an entry with a command line of its own, so it gets a
new image, and `os plan` counts that room, the twin's, and, when signing
starts, a new image for every entry.

a signature only adds a few KiB. signing an image that's on the esp
already takes more, since its signed copy goes in beside it before it
replaces it, so when there's one without a signature, `os plan` counts
room for an image that size. `os` doesn't rely on sbctl's own pacman hook: a staged generation's
image is signed before its trial boot. the hook still runs when packages
change on the running system, but not in a root `os` builds, like a staged
one, a clean build, or an install. it signs files at their paths on the
esp, which isn't mounted there, so it would only fail. `os` turns it off
for those transactions by linking `zz-sbctl.hook` to `/dev/null` in a hook
directory libalpm reads after the root's own.

when sbctl can't sign, say its keys are gone, `os apply` and `os update`
stop, but a rollback, a fallback, or `os gc` goes on: the menu is written,
new images go on the esp unsigned, and so do images built again, while
ones that can't be built again stay as they are. a warning names them.

turning `secure_boot` on or off changes the file, so it waits for a
reboot, with "secure boot" as the reason, and the next boot tries it once.
the keys are in `/var`, which no generation holds, so a rollback keeps
them. `os gc` signs images it finds unsigned when the running generation
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

every `os apply`, `add`, `remove`, `enable`, `disable`, `edit`, or `update`
that changes the machine records the result as the next generation, labeled
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
status` says if a system account's id ever changes anyway. a generation
waiting for the next boot gets them once more as the machine shuts down, from `yoq-carry.service`, so a password you change
between `os rollback` and the reboot comes along too.

when the esp is `/boot`, as archinstall sets it up, the kernel and
initramfs live on the esp, outside every root. each generation therefore
keeps copies of its own in its root's `/boot` directory, underneath the
esp's mount point, where grub can read them. the top entry boots from the
esp itself, so a kernel that `pacman` installs directly is the one it
boots. rolling back puts that generation's kernel back on the esp, when it
fits (see below).

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

until that reboot, `os apply` refuses to run, as it does after a rollback,
since a second change would start from the running root and leave the
first one behind. `os add` and the like still edit the config and the
lock, and `os apply` after the reboot makes the change.

the next boot runs the new generation, while the menu's default stays on
the one before. the menu that adds the new generation already keeps that
default, and the trial's one-shot boot is set up after it, so a power
cut in between boots the generation before, not one nothing has tried.
once the machine is up, `yoq-health.service` checks it:
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

if the new generation can't boot at all, the next boot lands on the default
by itself, since the trial entry was only for one boot. a kernel panic
reboots after 10 seconds, on every bootloader. either way, `os` notices on
that boot, makes it the newest generation with its config,
and `os status` explains what happened:

```
note: generation 7 didn't come up healthy, so this machine went back to generation 6. it's generation 8 now, with its config. `os rollback 7` tries 7 again.
```

until that reboot, the machine can't hibernate. resuming goes through the
bootloader, which would start the new generation's kernel with the memory
of the one running now, so `os` turns hibernation off in `/run`, which the
next boot clears. suspending to memory still works.

on grub, if you pick an older entry from the menu before the trial
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
`os rollback --to-booted` needs, or while a new generation waits for the
next boot.

limine and systemd-boot need copies of each generation's boot files on the
esp, and with the esp at `/boot` the running kernel lives there too. `os
plan` and `os apply` check the esp's free space before anything is built:
a change to a kernel, its initramfs, or microcode that won't fit stops with
E0131. the size is guessed from the running system's boot files, with a
little to spare. the error says which generations `os gc --keep 1`
would remove to make room, or, with grub or refind, that the esp only
holds the running system's files and has to be cleared by hand. when a new
generation's real files still don't fit, `os` doesn't record it, and the
running system stays as it was. a staged change that fails to build on a
nearly full disk also says the disk is the likely reason.

with the esp at `/boot`, a generation that has booted well, or one `os
rollback` starts, gets its kernel put on the esp. if it doesn't fit there,
nothing is copied: the generation boots the kernel in its own root, `os
rollback` or the health check says why, `os status` shows a note, and the
next boot tries again once there's room.

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
- only the three root layouts above, on a partition or right inside luks
  on one. a root on lvm, even lvm inside luks, or on another
  device-mapper volume, isn't supported yet, and `enable-rollback` says
  so.
- generations with limine are tested on archinstall's layout with snapper,
  not on a real omarchy install. omarchy builds its own unified kernel
  images, and `os` doesn't boot those: it boots the kernel and initramfs
  files in `/boot`, or with `[boot] uki`, images it builds from them. the
  vm tests boot images on systemd-boot and limine so far.
- secure boot is tested on systemd-boot only. grub as `os` installs it
  doesn't boot under secure boot, and limine stops booting if its config's
  checksum was enrolled (`limine enroll-config`), since `os` edits
  limine.conf. a generation from before `uki` boots a kernel without a
  signature, so on systemd-boot and refind the firmware refuses it while
  secure boot is on.

## later

- system accounts with the same ids on every machine a config repository
  describes, so restoring a backup onto a new machine keeps ownership
