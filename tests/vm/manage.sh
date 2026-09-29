#!/bin/sh
# a machine that can't have generations stays on the manage rung:
# enable-rollback names the check that fails ($1), and changes nothing.
# runs after the smoke test.
set -eu
. tests/vm/lib.sh

"$vm" ssh "/usr/local/bin/os init >/dev/null 2>&1 || true"
check "/usr/local/bin/os enable-rollback --yes >/tmp/out 2>&1; echo \$?" 1
check "grep -c '$1' /tmp/out" 1
check "test -e /var/lib/yoq/generations && echo generations || echo none" none
check "/usr/local/bin/os rollback --to-booted 2>&1 | grep -c 'no generations'" 1
# one os changes the machine at a time: with the lock held elsewhere, an
# apply says so and stops.
"$vm" ssh "mkdir -p /run/yoq && (setsid flock /run/yoq/lock sleep 30 </dev/null >/dev/null 2>&1 &) ; sleep 1"
check "/usr/local/bin/os apply --yes 2>&1 | grep -c 'is changing this machine'" 1
"$vm" ssh "sleep 30"
# leaving the manage rung takes only os's state; the config stays.
check "/usr/local/bin/os uninstall --yes >/dev/null; echo \$?" 0
check "test -e /var/lib/yoq && echo state || echo none" none
check "test -f /etc/yoq/machine.toml && echo config" config
echo "manage ok"
