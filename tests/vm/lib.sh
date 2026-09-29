# helpers the vm tests share. failures are named after the script that
# sources this. a failing command in a pipe fails the test.
set -o pipefail
vm=tests/vm/vm.sh
name=$(basename "$0" .sh)

# runs a command in the vm and compares what it prints.
check() {
    rc=0
    got=$("$vm" ssh "$1") || rc=$?
    if [ "$got" != "$2" ]; then
        echo "$name: $1 gave '$got' (exit $rc), not '$2'"
        exit 1
    fi
    echo "ok: $1 -> $got"
}

# check, with the btrfs top level mounted at /run/yoq-top for the command.
check_top() {
    check "mkdir -p /run/yoq-top && mount -o subvolid=5 \$(findmnt -no SOURCE / | sed 's/\\[.*//') /run/yoq-top && { $1; }; umount /run/yoq-top" "$2"
}

# yoq-health runs once per boot, after the rest; wait until it has run
# this boot, but not forever.
settled() {
    "$vm" ssh "for i in \$(seq 150); do [ \"\$(systemctl show -p ExecMainExitTimestampMonotonic --value yoq-health)\" != 0 ] && exit 0; sleep 2; done; echo 'no yoq-health run after 5 minutes'; exit 1"
}

# what the bootloader will boot next, on one line.
show_env() {
    case $VM_LOADER in
    grub) "$vm" ssh "grub-editenv $VM_ESP/yoq/grubenv list | grep ^yoq_ | sort | tr '\\n' ' '" ;;
    limine | systemd-boot) "$vm" ssh "cat /var/lib/yoq/trial 2>/dev/null; ls /sys/firmware/efi/efivars | grep ^LoaderEntry | tr '\\n' ' '" ;;
    refind) "$vm" ssh "cat /var/lib/yoq/trial 2>/dev/null; efibootmgr | head -n 3 | tr '\\n' ' '" ;;
    *) ;;
    esac
}

# "yes" while a generation is on trial, or "no".
on_trial() {
    case $VM_LOADER in
    grub) check "grub-editenv $VM_ESP/yoq/grubenv list | grep -q -e ^yoq_trial -e ^yoq_default && echo yes || echo no" "$1" ;;
    *) check "test -e /var/lib/yoq/trial && echo yes || echo no" "$1" ;;
    esac
}

# the loader's config with os's entries.
menu_file() {
    case $VM_LOADER in
    grub) echo "$VM_ESP/grub/grub.cfg" ;;
    limine) "$vm" ssh "ls $VM_ESP/EFI/*/limine.conf $VM_ESP/limine.conf 2>/dev/null | head -n 1" ;;
    refind) "$vm" ssh "ls $VM_ESP/EFI/*/yoq.conf | head -n 1" ;;
    systemd-boot) echo "$VM_ESP/loader/entries" ;;
    esac
}

# how many generations the boot menu lists.
menu_generations() {
    f=$(menu_file)
    case $VM_LOADER in
    grub) check "grep -c -e '--id head' -e '--id gen-' $f" "$1" ;;
    limine) check "grep -c '^/yoq [0-9]' $f" "$1" ;;
    refind) check "grep -c '^menuentry \"yoq [0-9]' $f" "$1" ;;
    systemd-boot) check "ls $f | grep -c -e '^yoq-head.conf' -e '^yoq-gen-'" "$1" ;;
    esac
}

# takes os's entries out of the boot menu, the way another tool that
# rewrites the bootloader's config would.
drop_menu() {
    f=$(menu_file)
    case $VM_LOADER in
    grub) "$vm" ssh "echo '# someone else' > $f" ;;
    limine) "$vm" ssh "sed -i '/^# yoq: generations/,/^# yoq: end/d' $f" ;;
    refind) "$vm" ssh "sed -i '/^include yoq.conf/d' \$(dirname $f)/refind.conf" ;;
    systemd-boot) "$vm" ssh "rm $f/yoq-head.conf" ;;
    esac
}

# makes the next boot run generation $1 from the menu, as if picked by
# hand. refind has no one-shot boot, so its default moves there until
# boot_done moves it back.
boot_once() {
    case $VM_LOADER in
    grub) "$vm" ssh "grub-editenv $VM_ESP/yoq/grubenv set yoq_next=gen-$1" ;;
    systemd-boot) "$vm" ssh "bootctl set-oneshot yoq-gen-$1.conf" ;;
    limine) "$vm" ssh "bootctl set-oneshot \"\$(grep '^/yoq $1 ' $(menu_file) | cut -c2- | sed 's/[^A-Za-z0-9+_.@-]/-/g')\"" ;;
    refind)
        f=$(menu_file)
        "$vm" ssh "cp $f /root/yoq.conf.saved && sed -i \"s|^default_selection .*|default_selection \\\"\$(grep -o '^menuentry \"yoq $1 [^\"]*' $f | cut -c12-)\\\"|\" $f && grep ^default_selection $f"
        ;;
    esac
}

# after boot_once, the next boot is the newest generation again.
boot_done() {
    [ "$VM_LOADER" = refind ] || return 0
    "$vm" ssh "cp /root/yoq.conf.saved $(menu_file)"
}

# waits up to 10 minutes for the vm to come up running the root $1. a boot
# that doesn't answer, or answers from another root, is waited out. if it
# never comes, this shows what the machine is doing and fails.
wait_root() {
    for _ in $(seq 60); do
        root=$(timeout 20 "$vm" ssh "findmnt -no FSROOT /" 2>/dev/null || true)
        [ "$root" = "$1" ] && return 0
        sleep 10
    done
    echo "$name: no boot into $1 after 10 minutes; the machine shows:"
    "$vm" ssh "findmnt -no FSROOT /; cat /proc/cmdline; systemctl is-active yoq-watchdog.timer multi-user.target; journalctl -b -u yoq-health -u yoq-watchdog.timer -u yoq-watchdog.service --no-pager -o cat | tail -n 10" || true
    exit 1
}

# after a trial that shouldn't come up: the next boot runs generation $1
# from its copy, and os took it on as the newest generation.
falls_back() {
    "$vm" reboot || true
    wait_root "/@roots/boot-$1"
    settled
    check "/usr/local/bin/os history | tail -n 1 | grep -c 'fell back from'" 1
}

# the newest generation's number.
newest() {
    "$vm" ssh "ls /var/lib/yoq/generations | sort -n | tail -n 1 | cut -d. -f1"
}

# makes the next trial boot's initramfs garbage, so its kernel can't
# start and panics, and panic=10 reboots into the generation before. grub
# and refind boot the staged root's own /boot, so that file is broken.
# limine and systemd-boot share boot files on the esp between generations
# with the same content, and breaking one could break the fallback too;
# there, the trial entry points at a garbage file of its own.
break_trial_boot() {
    case $VM_LOADER in
    limine) "$vm" ssh "echo not an initramfs > $VM_ESP/yoq/boot/garbage.img && sed -i '/^\/yoq trial boot/,/cmdline/ s|module_path: boot():[^ ]*initramfs[^ ]*|module_path: boot():/yoq/boot/garbage.img|' $(menu_file) && grep -A5 '^/yoq trial boot' $(menu_file)" ;;
    systemd-boot) "$vm" ssh "echo not an initramfs > $VM_ESP/yoq/boot/garbage.img && sed -i 's|^initrd .*initramfs.*|initrd /yoq/boot/garbage.img|' $VM_ESP/loader/entries/yoq-trial.conf && cat $VM_ESP/loader/entries/yoq-trial.conf" ;;
    *)
        staged=$(newest_root)
        "$vm" ssh "mkdir -p /run/yoq-top && mount -o subvolid=5 \$(findmnt -no SOURCE / | sed 's/\\[.*//') /run/yoq-top && echo not an initramfs > /run/yoq-top/$staged/boot/initramfs-linux.img; umount /run/yoq-top"
        ;;
    esac
}

# the newest generation's root, like @roots/7.
newest_root() {
    n=$(newest)
    "$vm" ssh "sed -n 's/.*\"root\":\"\\([^\"]*\\)\".*/\\1/p' /var/lib/yoq/generations/$n.json"
}

# the number of the generation before the newest.
second_newest() {
    "$vm" ssh "ls /var/lib/yoq/generations | sort -n | tail -n 2 | head -n 1 | cut -d. -f1"
}
