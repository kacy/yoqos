# yoq os

declarative arch linux with real rollback.

you describe the machine in one short file, `os` shows you exactly what it's
going to change, and every change becomes a generation you can boot back into.
it's still arch underneath: same packages, same wiki, and you can stop using it
whenever you want.

it's early. nothing touches a real machine yet, but the config side works:
`os config show` merges and checks a config, and `os plan` shows what would
change, given a lock and a facts file. try it on the test fixtures:

```
zig build
./zig-out/bin/os --config tests/golden/fresh-install/machine.toml \
    plan --facts tests/golden/fresh-install/facts.json
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
os apply      # show the plan, ask, apply it
os update     # move to today's arch packages
os rollback   # go back to the previous generation
```

## building

needs zig 0.16.

```
zig build
zig build test
./zig-out/bin/os help
```

## rough plan

- manage packages, services, users, and files on any arch install
- whole-system generations and rollback on btrfs, with the bootloader you
  already have (grub, systemd-boot, limine, refind)
- an installer that builds a machine straight from its config

## license

mit. see `LICENSE`.
