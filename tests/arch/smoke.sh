#!/bin/sh
# the try gate and apply on a real arch system: init a config for this
# machine, lock it, apply it, then add and remove a package with real
# downloads and signature checks. used by ci in an arch container.
set -eu
set -o pipefail

yos=$1
dir=$(mktemp -d)
cfg=$dir/machine.toml

# runs `yos <args>` on the config and checks what it printed has $1. yos
# failing fails the test.
says() {
    want=$1
    shift
    "$yos" --config "$cfg" "$@" > "$dir/out"
    grep -q "$want" "$dir/out" || { echo "smoke: yos $* didn't say '$want':"; cat "$dir/out"; exit 1; }
}

# whether status says $1. status exits 1 when something is failing, which
# is fine here; anything worse fails the test.
status_says() {
    rc=0
    "$yos" --config "$cfg" status > "$dir/status" || rc=$?
    [ "$rc" -le 1 ] || { echo "smoke: status exited $rc"; exit 1; }
    grep -q "$1" "$dir/status"
}

"$yos" --config "$cfg" init 2> "$dir/init.err"
cat "$dir/init.err" >&2
# init answers provider choices from what's installed. for the rest, take
# the suggested option, as pressing enter at `yos update`'s prompt would.
sed -n 's/.*like \(.*\) = "\(.*\)".*/"\1" = "\2"/p' "$dir/init.err" > "$dir/answers"
if [ -s "$dir/answers" ]; then
    if grep -q '^\[providers\]' "$cfg"; then
        sed -i "/^\[providers\]/r $dir/answers" "$cfg"
    else
        printf '\n[providers]\n' >> "$cfg"
        cat "$dir/answers" >> "$cfg"
    fi
fi
"$yos" --config "$cfg" update
status_says . || true
cat "$dir/status"
"$yos" --config "$cfg" plan -v
"$yos" --config "$cfg" --json plan > "$dir/plan.json"

# the try gate: a config read from this machine plans nothing, unless a
# provider had to be picked above.
if [ ! -s "$dir/answers" ] && ! { "$yos" --config "$cfg" plan > "$dir/out" && grep -q "nothing to do" "$dir/out"; }; then
    echo "try gate: the plan right after init isn't empty"
    exit 1
fi

# apply what the config says, then check nothing's left.
"$yos" --config "$cfg" apply --yes
says "nothing to do" plan

# a real package through the whole loop, checked with pacman itself.
"$yos" --config "$cfg" add --yes tree
pacman -Q tree
"$yos" --config "$cfg" remove --no-apply tree
pacman -Q tree
"$yos" --config "$cfg" apply --yes
if pacman -Q tree 2>/dev/null; then echo "tree is still installed"; exit 1; fi
says "nothing to do" plan

# a saved plan applies as it was saved, and not once it's out of date.
"$yos" --config "$cfg" add --no-apply tree
"$yos" --config "$cfg" plan -o "$dir/saved.json" > /dev/null
"$yos" --config "$cfg" remove --no-apply tree
rc=0
"$yos" --config "$cfg" apply --yes "$dir/saved.json" 2> "$dir/err" || rc=$?
[ "$rc" = 1 ] && grep -q E0128 "$dir/err" || { echo "smoke: a stale saved plan applied (exit $rc)"; cat "$dir/err"; exit 1; }
"$yos" --config "$cfg" add --no-apply tree
"$yos" --config "$cfg" apply --yes "$dir/saved.json"
pacman -Q tree
"$yos" --config "$cfg" remove --yes tree

# a package that needs something several packages provide, with no one to
# ask which: yos lists the choices and fails, and puts the config back.
# ant needs a java environment, which each jdk provides.
config=$(sha256sum < "$cfg")
lock=$(sha256sum < "$dir/machine.lock")
for json in "" --json; do
    rc=0
    # shellcheck disable=SC2086
    "$yos" --config "$cfg" $json add --no-apply ant < /dev/null > "$dir/out" 2> "$dir/err" || rc=$?
    if [ "$rc" != 1 ] || ! grep -q "E0123" "$dir/out" "$dir/err" || ! grep -q "java-environment has more than one provider: .*jdk" "$dir/out" "$dir/err"; then
        echo "smoke: yos $json add ant didn't list the providers and fail (exit $rc):"
        cat "$dir/out" "$dir/err"
        exit 1
    fi
    if [ -n "$json" ] && ! grep -q "yos.errors/1" "$dir/out"; then echo "smoke: yos --json add ant printed no errors document"; cat "$dir/out"; exit 1; fi
    [ "$(sha256sum < "$cfg")" = "$config" ] || { echo "smoke: yos $json add ant left the config changed"; exit 1; }
    [ "$(sha256sum < "$dir/machine.lock")" = "$lock" ] || { echo "smoke: yos $json add ant changed the lock"; exit 1; }
done

# a user: created with its shell and groups, then moved between groups.
printf '\n[users.yostest]\nshell = "bash"\ngroups = ["wheel"]\n' >> "$cfg"
"$yos" --config "$cfg" apply --yes
getent passwd yostest | grep -q ':/usr/bin/bash$'
id -nG yostest | grep -qw wheel
says "nothing to do" plan
sed -i 's/^groups = \["wheel"\]$/groups = ["video"]/' "$cfg"
"$yos" --config "$cfg" apply --yes
id -nG yostest | grep -qw video
if id -nG yostest | grep -qw wheel; then echo "yostest is still in wheel"; exit 1; fi
says "nothing to do" plan

# files and sysctl: written with their mode, and sysctl loaded where
# systemd runs the machine.
printf '\n[files."/etc/motd"]\ntext = "managed by yos\\n"\nmode = "0600"\n\n[sysctl]\n"vm.swappiness" = 17\n' >> "$cfg"
"$yos" --config "$cfg" apply --yes
grep -qx "managed by yos" /etc/motd
[ "$(stat -c %a /etc/motd)" = 600 ]
grep -qx "vm.swappiness = 17" /etc/sysctl.d/99-yos.conf
if [ -d /run/systemd/system ]; then [ "$(sysctl -n vm.swappiness)" = 17 ]; fi
says "nothing to do" plan

# rollback: back past an add, then forward again, with history to match.
"$yos" --config "$cfg" add --yes tree
"$yos" --config "$cfg" rollback --yes
if pacman -Q tree 2>/dev/null; then echo "tree is still installed after rollback"; exit 1; fi
if grep -q tree "$cfg"; then echo "the config still has tree after rollback"; exit 1; fi
"$yos" --config "$cfg" rollback --yes
pacman -Q tree
"$yos" --config "$cfg" history
"$yos" --config "$cfg" remove --yes tree

# a service through the whole loop, where systemd runs the machine: the
# package goes in and the unit starts, then the unit stops and the package
# goes.
if [ -d /run/systemd/system ]; then
    "$yos" --config "$cfg" enable --yes tailscale
    systemctl is-enabled tailscaled.service
    systemctl is-active tailscaled.service
    says "nothing to do" plan
    # an upgrade replacing tailscaled's binary under it: status says so,
    # the next apply that changes packages offers the restart, and a
    # restart clears it.
    cp /usr/bin/tailscaled /usr/bin/tailscaled.new
    mv -f /usr/bin/tailscaled.new /usr/bin/tailscaled
    status_says "running replaced files:.*tailscaled.service"
    says "systemctl restart tailscaled.service" add --yes tree
    "$yos" --config "$cfg" remove --yes tree
    systemctl restart tailscaled.service
    if status_says "running replaced files:.*tailscaled"; then echo "tailscaled still stale after a restart"; exit 1; fi
    "$yos" --config "$cfg" disable --yes tailscale
    if systemctl is-active tailscaled.service; then echo "tailscaled is still running"; exit 1; fi
    if pacman -Q tailscale 2>/dev/null; then echo "tailscale is still installed"; exit 1; fi
    says "nothing to do" plan
fi

# update applies what it resolved; on the same day there's nothing to do.
says "nothing to do" update --yes

# drift: with yos and its pacman hook installed the way a package would,
# a direct `pacman -S` shows in status until yos applies again.
install -Dm755 "$yos" /usr/bin/yos
install -Dm644 dist/yos-drift.hook /usr/share/libalpm/hooks/yos-drift.hook
pacman -S --noconfirm --noprogressbar htop >/dev/null
status_says "touched with pacman since the last apply: htop"
"$yos" --config "$cfg" --json plan > "$dir/drift-plan.json"
hash=$(sed -n 's/^  "hash": "\(.*\)",$/\1/p' "$dir/drift-plan.json")
"$yos" --config "$cfg" apply --yes
if status_says "touched with pacman"; then echo "drift survived an apply"; exit 1; fi

# events: the pacman run, the apply with its plan's hash, and the config
# commits, one json document a line.
"$yos" events > "$dir/events"
grep '"kind":"pacman"' "$dir/events" | grep -q '"htop"' || { echo "smoke: no pacman event for htop"; cat "$dir/events"; exit 1; }
grep '"kind":"apply"' "$dir/events" | tail -n 1 | grep -q "\"step\":\"done\",\"plan\":\"$hash\"" || { echo "smoke: the last apply event isn't plan $hash"; cat "$dir/events"; exit 1; }
grep -q '"kind":"commit"' "$dir/events" || { echo "smoke: no commit events"; exit 1; }
if grep -v '^{"schema":"yos.event/1",' "$dir/events"; then echo "smoke: a line of yos events isn't an event"; exit 1; fi
[ "$("$yos" events --since 2000-01-01T00:00Z | wc -l)" = "$(wc -l < "$dir/events")" ] || { echo "smoke: --since 2000 left events out"; exit 1; }
[ "$("$yos" events --since 99999999999999 | wc -l)" = 0 ] || { echo "smoke: --since the far future printed events"; exit 1; }
rm /usr/share/libalpm/hooks/yos-drift.hook

# a config that leaves out base doesn't get to remove it.
bare=$dir/bare.toml
printf 'version = 1\n[boot]\nkernel = "none"\n' > "$bare"
if "$yos" --config "$bare" plan 2> "$dir/bare.err"; then echo "planned removing base"; exit 1; fi
grep -q E0126 "$dir/bare.err"

# what enable-rollback makes of this machine: ready or not, never a crash.
rc=0
"$yos" --json enable-rollback > "$dir/enable.json" || rc=$?
[ "$rc" -le 1 ] || { echo "smoke: enable-rollback exited $rc"; exit 1; }
grep -q "yos.enable-rollback/1" "$dir/enable.json"

git -C "$dir" log --format=%s
echo "smoke ok"
