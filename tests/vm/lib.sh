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
    limine) "$vm" ssh "cat /var/lib/yoq/trial 2>/dev/null; ls /sys/firmware/efi/efivars | grep ^LoaderEntry | tr '\\n' ' '" ;;
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
    esac
}

# how many generations the boot menu lists.
menu_generations() {
    f=$(menu_file)
    case $VM_LOADER in
    grub) check "grep -c -e '--id head' -e '--id gen-' $f" "$1" ;;
    limine) check "grep -c '^/yoq [0-9]' $f" "$1" ;;
    refind) check "grep -c '^menuentry \"yoq [0-9]' $f" "$1" ;;
    esac
}

# makes the next boot run generation $1 from the menu, as if picked by
# hand. refind has no one-shot boot, so its default moves there until
# boot_done moves it back.
boot_once() {
    case $VM_LOADER in
    grub) "$vm" ssh "grub-editenv $VM_ESP/yoq/grubenv set yoq_next=gen-$1" ;;
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
# that doesn't answer, or answers from another root, is waited out.
wait_root() {
    for _ in $(seq 60); do
        root=$(timeout 20 "$vm" ssh "findmnt -no FSROOT /" 2>/dev/null || true)
        [ "$root" = "$1" ] && return 0
        sleep 10
    done
}

# the number of the generation before the newest.
second_newest() {
    "$vm" ssh "ls /var/lib/yoq/generations | sort -n | tail -n 2 | head -n 1 | cut -d. -f1"
}
