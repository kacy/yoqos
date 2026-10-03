#!/bin/sh
# the vm side of the grub spike. `setup` adds a test entry that boots the
# same kernel with yos.gen=test on its command line, and an /etc/grub.d
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
    cat > /etc/grub.d/41_yos-test <<EOF2
#!/bin/sh
cat <<'EOF3'
menuentry "yos test" --id yos-test {
    search --no-floppy --fs-uuid --set=root $root_uuid
    linux /boot/vmlinuz-linux $cmdline yos.gen=test
    initrd /boot/initramfs-linux.img
}
EOF3
EOF2
    cat > /etc/grub.d/01_yos-oneshot <<EOF2
#!/bin/sh
cat <<'EOF3'
insmod fat
insmod search_fs_uuid
search --no-floppy --fs-uuid --set=yosesp $esp_uuid
echo "yos: esp is \${yosesp}"
if [ -f (\${yosesp})/yos/grubenv ]; then
  load_env -f (\${yosesp})/yos/grubenv yos_next
  echo "yos: next is \${yos_next}"
  if [ "\${yos_next}" ]; then
    set default="\${yos_next}"
    set yos_next=
    save_env -f (\${yosesp})/yos/grubenv yos_next
    set boot_once=true
  fi
fi
EOF3
EOF2
    chmod +x /etc/grub.d/41_yos-test /etc/grub.d/01_yos-oneshot
    # grub's own messages on the serial console, which the harness logs.
    printf 'GRUB_TERMINAL_OUTPUT="console serial"\nGRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200"\n' >> /etc/default/grub
    mkdir -p /efi/yos
    grub-editenv /efi/yos/grubenv create
    grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tail -2
    pacman -Q grub
    ;;
esac
