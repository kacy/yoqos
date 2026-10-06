#!/bin/sh
# the manage rung, where a new kernel goes on live: pacman takes the old
# kernel's modules away with its package, and yos puts them back for the
# kernel that's still running, so a module it hasn't loaded yet still
# loads before the reboot. the first apply after the reboot removes them.
# runs after the smoke test, on a machine without generations.
set -eu
. tests/vm/lib.sh

yos=/usr/local/bin/yos
empty="nothing to do. this machine matches its config."

"$vm" ssh "$yos init >/dev/null 2>&1 || true"
# the scripts before can leave the lock ahead of the machine.
"$vm" ssh "$yos apply --yes" | tail -n 1
check "$yos plan" "$empty"
# an older kernel from the archive, running. the lock still has today's.
older_linux
"$vm" reboot
old=$("$vm" ssh "uname -r")
kernel_matches
# a module this kernel hasn't loaded yet.
check "lsmod | { grep -c '^dummy ' || true; }" 0

# yos puts today's linux back, live. the running kernel's modules stay.
"$vm" ssh "$yos apply --yes" | tail -n 2
check "test \"\$(pacman -Q linux | cut -d' ' -f2 | sed 's/\\.arch/-arch/')\" != $old && echo upgraded" upgraded
check "test -f /usr/lib/modules/$old/.yos-kept && echo kept" kept
check "modprobe dummy && lsmod | grep -c '^dummy '" 1
check "$yos plan" "$empty"

# after the reboot, the new kernel runs, and the next apply, even with
# nothing to do, removes the old modules.
"$vm" reboot
kernel_matches
check "test \"\$(uname -r)\" != $old && echo newer" newer
check "test -d /usr/lib/modules/$old && echo still there" "still there"
check "$yos apply --yes" "$empty"
check "test -d /usr/lib/modules/$old && echo still there || echo gone" gone
echo "kernel live ok"
