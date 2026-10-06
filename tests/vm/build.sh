#!/bin/sh
# a clean build: the config and the lock alone, installed into an empty
# directory, give the same packages and the same files yos writes as the
# machine they came from. runs after the smoke test.
set -eu
. tests/vm/lib.sh

"$vm" ssh "/usr/local/bin/yos init >/dev/null 2>&1 || true"
# files the smoke test's own config had yos write, which this one doesn't
# ask for, go with one apply.
"$vm" ssh "/usr/local/bin/yos apply --yes" | tail -n 1
"$vm" ssh "/usr/local/bin/yos build --clean /var/tmp/clean >/tmp/build.out 2>&1; echo \$? >/tmp/build.rc; tail -n 40 /tmp/build.out"
check "cat /tmp/build.rc" 0
check "pacman -r /var/tmp/clean -Q | sha256sum" "$("$vm" ssh "pacman -Q | sha256sum")"
check "cmp /etc/hostname /var/tmp/clean/etc/hostname && echo same" same
check "cmp /etc/locale.conf /var/tmp/clean/etc/locale.conf && echo same" same
# nothing stays mounted in it, and a second build won't start over it.
"$vm" ssh "findmnt -rn -o TARGET,SOURCE,FSTYPE | grep /var/tmp/clean || true; sleep 5"
check "findmnt -rn -o TARGET | { grep -c /var/tmp/clean || true; }" 0
check "/usr/local/bin/yos build --clean /var/tmp/clean >/tmp/out 2>&1; echo \$?" 1
check "grep -c 'can.t make /var/tmp/clean' /tmp/out" 1
"$vm" ssh "rm -rf /var/tmp/clean"

# a lock from an earlier day, resolved against the arch linux archive as it
# was then, since mirrors only have today's packages.
then=$(date -u -d '3 days ago' +%F)
"$vm" ssh "/usr/local/bin/yos update --no-apply --date $then" | tail -n 2
check "grep -c '^sync_date = \"$then\"' /etc/yos/machine.lock" 1
check "test -e /var/cache/yos/sync/$then/core.db && echo archived" archived
# today's lock again, and the machine with it, in case the mirrors moved
# since the apply above. the scripts after start from a machine that
# matches its config.
"$vm" ssh "/usr/local/bin/yos update --yes" | tail -n 1
check "/usr/local/bin/yos plan" "nothing to do. this machine matches its config."
echo "build ok"
