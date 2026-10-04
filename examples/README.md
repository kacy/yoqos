# examples

a few machines, written down. each directory has a `machine.toml` you can
read in a minute, and steal from. they're all real: ci checks every one on
each push, and on an arch container resolves the ones it can against
today's packages, so a name arch doesn't have, or a choice the config
should make, fails the build.

| example | what it shows |
| --- | --- |
| [minimal](minimal/machine.toml) | the least a machine needs: six packages, and yos's defaults for the rest |
| [laptop](laptop/machine.toml) | luks, signed unified kernel images for secure boot, battery services, and wi-fi whose password never goes in the config |
| [hyprland](hyprland/machine.toml) | a hyprland desktop with greetd and pipewire, and a [hyprland.conf](hyprland/hyprland.conf) that becomes the machine's default |
| [omarchy-lite](omarchy-lite/machine.toml) | omarchy's desktop on yos: its keybindings and look in [hyprland.lua](omarchy-lite/hypr/hyprland.lua), and its own quickshell ui, fetched at a pinned commit the first time you log in, installable from the live iso |
| [nvidia](nvidia/machine.toml) | kde on an nvidia card, a provider chosen up front, and a sysctl for games |
| [home-server](home-server/machine.toml) | the lts kernel, docker, tailscale, services yos doesn't know by name, a keys-only ssh drop-in, and a secret |
| [container](container/machine.toml) | a machine with no kernel of its own, for systemd-nspawn or a build box |
| [aur](aur/machine.toml) | packages from the aur, and chaotic-aur as a repository with its key |
| [fleet](fleet) | two machines sharing a base and a profile each, with `[remove]` and `unset` for the differences |

## trying one

you don't need to install anything to look at one. `yos config show`
prints the merged config, and `--resolved` adds where each value came
from:

```
yos --config examples/fleet/hosts/forge/machine.toml config show --resolved
```

to see what applying one would do to your machine, without applying it:

```
yos --config examples/minimal/machine.toml plan
```

it plans against the lock next to the config, so run `yos --config ...
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
lists that are sets, like packages and a user's groups, add up across
files, and every other value takes the last one set, so a host has the
final word. atlas drops a package the
base wants with `[remove]`, and forge clears a sysctl the base sets with
`unset`. with a repository like this one at `/etc/yos`, each machine
reads `hosts/<its hostname>/machine.toml` on its own, and `yos install
--host atlas` puts atlas on a new disk.

## omarchy-lite

omarchy is a hyprland desktop on arch with a lot of opinions, most of them
good. `omarchy-lite` keeps the parts that make it feel like omarchy, its
keybindings, its look, and its own quickshell ui, and leaves out its apps,
its menu, and the packages only its own repository has. every package comes
from arch's own repositories, so `yos install` builds it from the live iso:

```
yos install https://example.com/you/machines.git --disk /dev/nvme0n1 --encrypt --update
```

after the passphrase at boot, sddm logs straight in, as omarchy does.

the ui isn't a package, and nothing of omarchy's is copied here.
[shell/yos-shell](omarchy-lite/shell/yos-shell) runs at the first login:
it fetches omarchy's repository at the commit
[shell/manifest](omarchy-lite/shell/manifest) pins, only the parts it
needs, and lays out omarchy's bar, panels, notifications, lock screen, and
ai agents panel in `~/.local/share/yos-shell`, with their scripts as
omarchy wrote them. the manifest names every command the ui can run, and
where it comes from:

- most are omarchy's own, unchanged.
- a few are the script's own: the update icon and its click go through
  `yos status` and `yos update`, and the agents panel starts whichever
  coding agent the machine has, rather than installing one.
- the rest, for features left out like dictation and screen recording, do
  nothing.

if a newer commit runs a command the manifest doesn't name, setting up
stops and says which, rather than leave a panel that quietly does nothing.
to update, change the commit, check what's new, and log in again.

| omarchy | here |
| --- | --- |
| its hyprland lua, keybindings, and look | [hyprland.lua](omarchy-lite/hypr/hyprland.lua), one file, the same bindings for windows, workspaces, groups, and the scratchpad |
| the quickshell ui | the same, at a pinned commit, with the display, audio, network, bluetooth, power, and ai agents panels |
| the menus and app launcher | fuzzel, with a power menu and a keybinding list on it |
| screenshots and the clipboard manager | grim, slurp, and satty; cliphist through fuzzel |
| limine and snapper snapshots | yos's own generations and rollback |
| ufw | firewalld, which yos knows by name |

what's left out: omarchy's menu, theme switching, web apps, its own apps
like omacalc, and the dns switch in the network panel, since on yos that's
the machine's config.

## more

- [docs/usage.md](../docs/usage.md#the-config) has every key.
- `dist/profiles/omarchy.toml` is a profile for omarchy machines,
  installed at `/usr/share/yos/profiles/omarchy.toml`.
