# changelog

## unreleased

- `os init --new` writes a config for a machine with nothing on it yet,
  from a few questions and the hardware the live system sees: a kernel,
  grub, firmware, microcode, a gpu driver, networkmanager, and a user who
  can use sudo.
- the install plan notes what a new machine usually needs and its config
  lacks: firmware on real hardware, a network, and a user who can use sudo.
- the usage docs walk through installing from a thumb drive, step by step.
- enable-rollback converts a root that `snapper rollback` made, like
  `@/.snapshots/2/snapshot`, and makes the btrfs top level the default
  subvolume again for grub and refind.
- a lock from an earlier day builds, installs, and rolls back from the arch
  linux archive, for packages the cache doesn't have: mirrors keep only
  today's. `os update --date` resolves against the archive for that day,
  and `os install` no longer needs `--update` for an older lock.
- `os status` lists what changed on the running system after a staged
  generation was built, since those changes stay behind at the reboot.

## 0.1.1

generations work with every bootloader arch users run, and each one falls
back on its own from a trial boot that doesn't come up. a change that needs
a reboot is built beside the running system instead of into it. a machine
can be installed straight from its config repository, from yoq os's own
live iso, and `os uninstall` takes it all back off.

### every bootloader arch users run

- generations work with limine, refind, and systemd-boot, besides grub,
  without switching bootloaders. limine and systemd-boot get kernels
  copied to the esp; refind reads them from btrfs.
- all four fall back on their own when a trial boot doesn't come up:
  limine and systemd-boot through their one-shot entry, and refind through
  the firmware's one-time boot and a copy of refind in `EFI/yoq-trial`.
- `os status` notices a boot menu that lost os's generations, like a
  limine.conf another tool rewrote, and `os gc` writes them back.
- `enable-rollback` stops snap-pac's snapshots of the root, since each
  change is a generation already.

### new machines, and leaving

- `os install <config> --disk <dev>` puts the machine a config repository
  describes on a blank disk, from a live system: an esp, btrfs with the
  generations layout, the clean build as generation 1, and grub.
- a live iso of yoq os's own, built from arch's releng profile with `os`
  and what `os install` runs, comes with each release.
- `os uninstall` leaves plain arch on the running system: the config back
  in `/etc/yoq`, the pacman database back in `/var/lib/pacman`, and a
  bootloader set up the way arch sets it up. other generations stay unless
  you ask for them to go.
- `os build --clean <dir>` builds a root from the config and the lock
  alone, and lists what's on this machine that they don't explain.
- a config repository for several machines works: without
  `/etc/yoq/machine.toml`, `os` reads `/etc/yoq/hosts/<hostname>/machine.toml`.

### new commands

- `os edit` opens the config in your editor, checks it once it's saved,
  and commits and applies it, putting it back if it doesn't load and you
  stop there.
- `os diff <a> [<b>]` shows what differs between two generations:
  packages added, removed, and at other versions, and the config between
  their commits.
- `os doctor` checks how os is set up on the machine and says what to fix.
- `os docs` prints the whole reference as it came with this os.

### repositories and the aur

- `[repos.<name>]` declares a package repository with its server and
  signing key. `os` writes it for pacman, includes it from pacman.conf, and
  trusts the key. a plain http server needs a key.
- `aur = [...]`, or `os add --aur`, builds packages from the aur in a clean
  chroot with makechrootpkg, after a review of each new or changed recipe,
  into a local repository. the lock pins their recipe commits.
- reviews show every file in a new recipe, with control characters escaped
  so nothing can hide a line. a lock's recipe has to be a git commit, and
  a recipe has to build under its own name.
- a pacman.conf repository with `SigLevel = Optional` or `Never` is read
  that way, instead of as signed, and pacman.conf's includes are read the
  way pacman reads them.

### trial boots and the health check

- a change that needs a reboot is built into the next root, a snapshot of
  the running one, and the running system doesn't change until the reboot.
  a staged kernel boots from its own root until it has come up healthy.

- the health check also wants a default route within a minute when the
  config turns on networkmanager, systemd-networkd, iwd, dhcpcd, or connman.
- while a new generation waits for its reboot, the machine can't
  hibernate, since resuming would start the new kernel with the old one's
  memory.
- system accounts packages make come along into every root os makes, so
  an id is never given to a different account after a rollback, and a
  package installed again gets its files in `/var` back. `os status` says
  if a system account's id changes anyway.
- a generation waiting for the reboot gets the machine's passwords and
  state once more at shutdown, so a password changed after `os rollback`
  isn't left behind.

### fixes

- boot entries keep the running system's kernel arguments. `/proc` files
  were read as empty, which also left a clean build's mounts behind.
- only one os changes a machine at a time. another one says which process
  has it and stops, rather than running a second transaction beside it.
- right after `enable-rollback`, before the reboot, `os apply` and `os
  uninstall` see that a generation is waiting, even when `/var` moved.
- files os writes are never readable by anyone else on the way to their
  mode, and a symlink left where os writes its temporary copy isn't
  followed.
- the config refuses a sysctl value or server with a line break in it, and
  a unit name that isn't one.
- a service whose unit can't be enabled, like one without an `[Install]`
  section, is only started and stopped, instead of showing up in every plan.
- `os gc` refuses to run from a boot menu copy of an older generation.
- a limine trial that can't be set up no longer looks like a failed boot.
- `os` runs `/usr/bin/mkinitcpio` itself, not a wrapper earlier in `PATH`
  that might stop to ask a question.

## 0.1.0

the first release. `os` runs an arch machine from one config file, and on a
btrfs root with grub it keeps whole-system generations you can boot back
into.

on any arch install:

- `os init` reads the machine into `machine.toml`, `imported.toml`, and
  `machine.lock`, and changes nothing else.
- `os plan` and `os apply` manage packages (through libalpm, at the exact
  versions in the lock), `[system]` settings, services (over sd-bus),
  users and groups, files, sysctl, kernel modules, cpu microcode, and gpu
  drivers.
- `os update` resolves against today's arch packages, shows the arch news
  since the last update and a short summary of what moves, and writes the
  new lock only once the machine has it.
- `os add`, `remove`, `enable`, `disable`, and `adopt` edit the config in
  place, keeping its comments and formatting, and relock it.
- `os status`, `os why`, and `os history` explain the machine; a pacman
  hook records changes made with `pacman` directly.
- `os rollback` goes back to an earlier config and lock from the package
  cache.
- `[desktop]` covers hyprland, pipewire, and the login: greetd, sddm, or a
  tty. an omarchy profile ships in `/usr/share/yoq/profiles`.

on a btrfs root with grub, `os enable-rollback` adds generations:

- every change is a generation in the boot menu, and `/var`, `/home`,
  `/root`, `/srv`, and `/usr/local` stay out of them.
- `os rollback [n]` starts an older generation as a new one, with its
  config, and passwords, host keys, and the machine id carry over.
- a change that needs a reboot boots once on trial. a failed health check,
  a hung boot, or a kernel that can't boot falls back to the generation
  before by itself.
- `os gc` and `os pin` manage how many generations stay.
- it works on arch's cloud image layout and on archinstall's, including an
  esp at `/boot`.

everything takes `--json`, errors have stable codes (`os explain`), and the
limits are listed in `docs/generations.md`.
