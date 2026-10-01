# changelog

## unreleased

### new

- `[files."<path>"] secret = "<name>"` writes a value that never goes into
  the config or the lock. `os secret set <name>` keeps it, encrypted with
  systemd-creds under `/var/lib/yoq/secrets`, and `os secret list` and
  `os secret rm` go with it. a secret's file is `0600` unless the entry
  says otherwise, and the plan points out a mode that lets others read it.
- plans and facts compare a secret's file by an hmac-sha256 under a key
  only the machine has, so neither shows the value or a plain hash of it.
- a secret this machine doesn't have stops `os plan` and `os apply` with
  E0133, which names the `os secret set` to run, and `os status` lists it
  as failing.
- `os why <path>` names a file's secret, and `os schema secret` and `os
  schema secrets` describe the new `--json` documents.
- `os install --encrypt` puts luks2 under btrfs. cryptsetup asks for the
  passphrase, or `--passphrase-file` gives it, read once and never copied.
  `--tpm` adds a tpm key with systemd-cryptenroll and keeps the passphrase
  as a way in.
- `[boot] encrypt = true` adds sd-encrypt to mkinitcpio's hooks, with a
  drop-in, when they can't unlock luks already. `os init` sets it on a luks
  root, and `os init --new --encrypt` (or `--tpm`) writes it.
- facts name the luks volume under the root: its uuid, mapper name, and
  partition.
- `os enable-rollback` and `os doctor` check that the initramfs unlocks a
  luks root.
- `[boot] uki = true` boots generations from unified kernel images, which
  `os` builds with each generation's own ukify, without a command line in
  them, and shares on the esp by content. every bootloader's entries pass
  the command line to the image. `os plan` counts the images against the
  esp's room, and `os gc` removes the ones no entry uses.
- facts note a machine that boots unified kernel images already, from
  mkinitcpio's presets or `EFI/Linux` on the esp, and `os init` sets
  `[boot] uki` there when ukify is installed.
- `[boot] secure_boot = true`, with `uki`, signs every image `os` puts on
  the esp with sbctl's keys, before it gets there, along with refind's
  btrfs driver. it brings sbctl, waits for a reboot like a new kernel, and
  stops with E0134 when sbctl has no keys. `os` never makes or enrolls
  keys; usage.md has the one-time steps.
- `os doctor` checks sbctl, its keys, the firmware's secure boot and setup
  mode, and lists efi files on the esp without a signature. facts carry
  the same, and `os gc` signs images left unsigned.

### fixes

- on a luks root, grub and refind boot every generation from copies on the
  esp, since they can't read btrfs inside luks, and grub.cfg no longer
  looks for a root filesystem none of its entries use.
- the trial watchdog's five minutes count from when it starts in the booted
  root, so a passphrase typed slowly at a trial boot doesn't count against
  it.
- a build or install that ends only stops processes in its own mount
  namespace that use the root it built. a shell in another terminal whose
  working directory was `/mnt/yoq`, or a command that named a path there,
  was killed too.
- `os install` closes the luks volume an `--encrypt` run left open when it
  was cut off, with or without `--encrypt` this time. before, a run
  without it couldn't wipe the disk the volume held.
- `os enable-rollback` refuses a root on lvm, or another device-mapper
  volume that isn't luks, and `os doctor` flags one. lvm inside luks
  looked like a plain partition, so grub's entries looked for the root on
  a disk it can't read. facts carry the volume's kind as `root_dm`.
- `--passphrase-file` reads the file straight into one buffer that's
  wiped after, so a file that's too long, or a read that grew its buffer,
  leaves no copy in memory, and it refuses a file of more than one line,
  whose passphrase nobody could type at boot.

## 0.1.3

os can now tell you what it did, as json events, and why a file or unit is
on the machine. `os adopt` takes /etc files into the config, and installs
and applies show progress while packages download and install, which a
stalled-looking vm install showed was missing. most of the rest is fixes
that new failure tests and fuzzing turned up: power cuts, full disks and
esps, and mkinitcpio drop-ins that never reached a staged initramfs.

### new

- `os apply`, `os install`, `os update`, and `os rollback` show progress
  while libalpm downloads and installs packages: one updating line per step
  on a terminal, a few lines per step in a log, and nothing under `--json`.
- `os events` prints what os did as json lines: applies, config commits,
  generations, rollbacks, trials, gc, pins, enable-rollback, installs, and
  pacman runs outside os. `--follow` keeps printing new ones, and `--since`
  starts at a time.
- `os schema lock` and `os schema events`.
- `os why` answers for files (the config key that writes one, or the
  package that owns it) and for units (the key that enables one).
- `os adopt /etc/<file>` copies a file next to the config and adds a
  `[files]` entry for it, then applies like `os add`.
- `--` ends flags for every command.
- `os status` lists services the config turns on that systemd can't
  enable, since they have no `[Install]` section.
- aur packages build against the lock's package date.
- `os update` stops before any review with E0130 when a recipe needs an aur
  package the config doesn't list.
- a split aur recipe only installs the package named after it.
- `os plan` and `os apply` stop with E0131 before building anything when a
  new kernel, initramfs, or microcode won't fit on the esp. facts carry the
  esp's free space, the running boot files' sizes, and the generations.

### fixes

- a mkinitcpio drop-in os writes, like nvidia's or one from `[files]`,
  never made it into a staged generation's initramfs, or into a clean build
  or `os install`. the initramfs is now rebuilt inside the root being
  built, and every drop-in waits for a reboot, like a kernel.
- `os apply` plans again after the yes, and refuses with E0129 if the plan
  changed in between.
- a pacman lock left by a power cut no longer blocks every later apply:
  `os apply` clears one from before this boot.
- an apply cut off after pacman's transaction but before it wrote "done"
  no longer leaves every later apply saying it didn't finish. the next
  apply finds the machine already matches, so it records the old one as
  done, along with the generation it never got to.
- a staged change that can't be recorded fails the command instead of
  exiting 0.
- boot files that don't fit on the esp are refused before anything is
  copied, naming the generations `os gc` would remove. a staged build that
  fails on a nearly full disk says so.
- config edits no longer write invalid toml under a key that isn't a table
  or into an inline table, or leave a stray comma behind.
- with the esp at `/boot`, a kernel that doesn't fit there after a good
  boot or a rollback is no longer copied halfway. the generation keeps
  booting the kernel in its own root, os says why, and the next boot tries
  again.
- `os diff` with no generations says so. arch news titles lose control
  characters, and news dates out of range are skipped.

## 0.1.2

a new machine is easier to set up: `os init --new` writes a config to
start from, the live iso shows the install steps, and an older lock
installs from the arch linux archive. saved plans and json schemas help
with scripting. there's also a batch of security and reliability fixes
from a review of everything that runs as root.

### new

- `os init --new` writes a config for a machine with nothing on it yet,
  from a few questions and the hardware the live system sees: a kernel,
  grub, firmware, microcode, a gpu driver, networkmanager, and a user who
  can use sudo.
- the install plan notes what a new machine usually needs and its config
  lacks: firmware on real hardware, a network, and a user who can use sudo.
- the usage docs walk through installing from a thumb drive, step by step.
- the iso greets you with a banner and the install steps, and its boot
  menu says yoq os.
- `os plan -o <file>` saves a plan, and `os apply <file>` applies exactly
  that plan, or refuses with E0128 if it's out of date.
- `os schema` prints json schemas for the plan, facts, status, and errors
  documents, and for `machine.toml`.
- enable-rollback converts a root that `snapper rollback` made, like
  `@/.snapshots/2/snapshot`, and makes the btrfs top level the default
  subvolume again for grub and refind.
- a lock from an earlier day builds, installs, and rolls back from the arch
  linux archive, for packages the cache doesn't have: mirrors keep only
  today's. `os update --date` resolves against the archive for that day,
  and `os install` no longer needs `--update` for an older lock.
- `os status` lists what changed on the running system after a staged
  generation was built, since those changes stay behind at the reboot.

### fixes

- `os edit` applies the config after saving it. it had been stopping after
  the commit.
- security fixes for what runs as root: a lock's date is checked before it
  names a cache directory, toml nesting has a depth limit, a relative file
  source can't go through a symlink, and `os install` keeps a url's
  credentials out of the new machine's config repository.
- a saved plan's hash covers the content of the files it writes, so the
  plan goes out of date when that content changes.
- atomic writes and esp copies are synced to disk. a staged root that fails
  or can't be recorded is dropped. a carry stops instead of writing back an
  account file it couldn't read. the systemd job wait has a real 90 second
  deadline, and config edits and updates take the machine lock.
- refind trials no longer leave a firmware boot entry behind each time, and
  `os uninstall` can finish its pacman database step after being stopped
  partway.
- config history ignores GIT_DIR and GIT_WORK_TREE from the environment, so
  `os` run from a git hook commits to its own config.

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
