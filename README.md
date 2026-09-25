# yoq os

declarative arch linux with real rollback.

you describe the machine in one short file, `os` shows you exactly what it's
going to change, and every change becomes a generation you can boot back into.
it's still arch underneath: same packages, same wiki, and you can stop using it
whenever you want.

it's early. `os apply` installs and removes packages, sets the system
settings, turns services on and off, manages users, and rolls packages and
config back. whole-system rollback on btrfs comes next.

```
os init       # write a config that describes this machine
os status     # what matches the config, what changed, what's failing
os add fd     # edit the config (and the lock) for you
os update     # resolve against today's arch packages into machine.lock
os plan       # what applying would change
os apply      # show the plan, ask, apply it
os rollback   # go back to the previous generation
os why perl   # which config line brings a package in
```

[docs/usage.md](docs/usage.md) walks through all of it: getting started,
every command, and the config format.

reading packages and resolving need libalpm, and reading services needs
libsystemd. build with `-Dalpm -Dsystemd` to link them. without a real arch
machine, the test fixtures work too:

```
zig build
./zig-out/bin/os --config tests/golden/fresh-install/machine.toml \
    --facts tests/golden/fresh-install/facts.json plan
```

## the idea

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
os update     # move to today's arch packages
os apply      # show the plan, ask, apply it
os rollback   # go back to the previous generation
```

## building

needs zig 0.16.

```
zig build
zig build test
zig build test -Dalpm -Dsystemd   # needs libalpm and libsystemd
./zig-out/bin/os help
```

`tests/vm/test.sh zig-out/bin/os` boots arch's cloud image under kvm and
runs the whole loop in it. `tests/vm/vm.sh` starts, reaches, and stops that
vm by hand. ci runs the vm test on every push.

## rough plan

- manage packages, services, users, and files on any arch install
- whole-system generations and rollback on btrfs, with the bootloader you
  already have (grub, systemd-boot, limine, refind)
- an installer that builds a machine straight from its config

## license

mit. see `LICENSE`.
