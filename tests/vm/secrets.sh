#!/bin/sh
# secrets: a value `os secret set` keeps reaches the file that names it,
# and nothing os prints or keeps shows it. runs after the smoke test, on a
# machine systemd runs.
set -eu
. tests/vm/lib.sh

os=/usr/local/bin/os
"$vm" ssh "$os init >/dev/null 2>&1 || true"
"$vm" ssh "cp /etc/yoq/machine.toml /root/machine.toml.secrets"
check "printf hunter2 | $os secret set test/value >/dev/null; echo \$?" 0
check "stat -c %a /var/lib/yoq/secrets /var/lib/yoq/secrets/.key | tr '\\n' ' '" "700 600 "
check "$os secret list" "test/value               not in the config"
"$vm" ssh "printf '\\n[files.\"/etc/yoq-secret-test\"]\\nsecret = \"test/value\"\\n' >> /etc/yoq/machine.toml"
check "$os plan --json | grep -c '\"subject\": \"/etc/yoq-secret-test\"'" 1
check "$os apply --yes >/dev/null; echo \$?" 0
check "cat /etc/yoq-secret-test" hunter2
check "stat -c %a /etc/yoq-secret-test" 600
check "$os plan" "nothing to do. this machine matches its config."
check "$os why /etc/yoq-secret-test | grep -c 'for files.\"/etc/yoq-secret-test\" secret = \"test/value\"'" 1
# the value is nowhere os prints or keeps it: not in plans, facts, status,
# events, the journal, the config's history, or os's state.
check "{ $os plan --json; $os facts --json; $os status --json; $os why --json /etc/yoq-secret-test; $os events; cat /var/lib/yoq/journal; git -C /etc/yoq log -p; } 2>&1 | grep -c hunter2 || true" 0
check "grep -rl hunter2 /var/lib/yoq /etc/yoq | wc -l" 0
# a new value is a rewrite.
check "printf hunter3 | $os secret set test/value >/dev/null; $os plan | grep -c 'rewrite, mode 0600'" 1
check "$os apply --yes >/dev/null; cat /etc/yoq-secret-test" hunter3
check "$os plan" "nothing to do. this machine matches its config."
# without its value, the plan says how to set one, and status fails.
check "$os secret rm test/value" "removed test/value. the config still writes it to /etc/yoq-secret-test, so plans fail until it's set again or those entries go. the files stay as they are."
check "$os plan 2>&1 | grep -c '^error.E0133'" 1
check "$os status | grep -c 'secret test/value isn.t set here'" 1
# taken out of the config, the file stays, so it goes by hand.
"$vm" ssh "cp /root/machine.toml.secrets /etc/yoq/machine.toml && rm /etc/yoq-secret-test"
check "$os secret list" "no secrets. \`os secret set <name>\` keeps one."
check "$os plan" "nothing to do. this machine matches its config."
echo "secrets ok"
