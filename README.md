# yoq os

declarative arch linux with rollback.

you describe the machine in one short file. `os` shows what it's going to
change before it changes anything, and on a btrfs root every change becomes a
generation you can boot back into. underneath it's still arch, with the same
packages and the same wiki, and you can stop using it whenever you like.

```toml
version = 1
packages = ["git", "neovim", "ripgrep"]

[system]
hostname = "atlas"
timezone = "America/New_York"

[services]
ssh = true
```

```
os init       # write a config that describes this machine
os status     # what matches the config, what changed, what's failing
os add fd     # edit the config (and the lock) for you, then apply
os update     # resolve against today's arch packages
os plan       # what applying would change
os apply      # show the plan, ask, apply it
os rollback   # go back to the previous generation
os why perl   # which config line brings a package in
```

it's early. on any arch install, `os` manages packages, system settings,
services, users, files, and sysctl, and rolls packages and config back. on a
btrfs root with grub, limine, or refind, `os enable-rollback` turns on
whole-system generations: every change is a snapshot in the boot menu, and
on grub and limine an update that needs a reboot boots once on trial, then
falls back by itself if it doesn't come up healthy. the vm tests run that on
arch's cloud image and on archinstall's layouts. `os uninstall` takes it all
back off and leaves plain arch running the system you have.

- [docs/usage.md](docs/usage.md): installing, every command, and the config
  format
- [CHANGELOG.md](CHANGELOG.md): what each release has
- [docs/generations.md](docs/generations.md): how generations and rollback
  work, and what they don't do yet

## trying it without a machine

the test fixtures stand in for a real one:

```
zig build
./zig-out/bin/os --config tests/golden/fresh-install/machine.toml \
    --facts tests/golden/fresh-install/facts.json plan
```

## building and testing

needs zig 0.16. reading packages needs libalpm and reading services needs
libsystemd; `-Dalpm -Dsystemd` links them.

```
zig build
zig build test
zig build test -Dalpm -Dsystemd
```

`tests/vm/test.sh zig-out/bin/os` boots an arch vm under kvm and runs the
whole loop in it: the manage rung, enable-rollback, rollback, trial boots,
a clean build, and uninstalling. `VM_IMAGE` picks the machine: arch's cloud
image (the default), or one archinstall installs, with its default btrfs
layout (`archinstall`), an ext4 root (`ext4`), limine and snapper, like
omarchy's boot setup (`limine`), or refind (`refind`). the ext4 one stays
on the manage rung. ci runs all five on every push.

## what's next

see the end of [docs/generations.md](docs/generations.md). the big pieces
are an installer that builds a machine straight from its config (the clean
build is its first half), systemd-boot, and building the next generation
apart from the running system.

## license

mit. see `LICENSE`.
