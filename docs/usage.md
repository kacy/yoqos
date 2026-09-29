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
| `os plan` | every change applying would make |
| `os apply` | makes those changes, after asking |
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
| `os adopt` | puts packages installed outside the config into it |
| `os why` | which config line brings a package in |
| `os config show` | the config with all its includes merged |
| `os facts` | what `os` sees on this machine |
| `os explain` | the long explanation of an error code |
| `os help`, `os version` | the command list, and the version |

## installing

each release on github has an arch package and a tarball, with a
`sha256sums.txt` beside them:

```
sudo pacman -U yoq-os-0.1.0-1-x86_64.pkg.tar.zst
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
YOQ_VERSION=0.1.0 makepkg -si            # yoq-os 0.1.0, from v0.1.0
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
lists services still running files an upgrade replaced, and on a machine
with generations, a `note:` line when `os` fell back from a generation
that didn't come up healthy.

`os status` warns when the lock is more than 14 days old, since an old lock
holds back security fixes. it exits with 1 when something is failing.

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

### apply

```
$ os apply
packages
  + tree 2.3.2-1

plan: 1 to add, 0 to change, 0 to remove · no reboot

apply this? [y/N] y

applied 1 change.
```

`apply` shows the plan, asks, and then makes the changes. services being
turned off stop first, then one pacman transaction installs and removes
packages, then the settings change, then new services are enabled and
started. `apply` waits for each start and stop to finish, and a service
that fails to start stops the apply with the unit's name. services change
only when systemd runs the machine: not under `--root`, and not in a
container.

it installs exactly the versions in the lock, checks each package against
the lock's checksum and arch's signatures, and marks packages as explicit or
dependencies to match the config. it uses the machine's own pacman.conf for
mirrors and download settings. packages come from the lock's date, so run
`os update` first to move to today's.

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

`apply` keeps a journal in `/var/lib/yoq/journal`. if an apply is cut off
halfway, the next one says so and starts from the machine as it is.

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

`--dbs <dir>` resolves against databases you already have instead of
downloading, and `--date yyyy-mm-dd` names the date they're from.

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
os adopt           # everything installed but not in the config
os adopt htop      # just htop
```

`adopt` is the other way to settle drift: instead of removing a package you
installed with `pacman -S`, it puts it in the config.

### why

```
$ os why perl-error
perl-error: needed by git -> perl-error
git: in packages  (/etc/yoq/machine.toml:2)
```

`why` follows the lock's dependency graph back to the config line that
brings a package in. it exits with 1 when nothing in the config needs the
package.

## history and rollback

this section is about machines without generations. with them, history and
rollback work on whole copies of the system instead; see
[generations.md](generations.md).

`/etc/yoq` is a git repository. every change `os` makes there, from `init`,
`add`, `remove`, `enable`, `disable`, `adopt`, `update`, and `rollback`, is a
commit with a short message, like `add fd` (`adopt` commits as `add`). if
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
versions from the local cache. once the machine matches, it writes those
files back to `/etc/yoq` as a new generation, `rollback to 2: ...`, so
nothing is lost and `os rollback` again undoes the rollback. if the cached
package databases for that generation's date are gone, the plan stops and
says to run `os update`.

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

with generations, it also checks that the boot menu has them, that os's
units are there, and that the esp has room for another kernel. a sudo
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

limine and refind need the esp mounted at `/boot` for this, since that's
where arch installs the kernel.

the other generations stay as btrfs subvolumes unless you say yes when it
asks, or pass `--delete-generations`. the running root stays where it is,
in `@roots/<n>`, and so do `@var`, `@home`, and the other data subvolumes.

last, it removes the `yoq-os` package if pacman installed it, and `os`'s
own state in `/var/lib/yoq`. the config and its git history stay in
`/etc/yoq`. if a step fails, running `os uninstall` again picks up where
it stopped.

## installing a new machine

from yoq os's own live iso, booted in uefi mode: it's arch's live iso,
built from the same profile, with `os` and everything `os install` runs
already on it. arch's own iso works too, with `os` added (`pacman -U` the
release package, or copy the binary); on another live system, `pacman -S
dosfstools btrfs-progs grub git` first, and `os install` names any that
are missing:

```
os install https://github.com/you/machines --host atlas --disk /dev/nvme0n1
```

the first argument is the config repository, as a url or a directory.
`--host atlas` picks `hosts/atlas/machine.toml` in a repository for several
machines; without it, `os` uses the repository's own `machine.toml`. the
disk gets erased.

it shows its checks and what it will build, and asks first:

```
install atlas on /dev/nvme0n1 (476 GiB). everything on it is erased.

disk      an esp of 1024 MiB at /boot, and btrfs for the rest:
          @roots/1, @var, @home, @root, @srv, @usrlocal
boot      grub, with generation 1 as its first entry
packages  412 from the lock (2026-09-25)
users     kacy
services  18
```

then it partitions the disk, builds the machine the way `os build --clean`
does, and records it as generation 1 of the layout `enable-rollback` makes,
so the new machine has generations from its first boot. it asks for a
password for root and each user, since the config never holds one; with
`--yes` it doesn't ask, and the accounts stay locked until you set one.
grub goes on the disk's removable boot path, which every firmware checks,
and gets a boot entry of its own too when `efibootmgr` is there. `os`
itself comes along as `/usr/local/bin/os`.

mirrors only serve today's packages, so a lock from an earlier day needs
`--update`: it resolves the config against today's packages first and
commits the new lock to the fetched config, which you can push back
afterwards. the lock's kernel and grub have to be in it, and aur packages
wait until the machine is running: install without them, then add them
back and run `os update` there.

after a reboot, `/etc/yoq` is the repository you installed from, and a
machine whose hostname matches a directory under `hosts/` reads its config
from there.

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
| `[boot]` | `kernel`: `linux` unless you say otherwise. `none` for a machine without its own kernel, like a container. `modules`: kernel modules to load at every boot, like `i2c-dev`. |
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
names it, so a repository can keep them together. `mode` is octal, and
`0644` unless you say otherwise. `os plan` shows a file that's missing, has
different content, or has a different mode. files the config doesn't name
are left alone, and so is a file you take out of the config.

a path is absolute and plain: no `.` or `..` parts, no trailing `/`, and
nothing under `/etc/yoq` or `/var/lib/yoq`, which are `os`'s own. it also
can't be a file another key writes, like the sysctl file below.

`[sysctl]` becomes one file, `/etc/sysctl.d/99-yoq.conf`, and `apply` loads
it right away when systemd runs the machine.

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
different pkgbase is refused.

an aur package that needs another aur package needs that one in `aur` too;
`os` builds them in order. an `aur` list brings in devtools, which the
builds need, and they build against today's arch packages. `os add`, `os
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
  asked for.
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
written or a tool that didn't work; the message has the details.

## scripting

every command takes `--json` and prints one json document. each document
starts with a `schema` field, like `"schema": "yoq.plan/1"`, that names its
shape and version. errors with a code come out as a `yoq.errors/1`
document on stdout under `--json`; other problems, like a file that can't
be written, are an `os: ...` line on stderr either way.

exit codes:

| code | meaning |
| --- | --- |
| 0 | done |
| 1 | the command ran into a problem, or found one: `status` with something failing, `why` with nothing needing the package |
| 2 | the command line was wrong |

`os docs` prints this reference, the readme, and
[generations.md](generations.md) as one markdown document: the version
that came with the installed `os`.

global flags work before or after the command. a flag's value can't be
empty or start with `-`:

| flag | meaning |
| --- | --- |
| `--json` | machine-readable output |
| `--config <path>` | the config file, instead of `/etc/yoq/machine.toml` |
| `--root <dir>` | the machine's files live under `dir`, like a mounted install |
| `--facts <file>` | read the machine from a facts file instead of looking at it |

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
