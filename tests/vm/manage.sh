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
# os edit, through a terminal: a good edit is saved and committed, and a bad
# one that isn't edited again is put back.
"$vm" ssh "printf '#!/bin/sh\\necho \"# edited\" >> \"\$1\"\\n' > /root/good-edit && printf '#!/bin/sh\\necho \"bogus = 1\" >> \"\$1\"\\n' > /root/bad-edit && chmod +x /root/good-edit /root/bad-edit"
check "EDITOR=/root/good-edit script -qec '/usr/local/bin/os edit --no-apply' /dev/null >/dev/null; git -C /etc/yoq log -1 --format=%s" edit
check "tail -n 1 /etc/yoq/machine.toml" "# edited"
check "echo n | EDITOR=/root/bad-edit script -qec '/usr/local/bin/os edit --no-apply' /dev/null >/dev/null; grep -c bogus /etc/yoq/machine.toml || true" 0
check "/usr/local/bin/os edit 2>&1 | grep -c 'needs a terminal'" 1
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
