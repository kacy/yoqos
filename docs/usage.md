# using yoq os

yoq os describes an arch linux machine in one short file and shows you
exactly what would change to make the machine match it. this page covers how
to use it today.

## what works today

`os` reads a machine, writes a config for it, keeps that config and its lock
up to date, tells you what's different, and applies the difference. `os
apply` installs and removes packages, sets the `[system]` settings, turns
services on and off, creates users and sets their shells and groups, and
writes files and sysctl settings. on a btrfs root with grub, limine,
refind, or systemd-boot, `os enable-rollback` adds whole-system
generations, and a change that needs a reboot is then built beside the
running system instead of into it; see [generations.md](generations.md).

| command | what it does |
| --- | --- |
| `os init` | writes a config that describes this machine |
| `os status` | what matches the config, what changed, what's failing |
| `os plan` | every change applying would make; `-o <file>` saves it |
| `os apply` | makes those changes, after asking; `os apply <file>` applies a saved plan |
| `os history` | the generations |
| `os rollback` | goes back to an earlier generation |
| `os enable-rollback` | turns on whole-system generations (btrfs, with grub, limine, refind, or systemd-boot) |
| `os gc`, `os pin` | clean up old generations, or keep one |
| `os uninstall` | takes `os` off the machine, leaving plain arch |
| `os install` | puts the machine a config describes on a blank disk |
| `os update` | resolves the config against today's arch packages into the lock |
| `os add`, `os remove` | edit the package list, and the lock with it |
| `os edit` | opens the config in your editor, checks it, and applies it |
| `os diff` | what differs between two generations |
| `os doctor` | checks how `os` is set up on the machine |
| `os enable`, `os disable` | turn services on or off in the config |
| `os adopt` | puts packages installed outside the config into it, or a file from `/etc` |
| `os secret` | keeps, lists, or removes the values `[files]` entries name with `secret` |
| `os why` | which config line brings a package, file, or unit in |
| `os config show` | the config with all its includes merged |
| `os facts` | what `os` sees on this machine |
| `os explain` | the long explanation of an error code |
| `os help`, `os version` | the command list, and the version |
| `os schema` | json schemas for the config and for what `--json` prints |
| `os docs` | this page, the readme, and generations.md, as one document |
| `os build --clean` | builds a root from the config and the lock alone |

`os help` doesn't list the last three.

## installing

each release on github has an arch package and a tarball, with a
`sha256sums.txt` beside them:

```
sudo pacman -U yoq-os-0.1.3-1-x86_64.pkg.tar.zst
```

the package holds the `os` command, a pacman hook that records direct
`pacman` use for `os status`, the profiles in `/usr/share/yoq/profiles`,
and these docs. the tarball holds the same files, laid out like `/usr`.

to build it yourself, `dist/PKGBUILD` makes `yoq-os-git` from the
repository's `main` branch, or `yoq-os` from a release tag with
`YOQ_VERSION`. `YOQ_SOURCE` points it at a local clone instead of github:

```
cd dist
makepkg -si                              # yoq-os-git, from main
YOQ_VERSION=0.1.3 makepkg -si            # yoq-os 0.1.3, from v0.1.3
YOQ_SOURCE=file://$PWD/.. makepkg -si    # this checkout
```

## building by hand

you need zig 0.16.

```
zig build -Dalpm -Dsystemd
./zig-out/bin/os help
```

`-Dalpm` links libalpm, pacman's library. it's what reads installed packages
and resolves the config into a lock. `-Dsystemd` links libsystemd, for
reading which services are enabled and running. both are already on any arch
machine. without them, `os` still builds and runs, but it can't see packages
or services, and it can't resolve a lock.

`zig build test` runs every test, including the fuzz tests in `src/fuzz.zig`,
which go once over their seeds. to fuzz one for a million inputs (plain
`--fuzz` runs until you stop it):

```
zig build test -Dfuzz --fuzz=1M -Dtest-filter="fuzz lock"
```

## getting started

on an arch machine, as root:

```
os init
```

`init` reads the machine and writes its config to `/etc/yoq`:

- `machine.toml` holds the machine's own settings: hostname, timezone,
  locale, users, and enabled services. it names the cpu and gpu only when
  their microcode or driver is already installed, so reading the config
  back doesn't plan a driver install.
- `imported.toml` lists every package that was installed on purpose.
  `machine.toml` includes it.
- `machine.lock` records the exact version of every package, resolved
  against today's arch packages. `init` writes it when it can reach the
  package mirrors; otherwise `os update` does it later. when a package
  depends on something several packages provide, and one of them is
  installed, `init` records that one in `[providers]`.

`init` changes nothing else on the machine. then:

```
os status
os plan
```

on an up-to-date machine the plan is empty, or close to it. if the machine is
behind, the plan shows the upgrades.

from there, the idea is to make the config yours. move the packages you care
about from `imported.toml` into `packages` in `machine.toml`, and delete the
ones you don't. `os plan` shows what that would remove, and `os apply`
removes it.

## the everyday commands

### status

```
$ os status
archlinux · lock from 2026-09-25 (today)

ok        11 packages
changed   installed but not in the config: nano  -> os adopt keeps them, os plan removes them
          14 packages aren't installed yet  -> os plan
          settings differ: system.hostname, system.timezone, system.locale  -> os plan
          services not as configured: sshd.service, tailscaled.service  -> os plan
failing   none
```

each "changed" line ends with the command that deals with it. with the
pacman hook that comes with `os` in place, a direct `pacman -S` or `pacman
-R` also shows up, as "touched with pacman since the last apply", until the
next `os apply`. the hook records nothing for os's own transactions.

when an upgrade leaves a new default beside a config file you changed, as
`<file>.pacnew`, status lists it too. for files `os` writes itself, `os`
keeps its version and the `.pacnew` is only there to read. status also
lists services still running files an upgrade replaced, services the
config turns on whose unit has no `[Install]` section (they start, but
`enable` does nothing for them, so they won't come back at boot unless
another unit pulls them in), and on a machine
with generations, a `note:` line when `os` fell back from a generation
that didn't come up healthy.

`os status` warns when the lock is more than 14 days old, since an old lock
holds back security fixes. a secret the config names that this machine
doesn't have, or can't decrypt, is failing, with the `os secret set` that
fixes it. it exits with 1 when something is failing.

### plan

```
$ os plan
packages
  + amd-ucode 20250917-1  (hardware.cpu)
  + git 2.51.0-1
  + neovim 0.11.4-1
  + openssh 10.0p1-4  (services.ssh)
  + ripgrep 14.1.1-1
  + tailscale 1.88.1-1  (services.tailscale)
  + zsh 5.9-5
  - nano 8.6-1
  +7 dependencies (-v to list)
system
  ~ hostname: archlinux -> atlas
  ~ timezone: UTC -> America/New_York
  ~ locale: en_US.UTF-8
services
  + sshd.service: enable, start  (services.ssh)
  + tailscaled.service: enable, start  (services.tailscale)

plan: 16 to add, 3 to change, 1 to remove · reboot needed: microcode
```

`+` adds, `~` changes, and `-` removes. the text in parentheses is the config
key that asked for a change, when it isn't the `packages` list itself. `-v`
(or `--verbose`) lists the dependencies one by one. the last line says
whether the change needs a reboot, and why. `--lock <file>` plans against
another lock file.

on a machine with generations, a plan that changes a kernel, its
initramfs, or microcode also checks that the new boot files fit on the
esp, and stops with E0131 if they don't (see
[generations](generations.md)). `os apply` checks the same before it
builds anything.

`-o <file>` also saves the plan, as the same json `--json` prints. `os apply
<file>` then applies that plan and nothing else: if the config, the lock,
or the machine changed since, so that the plan would be different, it
refuses with E0128 and changes nothing. that's useful when one person or
script writes the plan and another looks it over before it runs.

### apply

```
$ os apply
packages
  + tree 2.3.2-1

plan: 1 to add, 0 to change, 0 to remove · no reboot

apply this? [y/N] y
downloading 1 package, 58 KiB  1/1
checking keys
checking packages
loading packages
checking file conflicts
installing 1 package  1/1

applied 1 change.
```

`apply` shows the plan, asks, and then makes the changes. once you say yes
it plans again, and if the plan isn't the one it showed, because the
config, the lock, or the machine changed in the meantime, it stops with
E0129 and changes nothing. run it again and look over the new plan.

services being turned off stop first, then one pacman transaction installs
and removes packages, then the settings change, then new services are
enabled and started. `apply` waits for each start and stop to finish, and a
service that fails to start stops the apply with the unit's name. services
change only when systemd runs the machine: not under `--root`, and not in
a container.

it installs exactly the versions in the lock, checks each package against
the lock's checksum and arch's signatures, and marks packages as explicit or
dependencies to match the config. it uses the machine's own pacman.conf for
mirrors and download settings. packages come from the lock's date, so run
`os update` first to move to today's. mirrors keep only today's packages,
so for a lock from an earlier day, anything the cache doesn't have comes
from the arch linux archive, which is slower.

afterwards it plans again and says if anything still differs. arch doesn't
restart services after an upgrade, so when packages changed, `apply` also
lists the services still running files the upgrade replaced and offers to
restart them. services a session depends on, like d-bus and display
managers, are left for a reboot.

`--yes` (or `-y`) skips the question; without a terminal, `apply` needs it.
it needs root and a build with libalpm. on a machine with generations, it
refuses to run on a copy of an older generation booted from the menu, since
that copy is remade from its record (`os rollback --to-booted` keeps it
first), and while a new generation is waiting for the next boot.

a pacman hook or package script that fails after the packages changed makes
`apply` exit with 1 and print what the hook or script said. the packages
stay changed, so fix the cause and run `apply` again.

read the plan before you say yes: `apply` removes every package the config
doesn't ask for. the exception is a few core packages (`base`,
`filesystem`, `glibc`, `pacman`, and `systemd`). if the config leaves one
out, `plan` and `apply` stop with E0126, since that's almost always a
mistake. to remove one on purpose, name it in `[remove]`.

while pacman's transaction runs, its progress goes to stderr. on a
terminal each phase is one line that updates in place, like `installing 168
packages  80/168 linux`. in a log or a pipe each phase gets one line, and a
long one also gets a line at each quarter, so a big update stays short.
`--json` shows none of it. `update`, `rollback`, `add`, and `install` do
the same when they apply.

`apply` keeps a journal in `/var/lib/yoq/journal`. if an apply is cut off
halfway, the next one says so and starts from the machine as it is. if it
was cut off after it made its changes, the next one has nothing to do, so
it records the old apply as done, and on a machine with generations,
records the generation it missed.

### add, remove, enable, disable

```
$ os add fd
+ packages "fd"

saved /etc/yoq/machine.toml.
updated machine.lock: +1.

packages
  + fd 10.3.0-1

plan: 1 to add, 0 to change, 0 to remove · no reboot

apply this? [y/N] y

applied 1 change.
```

these edit `machine.toml` for you, keep its comments and formatting, and
then apply the change the way `os apply` does: the plan, a question, and
the change. `--yes` skips the question, and `--no-apply` stops after the
edit. they also stop after the edit with `--json`, without a terminal
unless `--yes` is given, and when apply can't run here (not root, or a build
without libalpm). `os apply` makes the change later.

they also update the lock, since a service brings its package. they
resolve against the package date the lock already has, so adding one
package never upgrades anything else. that needs the package databases for
that date, which `os update` downloads. if they aren't there, `add` says
so and doesn't apply, and `os update` brings the lock up to date later. a
change the lock can't follow, like a package that doesn't exist, is taken
back: the file stays as it was, and nothing is committed.

`remove` works on packages from includes too: it adds them to `[remove]`
rather than editing the included file. if a package comes from a service or
a hardware choice, `remove` tells you which one to change instead.

### edit

```
os edit
```

opens the config in `$VISUAL` or `$EDITOR`, or `vi` if neither is set.
when you save and quit, `os` loads it again. if it doesn't load, you see
why and can edit it again; say no and the file goes back to how it was.
once it loads, `os` relocks it if it needs to, commits it as "edit", and
shows the plan and asks, the same as `os add`. `--no-apply` stops after
the commit. it needs a terminal.

### update

```
os update
```

downloads today's package databases, using the repositories and mirrors in
`/etc/pacman.conf`, and resolves the config against them. then it applies
the result like `os apply`: the plan, a question, and the change.
`machine.lock` moves to the new packages only once the machine has, so
saying no, or an apply that fails, leaves the lock as it was. `--yes` skips
the question. with `--no-apply`, with `--json`, or without a terminal and
`--yes`, it only writes the new lock, and `os apply` makes the change
later.

the config's aur packages are fetched and built first, each new or changed
recipe after a review of its own; see [aur packages](#aur-packages).

when a package depends on something several packages provide, like
`initramfs` (mkinitcpio, booster, or dracut), `os update` asks which one you
want and saves the answer in `[providers]` as a commit of its own, so it
only asks once. without a terminal, it stops and says which choices to make.

`--date yyyy-mm-dd` resolves against arch's packages as they were on that
day, from the arch linux archive. `--dbs <dir>` resolves against databases
you already have instead of downloading them, and `--date` then names the
day they're from.

an update can move hundreds of packages, so its plan is a summary:

```
packages
  upgrades 142    new 3    removed 1   (-v lists them)
  notable  linux 6.16.8.arch1-1 -> 6.17.1.arch1-1
           mesa 1:25.1.0-1 -> 1:25.2.0-1
           icu 76.1-1 -> 77.1-1

plan: 3 to add, 142 to change, 1 to remove · reboot needed: kernel
```

notable upgrades are the ones that need a reboot, graphics and boot
packages, and new major versions. past eight, the rest are counted on an
`and N more` line, so the screen stays short. `os update -v` lists every
package.

before the plan, `update` lists the arch news posted since the lock's
last date. arch posts there when an update needs a hand, so read those
items before saying yes.

databases are cached in `/var/cache/yoq/sync/<date>/`, so running it again
the same day doesn't download anything.

### adopt

```
os adopt                        # everything installed but not in the config
os adopt htop                   # just htop
os adopt /etc/ssh/sshd_config   # a file, as it is now
```

`adopt` is the other way to settle drift: instead of removing a package you
installed with `pacman -S`, it puts it in the config.

given a path, it takes a file you edited in `/etc`, or one with a `.pacnew`
beside it, into the config. the file is copied to `files/<path>` next to the
config, like `files/etc/ssh/sshd_config`, and gets a `[files]` entry with
that `source` and its mode. then it applies like `os add` does, with
`--yes` and `--no-apply`. it won't take files outside `/etc`, files `os`
writes already, or symlinks. it also leaves out machine state like
`/etc/shadow` and ssh host keys, and files not everyone can read: those may
hold secrets, and the config should stay safe to publish.

### why

```
$ os why perl-error
perl-error: needed by git -> perl-error
git: in packages  (/etc/yoq/machine.toml:2)
```

`why` follows the lock's dependency graph back to the config line that
brings a package in. it exits with 1 when nothing in the config needs the
package.

it takes files and units too. a path says which key makes `os` write the
file, or, for one `os` leaves alone, which package ships it. a unit, or a
service name like `ssh` that isn't a package, says which key enables or
disables it:

```
$ os why /etc/sysctl.d/99-yoq.conf
/etc/sysctl.d/99-yoq.conf: os writes it for sysctl  (/etc/yoq/machine.toml:9)
$ os why /etc/ssh/sshd_config
/etc/ssh/sshd_config: not managed by os; it comes with openssh
`os adopt /etc/ssh/sshd_config` takes it into the config
$ os why sshd.service
sshd.service: enabled by services.ssh  (/etc/yoq/machine.toml:12)
```

a file that holds a secret names the secret, never its value:
`/etc/wifi.psk: os writes it for files."/etc/wifi.psk" secret =
"wifi/home"`.

with `--json`, files print `yoq.why-file/1` and units `yoq.why-unit/1`.

## history and rollback

this section is about machines without generations. with them, history and
rollback work on whole copies of the system instead; see
[generations.md](generations.md).

`/etc/yoq` is a git repository. every change `os` makes there, from `init`,
`add`, `remove`, `enable`, `disable`, `adopt`, `edit`, `update`, and
`rollback`, is a commit with a short message, like `add fd` (`adopt` commits as `add`). if
the config lives inside another repository, like a dotfiles one, `os`
commits there, and only what's in the config's own directory. each commit
is a generation of the machine's config, numbered from the first, and `*`
marks the newest:

```
$ os history
    1  init: atlas as found on 2026-09-25
    2  update packages to 2026-09-25
    3  add fd
*   4  enable tailscale
```

`os rollback` goes back one generation, and `os rollback 2` goes back to
generation 2. it applies that generation's config and lock like `os apply`
does, with the plan and a question first, installing the older package
versions from the local cache, or from the arch linux archive when the
cache doesn't have them any more. once the machine matches, it writes
those files back to `/etc/yoq` as a new generation, `rollback to 2: ...`,
so nothing is lost and `os rollback` again undoes the rollback.

this rolls back packages, settings, services, users, and the files the
config names, not files that package scripts changed, or anything else `os`
doesn't manage.

edits you make to the config by hand aren't committed by `os apply`. `os
rollback` commits them first, as "local edits before rollback", so going
back never loses them.

## generations (early)

on a btrfs root with grub, limine, refind, or systemd-boot, `os
enable-rollback` turns the machine's history into generations: whole
copies of the system you can boot from the menu. it shows its checks and
steps and asks first; `--yes` skips the question. there, `os rollback [n]`
starts an older generation as a new one for the next boot, `os rollback
--to-booted` keeps the one you booted from the menu, `os gc [--keep n]`
removes old ones, and `os pin <n>` keeps one. `os diff 3 5` shows what
changed between two generations: packages added, removed, and at other
versions, then the config between their commits. with one number, it
compares that generation with the newest. it reads each generation's
root, so it needs root.
[generations.md](generations.md) covers how they work, and what they don't
do yet.

## checking the setup

```
$ os doctor
checks
  ok  config: /etc/yoq/machine.toml
  ok  config history: /etc/yoq
  ok  lock: from 2026-09-25
  ok  pacman hook: installed
  ok  last apply: finished
  ok  boot menu: has os's generations
  ok  units: all in place
  ok  esp space: 612 MiB free on /boot

nothing to fix.
```

`os doctor` looks at how `os` is set up and changes nothing. it checks
that:

- the config loads, and its directory is a git repository;
- the lock is there and under two weeks old;
- the pacman hook that notices changes made with pacman is installed;
- no apply stopped partway.

it also checks that the esp has room for another kernel, and with
generations, that the boot menu has them and that os's units are there. with
the root on luks, it checks that the initramfs can unlock it. with
`secure_boot` in the config, or firmware that enforces secure boot, it
checks that sbctl and its keys are there, says whether the firmware
enforces secure boot or is in setup mode, and lists the efi files on the
esp without a signature. a sudo
rule without a password shows up too: anything running as that user could
change the machine without asking. each check that fails says what to do,
and the exit code is 1 when one does.

## leaving

`os uninstall` takes `os` off the machine and leaves plain arch running the
system you have now. like `enable-rollback`, it lists its steps and asks
first; `--yes` skips the question.

on a machine with generations, it moves the config back into `/etc/yoq`
and the pacman database back to `/var/lib/pacman`, and removes `os`'s
units that run at boot. if `enable-rollback` turned off snap-pac's
snapshots of the root, they come back on. the bootloader gets set up to
boot the running root without `os`:

- grub reads a menu from `grub-mkconfig` in `/boot/grub` again.
- limine gets one plain entry where `os`'s section was.
- refind boots the kernel in `/boot` through `refind_linux.conf`.
- systemd-boot gets one entry of its own, `arch-linux.conf`, as its
  default, where os's were.

limine, refind, and systemd-boot need the esp mounted at `/boot` for this,
since that's where arch installs the kernel.

the other generations stay as btrfs subvolumes unless you say yes when it
asks, or pass `--delete-generations`. the running root stays where it is,
in `@roots/<n>`, and so do `@var`, `@home`, and the other data subvolumes.

last, it removes the `yoq-os` package if pacman installed it, and `os`'s
own state in `/var/lib/yoq`. the config and its git history stay in
`/etc/yoq`. if a step fails, running `os uninstall` again picks up where
it stopped.

## installing a new machine

### what you need

- the live iso, `yoq-os-<version>-x86_64.iso`, from a release. it's arch's
  own live iso, built from the same profile, with `os` and everything `os
  install` runs added.
- a usb drive of 2 gb or more.
- a disk of 16 gib or more for the new machine.
- a machine that boots in uefi mode. secure boot has to be off: the iso
  isn't signed for it, and `os` doesn't support it yet.
- a config repository that describes the machine, or nothing at all:
  `os init --new` writes one on the live system. see [a config for a new
  machine](#a-config-for-a-new-machine).

### step by step

1. write the iso to the drive, from any linux machine. everything on the
   drive is erased; `lsblk` says which one it is.

   ```
   sudo dd if=yoq-os-0.1.3-x86_64.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```

2. boot the new machine from the drive, in uefi mode. its boot menu says
   "yoq os live medium". it comes up at a root shell, like arch's iso,
   with a banner and a short version of these steps on the screen.

3. get online. a wired connection comes up by itself. for wi-fi:

   ```
   iwctl station wlan0 connect "my network"
   ```

4. find the disk to install on. everything on it is erased.

   ```
   lsblk
   ```

5. if you don't have a config for this machine yet, write one:

   ```
   os --config /root/machines/machine.toml init --new
   ```

   it asks for a name for the machine, your user name, and a time zone,
   and looks at the hardware for the rest. `/root/machines` is then a
   config repository to install from, in the next step, and to push
   somewhere once the machine is up.

   for a disk in luks2, add `--encrypt`, or `--tpm` for one the tpm
   unlocks: the config then has `[boot] encrypt = true`, and `tpm2-tss`
   with `--tpm`. see [an encrypted disk](#an-encrypted-disk).

6. install from the config repository:

   ```
   os install /root/machines --disk /dev/nvme0n1 --update
   os install https://github.com/you/machines --host atlas --disk /dev/nvme0n1 --update
   ```

   the first argument is the repository, as a url or a directory. a
   directory with a git repository in it is cloned, so only what's
   committed comes along.
   `--host atlas` picks `hosts/atlas/machine.toml` in a repository for
   several machines; without it, `os` uses the repository's own
   `machine.toml`. for a private repository, git asks for your name and a
   token, as it would anywhere else.

   `--update` resolves the config against today's packages first, and
   commits the new lock to the repository `os` fetched; it ends up in
   `/etc/yoq` on the new machine, so you can push it back from there.
   without it, `os` installs the lock as it is. mirrors only keep today's
   packages, so for a lock from an earlier day they come from the arch
   linux archive, which is slower, but gives you exactly what the lock
   says.

7. read what it's going to do, and say yes:

   ```
   install atlas on /dev/nvme0n1 (476 GiB). everything on it is erased.

   disk      an esp of 1024 MiB at /boot, and btrfs for the rest:
             @roots/1, @var, @home, @root, @srv, @usrlocal
   boot      grub, with generation 1 as its first entry
   packages  412 from the lock (2026-09-29)
   users     kacy
   services  18
   ```

8. set a password for root and each user when it asks. the config never
   holds one.

9. reboot, and take the drive out.

the new machine runs generation 1, with generations from its first boot.
`/etc/yoq` is the repository you installed from, and a machine whose
hostname matches a directory under `hosts/` reads its config from there.
`os` itself comes along as `/usr/local/bin/os`; installing the `yoq-os`
package on the new machine puts the packaged one, and its pacman hook, in
place.

### what it does

`os install` partitions the disk, then builds the machine the way `os
build --clean` builds a root. it records the machine as generation 1 of
the layout `enable-rollback` makes. grub goes on the disk's removable boot
path, which every firmware checks, and gets a boot entry of its own too.
with `--yes`, it doesn't ask anything, and the accounts stay locked until
you give them a password with `passwd -R /mnt/yoq <user>` before
rebooting.

it checks first that the firmware is uefi and that the disk is a whole
disk of 16 gib or more that nothing has mounted. it also checks that the tools it runs are
there, and that the lock has a kernel, grub, and btrfs-progs. arch's own iso works too,
with `os` added: `pacman -U` the release package, or copy the binary. on
another live system, `pacman -S dosfstools btrfs-progs grub git` first.

aur packages wait until the machine is running: install without them,
then add them back and run `os update` there.

### an encrypted disk

```
os install /root/machines --disk /dev/nvme0n1 --update --encrypt
os install /root/machines --disk /dev/nvme0n1 --update --tpm
```

`--encrypt` puts luks2 on the btrfs partition, with btrfs inside it. the
esp stays outside, since the firmware has to read it. the install plan
shows it:

```
encrypt   luks2 under btrfs, opened at boot as /dev/mapper/root
          the passphrase unlocks it, typed at every boot
```

cryptsetup asks for the passphrase itself, on the terminal: twice when it
sets up the partition, once more with `--tpm` to add the tpm's key, and
once more to open it for the install. `os` never sees it. for scripts and
tests, `--passphrase-file <file>` reads it from a file instead, once. it's
one line of up to 4096 bytes, since it has to be typed at boot too, and a
newline at the end of the file isn't part of it. it goes to cryptsetup on
its standard input, and never into the new machine, a log, or json.
without a terminal, `--encrypt` needs `--passphrase-file`.

`--tpm` also puts a key in the tpm, with `systemd-cryptenroll
--tpm2-device=auto`, so the machine unlocks at boot without anyone typing.
the passphrase still works for when the tpm can't unlock it, like after
some firmware updates or with the disk in another machine, so keep it
somewhere safe. `--tpm` means `--encrypt` too, and needs a tpm 2.0; a
1.2 one doesn't count.

the config has to say the root is encrypted, or the new machine's
initramfs can't unlock it: `[boot] encrypt = true` (see [encrypted
roots](#encrypted-roots)). with `--tpm`, it also needs `tpm2-tss` in
`packages`, which the initramfs unlocks with. the install checks both
before it changes anything, and `os init --new --encrypt`, or `--tpm`,
writes them.

the new machine's boot entries name the luks volume and the btrfs inside
it, `rd.luks.name=<luks uuid>=root root=UUID=<btrfs uuid>`, with
`rd.luks.options=tpm2-device=auto` for `--tpm`. there's no line for the
root in `/etc/crypttab`; sd-encrypt reads the command line. on the live
system, the install runs `cryptsetup`, and `systemd-cryptenroll` with
`tpm2-tss` for `--tpm`. yoq os's iso has them all.

### a config for a new machine

`os init --new` writes a small config for a machine with nothing on it
yet. it has what a new machine can't do without: a kernel and grub,
`linux-firmware` on real hardware, the cpu's microcode and the gpu's
driver from what the live system sees, networkmanager, a user in `wheel`,
and sudo for them. `--hostname`, `--user`, `--timezone`, and `--ssh` answer
its questions ahead of time, and without a terminal the first three are
required. `--encrypt` and `--tpm` add what `os install --encrypt` and
`--tpm` need: `[boot] encrypt = true`, and `tpm2-tss` for the tpm.

a config written for another machine only has what it lists, and `os`
doesn't add anything. the install plan notes what a new machine usually
needs and the config lacks, so check that it has:

- a kernel, like `linux`, `grub`, and `btrfs-progs`, which generations
  need;
- `linux-firmware`, on real hardware, or wi-fi and some graphics won't
  work;
- something that brings up the network, like `[services] networkmanager =
  true`, or the machine boots offline;
- a user in `wheel`, and `sudo` in `packages`, or only root can log in to
  run anything;
- `[hardware] cpu`, so the right microcode loads.

a config doesn't need a lock yet to be installed: `os install --update`
makes one.

## clean builds

```
sudo os build --clean /var/tmp/clean
```

builds a whole root in a new directory from the config and the lock
alone, the way pacstrap would: the locked packages, then everything else
the config sets. it takes this machine's pacman setup, keyring, and uid
map, and packages come from `os`'s own cache when it has them. afterwards
it lists what this machine has in `/etc` and `/usr` that the build
doesn't: files nothing in the config or its packages explains, and files
in `/etc` whose content differs. machine state like `/etc/shadow`, the
machine id, and ssh host keys is left out of the comparison. `--json` gives
the whole list.

the directory can't exist yet. `os` makes it itself, writable only by
root, since the build runs package scripts as root inside it, and nobody
else should have been able to put anything there first. everything the
build mounts inside it is unmounted when it ends, however it ends.

the build is the first half of an installer: the same steps, aimed at a
blank disk instead of a directory.

## the config

`machine.toml` is plain toml. a full example:

```toml
version = 1
include = ["imported.toml"]
packages = ["git", "neovim", "ripgrep"]

[providers]
initramfs = "mkinitcpio"

[system]
hostname = "atlas"
timezone = "America/New_York"
locale = "en_US.UTF-8"
keymap = "us"

[boot]
kernel = "linux-zen"

[hardware]
cpu = "amd"
gpu = "nvidia"

[desktop]
session = "hyprland"
audio = "pipewire"
login = "greetd"

[users.kacy]
shell = "zsh"
groups = ["wheel", "video"]

[services]
ssh = true
tailscale = true
bluetooth = false
```

| key | meaning |
| --- | --- |
| `version` | the config format. always 1 for now. |
| `include` | other config files to merge in, relative to this one |
| `packages` | packages you want installed. dependencies come along on their own. |
| `[providers]` | which package provides a virtual one, like `initramfs` |
| `[system]` | `hostname` (a plain name or a dotted one like `atlas.lan`), `timezone`, `locale`, and `keymap` |
| `[boot]` | `kernel`: `linux` unless you say otherwise. `none` for a machine without its own kernel, like a container. `modules`: kernel modules to load at every boot, like `i2c-dev`. `encrypt`: `true` when the root is on luks, so the initramfs unlocks it. `uki`: `true` to boot generations from unified kernel images. `secure_boot`: `true` to sign those images with sbctl's keys. |
| `[hardware]` | `cpu`: `amd` or `intel`. `gpu`: `amd`, `intel`, `nvidia`, or `none`. these bring in microcode and drivers. `nvidia` also loads its modules early, with a drop-in in `/etc/mkinitcpio.conf.d`, unless mkinitcpio.conf does already. |
| `[desktop]` | `session`: `hyprland`. `audio`: `pipewire`. `login`: `greetd`, `sddm`, or `tty`. these bring in their packages; see [the desktop](#the-desktop). |
| `[users.<name>]` | `shell`, and `groups`: the full list of groups beyond the user's own |
| `[services]` | `<name> = true` or `false`, for the services listed below |
| `[files."<path>"]` | a file `os` writes whole: `text` or `source`, and `mode` |
| `[sysctl]` | kernel settings, like `"vm.swappiness" = 10` |
| `[repos.<name>]` | a package repository beyond arch's own: `server`, and `key` |
| `aur` | packages to build from the aur; see [aur packages](#aur-packages) |

`[state]` is read but not used yet.

a key that implies packages, like `gpu = "nvidia"` or `ssh = true`, doesn't
need those packages in `packages` too. the plan shows them with the key that
asked for them.

### services

`[services]` takes short names:

| name | package | unit |
| --- | --- | --- |
| `avahi` | `avahi` | `avahi-daemon.service` |
| `bluetooth` | `bluez` | `bluetooth.service` |
| `cups` | `cups` | `cups.service` |
| `docker` | `docker` | `docker.service` |
| `firewalld` | `firewalld` | `firewalld.service` |
| `fstrim` | `util-linux` | `fstrim.timer` |
| `fwupd` | `fwupd` | `fwupd-refresh.timer` |
| `iwd` | `iwd` | `iwd.service` |
| `libvirt` | `libvirt` | `libvirtd.service` |
| `networkmanager` | `networkmanager` | `NetworkManager.service` |
| `power-profiles` | `power-profiles-daemon` | `power-profiles-daemon.service` |
| `reflector` | `reflector` | `reflector.timer` |
| `resolved` | `systemd` | `systemd-resolved.service` |
| `ssh` | `openssh` | `sshd.service` |
| `tailscale` | `tailscale` | `tailscaled.service` |
| `timesyncd` | `systemd` | `systemd-timesyncd.service` |
| `tlp` | `tlp` | `tlp.service` |

for anything else, name the unit and package yourself:

```toml
[services.syncthing]
unit = "syncthing@kacy.service"
package = "syncthing"
```

services the config doesn't mention are left alone, and so are users.

### users

```toml
[users.kacy]
shell = "zsh"
groups = ["wheel", "video"]
```

`apply` creates a user that doesn't exist yet, with its own group and a
home directory, then sets its shell and groups. `shell` is a name like
`zsh`, found under `/usr/bin`, or a full path; the shell's package has to
be installed, so add it to `packages`. `groups` is the whole list: `apply`
adds the user to the groups missing and takes it out of the others. with
no `groups` at all, its groups are left alone.

`os` manages people's accounts, not system ones: `root`, and accounts like
`bin` or `systemd-*`, can't be declared. user and group names follow
useradd's rules. `os` never deletes a user, and passwords stay yours to set
with `passwd`. every uid `os` gives out is kept in `/var/lib/yoq/ids`, so a
user created again gets its old uid back, and its files in `/home` are
still its own.

### files and sysctl

```toml
[files."/etc/ssh/sshd_config.d/10-local.conf"]
source = "files/sshd.conf"
mode = "0600"

[files."/etc/motd"]
text = "welcome to atlas\n"

[sysctl]
"vm.swappiness" = 10
"net.ipv4.ip_forward" = 1
```

a `[files]` entry is a file `os` writes whole. `text` is the content itself;
`source` names a file next to the config, relative to the config file that
names it, so a repository can keep them together; and `secret` names a
value that stays out of the config (see secrets, below). an entry has
exactly one of the three. `mode` is octal, and `0644` unless you say
otherwise, or `0600` for a secret. `os plan` shows a file that's missing, has
different content, or has a different mode. files the config doesn't name
are left alone, and so is a file you take out of the config. `os adopt
<path>` writes an entry for a file that's already there.

a file under `/etc/mkinitcpio.conf.d`, yours or nvidia's drop-in, changes
the initramfs, so the plan says it needs a reboot, and on a machine with
generations it's built into the next one like a kernel is. `apply` runs
`mkinitcpio -P` once, after every file is in place. a staged generation, a
clean build, and `os install` run it inside the root they're building,
through chroot, the way pacman runs the kernel's own hook there, so that
root boots with the drop-in. a root without mkinitcpio is skipped.

a path is absolute and plain: no `.` or `..` parts, no trailing `/`, and
nothing under `/etc/yoq` or `/var/lib/yoq`, which are `os`'s own. it also
can't be a file another key writes, like the sysctl file below.

`[sysctl]` becomes one file, `/etc/sysctl.d/99-yoq.conf`, and `apply` loads
it right away when systemd runs the machine.

### secrets

```toml
[files."/etc/NetworkManager/system-connections/home.nmconnection"]
secret = "wifi/home"
```

```
sudo os secret set wifi/home     # asks for the value twice, without echo
printf '%s' "$psk" | sudo os secret set wifi/home   # or reads it from stdin
sudo os secret list              # the names, and the files that use each
sudo os secret rm wifi/home
```

some files hold a password or a key, and those don't belong in a config you
might push somewhere. a `secret` key names the value instead, and the value
lives on the machine: `os secret set` encrypts it with `systemd-creds`, with
its default keys (the tpm2 and the host's credential key when there's a
tpm2, else the host key alone), into `/var/lib/yoq/secrets/<name>.cred`.
that directory is root's alone, so every `os secret` command needs root.
`apply` decrypts a value right before it writes the file, and wipes it from
memory once it's written.

a name is letters, digits, `-`, `_`, and `.`, with `/` to group them, like
`wifi/home`; no part of it starts with a dot. a value comes from stdin byte
for byte when stdin isn't a terminal, so `echo` would add a newline to it and
`printf '%s'` doesn't. at a terminal, it's one line, typed twice. values are
up to 64 KiB.

the file gets mode `0600` unless the entry gives a `mode`. one that lets
others read it is allowed, but the plan says so next to the file.

values are machine state, not config. `/var` never rolls back, so a
rollback keeps today's values, and they don't move with the config: another
machine can't decrypt them, so a new machine, or one `os install` puts on a
disk, needs each one set again. until then, `os plan` and `os apply` stop
with E0133 and the `os secret set` to run, and `os status` lists the secret
as failing.

no value ever shows up in what `os` prints or keeps: not in the plan, facts,
status, events, the journal, error messages, the lock, or generation
records. to tell whether a file needs rewriting, the observer hashes the
file and the value with hmac-sha256, under a random key made on the first
`os secret set` and kept beside the values in `/var/lib/yoq/secrets/.key`,
and the plan compares those. anyone can check guesses against a plain
sha-256 of a short password, but not against an hmac without the key, so a
plan or facts document is still safe to share. the plan's hash covers the keyed
hash, so `os apply <file>` won't write a value other than the one the plan
was made for.

reading values needs root, so `os plan` without root can't tell whether a
file holds the current value, and only shows it when it's missing or its
mode differs. `apply` runs as root and sees all of it.

files `os` makes from other keys (the sysctl file, the module list, the
greetd and tty login files, and nvidia's initramfs drop-in) start with a
"written by os" line. once nothing asks for one, `apply` removes it. a file
without that line, one you wrote yourself, is never removed.

### the desktop

```toml
[desktop]
session = "hyprland"
audio = "pipewire"
login = "greetd"
session_config = "files/hyprland.conf"
```

`session` and `audio` install what they need: hyprland and its portal, and
pipewire with pipewire-pulse and wireplumber.

`login` picks how you get to the session:

- `greetd` runs tuigreet on tty1, offering every installed wayland session.
  `os` writes `/etc/greetd/config.toml`.
- `sddm` runs sddm, which finds hyprland's session on its own.
- `tty` has no display manager. with a `session`, logging in on tty1
  starts it through uwsm, from `/etc/profile.d/yoq-session.sh`; without
  one, it's a plain console login.

a login choice owns the display manager. its own is enabled, and every
other one `os` knows (gdm, greetd, lightdm, ly, sddm) is disabled, since
only one can be the display manager. the switch happens at the next boot:
starting or stopping a display manager during `apply` would end the session
you're applying from, so the plan says a reboot is needed. with
generations, that boot is a trial, and the health check wants the new
display manager running. with no `login`, `os` leaves login alone.

`session_config` names a hyprland config next to the machine's config.
`os` copies it unchanged to `/etc/xdg/hypr/`, keeping its extension
(`hyprland.conf`, or `hyprland.lua` for newer hyprland). hyprland reads it
for anyone without a config of their own in `~/.config/hypr`, and a user
config can include it with `source = /etc/xdg/hypr/hyprland.conf`. that
makes it the machine's default, and part of every generation. everything
else in your home directory is yours; `os` doesn't touch it.

### omarchy

the package ships a profile with the system side of an omarchy machine:
hyprland with pipewire, sddm for login, and the services omarchy's
installer turns on (avahi, bluetooth, cups, docker's socket, networkmanager,
power-profiles-daemon, resolved, systemd-oomd, and ufw). it leaves packages
to `os init`, which imports the ones the machine has:

```toml
include = ["/usr/share/yoq/profiles/omarchy.toml", "imported.toml"]
```

on an omarchy install, that plans nothing. omarchy's own updates
(`omarchy-update` and its migrations) still change the machine behind
`os`'s back, so `os status` shows them as drift until `os adopt` or the next
apply settles it. generations work with omarchy's limine, but omarchy's own
limine tools can drop `os`'s entries from `limine.conf`. `os status`
notices, and `os gc` writes them again; see
[generations.md](generations.md#bootloaders).

### kernel modules

```toml
[boot]
modules = ["i2c-dev", "nct6775"]
```

`modules` becomes `/etc/modules-load.d/99-yoq.conf`, which systemd reads at
every boot, and `apply` loads the list right away on a running machine.

### encrypted roots

```toml
[boot]
encrypt = true
```

a root on luks has to be unlocked by the initramfs before anything else
runs. with `encrypt = true`, `os` makes sure mkinitcpio's hooks can do
that. when they have neither `encrypt` nor `sd-encrypt`, it writes
`/etc/mkinitcpio.conf.d/90-yoq-encrypt.conf`, which adds `sd-encrypt`
before `filesystems` and swaps busybox's hooks, like `udev` and `keymap`,
for systemd's, which sd-encrypt needs. with autodetect, mkinitcpio also counts
it as a failed build, without saying why, when it looks for a kind of
module the machine uses and finds none, which is what it finds when the
driver is built into the kernel, as arch's tpm and btrfs drivers are.
sd-encrypt looks for the tpm's on every build, so the drop-in stops
finding none from counting. like any change to the
initramfs, it waits for a reboot.

`os init` sets the key when the root is on luks. an encrypted archinstall
machine has the hooks already, so no drop-in comes with it. `os install
--encrypt` needs the key, since a new machine starts from mkinitcpio's own
hooks. the key holds nothing secret and doesn't say how the disk unlocks:
that's in the luks header and on the kernel's command line.

### unified kernel images

```toml
[boot]
uki = true
```

on a machine with generations, `uki = true` makes every new generation
boot a unified kernel image: its kernel, microcode, and initramfs in one
efi file, which `os` builds with ukify and puts on the esp. it works with
all four bootloaders, and it brings `systemd-ukify` with it. turning it on
or off changes what the menu boots, so the change waits for a reboot and
the next boot tries it once, like a new kernel. see
[generations.md](generations.md#unified-kernel-images).

without generations, `os` doesn't write the boot menu, so the key only
installs ukify. `os init` sets it on a machine that boots unified kernel
images already, like omarchy, when ukify is installed there.

### secure boot

```toml
[boot]
uki = true
secure_boot = true
```

with `secure_boot = true`, `os` signs every unified kernel image it puts
on the esp, so firmware that enforces secure boot will start them. it
needs `uki = true`: a kernel and a separate initramfs can't be signed as
one. it signs only on a machine with generations, where `os` writes the
boot menu. it brings `sbctl` and signs with sbctl's keys.

the keys are yours to make and enroll; `os` does neither. it's a one-time
job, in this order:

1. install sbctl and make the keys: `pacman -S sbctl`, then
   `sbctl create-keys`. they go in `/var/lib/sbctl`.
2. set `uki = true` and `secure_boot = true` under `[boot]`, and run
   `os apply`. like a new kernel, the change waits for a reboot. the next
   generation's images are signed, and so is every image the menu boots.
3. sign the bootloader. `os doctor` lists the efi files on the esp that
   have no signature. `sbctl sign -s <file>` signs one, and the `-s` has
   sbctl's pacman hook sign it again whenever its package updates it.
4. in the firmware setup, clear the secure boot keys, which puts it in
   setup mode. boot, and run `sbctl enroll-keys -m`. the `-m` keeps
   microsoft's keys next to yours: graphics cards and other devices carry
   firmware signed with them, and some machines won't start without it.
5. turn secure boot on in the firmware setup, if enrolling didn't, and
   reboot.

without the keys, `os plan` and `os apply` stop with E0134.

what `os` signs: its images in `yoq/boot` on the esp, and refind's btrfs
driver, which it installs. each image is signed in a work directory inside
the generation's root, then copied onto the esp, so the esp never has it
unsigned. the bootloader itself comes from the bootloader's own install
(`bootctl install`, limine's, `refind-install`), so its signature is yours
to add, as in step 3, and `os doctor` flags it until then. the vm tests
cover systemd-boot. grub won't boot under secure boot the way `os`
installs it: it needs its modules built in and shim's check turned off,
so keep secure boot off with grub for now.

the keys live in `/var`, outside every generation, so a rollback keeps
them. an image is signed when it's written, and while the running
generation or the new one has `secure_boot`, every menu write signs
whatever images the menu boots, so the generation a failed trial falls
back to starts too. a generation from before `uki` boots a plain kernel,
which firmware enforcing secure boot refuses; turn secure boot off in the
firmware before you boot one. the same goes for turning `secure_boot`
off: once it's off, images aren't signed any more.

`os install` won't install a config with `secure_boot = true`: a new
machine has no keys yet. install without it, then follow the steps above
there.

### repositories

```toml
[repos.chaotic-aur]
server = "https://cdn-mirror.chaotic.cx/$repo/$arch"
key = "EF925EA60F33D0CB85C44AD13056513887B78AEB"
```

a repository here works like one in pacman.conf, and travels with the
config to a new machine. it can't be in both: move it out of pacman.conf
when you move it into the config, or `os plan` says so. `os` writes every
configured repository to `/etc/pacman.d/yoq-repos.conf` and adds one line
to the end of pacman.conf that includes it, so plain `pacman` sees them
too, after arch's own.

`key` is the full fingerprint of the key its packages are signed with:
`os` imports it into pacman's keyring and signs it locally, and packages
from the repository must then be signed by it. without a key, its
packages aren't checked, the way pacman's `SigLevel = Optional TrustAll`
works. that's fine over https, or for a `file://` repository on the
machine itself, but a plain `http://` server needs a key: otherwise anyone
between you and it could hand you their own packages.

`os update` resolves against a new repository before any apply, so adding
one and updating is enough. the lock pins each package by hash, but a
repository like this keeps no history, so going back to an older lock
relies on the packages still being in the local cache.

### aur packages

```toml
aur = ["yay-bin"]
```

`os add --aur yay-bin` adds one for you, and `os remove --aur yay-bin`
takes it out. adding one saves the config and stops there; the next `os
update` reviews and builds it.

`os update` fetches each recipe from the aur with git and builds it with
devtools' `makechrootpkg` in a clean chroot of its own, under
`/var/cache/yoq/aur`, as an unprivileged `yoq-build` user. what it builds
goes into a local repository, `yoq-aur`, that `os` reads like any other,
and the lock pins each package by hash and by the recipe commit it was
built from. a recipe that hasn't changed isn't built again.

aur recipes run as code when they build, so `os update` shows a recipe
before building it: the first time, every file in it in full (binary
files by name only), and after that, what changed since the locked
commit. control characters show as escapes like `\x1b`, so a recipe can't
move the cursor and hide a line from you. each recipe is a question of its
own; `--yes` alone doesn't build an unreviewed one. without a terminal,
`os update` stops, unless `--trust-aur` says to build them as they are.

a recipe builds only under its own name: one whose `.SRCINFO` gives a
different pkgbase is refused. from a split recipe, which builds several
packages, only the one named after the recipe goes into `yoq-aur`, and a
split recipe with no package of that name is refused.

an aur package that needs another aur package needs that one in `aur` too,
and `os` builds them in order. before it builds anything, `os update` reads
what each recipe's `.SRCINFO` needs. a need that's in neither the arch
repositories nor `aur` stops it with E0130, which names the package to add.
an `aur` list brings in devtools, which the builds need. builds get their
arch packages as of the lock's date, from the arch linux archive when that
isn't today, so they match what the lock installs. `os add`, `os
remove`, and the like keep the recipes the lock already has; only `os
update` builds.

### includes

a repository for several machines can share files:

```
base.toml
profiles/workstation.toml
hosts/atlas/machine.toml
```

```toml
# hosts/atlas/machine.toml
include = ["../../base.toml", "../../profiles/workstation.toml"]
```

includes merge in order, and the including file always wins.

- package lists merge: every file's packages count.
- other values replace: the last one set wins.
- `[remove] packages = ["nano"]` takes a package out of what the includes
  asked for, and `[remove] aur` does the same for aur packages.
- `unset = ["desktop.audio"]` clears a key an include set. names with dots
  work as written, `sysctl.vm.swappiness`, or quoted,
  `sysctl."vm.swappiness"`.

`os config show` prints the merged config, and `--resolved` adds the file
and line every value came from:

```
$ os config show --resolved
version = 1  # hosts/atlas/machine.toml:1
packages = [
  "base",  # base.toml:1
  "git",  # profiles/workstation.toml:1
  "ripgrep",  # hosts/atlas/machine.toml:3
]
```

## errors

errors say what's wrong and give a code, and errors in the config name the
file and line:

```
error[E0213]: unknown service "sshd"
  --> /etc/yoq/machine.toml:3:1
   | did you mean "ssh"?  (os explain E0213)
```

`os explain E0213` prints the long explanation, and `os explain` lists every
code. E0127 is a step of an apply that failed, like a file that couldn't be
written or a tool that didn't work; the message has the details. E0128 is a
saved plan that's out of date, and E0129 a plan that changed between being
shown and the yes. E0131 is a change whose new boot files won't fit on the
esp, and E0133 a secret the config names that this machine doesn't have.

## scripting

every command takes `--json` and prints one json document. each document
starts with a `schema` field, like `"schema": "yoq.plan/1"`, that names its
shape and version. errors with a code come out as a `yoq.errors/1`
document on stdout under `--json`; other problems, like a file that can't
be written, are an `os: ...` line on stderr either way.

`os schema <name>` prints the json schema for a document: `plan`, `facts`,
`status`, `errors`, `events`, `secret` (what `os secret set` and `rm`
print), or `secrets` (`os secret list`). `os schema config` describes
`machine.toml`, which editors that check toml against a json schema, like
taplo, can use, and `os schema lock` describes `machine.lock`. `os schema`
alone lists them. the schemas come from the same code that writes and reads
the documents, so they can't fall out of date.

`os events` prints what `os` has done on this machine, oldest first, as one
`yoq.event/1` json document a line. that covers applies with their plan's
hash, config commits, new generations, rollbacks, trial boots, and pacman
runs outside `os` that the drift hook caught. it also has `gc` with the
`generations` removed (by `os gc` or after an apply), `pin` with a `step`
of `pinned` or `unpinned`, `enable-rollback` when generation 1 is set up,
and `install` on a machine `os install` put on its disk. `os uninstall`
removes `/var/lib/yoq`, events included, so it leaves none. `--follow` keeps
watching and prints new events as they land, like `tail -f`. every event has
a `time` in unix milliseconds and a `kind`, and the other fields depend on
the kind; `os schema events` has them all.

`--since <when>` leaves out events from before a time, with or without
`--follow`. it takes unix milliseconds, a date (`2026-09-30`), or a date and
time (`2026-09-30T14:00` or `2026-09-30T14:00:05`), all in utc, with an
optional trailing `Z`.

```
$ os events --follow
{"schema":"yoq.event/1","time":1790380800000,"kind":"pacman","packages":["htop"]}
{"schema":"yoq.event/1","time":1790380860000,"kind":"apply","step":"begin","plan":"e4bd7044..."}
{"schema":"yoq.event/1","time":1790380900000,"kind":"apply","step":"done","plan":"e4bd7044..."}
```

the events don't have a store of their own. they come from the apply
journal, `/var/lib/yoq/journal`, where `os` also notes its other events,
and the drift log, `/var/lib/yoq/drift`.

exit codes:

| code | meaning |
| --- | --- |
| 0 | done |
| 1 | the command ran into a problem, or found one: `status` with something failing, `why` with nothing needing the package |
| 2 | the command line was wrong |

`os docs` prints this reference, the readme, and
[generations.md](generations.md) as one markdown document: the version
that came with the installed `os`.

global flags work before or after the command, as `--config path` or
`--config=path`. a flag's value can't be empty or start with `-`:

| flag | meaning |
| --- | --- |
| `--json` | machine-readable output |
| `--config <path>` | the config file, instead of `/etc/yoq/machine.toml` |
| `--root <dir>` | the machine's files live under `dir`, like a mounted install |
| `--facts <file>` | read the machine from a facts file instead of looking at it |

everything after `--` is a name, not a flag, even when it starts with `-`:
`os why -- -x`. global flags after `--` don't count either.

## trying it without an arch machine

`os facts --json` saves what `os` sees on a machine, and `--facts` reads that
back in, so you can plan against a saved machine anywhere. the repository's
test cases work too:

```
zig build
./zig-out/bin/os --config tests/golden/fresh-install/machine.toml \
    --facts tests/golden/fresh-install/facts.json status
```

every directory in `tests/golden` is a small machine: a config, a lock, and a
facts file, along with what `plan` and `status` should say about it.
