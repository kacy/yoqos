#!/bin/sh
# the try gate and apply on a real arch system: init a config for this
# machine, lock it, apply it, then add and remove a package with real
# downloads and signature checks. used by ci in an arch container.
set -eu

os=$1
dir=$(mktemp -d)
cfg=$dir/machine.toml

"$os" --config "$cfg" init 2> "$dir/init.err"
cat "$dir/init.err" >&2
# init answers provider choices from what's installed. for the rest, take
# the suggested option, as pressing enter at `os update`'s prompt would.
sed -n 's/.*like \(.*\) = "\(.*\)".*/"\1" = "\2"/p' "$dir/init.err" > "$dir/answers"
if [ -s "$dir/answers" ]; then
    if grep -q '^\[providers\]' "$cfg"; then
        sed -i "/^\[providers\]/r $dir/answers" "$cfg"
    else
        printf '\n[providers]\n' >> "$cfg"
        cat "$dir/answers" >> "$cfg"
    fi
fi
"$os" --config "$cfg" update
"$os" --config "$cfg" status || true
"$os" --config "$cfg" plan -v
"$os" --config "$cfg" --json plan > "$dir/plan.json"

# the try gate: a config read from this machine plans nothing, unless a
# provider had to be picked above.
if [ ! -s "$dir/answers" ] && ! "$os" --config "$cfg" plan | grep -q "nothing to do"; then
    echo "try gate: the plan right after init isn't empty"
    exit 1
fi

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

# a service through the whole loop, where systemd runs the machine: the
# package goes in and the unit starts, then the unit stops and the package
# goes.
if [ -d /run/systemd/system ]; then
    "$os" --config "$cfg" enable tailscale
    "$os" --config "$cfg" apply --yes
    systemctl is-enabled tailscaled.service
    systemctl is-active tailscaled.service
    "$os" --config "$cfg" plan | grep -q "nothing to do"
    "$os" --config "$cfg" disable tailscale
    "$os" --config "$cfg" apply --yes
    if systemctl is-active tailscaled.service; then echo "tailscaled is still running"; exit 1; fi
    if pacman -Q tailscale 2>/dev/null; then echo "tailscale is still installed"; exit 1; fi
    "$os" --config "$cfg" plan | grep -q "nothing to do"
fi

# a config that leaves out base doesn't get to remove it.
bare=$dir/bare.toml
printf 'version = 1\n[boot]\nkernel = "none"\n' > "$bare"
if "$os" --config "$bare" plan 2> "$dir/bare.err"; then echo "planned removing base"; exit 1; fi
grep -q E0126 "$dir/bare.err"

git -C "$dir" log --format=%s
echo "smoke ok"
