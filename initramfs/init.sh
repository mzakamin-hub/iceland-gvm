#!/bin/busybox sh
# /init of the gvm test initramfs (busybox). Modes from the kernel command line gvm.test=:
#   v1     print facts, power off                      (no virtio needed: 8250 console only)
#   v1b    + virtio-blk / virtio-console / virtio-rng through the restricted-dma-pool (swiotlb):
#          read the first 4 MiB of /dev/vda, print its sha256 (host compares), write a marker at 8 MiB
#   shell  interactive busybox shell on the console (poweroff -f to end)
/bin/busybox --install -s /bin
mount -t proc proc /proc; mount -t sysfs sysfs /sys; mount -t devtmpfs devtmpfs /dev 2>/dev/null
T=$(sed -n 's/.*gvm\.test=\([a-z0-9]*\).*/\1/p' /proc/cmdline); [ -n "$T" ] || T=shell
say() { echo "GVM: $*"; echo "GVM: $*" > /dev/kmsg; }
say "mode $T kernel $(uname -r) cpus $(grep -c ^processor /proc/cpuinfo) memtotal $(sed -n 's/MemTotal: *//p' /proc/meminfo)"
say "restricted-dma-pool: $(dmesg | grep -i -m1 'restricted\|swiotlb' || echo none)"
say "cpu: $(grep -m1 -i 'CPU part' /proc/cpuinfo) features: $(grep -m1 Features /proc/cpuinfo | cut -c1-80)"
if [ "$T" = v1b ] || [ "$T" = v2s ]; then
	sleep 1
	say "pci: $(ls /sys/bus/pci/devices 2>/dev/null | wc -l) devices; virtio: $(ls /sys/bus/virtio/devices 2>/dev/null | tr '\n' ' ')"
	say "rng: $(cat /sys/class/misc/hw_random/rng_current 2>/dev/null)"
	if [ -b /dev/vda ]; then
		say "vda size $(cat /sys/block/vda/size) sectors"
		say "VDA-SHA256-4M $(dd if=/dev/vda bs=1M count=4 2>/dev/null | sha256sum | cut -d' ' -f1)"
		printf 'GVM-WRITE-OK %s\n' "$(cat /proc/sys/kernel/random/boot_id)" > /tmp/m
		dd if=/tmp/m of=/dev/vda bs=1M seek=8 conv=fsync 2>/dev/null && say "VDA-WRITE $(cat /tmp/m)"
	else
		say "VDA missing"
	fi
	[ -c /dev/hvc0 ] && echo "GVM: HVC0-HELLO" > /dev/hvc0 && say "hvc0 written"
	[ -d /sys/class/net/eth0 ] && say "eth0 present mac-masked"
fi
if [ "$T" = shell ]; then
	say "shell (poweroff -f to end)"
	exec setsid cttyhack sh
fi
say "DONE $T"; sleep 1
poweroff -f
