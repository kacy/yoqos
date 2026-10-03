#!/bin/sh
# [boot] uki in a vm with generations: the next root gets ukify and yos's
# ukify config, the trial boots a unified kernel image yos built from that
# root's kernel and initramfs, with the command line from its entry, and a
# rollback to a generation from before still boots the plain files. on
# systemd-boot, where the entry starts the image with `efi` and passes
# `options`, and on limine, where it's `protocol: efi` with `cmdline:`.
# runs after trial.sh, in the same vm.
set -eu
. tests/vm/lib.sh

entries=$VM_ESP/loader/entries
conf=$(menu_file)
# yos's section of limine.conf, and its trial entry.
section="sed -n '/^# yos: generations/,/^# yos: end/p' $conf"
trial_entry="sed -n '/^\\/yos trial boot\$/,/^# yos: end/p' $conf"
# systemd-stub names the image it started in this efi variable, as a
# utf-16 path after 4 bytes of attributes. no stub, no variable. only the
# file's name is compared, since bootloaders write the rest differently.
stub_image="f=\$(ls /sys/firmware/efi/efivars/StubImageIdentifier-* 2>/dev/null) && tail -c +5 \$f | tr -d '\\000' | tr '\\\\' / | sed 's|.*/||' || echo none"
case $VM_LOADER in
systemd-boot) on_failure="bootctl status --no-pager 2>&1 | head -n 30; cat /proc/cmdline; ls -l $VM_ESP/yos/boot" ;;
*) on_failure="$section; cat /proc/cmdline; ls -l $VM_ESP/yos/boot" ;;
esac

# the image the newest generation's entry starts, by name.
head_image() {
    case $VM_LOADER in
    systemd-boot) "$vm" ssh "sed -n 's|^efi .*/||p' $entries/yos-head.conf" ;;
    limine) "$vm" ssh "$section | sed -n 's|^    path: boot():.*/||p' | head -n 1" ;;
    esac
}

"$vm" reboot
settled
before=$(newest)
"$vm" ssh "if grep -q '^\\[boot\\]' /etc/yos/machine.toml; then sed -i '/^\\[boot\\]/a uki = true' /etc/yos/machine.toml; else printf '\\n[boot]\\nuki = true\\n' >> /etc/yos/machine.toml; fi && /usr/local/bin/yos update --yes" | tail -n 3
on_trial yes
# ukify is in the next root, which built the image; this one has none.
check "pacman -Q systemd-ukify >/dev/null 2>&1 || echo not yet" "not yet"
case $VM_LOADER in
systemd-boot)
    check "grep -c '^efi /yos/boot/[0-9a-f]*-yos.efi\$' $entries/yos-trial*.conf $entries/yos-head.conf | cut -d: -f2 | tr '\\n' ' '" "1 1 "
    check "grep -c -e '^linux ' -e '^initrd ' $entries/yos-trial*.conf || true" 0
    # one options line, with the trial's argument once. "sort-key
    # yos-trial" is in there too, so the dot has to be a dot.
    check "grep -c '^options ' $entries/yos-trial*.conf" 1
    check "grep -c '^options .* yos\\.trial\$' $entries/yos-trial*.conf" 1
    check "grep -c '^linux ' $entries/yos-gen-$before.conf" 1
    ;;
limine)
    # the newest generation and the trial start the image; older ones
    # boot their kernels.
    check "$section | grep -c '^    path: boot():/yos/boot/[0-9a-f]*-yos.efi\$'" 2
    check "$section | grep -c '^    protocol: efi\$'" 2
    check "$trial_entry | grep -c -e '^    protocol: efi\$' -e '^    cmdline: root=.* yos\\.trial\$'" 2
    check "$trial_entry | grep -c '^    module_path:' || true" 0
    check "$section | grep -c '^    protocol: linux\$' | grep -c -v '^0\$'" 1
    ;;
esac
image=$(head_image)
staged=$(newest_root)
"$vm" reboot
settled
show_env
check "journalctl -b -u yos-health --no-pager -o cat | grep -c 'the default now'" 1
on_trial no
# the stub started yos's image, and the root came from the entry's
# command line, since the image has none of its own.
check "$stub_image" "$image"
check "findmnt -no FSROOT / | sed 's|^/||'" "${staged#/}"
check "pacman -Q systemd-ukify >/dev/null && echo installed" installed
check "/usr/local/bin/yos plan" "nothing to do. this machine matches its config."
# the image boots from the esp, outside every root, and nothing else does.
check "ls $VM_ESP/yos/boot | grep -c -- '-yos.efi\$'" 1

# back to the generation from before: the plain kernel and initramfs, and
# its config, without the key.
"$vm" ssh "/usr/local/bin/yos rollback --yes $before" | tail -n 1
case $VM_LOADER in
systemd-boot) check "grep -c '^linux ' $entries/yos-head.conf" 1 ;;
limine) check "$section | sed -n '2,3p' | grep -c '^    protocol: linux\$'" 1 ;;
esac
"$vm" reboot
settled
check "$stub_image" none
check "grep -c '^uki = true' /etc/yos/machine.toml || true" 0
check "/usr/local/bin/yos plan" "nothing to do. this machine matches its config."
# the generation with the image is still in the menu, so its image stays.
check "ls $VM_ESP/yos/boot | grep -c -- '-yos.efi\$'" 1
echo "uki ok"
