#!/bin/sh
# system ids across a rollback: an account a package made stays in every
# generation after, so its id never goes to another package, and the
# package installed again gets it back with its files. runs on a machine
# with generations, before leave.sh.
set -eu
. tests/vm/lib.sh

"$vm" reboot
settled
"$vm" ssh "/usr/local/bin/yos add --yes chrony" | tail -n 1
"$vm" ssh "cat /usr/lib/sysusers.d/chrony.conf 2>/dev/null || true"
uid=$("$vm" ssh "id -u chrony")
"$vm" ssh "mkdir -p /var/lib/yos-ids-test && chown chrony /var/lib/yos-ids-test"

# a network connection saved since, like a wi-fi network joined, comes
# along too: networkmanager keeps them in /etc.
"$vm" ssh "mkdir -p /etc/NetworkManager/system-connections && printf '[connection]\\nid=yos-carry-test\\ntype=dummy\\ninterface-name=yosdummy0\\nautoconnect=false\\n' > /etc/NetworkManager/system-connections/yos-carry-test.nmconnection && chmod 600 /etc/NetworkManager/system-connections/yos-carry-test.nmconnection"

# back to before chrony: the account comes along, with its id.
"$vm" ssh "/usr/local/bin/yos rollback --yes" | tail -n 1
"$vm" reboot
settled
check "pacman -Q chrony >/dev/null 2>&1 || echo no chrony" "no chrony"
check "id -u chrony" "$uid"
check "stat -c %U /var/lib/yos-ids-test" chrony
check "grep -c '^id=yos-carry-test' /etc/NetworkManager/system-connections/yos-carry-test.nmconnection" 1

# another package's account can't take the id,
"$vm" ssh "/usr/local/bin/yos add --yes dnsmasq" | tail -n 1
check "test \$(id -u dnsmasq) != $uid && echo apart" apart
# and chrony again gets its own back, with its files.
"$vm" ssh "/usr/local/bin/yos add --yes chrony" | tail -n 1
check "id -u chrony" "$uid"
check "stat -c %U /var/lib/yos-ids-test" chrony
check "/usr/local/bin/yos status | grep -c 'system ids changed' || true" 0
echo "ids ok"
