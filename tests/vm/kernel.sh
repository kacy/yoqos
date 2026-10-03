#!/bin/sh
# a kernel that changes, through generations. the machine goes back a few
# weeks with `yos update --date`, linux with it, then forward with a plain
# `yos update`: the weekly update, with a new kernel and systemd. each is
# staged, tried once, and blessed, and every boot runs a kernel whose
# modules are in its root. then `yos rollback` across the change, and back.
# the generation with the older kernel stays pinned, for failures.sh's
# restore. runs after rollback.sh, in the same vm.
set -eu
. tests/vm/lib.sh

yos=/usr/local/bin/yos
on_failure="uname -r; pacman -Q linux systemd; ls /usr/lib/modules; ls -l $VM_ESP; cat /proc/cmdline; $os history | tail -n 5"

# a boot that came up healthy after a trial.
blessed() {
    "$vm" reboot
    settled
    check "journalctl -b -u yos-health --no-pager -o cat | grep -c 'the default now'" 1
    on_trial no
}

check "$os plan" "nothing to do. this machine matches its config."
today_kernel=$("$vm" ssh "uname -r")
then=$(older date)
echo "going back to $then"

# back: another linux, so a staged root with an initramfs built for
# modules the running root doesn't have.
"$vm" ssh "$os update --yes --date $then >/tmp/update.out 2>&1; echo \$? >/tmp/update.rc; tail -n 4 /tmp/update.out"
check "cat /tmp/update.rc" 0
check "grep -c 'reboot needed: .*kernel' /tmp/update.out" 1
on_trial yes
blessed
old_kernel=$("$vm" ssh "uname -r")
[ "$old_kernel" != "$today_kernel" ] || { echo "$name: still on $today_kernel after going back to $then"; exit 1; }
kernel_matches
old=$(newest)
check "$os pin $old" "generation $old is pinned: garbage collection keeps it."

# forward: the weekly update, the screen says what's notable and why it
# needs a reboot.
"$vm" ssh "$os update --yes >/tmp/update.out 2>&1; echo \$? >/tmp/update.rc; cat /tmp/update.out"
check "cat /tmp/update.rc" 0
check "grep -c '^  .........linux [^ ]* -> ' /tmp/update.out" 1
check "grep -c 'reboot needed: .*kernel' /tmp/update.out" 1
on_trial yes
blessed
check "uname -r" "$today_kernel"
kernel_matches
new=$(newest)
check "$os plan" "nothing to do. this machine matches its config."

# a rollback across the kernel change boots the older root's kernel, with
# its modules, and its lock and config come back with it.
"$vm" ssh "$os rollback --yes $old" | tail -n 2
"$vm" reboot
settled
check "uname -r" "$old_kernel"
kernel_matches
check "grep -c '^sync_date = \"$then\"' /etc/yos/machine.lock" 1
check "$os plan" "nothing to do. this machine matches its config."

# and forward again, to today's.
"$vm" ssh "$os rollback --yes $new" | tail -n 2
"$vm" reboot
settled
check "uname -r" "$today_kernel"
kernel_matches
check "$os plan" "nothing to do. this machine matches its config."
"$vm" ssh "echo $old > /root/old-kernel-gen"
echo "kernel ok"
