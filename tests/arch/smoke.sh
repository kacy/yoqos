#!/bin/sh
# the try gate and apply on a real arch system: init a config for this
# machine, lock it, apply it, then add and remove a package with real
# downloads and signature checks. used by ci in an arch container.
set -eu

os=$1
dir=$(mktemp -d)
cfg=$dir/machine.toml

"$os" --config "$cfg" init
# init can't answer provider questions without a terminal; record the usual
# answers, the way `os update` would after asking.
printf '\n[providers]\ninitramfs = "mkinitcpio"\n"libxtables.so" = "iptables"\n' >> "$cfg"
"$os" --config "$cfg" update
"$os" --config "$cfg" status || true
"$os" --config "$cfg" plan -v
"$os" --config "$cfg" --json plan > "$dir/plan.json"

# apply what the config says, then check nothing's left.
"$os" --config "$cfg" apply --yes
"$os" --config "$cfg" plan | grep -q "nothing to do"

# a real package through the whole loop, checked with pacman itself.
"$os" --config "$cfg" add tree
"$os" --config "$cfg" apply --yes
pacman -Q tree
"$os" --config "$cfg" remove tree
"$os" --config "$cfg" apply --yes
if pacman -Q tree 2>/dev/null; then echo "tree is still installed"; exit 1; fi
"$os" --config "$cfg" plan | grep -q "nothing to do"

git -C "$dir" log --format=%s
echo "smoke ok"
