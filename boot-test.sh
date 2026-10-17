#!/usr/bin/env bash
# Boot the image built by build.sh in QEMU and check that it gets all the way to multi-user mode.
#
#   ./boot-test.sh OUTDIR [TIMEOUT_SECONDS]
#
# The image runs overlay/usr/local/sbin/boot-ok as its last boot step; it prints a marker on the
# serial console and powers off. This script reads the console log (OUTDIR/serial.log) and checks
# for the marker. Uses KVM when /dev/kvm is usable and falls back to plain emulation.
set -euo pipefail

out="${1:?usage: ./boot-test.sh OUTDIR [TIMEOUT_SECONDS]}"
limit="${2:-900}"
log="$out/serial.log"
: > "$log"

accel=(-machine pc -cpu max)
mode="TCG (software emulation)"
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  accel=(-machine 'pc,accel=kvm' -cpu host)
  mode="KVM"
fi
echo "booting with $mode, timeout ${limit}s"

start=$SECONDS
set +e
timeout "$limit" qemu-system-x86_64 \
  "${accel[@]}" -m 512 -smp 2 \
  -display none -monitor none -serial "file:$log" -no-reboot \
  -kernel "$out/vmlinuz" -initrd "$out/initrd.img" \
  -append "root=/dev/vda rw console=ttyS0 panic=-1 systemd.show_status=1" \
  -drive "file=$out/rootfs.ext4,format=raw,if=virtio" \
  -nic none
status=$?
set -e
elapsed=$((SECONDS - start))

echo "qemu exited with status $status after ${elapsed}s"
echo "---- last lines of the console"
tail -n 25 "$log"
echo "----"

# The journal forwards the line to the console with a timestamp and "boot-ok[pid]:" in front of it.
if ! grep -Eq 'boot-ok\[[0-9]+\]: MINIMAL-ROOTFS-BOOT-OK' "$log"; then
  if [ "$status" -eq 124 ]; then
    echo "FAIL: timed out without reaching the marker"
  else
    echo "FAIL: marker not found"
  fi
  exit 1
fi
if ! grep -q 'BOOT-REPORT state=running' "$log"; then
  echo "FAIL: booted, but systemd does not report 'running'"
  grep 'BOOT-REPORT' "$log" || true
  exit 1
fi
echo "PASS: booted to multi-user mode, systemd state is running ($mode, ${elapsed}s wall clock)"
printf '%s\n' "$elapsed" > "$out/boot-wall-seconds"
printf '%s\n' "$mode" > "$out/boot-mode"
