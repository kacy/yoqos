# changelog

## unreleased

### new

- `[files."<path>"] secret = "<name>"` writes a value that never goes into
  the config or the lock. `os secret set <name>` keeps it on the machine,
  encrypted with systemd-creds under `/var/lib/yoq/secrets` and bound to
  no tpm pcrs, so turning secure boot on doesn't make it unreadable. `os
  secret list` and `os secret rm` go with it. at a terminal, the value is
  typed twice without echo, whatever `--json` and stdout are; otherwise
  it's read from stdin byte for byte.
- a secret's file is `0600` unless the entry says otherwise, and the plan
  points out a mode that lets others read it. plans and facts compare the
  file by an hmac-sha256 under a key only the machine has, so neither
  shows the value or a plain hash of it, and `os apply` writes a secret
  only if it still has the value the plan was made for.
- a secret this machine doesn't have stops `os plan` and `os apply` with
  E0133, which names the `os secret set` to run, and `os status` lists it
  as failing. `os install` checks the live system has every secret the
  config names before it erases the disk.
- `os secret set`, anything that decrypts a secret, and `os install
  --passphrase-file` mark the process as not dumpable before they hold
  the value, so it stays out of core dumps and out of /proc/<pid>/mem.
- `os why <path>` names a file's secret, and `os schema secret` and `os
  schema secrets` describe the new `--json` documents.
- `os install --encrypt` puts luks2 under btrfs. cryptsetup asks for the
  passphrase, or `--passphrase-file` gives it: one line, read once into a
  buffer that's wiped after. `--tpm` adds a key for a tpm 2.0 with
  systemd-cryptenroll and keeps the passphrase as a way in. the plan
  notes that without secure boot, the tpm keeps a powered-off disk safe,
  not a machine left alone. a run that was cut off with its luks volume
  open has it closed by the next one.
- `[boot] encrypt = true` adds sd-encrypt to mkinitcpio's hooks, with a
  drop-in, when they can't unlock luks already. `os init` sets it on a luks
  root, and `os init --new --encrypt` (or `--tpm`) writes it.
- generations work on a btrfs root inside luks. every bootloader boots
  them from copies on the esp, since none of them reads btrfs inside luks,
  with the arguments that unlock the root. facts name the luks volume
  under the root: its uuid, mapper name, and partition. `os
  enable-rollback` and `os doctor` check that the initramfs unlocks it,
  and `os uninstall` on grub adds those arguments, and the consoles, to
  `/etc/default/grub` when it lacks them.
- `[boot] uki = true` boots generations from unified kernel images, which
  `os` builds with each generation's own ukify from the kernel and
  initramfs copies in its root, never from the esp's files. images are
  named by their content and systemd's stub, and shared on the esp. every
  bootloader's entries pass the command line to the image, quoted
  arguments included. `os plan` counts the images against the esp's room,
  and `os gc` removes the ones no entry uses.
- facts note a machine that boots unified kernel images already, from
  mkinitcpio's presets or `EFI/Linux` on the esp, and `os init` sets
  `[boot] uki` there when ukify is installed.
- `[boot] secure_boot = true`, with `uki`, signs every image `os` puts on
  the esp with sbctl's db key, before it gets there, along with refind's
  btrfs driver. it brings sbctl, waits for a reboot like a new kernel, and
  stops `os apply` and `os update` with E0134 when sbctl has no keys. `os`
  never makes or enrolls keys; usage.md has the one-time steps.
- with secure boot, each entry's image has its command line built in, and
  the entries pass none. the stub ignores a command line from the
  bootloader then, so one added to an entry on the esp, like
  `init=/bin/sh`, never reaches the kernel. a signed image takes its
  kernel from the root's package in `/usr/lib/modules` and builds its
  initramfs in the root with mkinitcpio. images are per entry, shared by
  entries with the same command line, and a trial boots a twin with
  `yoq.trial` in it. `os plan` counts the room they take, and the room
  signing an unsigned image takes.
- an image on the esp without a signature from sbctl's db key, say from
  before `sbctl create-keys` made new ones, is built again from its
  root's files and signed. `os` never signs a file as it finds it on the
  esp. while the firmware enforces secure boot and sbctl has keys, every
  menu write signs, even for a generation without `[boot] secure_boot`.
  `os rollback`, a trial's fallback, and `os gc` still write the menu when
  sbctl can't sign, and warn about the images left unsigned.
- `os rollback` warns, before it asks, when the generation it goes back to
  is from before `[boot] uki` and the firmware enforces secure boot,
  except on limine, which starts that kernel itself. `os uninstall` on
  systemd-boot or refind won't start while the firmware enforces secure
  boot and arch's kernel in `/boot` has no signature.
- `os doctor` checks sbctl, its keys, the firmware's secure boot and setup
  mode, and lists efi files on the esp without a signature. facts carry
  the same, and `os gc` signs images left unsigned.
- `os doctor` warns when the tpm unlocks the root and secure boot is off.
  a warning shows as `warn` and fails nothing; its json check has
  `"warn": true`.
- `os install` shows a url source in its plan, with a line saying its
  packages' scripts run as root on the live system and the new machine.
  treat a config repository like code.
- a build or install that ends stops gpg's agents and any other process
  still using the root it built, and only those: processes in its own
  mount namespace, each signaled through a pidfd after a check that it's
  still in there.

### fixes

- a quoted kernel argument, like `acpi_osi="!Windows 2012"`, goes into
  every generation's entries as it was. it used to be split at its
  spaces, which lost runs of spaces, and a word inside its quotes that
  looked like `root=` was dropped.
- the trial watchdog's five minutes count from when it starts in the
  booted root, not from the kernel's start, so a passphrase typed slowly
  at a trial boot doesn't count against it. a machine that turned
  generations on earlier gets the new `yoq-watchdog.timer` in its next
  generation.
- the menu that records a generation going on trial keeps the default on
  the generation it falls back to, and the trial's one-shot boot comes
  after: grub.cfg's default, limine's and systemd-boot's default entry,
  and refind's `default_selection`. the default moves when the health
  check passes it. a power cut between the menu write and the trial used
  to leave the new generation as the default with no trial and no
  fallback. the trial is now set up before old generations are removed,
  and if it can't be, the new generation becomes the default as the
  message says.
- a kernel, initramfs, or image os puts on the esp has its directory
  synced once it's renamed into place, before the menu that boots it is
  written. fat kept the rename in memory, so a power cut right after a
  menu write could leave the newest entry pointing at a file that wasn't
  there.
- with `/boot` as the esp, a rollback or fallback marks the new root
  unsettled while it copies that root's kernel and initramfs onto the
  esp. a power cut halfway through used to leave a kernel and an
  initramfs there that didn't match, and the next menu write booted them
  and copied them into the root's own `/boot`. a staged generation's note
  is now written when it's recorded, and one that can't be recorded puts
  back the note the running root had.
- subvolumes in `@roots` and `@gens` that no generation uses go at the
  next gc, which runs after every new generation. a staged build stopped
  with ctrl-c or a power cut left its whole root behind for good, and so
  did a rollback or gc cut off between a snapshot and its record.
- the journal's lines go on the end of the file in place, so an event
  another os records at the same moment, like the health check at boot,
  can't drop an apply's `done` line, and a nearly full disk only needs
  room for the line. a line a power cut left half written stays on its
  own.
- `os gc`, `os pin`, and `os carry` take the machine lock, and the health
  check at boot waits for it. a gc could remove an image an apply had just
  put on the esp for its menu, a pin could write back the record of a
  generation gc had just removed, and a fallback at boot could take the
  same generation number as an `os apply` run right after login.
- `os enable-rollback` refuses a root on lvm, or on another device-mapper
  volume that isn't luks, and `os doctor` flags one. lvm looked like a
  plain partition, so grub's entries looked for the root on a disk it
  can't read. facts carry the volume's kind as `root_dm`.
- `[files]` writes and removals walk down to the file one directory at a
  time and write in the directory they opened. they follow root's
  symlinks, inside the root being written, but stop with the path and the
  reason at a directory another user owns or can write to (unless it's
  sticky) and at a symlink another user owns. before, a user who owned a
  directory on the way, like their home, could point the write at any
  file on the machine.
- the btrfs top level os works in is mounted at `/run/yoq/private/top`, in
  a directory only root can go into, and the directories in a root's
  `/tmp` where os builds and signs images are made fresh and root's
  alone. another user could reach a root's `/tmp` through the old mount
  at `/run/yoq/top`, make that directory first, and swap an image before
  it was signed.
- commit subjects from the config's history lose their control characters,
  like news titles, before `os history`, `os rollback`, or anything else
  prints them. a repository `os install` cloned could otherwise move the
  cursor or rewrite the terminal.
  directory on the way, like their home, could point the write, a secret's
  value included, at any file on the machine.
- a checked `[files]` write no longer leaves a directory on the way open.
  in an install, one in the target kept it busy, so its luks volume
  couldn't close until os exited.
- the health check judges a trial by the config and lock its generation
  was made with. a service turned on with `os enable` while a staged
  generation waited for its reboot wasn't in that generation, so it
  wasn't running, and the trial fell back.
- packages for a lock from an earlier day download from the archive as it
  was that day, then the day after, then the mirrors. an `os update`
  answered just after midnight utc, or an apply of a lock made just
  before, looked for packages only in an archive day that was older than
  the lock, or not there yet.
- a journal or drift log past 64 MiB read as empty, so an apply cut off
  went unnoticed, every pacman run ever showed as drift, and `os events`
  printed nothing. os now reads the end of a log for what happened last,
  and `os events` reads a long one a window at a time.
- pacman runs after an apply show as changed outside os even when the
  clock went back in between, like ntp fixing a clock that ran ahead.
  an apply's done line notes where the drift log ended, and the runs past
  that count, where before only runs stamped later than the apply did.
- a machine that turned generations on with 0.1.0 gets its units brought
  up to date in its next generation too: the watchdog timer that counts
  from the root's own start, and `yoq-carry.service`, which it never had,
  so a password changed after `os rollback` was left behind. 0.1.0 marked
  its units with a line of its own, which the update didn't take as os's.
- taking `[boot] encrypt` out of the config on a luks root whose own
  mkinitcpio hooks can't unlock it stops `os plan` and `os apply` with
  E0135. the plan used to remove the drop-in and rebuild an initramfs that
  couldn't open the root, which without generations left a machine that
  didn't boot.

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
