#!/bin/sh
# trials whose kernel the bootloader can't load at all, and a trial left
# alone by an older entry picked by hand. a broken initramfs (trial.sh)
# gets as far as a kernel panic, which reboots by itself; these stop in
# the bootloader. grub falls back to the generation before by itself.
# limine and refind would stop at an error screen, so os looks at the
# trial's files at shutdown and doesn't try a trial with a broken one, on
# systemd-boot too. a file that looks fine but won't start, a kernel for
# another machine, makes systemd-boot reboot, and the boot after runs the
# default. runs after trial.sh, in the same vm.
set -eu
. tests/vm/lib.sh

# an older generation picked by hand while a trial waits isn't the trial
# failing: it's still on trial, and the boot after tries it. refind's
# trial starts its own copy of refind, so that's where the pick goes.
"$vm" reboot
settled
"$vm" ssh "/usr/local/bin/os add --yes intel-ucode" | tail -n 1
on_trial yes
trial_n=$(newest)
case $VM_LOADER in
refind) "$vm" ssh "sed -i \"s|^default_selection .*|default_selection \\\"\$(grep -o '^menuentry \"yoq 1 [^\"]*' $(menu_file) | cut -c12-)\\\"|\" $VM_ESP/EFI/yoq-trial/refind.conf && grep ^default_selection $VM_ESP/EFI/yoq-trial/refind.conf" ;;
*) boot_once 1 ;;
esac
show_env
"$vm" reboot || true
wait_root /@roots/boot-1
settled
check "journalctl -b -u yoq-health --no-pager -o cat | grep -c \"generation $trial_n hasn't been tried yet\"" 1
on_trial yes
check "ls /var/lib/yoq/generations | sort -n | tail -n 1 | cut -d. -f1" "$trial_n"
"$vm" reboot
settled
check "journalctl -b -u yoq-health --no-pager -o cat | grep -c 'the default now'" 1
on_trial no
echo "picked by hand ok"

# what shows the trial was tried, or for a broken file, called off.
proof() {
    case $VM_LOADER:$1 in
    grub:*) echo "console:Falling back to" ;;
    systemd-boot:foreign) echo "console:Failed to start boot entry" ;;
    *) echo "journal:won't try it" ;;
    esac
}

cases="missing garbage"
[ "$VM_LOADER" = systemd-boot ] && cases="$cases foreign"
for how in $cases; do
    "$vm" reboot
    settled
    "$vm" ssh "/usr/local/bin/os add --yes intel-ucode" | tail -n 1
    on_trial yes
    before=$(second_newest)
    break_trial_kernel "$how"
    show_env
    falls_back "$before" "$(proof "$how")"
    on_trial no
    echo "load failure ok: $how"
done

# trials that hang before the root's watchdog would ordinarily be there:
# yoq-emergency.service reboots one that drops to an emergency shell, in
# the initramfs or the root, and the watchdog starts with the root's
# systemd, so a unit that holds up sysinit.target can't stop it.
for how in root fstab sysinit; do
    case $how in
    root) proof="console:Failed to mount" ;;
    fstab) proof="console:Timed out waiting for device" ;;
    sysinit) proof="console:start job is running for" ;;
    esac
    "$vm" reboot
    settled
    "$vm" ssh "/usr/local/bin/os add --yes intel-ucode" | tail -n 1
    on_trial yes
    before=$(second_newest)
    break_trial_early "$how"
    show_env
    falls_back "$before" "$proof"
    on_trial no
    echo "early hang ok: $how"
done
echo "load failures ok"
