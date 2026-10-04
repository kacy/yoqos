# changelog

## unreleased

### new

- `[firewall]` with `backend = "ufw"` and `allow` rules like `"22/tcp"`
  or `"53/udp from 172.16.0.0/12 to 172.17.0.1"`. yos installs ufw,
  writes its config and rules files the way `ufw allow` does, turns the
  service on, and runs `ufw reload` when the rules change. nothing comes in
  but what's allowed, and a rule added by hand shows up as a change.
- yoq os is now yos, and its command is `yos`, not `os`. the package is
  `yos` (and `yos-git`), the config lives in `/etc/yos`, state in
  `/var/lib/yos`, and everything yos writes says yos: units like
  `yos-health`, the esp's `yos` directory, boot entries, `yos.trial` on
  the kernel command line, `YOS_*` variables, and json documents named
  `yos.plan/1` and the like. a short name of its own, apart from the yoq
  scheduler it came from, and no `/usr/bin/os` to bump into another
  package's.
- on a machine yoq os set up, yos stops with E0138, since it reads none of
  yoq os's state. the way over: with the old package installed, `os
  uninstall`, then `mv /etc/yoq /etc/yos` and `mv /var/cache/yoq
  /var/cache/yos`. a config with repos or aur also drops
  /etc/pacman.d/yoq-repos.conf and its include, and E0138 waits for that
  too. `yos plan` reads the config as it was, history and all, and the
  first apply swaps the files yoq os generated under its own names, like
  99-yoq.conf, for yos's. `yos update` builds aur packages again into
  yos's repository, and `yos enable-rollback` turns generations on again.
  the two packages install side by side while you switch, and yos's
  pacman hook stays quiet until you have. ci runs that whole move, from a
  machine 0.1.5 set up.
- `yos enable-rollback` turns generations on again after an uninstall.
  the root an uninstall leaves running is in @roots, and yos took that as
  generations being on already, said so, and did nothing. a root in @roots
  without yos's records is a plain machine's now, everywhere yos looks, and
  the first generation is numbered after it. gc keeps that first generation
  whatever its number, and leaves alone the generations an uninstall kept
  from before it.
- man pages: `man yos` and `man yos-generations`, made from docs/usage.md
  and docs/generations.md with lowdown when the package builds, so
  they're never out of step with the docs. the release tarball and the
  live iso have them too, and ci lints them with mandoc.

### fixes

a review of the whole code base turned these up.

- a keyed custom repository lost its package signature checks after the
  first apply: yos read its own `SigLevel = Required DatabaseOptional`
  back as unsigned. only the package half of SigLevel counts now.
- a service systemd skips for a condition, like bluetooth.service on a
  machine without an adapter, counts as running. it was planned "start"
  forever, every apply ended "still differ", and on the rollback rung
  every trial boot failed its health check and fell back.
- `yos init` on a machine with aur packages, like yay, put them in
  `packages`, where they can't resolve, so there was no lock and no hint.
  they go under `aur` in imported.toml now, and `yos update --no-apply`
  builds them and writes the lock.
- `yos apply` commits the config, so hand edits it makes real are in the
  history, and a generation names a commit that has them. a rollback
  commits edits it's about to write over first.
- ctrl-c, a dropped ssh session, or a kill during the package transaction
  waits for it to finish, hooks and all, rather than leaving a package
  half replaced and the initramfs unbuilt.
- a lock applied on a machine without that day's databases, like `yos
  install` without `--update`, failed on any package arch updated earlier
  that day. those come from the arch linux archive's copy of every
  package now, checked against the lock's sha256 and their signatures.
- a change that needs a reboot is built into the next root, and those
  builds couldn't turn a unit off: switching display manager failed to
  build, and a service turned off in the same update stayed on. they
  also put a new user's home, and files under /root, /srv, and
  /usr/local, in the directories the data subvolumes hide at boot.
- the carry at shutdown put the running root's pacman keyring and
  subuid/subgid over a staged root's, undoing keys the build imported,
  archlinux-keyring's populate, and new users' id ranges.
- `yos rollback` with no number goes to the generation before the
  newest, whatever its number. after `yos gc --keep 1` it said "there's no
  generation 5".
- enable-rollback moves subvolumes nested in /var and the data
  directories, like /var/lib/machines and docker's, which came over as
  empty directories. it refuses a second run while the first generation
  waits for its boot, takes its steps back when one fails with an error,
  and a run cut off partway leaves nothing refusing changes to the old
  root, and says what to delete before running again.
- resolving never finished when a package in the set provides and
  conflicts with a real one something else depends on by name, like a
  -git build.
- installs and removals go in one transaction, so an update that bumps a
  library a package on its way out still needs no longer fails, saying
  no database provides it.
- a repository on this machine's disk (`Server = file://...`, like
  aurutils keeps) is read where it is. the download client had no
  file://, so init and update failed on it.
- /etc/pacman.d/yos-repos.conf is written before pacman.conf includes it,
  so an apply that fails after can't leave pacman reading an include of
  a missing file. once the last repository or aur package goes, it's no
  longer written again on every apply.
- the running kernel's modules kept through an upgrade move aside when a
  rollback before the reboot puts that kernel back, rather than stopping
  it as a file conflict.
- the kernel `[boot] kernel` names needs a reboot whatever it's called,
  like linux-cachyos, and linux-rt and linux-rt-lts are on the list. they
  were upgraded live, with no trial boot. the pacman hook rewrites the
  menu for any installed kernel package.
- a `[files]` entry for /etc/mkinitcpio.conf, a preset, or modprobe
  options rebuilds the initramfs and waits for a reboot, like a drop-in,
  and /etc/fstab and /etc/crypttab wait for one too.
- aur builds under sudo read the caller's makepkg.conf as root, could put
  the package in the caller's PKGDEST, and left it owned by the caller in
  yos's repository, where it went into later builds. builds get root's
  setup now, and their packages are root's.
- enable-rollback refuses a yos binary that anyone but root can change,
  like one in a build directory: every generation's boot and shutdown
  units run it as root. once a root has the yos package, its units run
  the packaged yos, not the copy `yos install` leaves in /usr/local/bin,
  which upgrades passed by. `yos doctor` warns while that copy is there.
- `yos doctor` counts a tpm pin as protection: it called a pin-protected
  key "sealed to nothing" and told you to enroll it again without the pin.
- `yos install` gives /root mode 0750, as arch does; it was 0755, open to
  every user. the names of secrets the live system lacks no longer come
  out as garbage. `--host` takes dotted names, and checks the host's
  config sets that hostname, since the new machine finds its config
  under hosts/ by it, and a machine reads hosts/<its hostname> first even
  when the repository has its own machine.toml. after `--yes`, it prints
  the commands that set a password, since the new root isn't mounted
  once it's done. the live iso has the profiles a config can include.
- `yos add` on a list wrapped with several items a line copied the line's
  other items into the new one, or wrote broken toml.
- an including file's `source`, `text`, or `secret` for a file replaces
  whichever the include set; both stayed, and the config wouldn't load.
- `gpu = "nvidia"` with a kernel other than `linux` brings nvidia-open-dkms
  and the kernel's headers: nvidia-open's modules are built for `linux`
  alone, so the initramfs build failed and the machine had no driver.
- `yos init` on an nvidia machine that doesn't load nvidia's modules early
  leaves `gpu` out and imports the driver packages, so the first plan is
  empty rather than a new drop-in and a reboot.
- the examples that give a user zsh install it, and the docs say which
  lists add up across includes, and how to replace one.
- arguments typed at the boot menu for one boot, like
  `systemd.unit=multi-user.target`, `single`, or `init=/bin/sh`, stayed in
  every entry yos wrote after, fallbacks included.
- with sbctl's keys made again but not enrolled, a rollback, a fallback,
  gc, or the pacman hook signed every image and grub again with them, and
  the firmware refused all of it. they leave the signed files as they are.
- `yos doctor` showed only the config's errors when it didn't load, and
  none of its checks. without generations, it no longer fails a root on
  lvm, luks it can't judge, or a small esp, which only generations need.
- an aur chroot that mkarchroot didn't finish, after a network failure or
  ctrl-c, is made again instead of failing every build.
- gc deleted a generation's subvolumes when its record wouldn't read; it
  sweeps nothing while one doesn't. a missing esp mount is an error, not
  a crash.
- a service that failed to restart after an apply left the exit code at 0
  and the rest unrestarted. all are tried, and a failure fails the apply.
- listing a user's primary group in `groups` planned "join" forever, and
  nvidia-settings and the like counted as a driver needing a reboot.
- every git yos runs ignores GIT_DIR and its kin, as config commits did,
  so a hook or `git rebase --exec` can't point it at another repository.
- `yos install` copies a local config directory as root's, takes a
  /dev/disk/by-id link for the disk it names, and doesn't call the disk
  unbootable when it stopped before touching it. `init --new` quotes its
  answers as toml.
- `--root` naming / another way, like `//`, is the running machine, with
  its lock and boot checks. `--json` output stays valid json with DEL or
  c1 characters in it.
- the pacman hook says when another yos keeps it from writing the menu,
  `status --json` has the fallback notice the text shows, builds say the
  units they turn on for their first boot, and the clean build report
  says when it couldn't list the files.
- `zig build test` always runs, so a change to test fixtures alone is
  tested.
- limine.conf with yos's begin line but no end line lost every entry
  after it, the machine's own included, at the next menu write. the
  entries stay now.
- a staged generation whose menu couldn't be written left a trial note
  for it, which misdirected the next fallback. the note goes back as it
  was. a trial that couldn't be set to boot next says so.
- a database download that's an error page or cut short was kept for the
  whole day. it has to look like a database, or the next server is tried.
- a system account back at the id it first had was reported as changed.
  `yos config show` keeps a `[remove]` that lets a core package go.
  `yos install --update` refuses an aur list before building it on the
  live system.
- ctrl-c or a dropped ssh session during `yos install` or enable-rollback
  stops it after the step it's in: install cleans up, rather than leaving
  the disk held by daemons in a namespace that outlived it, and
  enable-rollback takes back every step, rather than leaving subvolumes
  that stopped every run after.

## 0.1.5

the important one first. machines installed with `os install --tpm` on
current arch got a tpm key that wasn't sealed to anything, so the tpm
would hand it to whatever booted. after upgrading, run `os doctor`, and if
its tpm seal check fails, run the command it shows, which makes the key
again sealed to pcr 7.

the rest came from a round of tests that tried harder to break things:
trials whose kernel won't load, hangs before the watchdog starts, power
cuts at each step of a trial, an older entry picked by hand, kernel
upgrades with rollbacks across them, and upgrading os itself from 0.1.0
and 0.1.3. grub starts under secure boot now, and `examples/` has whole
machines to borrow from.

### new

- grub starts under secure boot. `os` installs grub with shim's check off
  and grub's `tpm` module built in, as the arch wiki does for your own
  keys, and with `secure_boot` it signs grub along with the images. a grub
  that isn't the one `os` signed last, like one installed before this,
  is installed again and signed. `os uninstall` under secure boot signs
  the grub it leaves behind, and needs sbctl's keys for that, and arch's
  kernel signed, as on systemd-boot and refind. grub's tpm
  module needs a tpm 2.0, so without one, `secure_boot` on grub stops
  `os plan` with E0136, and facts carry `tpm2`.
- `os plan` and `os apply` stop with E0137 while the firmware enforces
  secure boot without sbctl's key in its db, as after `sbctl create-keys`
  makes new keys. images signed with it wouldn't start, and limine and
  refind hang on one instead of falling back. facts carry `db_enrolled`,
  and `os doctor` has a "firmware keys" check.
- `os doctor` checks that the tpm's key still opens a luks root, without
  opening anything. after turning secure boot on, it doesn't until it's
  made again, and the boot asks for the passphrase. the same goes for
  switching between unified kernel images and plain kernels, since
  systemd's stub adds to pcr 7. `os uninstall` on a machine that boots
  images says so before it starts: arch's plain kernel boots next, so
  the passphrase is asked once, and it names the `systemd-cryptenroll`
  command that makes the key again.
- `os doctor` warns when the tpm unlocks the root on limine, even with
  secure boot on: limine loads a kernel without the firmware's check, so
  someone who can change its menu can boot their own with the disk
  unlocked.
- `examples/` has whole machines to read and borrow from: a minimal one,
  an encrypted laptop with secure boot, hyprland, kde on nvidia, a home
  server, a container, aur packages, and a fleet of two that share files.
  ci checks every one, and resolves them against today's arch packages.

### fixes

- E0123's hint quotes a provider name with a dot in it, like
  `"libxtables.so" = "iptables"`. copied as it was, the bare name made a
  toml table instead of a choice, and the config wouldn't load.
- on a luks root, a passphrase typed more than 90 seconds after the prompt
  came up landed in emergency mode, since the initramfs gave up waiting
  for the root. every generation there now has
  `x-systemd.device-timeout=infinity` in its `rootflags`.
- `os install --tpm` seals the tpm's key to pcr 7, the firmware's secure
  boot state, as the docs always said. machines installed with
  `os install --tpm` on systemd 258 or later got a tpm key bound to no
  pcrs, since systemd-cryptenroll seals to nothing unless told, so the tpm
  handed the key to anything that booted, a system on a usb stick
  included. `os doctor` now fails on a key like that and shows the
  `systemd-cryptenroll ... --tpm2-pcrs=7` command that enrolls it again.
- on grub, an entry that can't load its kernel or image falls back to the
  generation the trial falls back to. grub was given that generation by
  name, which it ignores for a fallback, so it showed the failed entry
  again and again instead of falling back, and the watchdog never started.
- an older entry picked by hand while a trial waits leaves the trial
  waiting, on limine, systemd-boot, and refind too. those cleared the
  trial's one-shot whatever booted, so `os` took the pick as the trial
  failing, and rolled the machine back to the generation picked, config
  and all. on refind, the check for a trial that hadn't booted yet looked
  at the wrong efi variable, so every boot looked like it had.
- a trial whose kernel or image the bootloader can't load falls back
  instead of stopping at an error screen. systemd-boot's trial entry has
  a boot counter, which makes systemd-boot 258 and later reboot into the
  default when it can't start it, and `os` doesn't try a trial whose
  files are missing, cut short, or changed since it put them on the esp,
  checking right after it sets the trial up and again at shutdown.
  limine and refind wait for a key otherwise.
- a trial that drops to an emergency shell, in the initramfs or the
  root, reboots into the generation before instead of waiting for a
  password, through `yoq-emergency.service`, which a mkinitcpio hook puts
  into a systemd initramfs too; a busybox one gets a hook that does the
  same. the watchdog starts with the root's systemd, so a unit that hangs
  before `sysinit.target` can't keep it from rebooting the machine. the
  next generation gets both.
- a grub trial that os 0.1.3 armed falls back if it fails, when the os
  that judges it is newer, like one in /usr/local upgraded before the
  reboot. 0.1.4 took only its own note in /var as a sign that os armed a
  trial, so it ended that one and kept the failed boot. the journal's
  armed event, which 0.1.3 wrote, counts now too.
- without generations, an apply that upgrades the running kernel's
  package keeps that kernel's modules until the reboot, as arch's
  kernel-modules-hook does. pacman took them away with the old package,
  so nothing new loaded until the reboot, like a usb stick's driver. the
  first `os apply` after the reboot removes them.
- the update screen lists the kernel and the other packages that need a
  reboot first among the notable ones. they were in name order, so a few
  weeks of major version bumps could push the kernel into "and n more".
- a power cut while a trial is set up no longer leaves the machine on the
  generation before with nothing saying why. os notes the trial before the
  menu that holds the default back, and the next boot sets the trial up
  again, so the boot after tries it. before, that boot ran the older
  generation for good, while the config and lock said the newer one.
- a power cut while a trial that passed is made the default no longer
  looks like a failed trial. os notes that it passed first, and the next
  boot finishes making it the default, where it used to fall back and
  make a new generation from the one before, though nothing was wrong.
- a fallback cut off after it made its generation, before it ended the
  trial, doesn't make a second one at the next boot. it ends the trial
  and says what happened.

## 0.1.4

this one is about disks and boot chains. `[files]` can hold secrets that
never go into the config or the lock, `os install --encrypt` puts the root
on luks (with a tpm key if you want one), and generations can boot as
unified kernel images, signed for secure boot with your own sbctl keys.
the fixes come from three review passes: power cuts around trial boots,
logs that grew too big to read, and a long list of ways a user, a cloned
config, or an aur recipe could get something past a plan.

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
- taking `[boot] encrypt` out of the config on a luks root whose own
  mkinitcpio hooks can't unlock it stops `os plan` and `os apply` with
  E0135, since the initramfs left would never open the root.
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
- a kernel, microcode, or initramfs change made with pacman directly gets
  the boot menu written again from os's pacman hook, where the newest
  entry boots copies on the esp or an image: limine, systemd-boot, a luks
  root, or `[boot] uki`. the entry kept booting the old kernel, whose
  modules pacman had removed, until the next generation.
- a rollback or fallback cut off after it made its generation, but before
  it put back that generation's config, gets the config put back at the
  next boot. the next `os apply` used to apply the newer config to the
  older system. the commit that puts it back names the generation now.
- `os events` keeps each log's events in the order they were written,
  merging the journal and the drift log by time. it sorted them all by
  time, so after the clock went back, an apply's later events could come
  out before its earlier ones.
- `os update` stops when the clock says it's before the lock's date, like
  a clock reset to 2000 before ntp sets it. it used to write a lock dated
  then, which every apply after took for an old one, fetching from the
  archive for that day, and the next update showed years of news.
  `--date` still sets any date.
- `os update` shows arch news posted on the old lock's day too. a lock's
  date is a whole day, and an item posted later that day, after the
  update that made the lock, never showed in any update.
- `os doctor` flags a lock dated after today by the clock, which passed
  as a fresh one.
- `os gc` writes the boot menu again even with nothing to remove, as the
  messages that send you to it say. it only did when the menu had lost
  os's entries or had unsigned images, so copies on the esp that went
  missing, or went stale after `mkinitcpio` by hand, stayed that way.
- os sets its umask to 022 when it starts, as pacman does. run from a
  root shell with umask 0, the directories it and its tools made, like
  the ones under /var/lib/yoq and the config's .git, were writable by
  anyone, who could then plant a generation's record, or a git setting
  that runs a command as root.
- `os install` won't fetch a config over plain http, git's own protocol,
  or ftp, or follow a redirect to one. anything on the way could change
  the config, and with it what runs as root on the new machine.
- a `[files]` path can't have a control character in it. one with a nul,
  written as `\u0000` in the toml, showed in the plan as one path, like
  `/etc/sudoers.d.off/x`, while os wrote the part before the nul,
  `/etc/sudoers.d/x`. checked writes refuse a nul in a path too.
- `[system] locale` and `keymap` take letters, digits, and `_.@+-`
  only. they go unquoted into /etc/locale.conf and /etc/vconsole.conf,
  which are shell: every login shell sources the first, and mkinitcpio's
  hooks source the second as root. a value like `C.UTF-8$(id)` ran there
  as a command, though the plan showed only a locale.
- everything os prints goes out with control characters as escapes, like
  `\x1b`, except newlines and tabs, and so do the c1 controls in utf-8.
  plans, errors, `os status`, `os diff`, and the aur review print text
  that others control: a cloned config and its lock, a recipe's
  .SRCINFO and what its build prints, file names on the esp. an escape
  sequence in any of them could move the cursor to hide a line of a plan
  before the yes, or set the clipboard. progress keeps its own escape
  for redrawing its line.
- an aur review shows a file whose name git quotes, like `é.install`.
  it was listed but its content was left out, though it can be the
  install script that runs as root. a symlink shows as one, and a file
  git can't show says so.
- an aur review shows a recipe's changes as text whatever its own
  .gitattributes says. one that marked its files `-diff` showed a
  changed PKGBUILD as "Binary files differ". the review also escapes the
  c1 controls in utf-8 and the marks that reverse the direction text
  shows in.
- a package file an aur recipe commits is removed before the build. one
  that sorted first, like `foo-0-0-any.pkg.tar.zst`, went into the local
  repository instead of what the build made, though the review only
  named it as a binary file.
- the copy of a recipe an aur build runs in is removed when the build
  ends. its files belonged to the build user, so a build could leave a
  program there, set-uid to that user, for anyone to run, and with it
  change the next recipe after its review.
- on grub, os notes a trial in /var when it arms one, as it does on the
  other bootloaders, and a trial only grub's env file on the esp names
  never makes the machine fall back. anything that could write the esp
  could plant one that booted an older generation once, and the health
  check then made that generation the newest, with its config, for good.
- a kernel, initramfs, or microcode file whose name has anything but
  letters, digits, and `._+-` is left out of the boot menu. names went
  unquoted into grub.cfg, so a file on the esp called
  `x;set root=(hd9);-ucode.img` became grub commands in every menu os
  wrote after, and went into each root's /boot with the rest.
- a config's includes stop at 256 files read, counting a file again for
  each include of it. a few files that each included the next twice were
  read millions of times, so a cloned config could keep `os install`
  from ever showing its plan.
- `os adopt` checks the file it reads: it opens it once, without
  following a symlink, and looks at what it opened. it used to check the
  path and then read it again, so a user who could write the file's
  directory, like a service's own under /etc, could swap in a symlink to
  /etc/shadow in between and have it copied into the config.
- `os install` clones a config into a directory only root can go into.
  git writes a url's password or token into the clone's .git/config,
  which anyone on the live system could read until os took it out.

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
