#!/usr/bin/env bash
# Build a minimal bootable Ubuntu image with debootstrap.
#
#   sudo ./build.sh SUITE OUTDIR        SUITE is jammy (22.04) or noble (24.04)
#
# Produces in OUTDIR:
#   rootfs/       the root file system as a directory (kept for inspection and for report.sh)
#   rootfs.ext4   the same as an ext4 image, written with mke2fs -d (no loop device, no mount)
#   vmlinuz       the kernel, copied out of the image
#   initrd.img    its initramfs
# Needs: debootstrap, e2fsprogs. Environment: MIRROR (default http://archive.ubuntu.com/ubuntu).
set -euo pipefail

suite="${1:?usage: sudo ./build.sh SUITE OUTDIR}"
out="${2:?usage: sudo ./build.sh SUITE OUTDIR}"
mirror="${MIRROR:-http://archive.ubuntu.com/ubuntu}"
here="$(cd "$(dirname "$0")" && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "build.sh needs root (debootstrap does)." >&2; exit 2; }

mkdir -p "$out"
out="$(cd "$out" && pwd)"
root="$out/rootfs"
rm -rf "$root" "$out/rootfs.ext4" "$out/vmlinuz" "$out/initrd.img"

echo "== debootstrap $suite (minbase) into $root"
# minbase is apt, dpkg, coreutils and not much else. On top of it, only what a boot needs:
#   systemd-sysv      /sbin/init
#   linux-image-virtual   a kernel with the virtio drivers, plus its modules
#   initramfs-tools   dependency of the kernel package: loads ext4 and virtio_blk before / is mounted
debootstrap --variant=minbase --arch=amd64 --components=main \
  --include=systemd-sysv,linux-image-virtual,initramfs-tools \
  "$suite" "$root" "$mirror"

# That is the release-day system. Bring it up to date from the -updates and -security pockets, so the
# kernel and libraries are the current ones. (debootstrap's --extra-suites would do it in one step, but
# it fails here with "dpkg: error: --install needs at least one package archive file", so apt does it.)
echo "== upgrade from $suite-updates and $suite-security"
cat > "$root/etc/apt/sources.list" <<APT
deb $mirror $suite main
deb $mirror $suite-updates main
deb $mirror $suite-security main
APT
unmount_all() {
  for m in dev/pts dev proc sys; do umount "$root/$m" 2>/dev/null || true; done
}
trap unmount_all EXIT
mount -t proc proc "$root/proc"
mount -t sysfs sys "$root/sys"
mount --bind /dev "$root/dev"
mount --bind /dev/pts "$root/dev/pts"
# Keep apt from trying to start services inside the chroot.
printf '#!/bin/sh\nexit 101\n' > "$root/usr/sbin/policy-rc.d"
chmod 755 "$root/usr/sbin/policy-rc.d"
# No Recommends: they would pull grub, iso-codes and python into a system that has no use for them.
mkdir -p "$root/etc/apt/apt.conf.d"
printf 'APT::Install-Recommends "false";\nAPT::Install-Suggests "false";\n' > "$root/etc/apt/apt.conf.d/01-minimal"
apt_in_root() { chroot "$root" env DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get -y -q "$@"; }
apt_in_root update
apt_in_root dist-upgrade
# The upgrade installs the new kernel next to the release-day one. Keep only the newest.
mapfile -t kernels < <(find "$root/boot" -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' | sed 's/^vmlinuz-//' | sort -V)
if [ "${#kernels[@]}" -gt 1 ]; then
  old=()
  for v in "${kernels[@]::${#kernels[@]}-1}"; do
    old+=("linux-image-$v" "linux-modules-$v")
  done
  echo "removing old kernels: ${old[*]}"
  apt_in_root purge "${old[@]}"
fi
apt_in_root autoremove --purge
apt_in_root clean
rm -f "$root/usr/sbin/policy-rc.d"
unmount_all
trap - EXIT

echo "== configure"
cp -a "$here/overlay/." "$root/"
echo minimal > "$root/etc/hostname"
mkdir -p "$root/etc/systemd/system/multi-user.target.wants"
ln -sf ../boot-ok.service "$root/etc/systemd/system/multi-user.target.wants/boot-ok.service"
# An empty machine-id makes systemd generate one on the first boot instead of every image sharing it.
: > "$root/etc/machine-id"

echo "== trim"
# Keep the copyright files (the licences travel with the binaries); drop the rest of the documentation.
find "$root/usr/share/doc" -type f ! -name copyright -delete 2>/dev/null || true
find "$root/usr/share/doc" -type d -empty -delete 2>/dev/null || true
rm -rf "$root"/usr/share/man/* "$root"/usr/share/info/* "$root"/usr/share/lintian "$root"/usr/share/locale/*
# The kernel swap above leaves vmlinuz.old and initrd.img.old behind; there is no older kernel to point at.
rm -f "$root/boot/vmlinuz.old" "$root/boot/initrd.img.old"
rm -rf "$root"/var/cache/apt/* "$root"/var/lib/apt/lists/* "$root"/var/log/*.log "$root"/var/log/apt/*
# Stop later installs from bringing the documentation back.
mkdir -p "$root/etc/dpkg/dpkg.cfg.d"
cat > "$root/etc/dpkg/dpkg.cfg.d/01_nodoc" <<'DPKG'
path-exclude /usr/share/doc/*
path-include /usr/share/doc/*/copyright
path-exclude /usr/share/man/*
path-exclude /usr/share/info/*
path-exclude /usr/share/locale/*
DPKG

echo "== kernel and initramfs"
vmlinuz="$(find "$root/boot" -maxdepth 1 -name 'vmlinuz-*' | sort -V | tail -n 1)"
initrd="$(find "$root/boot" -maxdepth 1 -name 'initrd.img-*' | sort -V | tail -n 1)"
if [ -z "$vmlinuz" ] || [ -z "$initrd" ]; then
  echo "no kernel or initramfs in $root/boot" >&2
  exit 1
fi
install -m 0644 "$vmlinuz" "$out/vmlinuz"
install -m 0644 "$initrd" "$out/initrd.img"
echo "kernel: $(basename "$vmlinuz")"

echo "== ext4 image"
used_mb="$(du -sm "$root" | cut -f1)"
size_mb=$((used_mb + used_mb / 10 + 64))
rm -f "$out/rootfs.ext4"
mke2fs -q -t ext4 -L rootfs -d "$root" -F "$out/rootfs.ext4" "${size_mb}M"
echo "rootfs directory: ${used_mb} MB, image: ${size_mb} MB"
echo "== done"
