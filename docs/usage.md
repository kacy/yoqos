# using yoq os

yoq os describes an arch linux machine in one short file and shows you
exactly what would change to make the machine match it. this page covers how
to use it today.

## what works today

`os` reads a machine, writes a config for it, keeps that config and its lock
up to date, tells you what's different, and applies the difference. `os
apply` installs and removes packages and sets the `[system]` settings.
services and users show up in the plan, but `apply` doesn't change them yet.
every other command only reads the machine or edits the config.

| command | what it does |
| --- | --- |
| `os init` | writes a config that describes this machine |
| `os status` | what matches the config, what changed, what's failing |
| `os plan` | every change applying would make |
| `os apply` | makes those changes, after asking |
| `os update` | resolves the config against today's arch packages into the lock |
| `os add`, `os remove` | edit the package list, and the lock with it |
| `os enable`, `os disable` | turn services on or off in the config |
| `os adopt` | puts packages installed outside the config into it |
| `os why` | which config line brings a package in |
| `os config show` | the config with all its includes merged |
| `os facts` | what `os` sees on this machine |
| `os explain` | the long explanation of an error code |

## building

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

each "changed" line ends with the command that deals with it. `os status`
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

`apply` shows the plan, asks, and then makes the changes: one pacman
transaction for the packages, then the settings. it installs exactly the
versions in the lock, checks each package against the lock's checksum and
arch's signatures, and marks packages as explicit or dependencies to match
the config. it uses the machine's own pacman.conf for mirrors and download
settings. packages come from the lock's date, so run `os update` first to
move to today's.

afterwards it plans again and says if anything still differs. `--yes` skips
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
updated machine.lock: +1. next: os plan, then os apply
```

these edit `machine.toml` for you and keep its comments and formatting. `add`
and `remove` also update the lock, resolving against the same package date
the lock already has, so adding one package never upgrades anything else.
that needs the package databases for that date, which `os update` downloads.
if they aren't there, `add` says so, and `os update` catches the lock up.

`remove` works on packages from includes too: it adds them to `[remove]`
rather than editing the included file. if a package comes from a service or
a hardware choice, `remove` tells you which one to change instead.

### update

```
os update
```

downloads today's package databases, using the repositories and mirrors in
`/etc/pacman.conf`, resolves the config against them, and writes the lock.
when a package depends on something several packages provide, like
`initramfs` (mkinitcpio, booster, or dracut), `os update` asks which one you
want and saves the answer in `[providers]`, so it only asks once. without a
terminal, it stops and says which choices to make.

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

## history

`/etc/yoq` is a git repository. every change `os` makes there, from `init`,
`add`, `remove`, `enable`, `disable`, `adopt`, and `update`, is a commit with
a short message, like `add fd`. `git -C /etc/yoq log` is the history of the
machine's config. edits you make by hand aren't committed for you.

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
| `[hardware]` | `cpu`: `amd` or `intel`. `gpu`: `amd`, `intel`, `nvidia`, or `none`. these bring in microcode and drivers. |
| `[desktop]` | `session`: `hyprland`. `audio`: `pipewire`. these bring in their packages. |
| `[users.<name>]` | `shell`, and `groups`: the full list of groups beyond the user's own |
| `[services]` | `<name> = true` or `false`, for the services listed below |

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
