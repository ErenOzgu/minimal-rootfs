#!/usr/bin/env bash
# Size and boot report for an image built by build.sh and booted by boot-test.sh.
#
#   ./report.sh OUTDIR                      markdown on stdout, OUTDIR/report.json on disk
#   ./report.sh OUTDIR budget.txt           also fail (exit 1) if a number is over its budget
#
# budget.txt has one "SUITE METRIC MAX" per line, for example "noble rootfs_mb 300".
# Metrics: rootfs_mb, modules_mb, userland_mb, image_mb, initrd_mb, vmlinuz_mb, tar_gz_mb, packages.
set -euo pipefail

out="${1:?usage: ./report.sh OUTDIR [budget.txt]}"
budget="${2:-}"
root="$out/rootfs"
log="$out/boot-report.log"

mb() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1048576 }'; }
dir_bytes() { du -sb --apparent-size "$1" | cut -f1; }
file_bytes() { stat -c %s "$1"; }

osr() { sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$root/etc/os-release"; }
suite="$(osr VERSION_CODENAME)"
pretty="$(osr PRETTY_NAME)"

total="$(dir_bytes "$root")"
modules="$(dir_bytes "$root/usr/lib/modules")"
bootdir="$(dir_bytes "$root/boot")"
packages="$(dpkg-query --admindir="$root/var/lib/dpkg" -W -f='${Package}\n' | wc -l)"
tar_gz="$(tar -C "$root" -cf - . | gzip -6 | wc -c)"

metrics_rootfs_mb="$(mb "$total")"
metrics_modules_mb="$(mb "$modules")"
metrics_userland_mb="$(mb $((total - modules - bootdir)))"
metrics_image_mb="$(mb "$(file_bytes "$out/rootfs.ext4")")"
metrics_initrd_mb="$(mb "$(file_bytes "$out/initrd.img")")"
metrics_vmlinuz_mb="$(mb "$(file_bytes "$out/vmlinuz")")"
metrics_tar_gz_mb="$(mb "$tar_gz")"

boot_value() { sed -n "s/.*BOOT-REPORT $1=\(.*\)\r\{0,1\}$/\1/p" "$log" 2>/dev/null | tail -n 1 | tr -d '\r'; }
kernel_version="$(boot_value kernel)"
startup="$(sed -n 's/.*BOOT-REPORT Startup finished in //p' "$log" 2>/dev/null | tail -n 1 | tr -d '\r')"
qemu_mode="$(cat "$out/boot-mode" 2>/dev/null || echo unknown)"
processes="$(boot_value processes)"
mem_used="$(boot_value mem_used_mb)"
state="$(boot_value state)"

{
  echo "### $pretty ($suite): minimal image"
  echo
  echo "| What | Size |"
  echo "|---|---:|"
  echo "| Root file system (apparent size) | ${metrics_rootfs_mb} MB |"
  echo "| of which kernel modules | ${metrics_modules_mb} MB |"
  echo "| of which everything else (userland) | ${metrics_userland_mb} MB |"
  echo "| Root file system as tar.gz | ${metrics_tar_gz_mb} MB |"
  echo "| ext4 image | ${metrics_image_mb} MB |"
  echo "| Kernel (vmlinuz) | ${metrics_vmlinuz_mb} MB |"
  echo "| Initramfs | ${metrics_initrd_mb} MB |"
  echo "| Installed packages | ${packages} |"
  echo
  echo "Biggest packages:"
  echo
  echo '```'
  dpkg-query --admindir="$root/var/lib/dpkg" -W -f='${Installed-Size}\t${Package}\n' | sort -rn | head -n 8 \
    | awk -F'\t' '{ printf "%7.1f MB  %s\n", $1 / 1024, $2 }'
  echo '```'
  if [ -n "$state" ]; then
    echo
    echo "Boot: kernel ${kernel_version}, systemd state \`${state}\`, ${processes} processes, ${mem_used} MB used."
    echo "systemd: ${startup}"
    echo "QEMU ran with ${qemu_mode}; software emulation is several times slower than KVM, so compare timings only within one mode."
  fi
} | tee "$out/report.md"

cat > "$out/report.json" <<JSON
{"suite":"$suite","rootfs_mb":$metrics_rootfs_mb,"modules_mb":$metrics_modules_mb,"userland_mb":$metrics_userland_mb,
 "tar_gz_mb":$metrics_tar_gz_mb,"image_mb":$metrics_image_mb,"vmlinuz_mb":$metrics_vmlinuz_mb,"initrd_mb":$metrics_initrd_mb,
 "packages":$packages,"kernel":"$kernel_version","systemd_state":"${state}"}
JSON

if [ -n "$budget" ]; then
  over=0
  lines=""
  while read -r b_suite b_metric b_max; do
    [ -z "${b_suite:-}" ] && continue
    case "$b_suite" in \#*) continue ;; esac
    [ "$b_suite" = "$suite" ] || continue
    var="metrics_$b_metric"
    if [ "$b_metric" = packages ]; then
      actual="$packages"
    else
      actual="${!var}"
    fi
    if awk -v a="$actual" -v m="$b_max" 'BEGIN { exit !(a <= m) }'; then
      lines+="  ok    $b_metric = $actual (max $b_max)"$'\n'
    else
      lines+="  OVER  $b_metric = $actual (max $b_max)"$'\n'
      over=1
    fi
  done < "$budget"
  {
    echo
    echo "Budget ($budget):"
    echo
    echo '```'
    printf '%s' "$lines"
    echo '```'
  } | tee -a "$out/report.md"
  [ "$over" -eq 0 ] || exit 1
fi
