#!/bin/sh
# aur packages in a vm: a recipe from a local stand-in for the aur,
# reviewed, built in a clean chroot, installed from yos's own repository,
# and pinned in the lock. runs after the smoke test.
set -eu
. tests/vm/lib.sh

"$vm" ssh "pacman -S --noconfirm --needed --noprogressbar devtools >/dev/null"
"$vm" ssh "/usr/local/bin/yos init >/dev/null 2>&1 || true"

# a recipe in a git repository, where YOS_AUR points: version $1, and a
# dependency $2 if given.
recipe() {
    "$vm" ssh "mkdir -p /root/aur/yos-hello.git && cd /root/aur/yos-hello.git && git init -q 2>/dev/null; \
printf 'pkgname=yos-hello\npkgver=%s\npkgrel=1\npkgdesc=\"a package yos builds in tests\"\narch=(any)\nlicense=(MIT)\ndepends=(${2:-})\npackage() { install -Dm644 /dev/null \"\$pkgdir/usr/share/yos-hello/v%s\"; }\n' $1 $1 > PKGBUILD && \
printf 'pkgbase = yos-hello\n\tpkgdesc = a package yos builds in tests\n\tpkgver = %s\n\tpkgrel = 1\n\tarch = any\n\tlicense = MIT\n${2:+\tdepends = $2\n}\npkgname = yos-hello\n' $1 > .SRCINFO && \
git add -A && git -c user.name=t -c user.email=t@localhost commit -q -m v$1"
}
# a split recipe: yos-split and yos-split-extra from one pkgbase.
split_recipe() {
    "$vm" ssh "mkdir -p /root/aur/yos-split.git && cd /root/aur/yos-split.git && git init -q 2>/dev/null; \
printf 'pkgbase=yos-split\npkgname=(yos-split yos-split-extra)\npkgver=1\npkgrel=1\narch=(any)\nlicense=(MIT)\npackage_yos-split() { install -Dm644 /dev/null \"\$pkgdir/usr/share/yos-split/main\"; }\npackage_yos-split-extra() { install -Dm644 /dev/null \"\$pkgdir/usr/share/yos-split/extra\"; }\n' > PKGBUILD && \
printf 'pkgbase = yos-split\n\tpkgver = 1\n\tpkgrel = 1\n\tarch = any\n\tlicense = MIT\n\npkgname = yos-split\n\npkgname = yos-split-extra\n' > .SRCINFO && \
git add -A && git -c user.name=t -c user.email=t@localhost commit -q -m v1"
}
aur_os() {
    "$vm" ssh "YOS_AUR=file:///root/aur /usr/local/bin/yos $1"
}
# runs yos update with no terminal, shows what it said, and leaves its exit
# code in /tmp/rc and its output in /tmp/out.
update_quietly() {
    "$vm" ssh "YOS_AUR=file:///root/aur /usr/local/bin/yos update --yes >/tmp/out 2>&1; echo \$? >/tmp/rc; cat /tmp/out"
}

recipe 1
# a top-level key, so it goes before the config's first table.
"$vm" ssh "sed -i '/^version = /a aur = [\"yos-hello\"]' /etc/yos/machine.toml && grep -n '^aur' /etc/yos/machine.toml"
# without a terminal, a new recipe isn't built unreviewed.
update_quietly
check "cat /tmp/rc" 1
check "grep -c 'review it in a terminal' /tmp/out" 1
check "pacman -Q yos-hello >/dev/null 2>&1 || echo none" none
aur_os "update --yes --trust-aur"
check "pacman -Q yos-hello" "yos-hello 1-1"
check "test -e /usr/share/yos-hello/v1 && echo built" built
# the build user's copy of the recipe goes with the build.
check "test -e /var/cache/yos/aur/build/yos-hello && echo left || echo gone" gone
# the chroot names its servers itself, since arch-nspawn rewrites its
# mirrorlist from the host's.
check "grep -c '^Include' /var/cache/yos/aur/chroot/root/etc/pacman.conf || true" 0
check "grep -A1 '^\[core\]' /var/cache/yos/aur/chroot/root/etc/pacman.conf | grep -c '^Server = '" 1
check "grep -A4 '^\[packages.yos-hello\]' /etc/yos/machine.lock | grep -c '^recipe = '" 1
check "grep -c '^\[yos-aur\]' /etc/pacman.d/yos-repos.conf" 1
# plain pacman reads it too, through the line yos added to pacman.conf.
check "grep -c '^Include = /etc/pacman.d/yos-repos.conf' /etc/pacman.conf" 1
check "pacman -Sy >/dev/null && pacman -Sl yos-aur | cut -d' ' -f2" yos-hello
check "/usr/local/bin/yos plan" "nothing to do. this machine matches its config."

# a changed recipe is reviewed again, then built and upgraded.
recipe 2
update_quietly
check "cat /tmp/rc" 1
check "grep -c 'recipe is changed' /tmp/out" 1
aur_os "update --yes --trust-aur"
check "pacman -Q yos-hello" "yos-hello 2-1"
check "/usr/local/bin/yos plan" "nothing to do. this machine matches its config."

# a need nothing has, and aur doesn't list, stops the update by name,
# before any review.
recipe 3 yos-nowhere
aur_os "update --yes --trust-aur >/tmp/out 2>&1; echo \$? >/tmp/rc; cat /tmp/out"
check "cat /tmp/rc" 1
check "grep -c 'E0130.*yos-hello needs yos-nowhere' /tmp/out" 1
check "grep -c 'recipe is changed' /tmp/out || true" 0
check "pacman -Q yos-hello" "yos-hello 2-1"
recipe 4

# from a split recipe, only the package named after it goes in.
split_recipe
"$vm" ssh "sed -i 's/^aur = .*/aur = [\"yos-hello\", \"yos-split\"]/' /etc/yos/machine.toml"
aur_os "update --yes --trust-aur"
check "pacman -Q yos-split" "yos-split 1-1"
check "test -e /usr/share/yos-split/main && echo built" built
check "pacman -Sy >/dev/null && pacman -Sl yos-aur | cut -d' ' -f2 | sort | tr '\n' ' '" "yos-hello yos-split "
check "/usr/local/bin/yos plan" "nothing to do. this machine matches its config."
echo "aur ok"
