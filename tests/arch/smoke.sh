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
"$os" --config "$cfg" add --yes tree
pacman -Q tree
"$os" --config "$cfg" remove --no-apply tree
pacman -Q tree
"$os" --config "$cfg" apply --yes
if pacman -Q tree 2>/dev/null; then echo "tree is still installed"; exit 1; fi
"$os" --config "$cfg" plan | grep -q "nothing to do"

# a user: created with its shell and groups, then moved between groups.
printf '\n[users.yoqtest]\nshell = "bash"\ngroups = ["wheel"]\n' >> "$cfg"
"$os" --config "$cfg" apply --yes
getent passwd yoqtest | grep -q ':/usr/bin/bash$'
id -nG yoqtest | grep -qw wheel
"$os" --config "$cfg" plan | grep -q "nothing to do"
sed -i 's/^groups = \["wheel"\]$/groups = ["video"]/' "$cfg"
"$os" --config "$cfg" apply --yes
id -nG yoqtest | grep -qw video
if id -nG yoqtest | grep -qw wheel; then echo "yoqtest is still in wheel"; exit 1; fi
"$os" --config "$cfg" plan | grep -q "nothing to do"

# files and sysctl: written with their mode, and sysctl loaded where
# systemd runs the machine.
printf '\n[files."/etc/motd"]\ntext = "managed by os\\n"\nmode = "0600"\n\n[sysctl]\n"vm.swappiness" = 17\n' >> "$cfg"
"$os" --config "$cfg" apply --yes
grep -qx "managed by os" /etc/motd
[ "$(stat -c %a /etc/motd)" = 600 ]
grep -qx "vm.swappiness = 17" /etc/sysctl.d/99-yoq.conf
if [ -d /run/systemd/system ]; then [ "$(sysctl -n vm.swappiness)" = 17 ]; fi
"$os" --config "$cfg" plan | grep -q "nothing to do"

# rollback: back past an add, then forward again, with history to match.
"$os" --config "$cfg" add --yes tree
"$os" --config "$cfg" rollback --yes
if pacman -Q tree 2>/dev/null; then echo "tree is still installed after rollback"; exit 1; fi
if grep -q tree "$cfg"; then echo "the config still has tree after rollback"; exit 1; fi
"$os" --config "$cfg" rollback --yes
pacman -Q tree
"$os" --config "$cfg" history
"$os" --config "$cfg" remove --yes tree

# a service through the whole loop, where systemd runs the machine: the
# package goes in and the unit starts, then the unit stops and the package
# goes.
if [ -d /run/systemd/system ]; then
    "$os" --config "$cfg" enable --yes tailscale
    systemctl is-enabled tailscaled.service
    systemctl is-active tailscaled.service
    "$os" --config "$cfg" plan | grep -q "nothing to do"
    # an upgrade replacing tailscaled's binary under it: status says so,
    # the next apply that changes packages offers the restart, and a
    # restart clears it.
    cp /usr/bin/tailscaled /usr/bin/tailscaled.new
    mv -f /usr/bin/tailscaled.new /usr/bin/tailscaled
    "$os" --config "$cfg" status | grep -q "running replaced files:.*tailscaled.service"
    "$os" --config "$cfg" add --yes tree | grep -q "systemctl restart tailscaled.service"
    "$os" --config "$cfg" remove --yes tree
    systemctl restart tailscaled.service
    if "$os" --config "$cfg" status | grep -q "running replaced files:.*tailscaled"; then echo "tailscaled still stale after a restart"; exit 1; fi
    "$os" --config "$cfg" disable --yes tailscale
    if systemctl is-active tailscaled.service; then echo "tailscaled is still running"; exit 1; fi
    if pacman -Q tailscale 2>/dev/null; then echo "tailscale is still installed"; exit 1; fi
    "$os" --config "$cfg" plan | grep -q "nothing to do"
fi

# update applies what it resolved; on the same day there's nothing to do.
"$os" --config "$cfg" update --yes | tee "$dir/update.out"
grep -q "nothing to do" "$dir/update.out"

# drift: with os and its pacman hook installed the way a package would,
# a direct `pacman -S` shows in status until os applies again.
install -Dm755 "$os" /usr/bin/os
install -Dm644 dist/yoq-drift.hook /usr/share/libalpm/hooks/yoq-drift.hook
pacman -S --noconfirm --noprogressbar htop >/dev/null
"$os" --config "$cfg" status | grep -q "touched with pacman since the last apply: htop"
"$os" --config "$cfg" apply --yes
if "$os" --config "$cfg" status | grep -q "touched with pacman"; then echo "drift survived an apply"; exit 1; fi
rm /usr/share/libalpm/hooks/yoq-drift.hook

# a config that leaves out base doesn't get to remove it.
bare=$dir/bare.toml
printf 'version = 1\n[boot]\nkernel = "none"\n' > "$bare"
if "$os" --config "$bare" plan 2> "$dir/bare.err"; then echo "planned removing base"; exit 1; fi
grep -q E0126 "$dir/bare.err"

git -C "$dir" log --format=%s
echo "smoke ok"
