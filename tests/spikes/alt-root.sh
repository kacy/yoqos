#!/bin/sh
# spike: install a desktop's worth of packages into an empty root with os,
# the way a staged generation would be built, and list the install scripts
# and hooks that complained. prints what happened; it doesn't fail.
set -u
os=$1
root=/tmp/alt-root
dir=$(mktemp -d)
cfg=$dir/machine.toml
mkdir -p "$root/var/lib/pacman/local" "$root/etc/pacman.d"
echo 9 > "$root/var/lib/pacman/local/ALPM_DB_VERSION"
cp /etc/pacman.conf "$root/etc/pacman.conf"
cp /etc/pacman.d/mirrorlist "$root/etc/pacman.d/mirrorlist"

cat > "$cfg" <<'TOML'
version = 1
packages = [
  "base", "linux", "linux-firmware", "mkinitcpio", "grub", "efibootmgr",
  "btrfs-progs", "networkmanager", "openssh", "sudo", "vim",
  "hyprland", "xdg-desktop-portal-hyprland", "pipewire", "pipewire-pulse",
  "wireplumber", "ghostty", "firefox", "docker", "cups", "bluez",
]
TOML

# answer provider questions with the suggested option until the lock
# resolves.
for _ in 1 2 3 4 5; do
    if "$os" --root "$root" --config "$cfg" update --no-apply 2> "$dir/err"; then break; fi
    cat "$dir/err"
    answers=$(sed -n 's/.*like \(.*\) = "\(.*\)".*/"\1" = "\2"/p' "$dir/err")
    [ -n "$answers" ] || break
    grep -q '^\[providers\]' "$cfg" || printf '\n[providers]\n' >> "$cfg"
    printf '%s\n' "$answers" >> "$cfg"
done


# one root as a plain chroot, one with the api filesystems pacstrap mounts.
install_into() {
    target=$1
    mkdir -p "$target/var/lib/pacman/local" "$target/etc/pacman.d"
    echo 9 > "$target/var/lib/pacman/local/ALPM_DB_VERSION"
    cp /etc/pacman.conf "$target/etc/pacman.conf"
    cp /etc/pacman.d/mirrorlist "$target/etc/pacman.d/mirrorlist"
    echo "--- apply into $target"
    start=$(date +%s)
    "$os" --root "$target" --config "$cfg" apply --yes > "$dir/apply.out" 2>&1
    echo "exit $?, $(($(date +%s) - start))s"
    grep -E "^applied|^error" "$dir/apply.out"
    echo "--- scriptlet and hook trouble"
    grep -iE "\[ALPM\] (warning|error)|not mounted|cannot|failed|error|skipped" "$target/var/log/pacman.log" \
        | sed 's/^\[[^]]*\] //' | sort | uniq -c | sort -rn | head -30
    echo "--- outcomes"
    ls -la "$target/boot" 2>&1 | grep -E "initramfs|vmlinuz" || echo "no kernel or initramfs in /boot"
    grep -c "Image generation successful" "$target/var/log/pacman.log" | sed 's/^/initramfs images built: /'
    ls "$target/usr/lib/locale" 2>&1 | head -3
    [ -s "$target/etc/machine-id" ] && echo "machine-id set" || echo "no machine-id"
    du -sh "$target"
}

install_into /tmp/alt-root

bound=/tmp/alt-root-bound
mkdir -p "$bound"
for fs in proc sys dev run; do
    mkdir -p "$bound/$fs"
    mount --rbind "/$fs" "$bound/$fs" || echo "can't mount /$fs"
done
install_into "$bound"
