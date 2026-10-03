# yos

declarative arch linux with rollback.

you write down what your machine should be in one short file. `yos` shows
you what it would change before it touches anything, and every change
becomes a generation you can boot back into. underneath it's still arch:
the same packages, the same wiki, the same bootloader you already have.
and if you get bored of it, `yos uninstall` hands you back a plain arch
install.

no new language to learn, no `/nix/store`. just toml.

```toml
version = 1
packages = ["git", "neovim", "ripgrep"]

[system]
hostname = "atlas"
timezone = "America/New_York"

[services]
ssh = true
```

## what it feels like

you want htop:

```
$ sudo yos add htop
+ packages "htop"

saved /etc/yos/machine.toml.
packages
  + htop 3.4.1-1

plan: 1 to add, 0 to change, 0 to remove
apply this? [y/N]
```

that's the whole loop: change the config (or let `yos add` do it), read the
plan, say yes. the config and its lock live in a git repository, and every
apply is a commit, so you get history without having to remember to make
it.

the weekly update is the same thing with more packages in it, so it
leads with the counts and the few that matter, plus any arch news you
should read first:

```
$ sudo yos update
packages
  upgrades 142    new 3    removed 1   (-v lists them)
  notable  linux 6.16.7.arch1-1 -> 6.16.8.arch1-1
           systemd 257.9-1 -> 258-1

plan: 3 to add, 142 to change, 1 to remove · reboot needed: kernel, systemd
apply this? [y/N]
```

a change that needs a reboot is built beside the running system, and the
next boot tries it once. if it doesn't come up healthy, the machine goes
back on its own and tells you why:

```
generation 13 didn't come up healthy, so this machine went back to
generation 12. it's generation 14 now, with its config. `yos rollback 13`
tries 13 again.
```

nobody has to pick anything from a boot menu at 2am. and when you just
change your mind, `yos rollback` puts the previous generation back, config
and all.

## trying it

`yos init` reads your machine and writes a config that describes it. it
doesn't change anything else, so it's a safe first step:

```
sudo yos init     # writes /etc/yos: machine.toml, imported.toml, machine.lock
yos status        # what matches the config, what changed, what's failing
yos plan          # should be empty, or close to it
```

from there you can stay as far in as you like:

| step | what you get | what changes on the machine |
| --- | --- | --- |
| try | a config and a lock for the machine you have; `yos plan`, `yos why`, `yos status` | nothing outside `/etc/yos` |
| manage | packages, services, users, files, and secrets from the config; config history; package rollback | a pacman hook that notices when you use pacman directly |
| rollback | whole-system generations in the boot menu, trial boots with automatic fallback | a one-time layout change on btrfs, `yos enable-rollback`, shown as a plan first |
| install | a new machine straight from your config repository, encrypted if you like | the whole disk |

generations need a btrfs root and one of grub, limine, refind, or
systemd-boot. they work on luks too, and can boot unified kernel images
signed for secure boot with your own keys.

## the commands you'll actually use

```
yos status     # how's the machine doing?
yos add fd     # add a package to the config, then apply
yos plan       # what would applying change?
yos apply      # show the plan, ask, apply it
yos update     # move to today's arch packages, then apply
yos rollback   # go back to the previous generation
yos why perl   # which line in the config brings perl in?
```

there are more (`yos help` lists them), but those cover most days. every
command takes `--json` for scripts, and errors come with stable codes that
`yos explain E0213` explains in full.

## where it's at

early, and fun to poke at. it's tested a lot in vms: every push boots
seven arch machines under kvm (arch's cloud image, archinstall's layouts,
ext4, limine with snapper, refind, systemd-boot, and a snapper rollback),
and walks them through applies, updates, rollbacks, broken kernels, power
cuts, secure boot, encrypted installs, upgrading `yos` itself, and leaving.
what it hasn't had yet is much time on real hardware. if you try it on a
spare machine, i'd love to hear how it went.

- [examples/](examples): whole machines to read and borrow from, from a
  six-package minimal one to a fleet of two that share files
- [docs/usage.md](docs/usage.md): installing it, every command, and the
  config format
- [docs/generations.md](docs/generations.md): how generations, trials, and
  rollback work, and what they don't do yet
- [CHANGELOG.md](CHANGELOG.md): what's in each release

## no arch machine handy?

the test fixtures can stand in for one:

```
zig build
./zig-out/bin/yos --config tests/golden/fresh-install/machine.toml \
    --facts tests/golden/fresh-install/facts.json plan
```

## building and testing

you need zig 0.16. reading packages needs libalpm and reading services
needs libsystemd; `-Dalpm -Dsystemd` links them.

```
zig build
zig build test
zig build test -Dalpm -Dsystemd
```

`tests/vm/test.sh zig-out/bin/yos` boots an arch vm under kvm and runs the
whole thing in it. `VM_IMAGE` picks the machine: `cloud` (the default),
`archinstall`, `ext4`, `limine`, `refind`, `sdboot`, or `snapper`. ci runs
all of them on every push, and also builds the live iso and installs a
machine from it.

## license

mit. see `LICENSE`.
