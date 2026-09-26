#!/bin/sh
# trial boots in a vm with generations: a change that needs a reboot boots
# once on trial, and becomes the default only if it comes up healthy.
# runs after rollback.sh, in the same vm.
set -eu
vm=tests/vm/vm.sh

check() {
    got=$("$vm" ssh "$1")
    if [ "$got" != "$2" ]; then
        echo "trial: $1 gave '$got', not '$2'"
        exit 1
    fi
    echo "ok: $1 -> $got"
}
# yoq-health runs after boot; wait for it to be done, but not forever.
settled() {
    "$vm" ssh "for i in \$(seq 150); do [ \"\$(systemctl show -p ActiveState --value yoq-health)\" = activating ] || exit 0; sleep 2; done; echo 'yoq-health still running after 5 minutes'; exit 1"
}
env() {
    "$vm" ssh "grub-editenv /efi/yoq/grubenv list | grep ^yoq_ | sort | tr '\\n' ' '"
}

# a healthy trial: microcode needs a reboot.
"$vm" ssh "/usr/local/bin/os add --yes amd-ucode" | tail -n 2
env
"$vm" reboot
settled
check "journalctl -b -u yoq-health --no-pager -o cat | grep -c 'the default now'" 1
check "grub-editenv /efi/yoq/grubenv list | grep -c -e ^yoq_trial -e ^yoq_default || true" 0

# an unhealthy trial: a service the config turns on that only starts
# while a marker file exists. the trial boot runs without the marker.
"$vm" ssh "touch /etc/yoq-flaky-ok && printf '[Unit]\\nDescription=flaky\\n[Service]\\nType=oneshot\\nRemainAfterExit=yes\\nExecStart=/usr/bin/test -e /etc/yoq-flaky-ok\\n[Install]\\nWantedBy=multi-user.target\\n' > /etc/systemd/system/yoq-flaky.service && systemctl daemon-reload"
"$vm" ssh "printf '\\n[services.flaky]\\nunit = \"yoq-flaky.service\"\\npackage = \"pacman\"\\n' >> /etc/yoq/machine.toml && /usr/local/bin/os apply --yes" | tail -n 2
before=$("$vm" ssh "ls /var/lib/yoq/generations | sort -n | tail -n 1 | cut -d. -f1")
"$vm" ssh "/usr/local/bin/os remove --yes amd-ucode" | tail -n 2
"$vm" ssh "rm /etc/yoq-flaky-ok"
env
"$vm" reboot
# the trial boot may answer before its health check reboots it, so wait
# for the boot after: the generation before, from its copy.
for _ in $(seq 60); do
    root=$(timeout 20 "$vm" ssh "findmnt -no FSROOT /" 2>/dev/null || true)
    [ "$root" = "/@roots/boot-$before" ] && break
    sleep 5
done
check "findmnt -no FSROOT /" "/@roots/boot-$before"
# and os took the fallback on as the newest generation, with its config,
# and says what happened.
settled
check "/usr/local/bin/os history | tail -n 1 | grep -c 'fell back from'" 1
check "grub-editenv /efi/yoq/grubenv list | grep -c -e ^yoq_trial -e ^yoq_default || true" 0
check "/usr/local/bin/os status | grep -c '^note: generation'" 1
check "/usr/local/bin/os plan" "nothing to do. this machine matches its config."
echo "trial ok"
