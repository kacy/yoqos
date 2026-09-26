# using yoq os

yoq os describes an arch linux machine in one short file and shows you
exactly what would change to make the machine match it. this page covers how
to use it today.

## what works today

`os` reads a machine, writes a config for it, keeps that config and its lock
up to date, tells you what's different, and applies the difference. `os
apply` installs and removes packages, sets the `[system]` settings, turns
services on and off, and creates users and sets their shells and groups.
every other command only reads the machine or edits the config.

| command | what it does |
| --- | --- |
| `os init` | writes a config that describes this machine |
| `os status` | what matches the config, what changed, what's failing |
| `os plan` | every change applying would make |
| `os apply` | makes those changes, after asking |
| `os history` | the config's generations |
| `os rollback` | goes back to an earlier generation |
| `os update` | resolves the config against today's arch packages into the lock |
| `os add`, `os remove` | edit the package list, and the lock with it |
| `os enable`, `os disable` | turn services on or off in the config |
| `os adopt` | puts packages installed outside the config into it |
| `os why` | which config line brings a package in |
| `os config show` | the config with all its includes merged |
| `os facts` | what `os` sees on this machine |
| `os explain` | the long explanation of an error code |

## installing

`dist/PKGBUILD` in the repository builds the `yoq-os-git` package, with the
`os` command and a pacman hook that records direct `pacman` use for `os
status`:

```
cd dist
makepkg -si
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
-R` also shows up, as "touched with pacman since the last apply", until
the next `os apply`. the hook records nothing for os's own transactions. `os status`
also warns when the lock is more than 14 days old, since an old lock holds
back security fixes. it exits with 1 when something is failing.

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
lists the dependencies one by one. the last line says whether the change
needs a reboot, and why.

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
container. it installs exactly the
versions in the lock, checks each package against the lock's checksum and
arch's signatures, and marks packages as explicit or dependencies to match
the config. it uses the machine's own pacman.conf for mirrors and download
settings. packages come from the lock's date, so run `os update` first to
move to today's.

afterwards it plans again and says if anything still differs. arch
doesn't restart services after an upgrade, so when packages changed,
`apply` also lists the services still running files the upgrade replaced
and offers to restart them. `os status` shows them too. services a
session depends on, like d-bus and display managers, are left for a
reboot. `--yes` skips
the question; without a terminal, `apply` needs it. it needs root.

read the plan before you say yes: `apply` removes every package the config
doesn't ask for. the exception is a few core packages (`base`,
`filesystem`, `glibc`, `pacman`, and `systemd`). if the config leaves one
out, `plan` and `apply` stop with E0126, since that's almost always a
mistake. to remove one on purpose, name it in `[remove]`.

`apply` keeps a journal in `/var/lib/yoq/journal`. if one is cut off
halfway, the next `apply` says so and starts from the machine as it is.

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
edit. without a terminal, or with `--json`, they stop after the edit too,
and `os apply` makes the change.

they also update the lock, since a service brings its package, resolving
against the same package date the lock already has, so adding one package
never upgrades anything else. that needs the package databases for that
date, which `os update` downloads. if they aren't there, `add` says so,
doesn't apply, and `os update` catches the lock up.

`remove` works on packages from includes too: it adds them to `[remove]`
rather than editing the included file. if a package comes from a service or
a hardware choice, `remove` tells you which one to change instead.

### update

```
os update
```

downloads today's package databases, using the repositories and mirrors in
`/etc/pacman.conf`, and resolves the config against them. then it applies
the result like `os apply`: the plan, a question, and the change.
`machine.lock` moves to the new packages only once the machine has, so
saying no, or an apply that fails, leaves the lock as it was. `--yes` skips
the question. with `--no-apply`, without a terminal, or with `--json`, it
only writes the new lock, and `os apply` makes the change later.

when a package depends on something several packages provide, like
`initramfs` (mkinitcpio, booster, or dracut), `os update` asks which one you
want and saves the answer in `[providers]`, so it only asks once. without a
terminal, it stops and says which choices to make.

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
packages, and new major versions. `os update -v` lists every package.

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

`/etc/yoq` is a git repository. every change `os` makes there, from `init`,
`add`, `remove`, `enable`, `disable`, `adopt`, `update`, and `rollback`, is a
commit with a short message, like `add fd`. each commit is a generation of
the machine's config, numbered from the first:

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
nothing is lost and `os rollback` again undoes the rollback.

this rolls back packages, settings, services, and users, not files that
package scripts changed, or anything else `os` doesn't manage. whole-system
rollback, with snapshots and boot entries, comes later on btrfs.

edits you make to the config by hand aren't committed for you.

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
| `[system]` | `hostname`, `timezone`, `locale`, and `keymap` |
| `[boot]` | `kernel`: `linux` unless you say otherwise. `none` for a machine without its own kernel, like a container. |
| `[hardware]` | `cpu`: `amd` or `intel`. `gpu`: `amd`, `intel`, `nvidia`, or `none`. these bring in microcode and drivers. `nvidia` also loads its modules early, with a drop-in in `/etc/mkinitcpio.conf.d`, unless mkinitcpio.conf does already. |
| `[desktop]` | `session`: `hyprland`. `audio`: `pipewire`. these bring in their packages. |
| `[users.<name>]` | `shell`, and `groups`: the full list of groups beyond the user's own |
| `[services]` | `<name> = true` or `false`, for the services listed below |
| `[files."<path>"]` | a file `os` writes whole: `text` or `source`, and `mode` |
| `[sysctl]` | kernel settings, like `"vm.swappiness" = 10` |

`aur` and `[state]` are read but not used yet.

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

`os` never deletes a user, and passwords stay yours to set with `passwd`.
every uid `os` gives out is kept in `/var/lib/yoq/ids`, so a user created
again gets its old uid back, and its files in `/home` are still its own.

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
names it, so a repository can keep them together. `mode` is octal and
`0644` unless you say otherwise. `os plan` shows a file that's missing, has
different content, or has a different mode. files the config doesn't name
are left alone, and so is a file you take out of the config.

`[sysctl]` becomes one file, `/etc/sysctl.d/99-yoq.conf`, and `apply` loads
it right away when systemd runs the machine.

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
- `unset = ["desktop.audio"]` clears a key an include set.

`os config show --resolved` prints the merged result with the file and line
every value came from:

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

every error names the file and line, says what's wrong, and gives a code:

```
error[E0213]: unknown service "sshd"
  --> /etc/yoq/machine.toml:3:1
   | did you mean "ssh"?  (os explain E0213)
```

`os explain E0213` prints the long explanation, and `os explain` lists every
code.

## scripting

every command takes `--json` and prints one json document. each document
starts with a `schema` field, like `"schema": "yoq.plan/1"`, that names its
shape and version. errors come out as a `yoq.errors/1` document on stdout
under `--json`.

exit codes:

| code | meaning |
| --- | --- |
| 0 | done |
| 1 | the command ran into a problem, or found one: `status` with something failing, `why` with nothing needing the package |
| 2 | the command line was wrong |

global flags work before or after the command:

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
