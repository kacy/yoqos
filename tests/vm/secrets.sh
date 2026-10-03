#!/bin/sh
# secrets: a value `yos secret set` keeps reaches the file that names it,
# and nothing yos prints or keeps shows it. runs after the smoke test, on a
# machine systemd runs.
set -eu
. tests/vm/lib.sh

yos=/usr/local/bin/yos
"$vm" ssh "$yos init >/dev/null 2>&1 || true"
"$vm" ssh "cp /etc/yos/machine.toml /root/machine.toml.secrets"
check "printf hunter2 | $yos secret set test/value >/dev/null; echo \$?" 0
check "stat -c %a /var/lib/yos/secrets /var/lib/yos/secrets/.key | tr '\\n' ' '" "700 600 "
check "$yos secret list" "test/value               not in the config"
"$vm" ssh "printf '\\n[files.\"/etc/yos-secret-test\"]\\nsecret = \"test/value\"\\n' >> /etc/yos/machine.toml"
check "$yos plan --json | grep -c '\"subject\": \"/etc/yos-secret-test\"'" 1
check "$yos apply --yes >/dev/null; echo \$?" 0
check "cat /etc/yos-secret-test" hunter2
check "stat -c %a /etc/yos-secret-test" 600
check "$yos plan" "nothing to do. this machine matches its config."
check "$yos why /etc/yos-secret-test | grep -c 'for files.\"/etc/yos-secret-test\" secret = \"test/value\"'" 1
# the value is nowhere yos prints or keeps it: not in plans, facts, status,
# events, the journal, the config's history, or yos's state.
check "{ $yos plan --json; $yos facts --json; $yos status --json; $yos why --json /etc/yos-secret-test; $yos events; cat /var/lib/yos/journal; git -C /etc/yos log -p; } 2>&1 | grep -c hunter2 || true" 0
check "grep -rl hunter2 /var/lib/yos /etc/yos | wc -l" 0
# a new value is a rewrite.
check "printf hunter3 | $yos secret set test/value >/dev/null; $yos plan | grep -c 'rewrite, mode 0600'" 1
check "$yos apply --yes >/dev/null; cat /etc/yos-secret-test" hunter3
check "$yos plan" "nothing to do. this machine matches its config."
# values without their key get a new one, so a changed file still shows.
check "rm /var/lib/yos/secrets/.key; printf x > /etc/yos-secret-test; $yos plan | grep -c 'rewrite, mode 0600'" 1
check "$yos apply --yes >/dev/null; cat /etc/yos-secret-test" hunter3
# without its value, the plan says how to set one, and status fails.
check "$yos secret rm test/value" "removed test/value. the config still writes it to /etc/yos-secret-test, so plans fail until it's set again or those entries go. the files stay as they are."
check "$yos plan 2>&1 | grep -c '^error.E0133'" 1
check "$yos status | grep -c 'secret test/value isn.t set here'" 1
# taken out of the config, the file stays, so it goes by hand.
"$vm" ssh "cp /root/machine.toml.secrets /etc/yos/machine.toml && rm /etc/yos-secret-test"
check "$yos secret list" "no secrets. \`yos secret set <name>\` keeps one."
check "$yos plan" "nothing to do. this machine matches its config."
echo "secrets ok"
