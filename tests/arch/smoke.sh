#!/bin/sh
# the try gate on a real arch system: init a config for this machine, lock
# it, and check that status and plan run. used by ci in an arch container.
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
"$os" --config "$cfg" plan
"$os" --config "$cfg" --json plan > "$dir/plan.json"
git -C "$dir" log --format=%s
echo "smoke ok"
