#!/bin/sh
# os upgraded under a machine an older os set up. 0.1.0 turns generations
# on, makes a few, and runs a trial. then the os under test replaces it in
# /usr/bin, the way the package would, while 0.1.0 arms one more trial, as
# an `os update` that upgrades os itself does: the new os judges a trial
# the old one armed. after that the new os has to read everything 0.1.0
# left (records, the journal, the drift log, grub's env file and menu, its
# units, the config's history) and bring it up to date. a rollback to a
# generation from before the upgrade runs 0.1.0 again, on what the new os
# wrote, and 0.1.0 rolls forward again. last, 0.1.3 arms a trial that
# fails, and the new os has to fall back from it, though 0.1.3 noted grub
# trials only in the journal. runs on the cloud image, in a vm of its own.
# usage: tests/vm/upgrade.sh <os 0.1.0> <os 0.1.3> <new os>
set -eu
. tests/vm/lib.sh

old=$1
old013=$2
new=$3
on_failure="/usr/bin/os version; grub-editenv $VM_ESP/yoq/grubenv list; ls /var/lib/yoq /var/lib/yoq/generations; tail -n 5 /var/lib/yoq/journal; journalctl -b -u yoq-health --no-pager -o cat | tail -n 20"

# os where its package puts it, with the drift hook beside it.
install_os() {
    "$vm" copy "$1" /usr/bin/os
    "$vm" copy dist/yoq-drift.hook /usr/share/libalpm/hooks/yoq-drift.hook
}

"$vm" ssh "mkdir -p /usr/share/libalpm/hooks"
install_os "$old"
check "os version" "os 0.1.0"
want_version=$("$new" version)

# 0.1.0 sets the machine up: a config, generations, a live apply, a pacman
# run outside os, and a trial it blesses.
"$vm" ssh "os init >/dev/null"
"$vm" ssh "os apply --yes" | tail -n 2
"$vm" ssh "os enable-rollback --yes" | tail -n 2
"$vm" reboot
check "findmnt -no FSROOT /" /@roots/1
"$vm" ssh "os add --yes tree" | tail -n 2
"$vm" ssh "pacman -S --noconfirm --needed --noprogressbar figlet >/dev/null"
"$vm" ssh "os add --yes intel-ucode" | tail -n 2
on_trial yes
"$vm" reboot
settled
on_trial no
"$vm" ssh "os history"

# the upgrade, as `os update` does it when os is one of the packages: the
# new os goes into the root, and the old one, still running, makes the
# next generation and arms its trial. that generation boots the new os,
# whose health check judges a trial only grub's env file names.
"$vm" ssh "cp /usr/bin/os /root/os-0.1.0"
install_os "$new"
check "os version" "$want_version"
"$vm" ssh "/root/os-0.1.0 add --yes amd-ucode" | tail -n 2
on_trial yes
armed=$(newest)
"$vm" reboot
settled
check "journalctl -b -u yoq-health --no-pager -o cat | grep -c 'the default now'" 1
on_trial no
check "os version" "$want_version"

# the new os reads what 0.1.0 left.
check "os history | grep -c '^[ *] *$armed  '" 1
check "os plan" "nothing to do. this machine matches its config."
check "os status >/tmp/status; echo \$?" 0
check "os events >/dev/null; echo \$?" 0
check "os events | grep -c '\"kind\":\"apply\"' | grep -vc '^0\$'" 1
check "os doctor | grep -c '^  ok  boot menu'" 1
check "git -C /etc/yoq log --format=%s | grep -c 'add tree'" 1

# its first generation brings 0.1.0's units up to date: the watchdog
# counts from the root's start, and yoq-carry.service goes in.
"$vm" ssh "os add --yes cowsay" | tail -n 2
check "grep -c '^OnActiveSec=' /etc/systemd/system/yoq-watchdog.timer" 1
check "test -e /etc/systemd/system/multi-user.target.wants/yoq-carry.service && echo on" on
# its own drift hook, and its own trial.
"$vm" ssh "pacman -S --noconfirm --needed --noprogressbar fortune-mod >/dev/null"
check "os status | grep -q fortune-mod && echo changed" changed
"$vm" ssh "os remove --yes intel-ucode" | tail -n 2
on_trial yes
"$vm" reboot
settled
check "journalctl -b -u yoq-health --no-pager -o cat | grep -c 'the default now'" 1
on_trial no
newest_new=$(newest)

# back to generation 2, from before the upgrade: its root has 0.1.0, which
# then runs on the new os's records, journal, and menu.
"$vm" ssh "os rollback --yes 2" | tail -n 3
"$vm" reboot
settled
check "os version" "os 0.1.0"
check "os history | grep -c '^[ *] *$newest_new  '" 1
check "os status >/dev/null; echo \$?" 0
check "os plan" "nothing to do. this machine matches its config."
# and forward again with 0.1.0, to the new os's newest generation.
"$vm" ssh "os rollback --yes $newest_new" | tail -n 3
"$vm" reboot
settled
check "os version" "$want_version"
check "os plan" "nothing to do. this machine matches its config."
check "os gc >/dev/null; echo \$?" 0
check "os doctor | grep -c '^  ok  boot menu'" 1
check "grep -c -e '--id head' $VM_ESP/grub/grub.cfg" 1

# a trial 0.1.3 arms, run beside the new os, as one in /usr/local would
# be. it can't boot, and the boot that falls back runs the new os, which
# finds 0.1.3's armed event in the journal, not a note of its own.
"$vm" copy "$old013" /root/os-0.1.3
check "/root/os-0.1.3 version" "os 0.1.3"
"$vm" ssh "/root/os-0.1.3 add --yes intel-ucode" | tail -n 2
on_trial yes
check "test -e /var/lib/yoq/trial && echo noted || echo journal only" "journal only"
before=$(second_newest)
break_trial_boot
falls_back "$before"
check "os version" "$want_version"
check "os plan" "nothing to do. this machine matches its config."
echo "upgrade ok"
