#!/bin/sh
# yos upgraded under a machine an older yos set up. 0.1.0 turns generations
# on, makes a few, and runs a trial. then the yos under test replaces it in
# /usr/bin, the way the package would, while 0.1.0 arms one more trial, as
# a `yos update` that upgrades yos itself does: the new yos judges a trial
# the old one armed. after that the new yos has to read everything 0.1.0
# left (records, the journal, the drift log, grub's env file and menu, its
# units, the config's history) and bring it up to date. a rollback to a
# generation from before the upgrade runs 0.1.0 again, on what the new yos
# wrote, and 0.1.0 rolls forward again. last, 0.1.3 arms a trial that
# fails, and the new yos has to fall back from it, though 0.1.3 noted grub
# trials only in the journal. runs on the cloud image, in a vm of its own.
# usage: tests/vm/upgrade.sh <yos 0.1.0> <yos 0.1.3> <new yos>
set -eu
. tests/vm/lib.sh

old=$1
old013=$2
new=$3
on_failure="/usr/bin/yos version; grub-editenv $VM_ESP/yos/grubenv list; ls /var/lib/yos /var/lib/yos/generations; tail -n 5 /var/lib/yos/journal; journalctl -b -u yos-health --no-pager -o cat | tail -n 20"

# yos where its package puts it, with the drift hook beside it.
install_os() {
    "$vm" copy "$1" /usr/bin/yos
    "$vm" copy dist/yos-drift.hook /usr/share/libalpm/hooks/yos-drift.hook
}

"$vm" ssh "mkdir -p /usr/share/libalpm/hooks"
install_os "$old"
check "yos version" "yos 0.1.0"
want_version=$("$new" version)

# 0.1.0 sets the machine up: a config, generations, a live apply, a pacman
# run outside yos, and a trial it blesses.
"$vm" ssh "yos init >/dev/null"
"$vm" ssh "yos apply --yes" | tail -n 2
"$vm" ssh "yos enable-rollback --yes" | tail -n 2
"$vm" reboot
check "findmnt -no FSROOT /" /@roots/1
"$vm" ssh "yos add --yes tree" | tail -n 2
"$vm" ssh "pacman -S --noconfirm --needed --noprogressbar figlet >/dev/null"
"$vm" ssh "yos add --yes intel-ucode" | tail -n 2
on_trial yes
"$vm" reboot
settled
on_trial no
"$vm" ssh "yos history"

# the upgrade, as `yos update` does it when yos is one of the packages: the
# new yos goes into the root, and the old one, still running, makes the
# next generation and arms its trial. that generation boots the new yos,
# whose health check judges a trial only grub's env file names.
"$vm" ssh "cp /usr/bin/yos /root/yos-0.1.0"
install_os "$new"
check "yos version" "$want_version"
"$vm" ssh "/root/yos-0.1.0 add --yes amd-ucode" | tail -n 2
on_trial yes
armed=$(newest)
"$vm" reboot
settled
check "journalctl -b -u yos-health --no-pager -o cat | grep -c 'the default now'" 1
on_trial no
check "yos version" "$want_version"

# the new yos reads what 0.1.0 left.
check "yos history | grep -c '^[ *] *$armed  '" 1
check "yos plan" "nothing to do. this machine matches its config."
check "yos status >/tmp/status; echo \$?" 0
check "yos events >/dev/null; echo \$?" 0
check "yos events | grep -c '\"kind\":\"apply\"' | grep -vc '^0\$'" 1
check "yos doctor | grep -c '^  ok  boot menu'" 1
check "git -C /etc/yos log --format=%s | grep -c 'add tree'" 1

# its first generation brings 0.1.0's units up to date: the watchdog
# counts from the root's start, and yos-carry.service goes in.
"$vm" ssh "yos add --yes cowsay" | tail -n 2
check "grep -c '^OnActiveSec=' /etc/systemd/system/yos-watchdog.timer" 1
check "test -e /etc/systemd/system/multi-user.target.wants/yos-carry.service && echo on" on
# its own drift hook, and its own trial.
"$vm" ssh "pacman -S --noconfirm --needed --noprogressbar fortune-mod >/dev/null"
check "yos status | grep -q fortune-mod && echo changed" changed
"$vm" ssh "yos remove --yes intel-ucode" | tail -n 2
on_trial yes
"$vm" reboot
settled
check "journalctl -b -u yos-health --no-pager -o cat | grep -c 'the default now'" 1
on_trial no
newest_new=$(newest)

# back to generation 2, from before the upgrade: its root has 0.1.0, which
# then runs on the new yos's records, journal, and menu.
"$vm" ssh "yos rollback --yes 2" | tail -n 3
"$vm" reboot
settled
check "yos version" "yos 0.1.0"
check "yos history | grep -c '^[ *] *$newest_new  '" 1
check "yos status >/dev/null; echo \$?" 0
check "yos plan" "nothing to do. this machine matches its config."
# and forward again with 0.1.0, to the new yos's newest generation.
"$vm" ssh "yos rollback --yes $newest_new" | tail -n 3
"$vm" reboot
settled
check "yos version" "$want_version"
check "yos plan" "nothing to do. this machine matches its config."
check "yos gc >/dev/null; echo \$?" 0
check "yos doctor | grep -c '^  ok  boot menu'" 1
check "grep -c -e '--id head' $VM_ESP/grub/grub.cfg" 1

# a trial 0.1.3 arms, run beside the new yos, as one in /usr/local would
# be. it can't boot, and the boot that falls back runs the new yos, which
# finds 0.1.3's armed event in the journal, not a note of its own.
"$vm" copy "$old013" /root/yos-0.1.3
check "/root/yos-0.1.3 version" "yos 0.1.3"
"$vm" ssh "/root/yos-0.1.3 add --yes intel-ucode" | tail -n 2
on_trial yes
check "test -e /var/lib/yos/trial && echo noted || echo journal only" "journal only"
before=$(second_newest)
break_trial_boot
"$vm" reboot || true
wait_root "/@roots/boot-$before"
settled
check "yos history | tail -n 1 | grep -c 'fell back from'" 1
check "yos version" "$want_version"
check "yos plan" "nothing to do. this machine matches its config."
echo "upgrade ok"
