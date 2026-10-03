# examples

a few machines, written down. each directory has a `machine.toml` you can
read in a minute, and steal from. they're all real: ci checks every one on
each push, and on an arch container resolves the ones it can against
today's packages, so a name arch doesn't have, or a choice the config
should make, fails the build.

| example | what it shows |
| --- | --- |
| [minimal](minimal/machine.toml) | the least a machine needs: six packages, and os's defaults for the rest |
| [laptop](laptop/machine.toml) | luks, signed unified kernel images for secure boot, battery services, and wi-fi whose password never goes in the config |
| [hyprland](hyprland/machine.toml) | a hyprland desktop with greetd and pipewire, and a [hyprland.conf](hyprland/hyprland.conf) that becomes the machine's default |
| [nvidia](nvidia/machine.toml) | kde on an nvidia card, a provider chosen up front, and a sysctl for games |
| [home-server](home-server/machine.toml) | the lts kernel, docker, tailscale, services os doesn't know by name, a keys-only ssh drop-in, and a secret |
| [container](container/machine.toml) | a machine with no kernel of its own, for systemd-nspawn or a build box |
| [aur](aur/machine.toml) | packages from the aur, and chaotic-aur as a repository with its key |
| [fleet](fleet) | two machines sharing a base and a profile each, with `[remove]` and `unset` for the differences |

## trying one

you don't need to install anything to look at one. `os config show`
prints the merged config, and `--resolved` adds where each value came
from:

```
os --config examples/fleet/hosts/forge/machine.toml config show --resolved
```

to see what applying one would do to your machine, without applying it:

```
os --config examples/minimal/machine.toml plan
```

it plans against the lock next to the config, so run `os --config ...
update --no-apply` on a copy first to resolve one.

## the fleet

`fleet/` is how a repository for several machines can look:

```
base.toml                 what every machine shares
profiles/desktop.toml     what a desktop adds
profiles/server.toml      what a server adds
hosts/atlas/machine.toml  the desktop
hosts/forge/machine.toml  the build server
files/motd                a file base.toml puts in /etc
```

each host includes the base, then its profile, then says what's its own.
package lists add up across files, and every other value takes the last
one set, so a host always has the final word. atlas drops a package the
base wants with `[remove]`, and forge clears a sysctl the base sets with
`unset`. with a repository like this one at `/etc/yoq`, each machine
reads `hosts/<its hostname>/machine.toml` on its own, and `os install
--host atlas` puts atlas on a new disk.

## more

- [docs/usage.md](../docs/usage.md#the-config) has every key.
- `dist/profiles/omarchy.toml` is a profile for omarchy machines,
  installed at `/usr/share/yoq/profiles/omarchy.toml`.
