#!/bin/sh
# moving a machine from yoq os, yos's name before 0.2.0, to yos. yoq os
# 0.1.5 sets the machine up with generations and a trial. yos stops on it
# with E0138, since it doesn't read yoq os's state. the way over is the
# one E0138 gives: the old `os uninstall`, then /etc/yoq moved to
# /etc/yos, after which yos plans nothing, turns generations on again,
# and runs a trial of its own. runs on the cloud image, in a vm of its own.
# usage: tests/vm/switch.sh <yoq os 0.1.5's tree, built> <yos>
set -eu
. tests/vm/lib.sh

old=$1
new=$2
on_failure="ls /etc/yoq /etc/yos /var/lib/yoq /var/lib/yos 2>&1; findmnt -no FSROOT /; journalctl -b -u yos-health -u yoq-health --no-pager -o cat | tail -n 20"

# yoq os where its package put it, with its drift hook.
"$vm" ssh "mkdir -p /usr/share/libalpm/hooks"
"$vm" copy "$old/zig-out/bin/os" /usr/bin/os
"$vm" copy "$old/dist/yoq-drift.hook" /usr/share/libalpm/hooks/yoq-drift.hook
check "os version" "os 0.1.5"

# yoq os's own health check, which yos's settled doesn't know.
old_settled() {
    "$vm" ssh "for i in \$(seq 150); do [ \"\$(systemctl show -p ExecMainExitTimestampMonotonic --value yoq-health)\" != 0 ] && exit 0; sleep 2; done; echo 'no yoq-health run after 5 minutes'; exit 1"
}

# yoq os sets the machine up: a config, generations, a live apply, and a
# trial it blesses.
"$vm" ssh "os init >/dev/null"
"$vm" ssh "os apply --yes" | tail -n 2
"$vm" ssh "os enable-rollback --yes" | tail -n 2
"$vm" reboot
check "findmnt -no FSROOT /" /@roots/1
"$vm" ssh "os add --yes tree" | tail -n 2
"$vm" ssh "os add --yes intel-ucode" | tail -n 2
"$vm" reboot
old_settled
check "grub-editenv $VM_ESP/yoq/grubenv list | grep -c -e ^yoq_trial -e ^yoq_default || true" 0

# yos, installed beside it, won't touch the machine yoq os set up.
"$vm" copy "$new" /usr/bin/yos
"$vm" copy dist/yos-drift.hook /usr/share/libalpm/hooks/yos-drift.hook
check "yos status >/dev/null 2>/tmp/err; echo \$?" 1
check "grep -c 'error\\[E0138\\]: this machine was set up by yoq os' /tmp/err" 1
check "yos version" "yos $("$new" version | cut -d' ' -f2)"

# the way over, as E0138 says: the old uninstall, generations and all, and
# the config moved.
"$vm" ssh "os uninstall --yes --delete-generations" | tail -n 1
check "test -e /var/lib/yoq && echo state || echo none" none
"$vm" ssh "rm -f /usr/bin/os /usr/share/libalpm/hooks/yoq-drift.hook"
"$vm" reboot
"$vm" ssh "mv /etc/yoq /etc/yos"
check "yos plan" "nothing to do. this machine matches its config."
check "git -C /etc/yos log --format=%s | grep -c 'add tree'" 1

# generations again, under yos, and a trial of its own.
"$vm" ssh "yos enable-rollback --yes" | tail -n 2
"$vm" reboot
settled
check "test -e /var/lib/yos/generations/1.json && echo yes" yes
"$vm" ssh "yos add --yes amd-ucode" | tail -n 2
on_trial yes
"$vm" reboot
settled
check "journalctl -b -u yos-health --no-pager -o cat | grep -c 'the default now'" 1
on_trial no
check "yos plan" "nothing to do. this machine matches its config."
check "yos doctor | grep -c '^  ok  boot menu'" 1
check "pacman -Q tree intel-ucode amd-ucode >/dev/null && echo kept" kept
echo "switch ok"
