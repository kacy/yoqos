#!/bin/sh
# the vm side of the grub spike. `setup` adds a test entry that boots the
# same kernel with yoq.gen=test on its command line, and an /etc/grub.d
# script that reads a one-shot choice from an env file on the esp.
set -eu
root_uuid=$(findmnt -no UUID /)
# /efi can be an automount, which findmnt lists first, without a uuid.
esp_uuid=$(findmnt -no UUID /efi | grep -m1 .)
# the default entry's command line, so the test entry differs only by its
# marker.
cmdline=$(sed 's/^BOOT_IMAGE=[^ ]* //' /proc/cmdline)
case $1 in
setup)
    cat > /etc/grub.d/41_yoq-test <<EOF2
#!/bin/sh
cat <<'EOF3'
menuentry "yoq test" --id yoq-test {
    search --no-floppy --fs-uuid --set=root $root_uuid
    linux /boot/vmlinuz-linux $cmdline yoq.gen=test
    initrd /boot/initramfs-linux.img
}
EOF3
EOF2
    cat > /etc/grub.d/01_yoq-oneshot <<EOF2
#!/bin/sh
cat <<'EOF3'
insmod fat
insmod search_fs_uuid
search --no-floppy --fs-uuid --set=yoqesp $esp_uuid
echo "yoq: esp is \${yoqesp}"
if [ -f (\${yoqesp})/yoq/grubenv ]; then
  load_env -f (\${yoqesp})/yoq/grubenv yoq_next
  echo "yoq: next is \${yoq_next}"
  if [ "\${yoq_next}" ]; then
    set default="\${yoq_next}"
    set yoq_next=
    save_env -f (\${yoqesp})/yoq/grubenv yoq_next
    set boot_once=true
  fi
fi
EOF3
EOF2
    chmod +x /etc/grub.d/41_yoq-test /etc/grub.d/01_yoq-oneshot
    # grub's own messages on the serial console, which the harness logs.
    printf 'GRUB_TERMINAL_OUTPUT="console serial"\nGRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200"\n' >> /etc/default/grub
    mkdir -p /efi/yoq
    grub-editenv /efi/yoq/grubenv create
    grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tail -2
    pacman -Q grub
    ;;
esac
