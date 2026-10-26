#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# gvm.sh - general-purpose virtual machines on the OnePlus Pad 4 (Gunyah, protected VMs, crosvm). gvm agent, 23 Oct 2026; 0.3 (vmapp agent): module install keeps /lib, root=PARTUUID,
# clean stop through the guest agent on hvc0, reset-disk from a pristine copy.
#
#   sudo ./gvm.sh check            guards only (kernel, checksums, power, memory, no other crosvm)
#   sudo ./gvm.sh load             modprobe the kernel's Gunyah modules (kernel-iceland q90m+; skipped if /dev/gunyah exists)
#   sudo ./gvm.sh v1               V1: guest kernel + busybox initramfs, 8250 serial console only, no virtio -> power off
#   sudo ./gvm.sh v1b              V1b: + virtio-blk / virtio-console / virtio-rng through the swiotlb (restricted DMA pool)
#   sudo ./gvm.sh shell            interactive busybox shell in the VM on this terminal (poweroff -f ends it)
#   sudo ./gvm.sh net-up|net-down  the NAT tap gvmtap0 (NetworkManager "shared" connection gvm-tap, not autoconnected)
#   sudo ./gvm.sh v2               V2: Fedora 44 Cloud on virtio-blk + virtio-net (cloud-init seed, 9p share); checks DHCP,
#                                  DNS, HTTPS, dnf from inside the guest; then stops the VM
#   sudo ./gvm.sh run [--gpu]      start the Fedora VM for use (serial log to the run dir; --gpu: a virtio-gpu 2D window
#                                  on the GNOME / Plasma session of the seat0 user); returns when the VM stops
#   sudo ./gvm.sh run --simplefb   (0.3, V8) no virtio-gpu: crosvm --simplefb, a framebuffer in shared memory below the
#                                  swiotlb (guest simpledrm) shown in a window by crosvm's bridge; window keyboard / touch
#   sudo ./gvm.sh v3               V3: `run --gpu` in the background + guest checks over ssh (DRM connector, desktop)
#   sudo ./gvm.sh run --gpu3d      (0.2, V4) virtio-gpu with virglrenderer: virgl (GL) + msm DRM native context (GL via
#                                  freedreno in the guest); host-visible blobs reach the protected guest through runtime
#                                  GuestAccept (CROSVM_GVM_ACCEPT=1: gvm-accept device + gunyah_guest built into the guest kernel)
#                                  GVM_VENUS=1 adds venus (Vulkan) through virgl_render_server (experimental)
#   sudo GVM_V1B_PASSED=1 ./gvm.sh v4   V4 rows (virgl, the default 3D): accept transport, virgl GL, glmark2,
#                                  V4-5 host-visible blobs (gvm-blobtest) through GuestAccept, release
#   sudo GVM_V1B_PASSED=1 ./gvm.sh v4n  V4N rows: msm DRM native context only (experimental)
#   sudo GVM_V1B_PASSED=1 [GVM_ZINK=1] ./gvm.sh v5   V5 (V5Z with zink) rows: 3D desktop in the window (virgl + venus): guest / host frame statistics,
#                                  KWin window (app id, frame), window close -> clean (no hard VM exit)
#   sudo GVM_V1B_PASSED=1 ./gvm.sh v6   V6 rows: guest display stack probes (modetest, kmscube, weston, Xorg PageFlip off +
#                                  ShadowFB, Xorg default), each judged by the host frame statistics
#   sudo GVM_V1B_PASSED=1 ./gvm.sh v8   V8 rows: the desktop on the simplefb software display (`run --simplefb`): guest
#                                  session, guest / host (GVM-SIMPLEFB-FRAME) frame statistics, window shot, KWin window
#   sudo GVM_V1B_PASSED=1 [GVM_INPUT_MODE=tablet|touchpad|touch] ./gvm.sh vin   VIN rows (0.2-6): the window's
#                                  input modes: a host uinput touch screen -> KWin -> crosvm -> guest evdev
#                                  (gvm-evrec.py), fullscreen / leave fullscreen / output by name
#   sudo GVM_V1B_PASSED=1 [GVM_RUNMODE=--simplefb] ./gvm.sh v9   V9 rows (0.2-7): the display over VNC (crosvm
#                                  --vnc-server on 127.0.0.1), our RFB client gvm-vncprobe.py, guest evdev
#   sudo GVM_V1B_PASSED=1 ./gvm.sh v11  V11 rows: network throughput + CPU both ways, userspace virtio-net vs vhost-net
#   sudo GVM_V1B_PASSED=1 ./gvm.sh pvm  PV rows: the opt-in shared memory mode (boot shim; host CAN read the VM's RAM)
#   sudo GVM_V1B_PASSED=1 ./gvm.sh v10  V10 rows (parity step 3): virgl GL vs venus Vulkan vs zink-over-venus GL vs
#                                  llvmpipe on one VM, GuestAccept cost (GVM-ACCEPT-STATS)
#   sudo GVM_V1B_PASSED=1 ./gvm.sh win  W2-W6 rows: the Windows 11 ARM64 image (GVM_WIN_IMAGE, GVM_WIN_MEM, GVM_WIN_SOAK_MIN)
#   sudo ./gvm.sh stop            clean stop: guest agent poweroff (hvc0), wait 60 s, then crosvm stop, kill last
#   sudo ./gvm.sh make-pristine F.raw.zst   keep a pristine copy of the Fedora disk ($VMDIR/fedora44.pristine.raw)
#   sudo ./gvm.sh reset-disk       fresh $VMDIR/fedora44.raw from the pristine copy (GVM_FRESH=1 v2/v3/v4 do it first)
#   sudo ./gvm.sh unload           no-op until q90o: modules kept loaded (pm-notifier bug, fixed in q90o); GVM_ALLOW_UNLOAD=1 = modprobe -r
#
# Files: the payload next to this script (bundle in /run/gvm or the iceland-gvm rpm); logs / socket / share in /run/gvm; the Fedora disk
# image and its seed in $GVM_VMDIR (default /var/lib/gvm, created with chattr +C). Logs: /run/gvm/log/.
# Never: an unprotected VM (the RM loses a VM id per refusal), a second crosvm, any partition / block device, /etc
# (except the NetworkManager connection of net-up, removed by net-down), /boot, /lib/modules. A reboot clears the
# modules and /run/gvm. crosvm runs with --disable-sandbox as ONE process (threads only): it never forks while it
# holds lent guest memory (SuperTurtleDev's fork hazard); its guest RAM is a shared memfd.
set -u
D=${GVM_PAYLOAD:-$(cd "$(dirname "$0")" && pwd)}   # payload: crosvm, guest/ (the unpacked bundle or /usr/libexec/iceland-gvm)
R=${GVM_RUN:-/run/gvm}                     # logs, control socket, 9p share (tmpfs)
VMDIR=${GVM_VMDIR:-/var/lib/gvm}
L=$R/log
# 0.3-5: the host modules come with the kernel (kernel-iceland q90m+: CONFIG_GUNYAH=m), loaded with modprobe;
# iceland-gvm no longer ships them, so a kernel update no longer breaks VMs. Top-level modules (deps by depmod):
MODS="gunyah_rsc_mgr gunyah_vcpu gunyah_qcom gunyah_irqfd gunyah_ioeventfd gunyah_qtvm"
CROSVM=${GVM_CROSVM:-$D/crosvm}           # GVM_CROSVM / GVM_IMAGE: bisect overrides (e.g. $D/bisect/crosvm-640ac8b)
IMAGE=${GVM_IMAGE:-$D/guest/Image}
INITRD=$D/guest/initramfs-gvm.cpio.gz
SOCK=$R/crosvm.sock
CPUS=${GVM_CPUS:-4}
MEM=${GVM_MEM:-2048}
SWIOTLB=${GVM_SWIOTLB:-128}
# 0.3-36 (optimisation item 1): guest RAM in 2 MiB THP folios for every VM, lent to Gunyah as 2 MiB blocks (Windows
# froze the host with 4 KiB lends: a TrustZone call per page, WINN vs WINH 25 Oct); GVM_HUGEPAGES=0 = 4 KiB lends
export GVM_HUGEPAGES=${GVM_HUGEPAGES:-1}
# v10n: io_uring disks by default (vm-run OPT v10m Du: read 3.3 GB/s, write 1.3 GB/s vs 0.7 / 0.7 with epoll); GVM_BLK_OPTS= (empty) = epoll
export GVM_BLK_OPTS=${GVM_BLK_OPTS-async-executor=uring}
# item 4: GVM_VMM_CPUS=1-7 keeps crosvm's own threads (devices, display, the VMM) off the listed-out CPUs; the
# vCPU threads take GVM_AFFINITY (crosvm --cpu-affinity) on top. Applied to this script, so crosvm inherits it.
[ -n "${GVM_VMM_CPUS:-}" ] && taskset -pc "$GVM_VMM_CPUS" $$ > /dev/null 2>&1
DISK=$VMDIR/fedora44.raw
SEED=$VMDIR/seed-cidata.img
SHARE=$R/share
TAP=gvmtap0
# root of Fedora-Cloud-Base-Generic-44-1.7.aarch64 (GPT p2, btrfs). No initramfs: the kernel cannot resolve UUID=,
# but it resolves PARTUUID= itself (V2 23 Oct: root=UUID panicked, /dev/vda2 and PARTUUID boot).
ROOTDEV=${GVM_ROOT:-PARTUUID=51293621-3df4-4df4-95a5-16321a399417}
PRISTINE=$VMDIR/fedora44.pristine.raw
AGENT_IN=$R/agent.in
MAC=${GVM_MAC:-0a:1c:47:56:4d:01}     # fixed MAC: the guest IP is found by it (V3 23 Oct: a random MAC per boot + a stale lease)
STEP=${1:-}; shift || true

mkdir -p "$L"
say() { echo "$*" | tee -a "$L/gvm.log"; echo "gvm: $*" > /dev/kmsg 2>/dev/null || true; }
row() { say "ROW $1 $2 ${3:-}"; }   # ROW <id> PASS|FAIL|INFO text
die() { say "FAIL $*"; exit 1; }
caller_user() { echo "${SUDO_USER:-$(id -nu "${PKEXEC_UID:-1000}")}"; }

guard() {
	[ "$(id -u)" = 0 ] || die "not root (use sudo)"
	modinfo -n gunyah_rsc_mgr > /dev/null 2>&1 || die "this kernel ($(uname -r)) has no Gunyah modules (CONFIG_GUNYAH): install kernel-iceland q90m or later"
	modinfo -n gunyah_vcpu > /dev/null 2>&1 || die "this kernel ($(uname -r)) lacks gunyah_vcpu (CONFIG_GUNYAH incomplete)"
	if [ -f "$D/SHA256SUMS" ]; then (cd "$D" && sha256sum --quiet -c SHA256SUMS) || die "bundle checksum mismatch"
	else rpm -Vf "$D/gvm.sh" > /dev/null 2>&1 || die "package files changed (rpm -V iceland-gvm)"; fi
	local ps=/sys/class/power_supply s b= on=0 cap st
	for s in "$ps"/*; do
		[ "$(cat "$s/type" 2>/dev/null)" = Battery ] && b=$s
		case "$(cat "$s/type" 2>/dev/null)" in USB|USB_PD|USB_C|Mains|Wireless) [ "$(cat "$s/online" 2>/dev/null)" = 1 ] && on=1 ;; esac
	done
	cap=$(cat "$b/capacity" 2>/dev/null || echo 0); st=$(cat "$b/status" 2>/dev/null || echo unknown)
	case "$st" in Charging|Full) on=1 ;; esac
	[ "$on" = 1 ] || [ "$cap" -ge 30 ] || die "battery ${cap} % and no charger (need >= 30 %)"
	say "guard: kernel $(uname -r), battery ${cap} % ($st, charger $on), MemAvailable $(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo) MiB"
}

crosvm_running() { pgrep -x crosvm > /dev/null; }

need_mem() {   # MiB of guest RAM + swiotlb + 1 GiB left for the host
	local avail; avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
	local sw=$SWIOTLB; [ "${GVM_PVM:-0}" = 1 ] && sw=0
	# v10n: the guest kernel builds its restricted DMA pool slot array in ONE kmalloc (24 B per 2 KiB slot, 4 MiB max):
	# above ~340 MiB the pool fails and the guest has no disk (vm-run OPT S5 = 512: never came up)
	[ "$sw" -le 320 ] || die "swiotlb $sw MiB: at most 320 (the guest kernel cannot allocate a larger restricted DMA pool)"
	[ "$avail" -ge $(( $1 + sw + 1024 )) ] || die "MemAvailable $avail MiB < guest $1 + swiotlb $sw + 1024 MiB"
}

load() {
	if [ -c /dev/gunyah ]; then say "load: /dev/gunyah already present"; return 0; fi
	local before; before=$(dmesg | wc -l)
	modprobe -a $MODS || die "modprobe $MODS failed"
	for _ in 1 2 3 4 5 6 7 8 9 10; do [ -c /dev/gunyah ] && break; sleep 0.3; done
	[ -c /dev/gunyah ] && row L1 PASS "/dev/gunyah present (kernel modules $(modinfo -F vermagic gunyah_rsc_mgr | cut -d' ' -f1))" || die "no /dev/gunyah after modprobe"
	dmesg | grep -m1 -o 'Running under Gunyah hypervisor [^ ]*' | sed 's/^/hyp: /' | tee -a "$L/gvm.log"
	dmesg | tail -n +"$((before + 1))" | grep -E 'BUG|WARNING|Oops|SError' | grep -vE 'gvm: |vm-run: |iceland-combo' && row L2 FAIL "kernel warnings at load" || row L2 PASS "no kernel warnings at load"
	chmod 600 /dev/gunyah
}

unload() {
	# gunyah_rsc_mgr registers a PM notifier and never unregisters it: after modprobe -r the next suspend
	# oopses (q90m / q90n; fixed in q90o). Loading again is idempotent, so never unload until q90o is proven;
	# GVM_ALLOW_UNLOAD=1 overrides once a fixed kernel runs.
	if [ "${GVM_ALLOW_UNLOAD:-0}" != 1 ]; then
		say "unload: Gunyah modules kept loaded (pm-notifier bug, fixed in q90o)"; row U1 INFO "modules kept loaded (pm-notifier bug, fixed in q90o)"; return 0
	fi
	crosvm_running && die "crosvm still running (sudo $0 stop)"
	local m r=""; for m in $MODS; do r="$m $r"; done
	modprobe -r -a $r 2>/dev/null || say "modprobe -r: some modules stay until the reboot"
	[ -c /dev/gunyah ] && say "unload: /dev/gunyah still present" || row U1 PASS "modules unloaded"
}

# common crosvm arguments: protected VM (lent RAM), no firmware, single process, no USB / balloon (lent RAM cannot balloon)
# GVM_HUGEPAGES=1: guest RAM (a shmem memfd) in 2 MiB THP folios, lent to Gunyah as 2 MiB blocks instead of
#   4 KiB pages (fewer stage-2 entries in the hypervisor's page-table pool; suspect of the 23 Oct host hang and
#   of lyc8503's >1 GiB ENOMEM). Needs shmem THP 'advise' (Fedora default 'never'; set by thp_prep, runtime only).
# GVM_AFFINITY=6,7: pin the vCPU threads (crosvm --cpu-affinity), e.g. to cores without device interrupts.
# GVM_PVM=1 (parity step 4, opt-in): the shared memory mode (--protected-vm-pseudo-unprotected): RAM shared at run
#   time and accepted by the boot shim, THE HOST CAN READ THE VM'S MEMORY; no swiotlb bounce pool.
base_args() {
	if [ "${GVM_PVM:-0}" = 1 ]; then
		echo run --disable-sandbox --hypervisor gunyah --protected-vm-pseudo-unprotected --no-usb --no-balloon \
			--cpus "$1" --mem "$2" -s "$SOCK" \
			${GVM_AFFINITY:+--cpu-affinity $GVM_AFFINITY} $([ "${GVM_HUGEPAGES:-0}" = 1 ] && echo --hugepages)
		return 0
	fi
	echo run --disable-sandbox --hypervisor gunyah --protected-vm-without-firmware --no-usb --no-balloon \
		--cpus "$1" --mem "$2" --swiotlb "$SWIOTLB" -s "$SOCK" \
		${GVM_AFFINITY:+--cpu-affinity $GVM_AFFINITY} $([ "${GVM_HUGEPAGES:-0}" = 1 ] && echo --hugepages)
}

thp_prep() {   # before a VM start with GVM_HUGEPAGES=1
	[ "${GVM_HUGEPAGES:-0}" = 1 ] || return 0
	local f=/sys/kernel/mm/transparent_hugepage/shmem_enabled
	grep -qE '\[(never|deny)\]' $f && { echo advise > $f; say "thp: shmem_enabled set to advise (was never; a reboot restores it)"; }
	echo 1 > /proc/sys/vm/compact_memory 2>/dev/null
	say "thp: $(grep -E 'ShmemHugePages|MemAvailable' /proc/meminfo | tr -s ' ' | tr '\n' ' ')"
}

run_crosvm() {   # $1 timeout (s), $2 console log, rest: crosvm args. Returns crosvm's exit code (124 = timeout).
	local t=$1 con=$2; shift 2
	crosvm_running && die "another crosvm is running"
	rm -f "$SOCK"
	say "crosvm $*"
	timeout -s TERM -k 15 "$t" "$CROSVM" --log-level info "$@" > "$L/crosvm-stdout.txt" 2> "$L/crosvm-stderr.txt"
	local rc=$?
	say "crosvm exit $rc"; tail -n 5 "$L/crosvm-stderr.txt" | sed 's/^/  crosvm: /' | tee -a "$L/gvm.log"
	return $rc
}

v1() {   # V1 / V1b / shell
	local mode=$1 args con=$L/console-$1.txt t0 t1
	guard; load; need_mem 512
	: > "$con"
	args="$(base_args 2 512) --initrd $INITRD"
	if [ "$mode" = v1 ]; then
		args="$args --no-rng --serial type=file,path=$con,hardware=serial,num=1,console,earlycon"
		t0=$(date +%s.%N); run_crosvm 120 "$con" $args -p "gvm.test=v1 panic=-1" "$IMAGE"; local rc=$?; t1=$(date +%s.%N)
		grep -q 'GVM: DONE v1' "$con" && row V1-1 PASS "guest booted to /init and powered off ($(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b - a}') s)" \
			|| row V1-1 FAIL "no 'GVM: DONE v1' on the serial console (rc $rc)"
		grep -m1 'GVM: mode' "$con" | sed 's/^/  /' | tee -a "$L/gvm.log"
		[ "$rc" = 0 ] && row V1-2 PASS "crosvm exit 0" || row V1-2 FAIL "crosvm exit $rc"
	elif [ "$mode" = v1b ]; then
		local img=$R/v1b-disk.img hs
		head -c $((4 * 1024 * 1024)) /dev/urandom > "$img"; truncate -s 16M "$img"
		hs=$(head -c $((4 * 1024 * 1024)) "$img" | sha256sum | cut -d' ' -f1)
		args="$args --serial type=file,path=$con,hardware=serial,num=1,console,earlycon"
		args="$args --serial type=file,path=$L/hvc0-v1b.txt,hardware=virtio-console,num=1 --block $img"
		run_crosvm 120 "$con" $args -p "gvm.test=v1b panic=-1" "$IMAGE"; local rc=$?
		grep -q 'GVM: DONE v1b' "$con" && row V1b-1 PASS "guest finished" || row V1b-1 FAIL "no DONE (rc $rc)"
		grep -q "VDA-SHA256-4M $hs" "$con" && row V1b-2 PASS "virtio-blk read through swiotlb: sha256 matches" \
			|| row V1b-2 FAIL "virtio-blk read sha256 mismatch or missing (host $hs)"
		dd if="$img" bs=1M skip=8 count=1 2>/dev/null | grep -aq 'GVM-WRITE-OK' && row V1b-3 PASS "virtio-blk write visible on the host" \
			|| row V1b-3 FAIL "guest write not found in the image"
		grep -q 'HVC0-HELLO' "$L/hvc0-v1b.txt" 2>/dev/null && row V1b-4 PASS "virtio-console" || row V1b-4 FAIL "virtio-console text missing"
		grep -m1 'GVM: rng' "$con" | grep -q virtio && row V1b-5 PASS "virtio-rng" || row V1b-5 INFO "virtio-rng not current"
		grep -E 'host access to lent memory|DENIED|failed to build the vm' "$L/crosvm-stderr.txt" | head -3 | sed 's/^/  /' | tee -a "$L/gvm.log"
		rm -f "$img"
	else
		args="$args --no-rng --serial type=stdout,hardware=serial,num=1,console,earlycon,stdin"
		crosvm_running && die "another crosvm is running"; rm -f "$SOCK"
		"$CROSVM" --log-level warn $args -p "gvm.test=shell panic=-1" "$IMAGE"
	fi
	dmesg | tail -n 50 | grep -E 'BUG|WARNING|Oops|SError|Internal error' | grep -vE 'gvm: |vm-run: |iceland-combo' && row K1 FAIL "host kernel warnings" || row K1 PASS "no host kernel warnings"
}

net_up() {
	nmcli -t -f NAME connection show | grep -qx gvm-tap || \
		nmcli connection add type tun con-name gvm-tap ifname "$TAP" mode tap owner 0 tun.vnet-hdr yes \
			ipv4.method shared ipv4.addresses 10.250.0.1/24 ipv6.method disabled connection.autoconnect no > /dev/null \
		|| die "nmcli add gvm-tap"
	nmcli connection up gvm-tap > /dev/null || die "nmcli up gvm-tap"
	ip -br addr show "$TAP" | tee -a "$L/gvm.log"
	row N0 PASS "tap $TAP up (NAT via NetworkManager shared mode)"
}
net_down() { nmcli connection down gvm-tap > /dev/null 2>&1; nmcli connection delete gvm-tap > /dev/null 2>&1; say "net-down: gvm-tap removed"; }

seed() {   # cloud-init NoCloud seed (vfat CIDATA) + 9p share with the guest kernel modules
	local u h key pw hash m
	u=${SUDO_USER:-$(id -nu "${PKEXEC_UID:-1000}")}
	h=$(getent passwd "$u" | cut -d: -f6)
	mkdir -p "$VMDIR" "$SHARE"; chattr +C "$VMDIR" 2>/dev/null || true
	cp "$D"/guest/modules-*.tar.gz "$SHARE/"
	mkdir -p "$SHARE/extra" "$SHARE/tools"; cp "$D"/guest/extra/*.ko "$SHARE/extra/" 2>/dev/null || true
	cp "${GVM_TOOLS:-$D/guest/tools}"/* "$SHARE/tools/" 2>/dev/null || true
	# desktop flags read by gvm-agent --setup before the display manager (0.3-8): autologin (default on: touch /
	# the host OSK cannot type into a greeter in the VM window), noglamor (Xorg without glamor: GVM_NOGLAMOR=1)
	rm -f "$SHARE/tools/noglamor" "$SHARE/tools/autologin" "$SHARE/tools/zink" "$SHARE/tools/wayland"
	[ "${GVM_ZINK:-0}" = 1 ] && touch "$SHARE/tools/zink"
	[ "${GVM_WAYLAND:-0}" = 1 ] && touch "$SHARE/tools/wayland"
	[ "${GVM_AUTOLOGIN:-1}" = 1 ] && touch "$SHARE/tools/autologin"
	[ "${GVM_NOGLAMOR:-0}" = 1 ] && touch "$SHARE/tools/noglamor"
	if [ -f "$SEED" ]; then say "seed: $SEED exists (kept)"; return 0; fi
	key=$(cat "$h"/.ssh/id_ed25519.pub "$h"/.ssh/id_*.pub 2>/dev/null | head -n1)
	[ -n "$key" ] || { sudo -u "$u" ssh-keygen -q -t ed25519 -N '' -f "$h/.ssh/id_ed25519"; key=$(cat "$h/.ssh/id_ed25519.pub"); }
	pw=$(head -c 12 /dev/urandom | base64 | tr -d '/+=' | cut -c1-12)
	hash=$(openssl passwd -6 "$pw") || die "openssl passwd"
	sudo -u "$u" mkdir -p "$h/.config"; install -m 600 -o "$u" /dev/null "$h/.config/gvm-fedora-password.txt"
	echo "gvm-fedora user gvm password: $pw" > "$h/.config/gvm-fedora-password.txt"
	m=$(mktemp -d)
	cat > "$m/meta-data" <<-EOF
	instance-id: gvm-fedora-3
	local-hostname: gvm-fedora
	EOF
	cat > "$m/user-data" <<-EOF
	#cloud-config
	users:
	  - name: gvm
	    groups: [wheel]
	    sudo: ALL=(ALL) NOPASSWD:ALL
	    lock_passwd: false
	    passwd: $hash
	    ssh_authorized_keys: ["$key"]
	ssh_pwauth: false
	bootcmd:
	  - [sh, -c, 'mkdir -p /mnt/gvmshare; mount -t 9p -o trans=virtio,version=9p2000.L,ro gvmshare /mnt/gvmshare && { if [ -L /lib ]; then tar -C /usr -xzf /mnt/gvmshare/modules-*.tar.gz; else tar -C / -xzf /mnt/gvmshare/modules-*.tar.gz; fi; } && { r=\$(uname -r); mkdir -p /lib/modules/\$r/extra; if grep -q gunyah_guest /lib/modules/\$r/modules.builtin 2>/dev/null; then rm -f /lib/modules/\$r/extra/gunyah_guest.ko; else cp /mnt/gvmshare/extra/*.ko /lib/modules/\$r/extra/ 2>/dev/null; fi; true; } && depmod -a && restorecon -R /lib/modules/\$(uname -r) || true']
	  - [sh, -c, 'if [ -f /mnt/gvmshare/tools/gvm-agent ]; then install -m 755 /mnt/gvmshare/tools/gvm-agent /usr/local/sbin/gvm-agent; install -m 644 /mnt/gvmshare/tools/gvm-agent.service /etc/systemd/system/gvm-agent.service; systemctl mask serial-getty@hvc0.service; systemctl enable gvm-agent.service; fi; true']
	runcmd:
	  - [sh, -c, 'systemctl start --no-block gvm-agent.service || true']
	  - [sh, -c, 'echo "GVM-V2: kernel \$(uname -r) ip \$(ip -4 -o addr show scope global | awk "{print \\\$4}" | head -n1) dns \$(getent hosts fedoraproject.org > /dev/null && echo ok || echo fail) https \$(curl -s -o /dev/null -w "%{http_code}" https://fedoraproject.org) dnf \$(dnf -q makecache > /dev/null 2>&1 && echo ok || echo fail)" > /dev/ttyS0']
	  - [sh, -c, 'echo GVM-V2-DONE > /dev/ttyS0']
	EOF
	truncate -s 4M "$SEED.tmp"; mkfs.vfat -n CIDATA "$SEED.tmp" > /dev/null || die "mkfs.vfat"
	mkdir -p "$m/mnt"; mount -o loop "$SEED.tmp" "$m/mnt" || die "loop mount of the seed"
	cp "$m/meta-data" "$m/user-data" "$m/mnt/"; umount "$m/mnt"; mv "$SEED.tmp" "$SEED"; rm -rf "$m"
	say "seed: $SEED written (user gvm; password in $h/.config/gvm-fedora-password.txt, mode 600)"
}

fedora_args() {   # $1 = console file
	echo "$(base_args "$CPUS" "$MEM") --serial type=file,path=$1,hardware=serial,num=1,console,earlycon" \
		"--block $DISK${GVM_BLK_OPTS:+,$GVM_BLK_OPTS} --block $SEED,ro=true --shared-dir $SHARE:gvmshare:type=p9 --net tap-name=$TAP,mac=$MAC$([ "${GVM_VHOST_NET:-0}" = 1 ] && echo ,vhost-net)" "--serial type=file,path=$L/agent-out.txt,input=$AGENT_IN,hardware=virtio-console,num=1"
}
FPARAMS="console=ttyS0 root=$ROOTDEV rootfstype=btrfs rootflags=subvol=root rw rootwait systemd.firstboot=off"

agent_fifo() {   # the guest agent reads commands from hvc0 = this FIFO; fd 7 keeps a writer so crosvm never sees EOF
	rm -f "$AGENT_IN"; mkfifo -m 600 "$AGENT_IN" || die "mkfifo $AGENT_IN"
	exec 7<>"$AGENT_IN"
}

clean_stop() {   # $1 = crosvm pid (optional). Agent poweroff -> wait 60 s -> crosvm stop -> wait 15 s -> kill
	local pid=${1:-$(pgrep -x crosvm | head -n1)} t=0
	[ -n "$pid" ] || { say "stop: no crosvm running"; return 0; }
	if [ -p "$AGENT_IN" ] && timeout 5 sh -c 'echo poweroff > "$1"' _ "$AGENT_IN"; then
		say "stop: asked the guest agent to power off"
		while [ $t -lt 60 ] && kill -0 "$pid" 2>/dev/null; do sleep 1; t=$((t + 1)); done
	fi
	if kill -0 "$pid" 2>/dev/null; then
		say "stop: guest still running after ${t} s: crosvm stop"
		"$CROSVM" stop "$SOCK" 2>/dev/null; t=0
		while [ $t -lt 15 ] && kill -0 "$pid" 2>/dev/null; do sleep 1; t=$((t + 1)); done
	fi
	kill -0 "$pid" 2>/dev/null && { say "stop: SIGKILL (the disk may need reset-disk)"; kill -9 "$pid"; }
	grep -q 'ok poweroff' "$L/agent-out.txt" 2>/dev/null && row S1 PASS "clean guest poweroff through the agent" || row S1 INFO "no agent poweroff (crosvm stop used)"
}

make_pristine() {   # $1 = fedora44-cloud.raw.zst
	[ -f "${1:-}" ] || die "usage: gvm.sh make-pristine fedora44-cloud.raw.zst"
	mkdir -p "$VMDIR"; chattr +C "$VMDIR" 2>/dev/null || true
	zstd -d --sparse -f "$1" -o "$PRISTINE" || die "zstd"
	chmod 444 "$PRISTINE"; say "pristine copy: $PRISTINE ($(sha256sum "$PRISTINE" | cut -c1-16)...)"
}

reset_disk() {
	crosvm_running && die "crosvm is running"
	[ -f "$PRISTINE" ] || die "no $PRISTINE (gvm.sh make-pristine fedora44-cloud.raw.zst first)"
	cp --reflink=auto --sparse=always "$PRISTINE" "$DISK.new" && chmod 644 "$DISK.new" && mv "$DISK.new" "$DISK" || die "copy"
	rm -f "$SEED"; say "reset-disk: $DISK fresh from the pristine copy, seed removed"
}

grow_disk() {   # the 5 GiB cloud image is too small for a desktop (V3-2: dnf needed 3.4 GB more)
	local want=$(( ${GVM_DISK_GB:-20} * 1024 * 1024 * 1024 )) have
	have=$(stat -c %s "$DISK" 2>/dev/null || echo 0)
	[ "$have" -gt 0 ] && [ "$have" -lt "$want" ] && { truncate -s "$want" "$DISK" && say "disk: grown to ${GVM_DISK_GB:-20} GiB (the guest grows its fs at boot)"; }
	return 0
}

v2() {
	guard; load; need_mem "$MEM"; thp_prep
	[ "${GVM_FRESH:-0}" = 1 ] && reset_disk
	[ -f "$DISK" ] || die "no $DISK (unpack fedora44-cloud.raw.zst there first, see INSTALL.txt)"
	grow_disk
	seed; ip link show "$TAP" > /dev/null 2>&1 || net_up; agent_fifo
	local con=$L/console-v2.txt; : > "$con"
	"$CROSVM" --log-level "${GVM_LOGLEVEL:-info}" $(fedora_args "$con") -p "$FPARAMS" "$IMAGE" > "$L/crosvm-stdout.txt" 2> "$L/crosvm-stderr.txt" &
	local pid=$! t=0
	say "v2: crosvm pid $pid, waiting up to 420 s for cloud-init"
	while [ $t -lt 420 ] && kill -0 $pid 2>/dev/null && ! grep -q GVM-V2-DONE "$con"; do sleep 5; t=$((t + 5)); done
	grep -q 'Reached target.*Multi-User\|login:' "$con" && row V2-1 PASS "Fedora 44 booted on virtio-blk" || row V2-1 FAIL "no multi-user / login prompt"
	local r; r=$(grep -a -m1 'GVM-V2:' "$con")
	say "  $r"
	echo "$r" | grep -q 'ip 10\.250\.0\.' && row V2-2 PASS "DHCP address from the NAT tap" || row V2-2 FAIL "no 10.250.0.x address"
	echo "$r" | grep -q 'dns ok' && row V2-3 PASS "DNS" || row V2-3 FAIL "DNS"
	echo "$r" | grep -qE 'https (200|301|302)' && row V2-4 PASS "HTTPS" || row V2-4 FAIL "HTTPS"
	echo "$r" | grep -q 'dnf ok' && row V2-5 PASS "dnf makecache" || row V2-5 FAIL "dnf makecache"
	grep -a -c 'virtio\|9p' "$con" > /dev/null
	clean_stop $pid
	wait $pid; say "v2: crosvm exit $?"
	dmesg | tail -n 80 | grep -E 'BUG|WARNING|Oops|SError|Internal error' | grep -vE 'gvm: |vm-run: |iceland-combo' && row K1 FAIL "host kernel warnings" || row K1 PASS "no host kernel warnings"
}

guest_ip() { awk -v m="$MAC" 'tolower($2) == m {print $3}' /var/lib/NetworkManager/dnsmasq-$TAP.leases 2>/dev/null | tail -n1; }

wl_uid() {   # uid of the active graphical user session on seat0 (GNOME or Plasma; skips the sddm / gdm greeter)
	local s
	for s in $(loginctl list-sessions --no-legend | awk '{print $1}'); do
		[ "$(loginctl show-session "$s" -p Seat --value 2>/dev/null)" = seat0 ] || continue
		[ "$(loginctl show-session "$s" -p Class --value 2>/dev/null)" = user ] || continue
		[ "$(loginctl show-session "$s" -p Active --value 2>/dev/null)" = yes ] || continue
		loginctl show-session "$s" -p User --value; return 0
	done
	loginctl list-sessions --no-legend | awk '$4 == "seat0" {print $2; exit}'
}

wl_sock() {  # GNOME and kwin_wayland create wayland-0 (kwin takes the next free name if 0 is in use)
	local uid s; uid=$(wl_uid)
	for s in $(ls /run/user/$uid 2>/dev/null | grep -E '^wayland-[0-9]+$' | sort -t- -k2 -n); do
		[ -S "/run/user/$uid/$s" ] && [ "$(stat -c %u "/run/user/$uid/$s")" = "$uid" ] && { echo "/run/user/$uid/$s"; return 0; }
	done
	die "no Wayland socket in /run/user/$uid"
}

gpu3d_args() {   # V4: virglrenderer (virgl + msm native context [+ venus]); blobs via GuestAccept; no fixed blob mapping
	local ct="${GVM_CTX:-virgl:virgl2}" rs=""   # default virgl; GVM_CTX=drm = msm native context (experimental)
	[ "${GVM_VENUS:-0}" = 1 ] && { ct="$ct:venus"; rs="--gpu-render-server path=/usr/libexec/virgl_render_server"; }
	echo "--gpu backend=virglrenderer,context-types=$ct,egl=true,gles=true,surfaceless=true,fixed-blob-mapping=false" 		",pci-bar-size=${GVM_BAR:-0x40000000},displays=[[mode=windowed[${GVM_W:-1600},${GVM_H:-1000}]]]" 		"$rs --wayland-sock $(wl_sock) --display-window-keyboard --display-window-mouse" | sed 's/ ,/,/'
}

gpu_args() {   # virtio-gpu 2D window on the seat0 user's Wayland session (GNOME or Plasma) + window keyboard / mouse as virtio-input
	local sock
	sock=$(wl_sock)
	echo "--gpu backend=2d,displays=[[mode=windowed[${GVM_W:-1600},${GVM_H:-1000}]]] --wayland-sock $sock" \
		"--display-window-keyboard --display-window-mouse"
}

simplefb_args() {   # V8: no virtio-gpu; crosvm's simplefb bridge shows the guest's simpledrm framebuffer in a window on the
	# seat0 user's Wayland session; its keyboard / touch reach the guest as virtio-input (built in, no extra flags)
	echo "--simplefb width=${GVM_W:-1600},height=${GVM_H:-1000} --wayland-sock $(wl_sock)"
}

run_vm() {
	guard; load; need_mem "$MEM"; thp_prep
	[ "${GVM_FRESH:-0}" = 1 ] && reset_disk
	[ -f "$DISK" ] || die "no $DISK"
	grow_disk
	seed; ip link show "$TAP" > /dev/null 2>&1 || net_up; agent_fifo
	local con=$L/console-run.txt g=""
	mv -f "$L/crosvm-stderr.txt" "$L/crosvm-stderr.prev.txt" 2>/dev/null   # one log per run (accept counts, diagnosis)
	export CROSVM_GVM_WINDOW_TITLE="${GVM_TITLE:-gvm: Fedora 44}" CROSVM_GVM_APP_ID=org.iceland.VirtualMachines
	# 0.2-6: the window's input mode and fullscreen / monitor (crosvm gvm_input.rs, display_wl.c)
	[ -n "${GVM_INPUT_MODE:-}" ] && export CROSVM_GVM_INPUT_MODE=$GVM_INPUT_MODE
	[ "${GVM_FULLSCREEN:-0}" = 1 ] && export CROSVM_GVM_FULLSCREEN=1
	[ -n "${GVM_OUTPUT:-}" ] && export CROSVM_GVM_OUTPUT=$GVM_OUTPUT
	[ "${1:-}" = --gpu ] && g=$(gpu_args)
	[ "${1:-}" = --simplefb ] && g=$(simplefb_args)
	if [ "${1:-}" = --gpu3d ]; then
		g=$(gpu3d_args); export CROSVM_GVM_ACCEPT=1
		# vm-run 24 Oct: the virgl scanout was a UBWC bo (modifier 0x0500000000000001), which no readback path can
		# copy (ctx0 black, dmabuf not linear, backing empty) -> the black window. noubwc,notile makes host freedreno
		# allocate it uncompressed / linear; GVM_FD_DEBUG= (empty) keeps UBWC.
		export FD_MESA_DEBUG=${GVM_FD_DEBUG-noubwc,notile}
		# v3 run: ctx0, dmabuf and guest backing always agreed; read through virglrenderer only (no CPU read of
		# GPU dmabufs while auto mode re-probes a black frame every second). GVM_SCANOUT_READ=auto restores it.
		export CROSVM_GVM_SCANOUT_READ=${GVM_SCANOUT_READ:-ctx0}
		[ -n "${GVM_REFRESH_MS:-}" ] && export CROSVM_GVM_REFRESH_MS=$GVM_REFRESH_MS
		say "run: FD_MESA_DEBUG=$FD_MESA_DEBUG CROSVM_GVM_SCANOUT_READ=$CROSVM_GVM_SCANOUT_READ"
	fi
	# 0.2-7: GVM_VNC=1 serves the display over VNC (crosvm --vnc-server) instead of the window
	[ "${GVM_VNC:-0}" = 1 ] && [ -n "$g" ] && g="$g --vnc-server host=${GVM_VNC_HOST:-127.0.0.1},port=${GVM_VNC_PORT:-5900}${GVM_VNC_PWFILE:+,password-file=$GVM_VNC_PWFILE}"
	local fp="$FPARAMS"; [ -n "$g" ] && fp="console=tty0 $FPARAMS"     # last console= stays ttyS0 (/dev/console)
	crosvm_running && die "another crosvm is running"; rm -f "$SOCK"
	while :; do
		local off; off=$(stat -c %s "$con" 2>/dev/null || echo 0)
		"$CROSVM" --log-level "${GVM_LOGLEVEL:-info}" $(fedora_args "$con") $g -p "$fp" "$IMAGE" >> "$L/crosvm-stdout.txt" 2>> "$L/crosvm-stderr.txt"
		local rc=$?; say "run: crosvm exit $rc"
		# 32 = crosvm's reboot code; on Gunyah a guest reboot exits 0 (PSCI SYSTEM_RESET -> SYSTEM_OFF),
		# so look at the guest's last "reboot:" console line (pr_emerg: always printed)
		# crosvm 0.3-19+: "GVM-EXIT type=2|3" = PSCI SYSTEM_RESET (a Windows guest prints no console line)
		if [ $rc = 32 ] || { [ $rc = 0 ] && tail -c +$((off + 1)) "$con" | grep -a 'reboot: ' | tail -n1 | grep -q 'Restarting system'; } 			|| { [ $rc = 0 ] && grep -a 'GVM-EXIT type=' "$L/crosvm-stderr.txt" | tail -n1 | grep -q 'type=[23] '; }; then
			say "run: guest reboot -> start again"
		else
			break
		fi
		rm -f "$SOCK"
	done
}

v3() {
	MEM=${GVM_MEM:-3072}
	( run_vm --gpu ) &
	local t=0 ip=""
	while [ $t -lt 300 ]; do
		ip=$(guest_ip)
		[ -n "$ip" ] && sudo -u "$(caller_user)" ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=3 "gvm@$ip" true 2>/dev/null && break
		sleep 5; t=$((t + 5))
	done
	[ -n "$ip" ] || die "no guest address on $TAP for MAC $MAC"
	if sudo -u "$(caller_user)" ssh -o BatchMode=yes -o ConnectTimeout=5 "gvm@$ip" true 2>/dev/null; then row N1 PASS "ssh gvm@$ip"
	else row N1 FAIL "ssh gvm@$ip failed (key / sshd): the guest checks below cannot run"; fi
	G() { sudo -u "$(caller_user)" ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=4 "gvm@$ip" "$@"; }
	grep -q 'error' "$L/crosvm-stderr.txt" && grep -i 'display\|wayland\|gpu' "$L/crosvm-stderr.txt" | head -5 | sed 's/^/  /'
	G 'cat /sys/class/drm/card*-Virtual-1/status /sys/class/drm/card*-Virtual-1/modes 2>/dev/null | head -3' | tee -a "$L/gvm.log" | grep -q '^connected' \
		&& row V3-1 PASS "guest virtio-gpu connector connected" || row V3-1 FAIL "no connected virtio-gpu connector"
	G 'systemctl is-active graphical.target; loginctl list-sessions --no-legend' | tee -a "$L/gvm.log"
	row V3-2 INFO "desktop: see INSTALL.txt V3 (install a desktop in the guest, then the owner looks at the window)"
}

v4_guest() {   # boot the 3D VM in the background, wait for ssh; sets ip and G()
	MEM=${GVM_MEM:-2048}
	( run_vm "${GVM_RUNMODE:---gpu3d}" ) &      # GVM_RUNMODE=--gpu: the 2D virtio-gpu (V52D)
	local t=0; ip=""
	while [ $t -lt 300 ]; do
		ip=$(guest_ip)
		[ -n "$ip" ] && sudo -u "$(caller_user)" ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=3 "gvm@$ip" true 2>/dev/null && break
		# p6: a boot shim that gave up never brings a guest: stop waiting at once (shared memory mode)
		[ "${GVM_PVM:-0}" = 1 ] && grep -aqE 'GH-SHIM: (gave up|nothing written)' "$L/crosvm-stderr.txt" 2> /dev/null && break
		sleep 5; t=$((t + 5))
	done
	if [ -z "$ip" ] && [ "${GVM_NODIE:-0}" = 1 ]; then   # p6: the caller wants its rows even without a guest
		row N1 FAIL "no guest address on $TAP for MAC $MAC"
		G() { return 1; }
		return 1
	fi
	[ -n "$ip" ] || die "no guest address on $TAP for MAC $MAC"
	if sudo -u "$(caller_user)" ssh -o BatchMode=yes -o ConnectTimeout=5 "gvm@$ip" true 2>/dev/null; then row N1 PASS "ssh gvm@$ip"
	else row N1 FAIL "ssh gvm@$ip failed (key / sshd): the guest checks below cannot run"; fi
	G() { sudo -u "$(caller_user)" ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=4 "gvm@$ip" "$@"; }
	G 'sudo dmesg | grep -E "gunyah_guest|gunyah_accept"' | tee -a "$L/gvm.log" > "$L/v4-guest-accept.txt"
	# 0.3-12: gunyah_guest is built into the guest kernel (no module load); the .ko is only a fallback
	# v3 run: builtin=0 although the client came up without a module -> the built-in is what counts: RM client +
	# accept transport up with NO gunyah_guest module loaded; modules.builtin / the kernel build are info only
	G 'r=$(uname -r); echo "module=$(grep -c "^gunyah_guest " /proc/modules) builtin-list=$(cat /lib/modules/$r/modules.builtin /usr/lib/modules/$r/modules.builtin 2>/dev/null | grep -c gunyah_guest) kernel=$(uname -v | cut -c1-40)"' > "$L/v4-guest-builtin.txt" 2>&1
	if [ "${GVM_RUNMODE:---gpu3d}" != --gpu3d ]; then   # V8 simplefb, V52D / OPT 2D: GuestAccept only with --gpu3d (CROSVM_GVM_ACCEPT unset)
		row V4-1 NOT-RUN "run mode ${GVM_RUNMODE}: no GuestAccept transport (only the 3D mode has it)"
	elif grep -q 'RM client ready' "$L/v4-guest-accept.txt" && grep -q 'accept transport ready' "$L/v4-guest-accept.txt"; then
		if grep -q 'module=0' "$L/v4-guest-builtin.txt"; then row V4-1 PASS "built-in gunyah_guest: RM client + accept transport up, no module loaded ($(cat "$L/v4-guest-builtin.txt"))"
		else row V4-1 FAIL "RM client + accept up, but not from the built-in ($(cat "$L/v4-guest-builtin.txt"))"; fi
	else
		row V4-1 FAIL "guest accept not ready (rm-rpc node or virtio id 60 missing; $(cat "$L/v4-guest-builtin.txt"))"
	fi
	G 'rpm -q mesa-demos egl-utils glmark2 vulkan-tools gcc mesa-libEGL-devel libglvnd-devel vulkan-loader-devel > /dev/null || sudo dnf -y -q install mesa-demos egl-utils glmark2 vulkan-tools gcc mesa-libEGL-devel libglvnd-devel vulkan-loader-devel' > /dev/null 2>&1
	# the display manager holds card0 (DRM master) once a desktop is installed: stop it for the GL rows
	G 'sudo systemctl stop display-manager 2>/dev/null; true'
	G 'ls -l /dev/dri; rpm -q mesa-dri-drivers mesa-libEGL mesa-libgbm' > "$L/v4-guest-gl-env.txt" 2>&1
}

v4_end() {   # $1 = row prefix
	G 'sudo dmesg | grep -iE "virtio_gpu|drm|gunyah" | tail -n 30' > "$L/v4-guest-dmesg.txt" 2>&1
	G 'sudo systemctl start display-manager 2>/dev/null; true'
	clean_stop; wait
	grep -c 'could not take back' "$L/crosvm-stderr.txt" | grep -qx 0 && row "$1-7" PASS "every blob released and reclaimed" || row "$1-7" FAIL "blobs left shared (reboot clears)"
	dmesg | tail -n 80 | grep -E 'BUG|WARNING|Oops|SError|Internal error' | grep -vE 'gvm: |vm-run: |iceland-combo' && row K1 FAIL "host kernel warnings" || row K1 PASS "no host kernel warnings"
}

v4() {   # 3D, default = virgl (V4 A/B 24 Oct: virgl GL on the Adreno 840, glmark2 9253; the native context fails in guest Mesa)
	[ "${GVM_V1B_PASSED:-0}" = 1 ] || die "V4 needs V1b PASS first (GVM_V1B_PASSED=1 once the coordinator has seen it)"
	export GVM_CTX=${GVM_CTX:-virgl:virgl2}
	v4_guest
	G 'EGL_PLATFORM=surfaceless EGL_LOG_LEVEL=debug eglinfo -B 2>&1 | head -n 80' > "$L/v4-eglinfo.txt" 2>&1
	local r; r=$(grep -m1 -iE "profile renderer:" "$L/v4-eglinfo.txt" | sed 's/.*renderer: *//')
	say "  GL: $r"
	echo "$r" | grep -qi virgl && row V4-2 PASS "virgl renderer: $r" || row V4-2 FAIL "no virgl renderer: $r"
	G 'sudo timeout 180 glmark2-es2-drm --off-screen -b build:use-vbo=true -b texture -b shading 2>&1 | tail -n 12' | tee -a "$L/gvm.log" > "$L/v4-glmark2.txt"
	grep -q 'glmark2 Score' "$L/v4-glmark2.txt" && row V4-4 PASS "glmark2: $(grep 'glmark2 Score' "$L/v4-glmark2.txt")" || row V4-4 FAIL "glmark2 did not finish"
	# V4-5: host-visible blobs through runtime GuestAccept. Virgl backs only GL persistent+coherent buffers with
	# host blobs, and only when the host advertises buffer storage (a GLES host like ours does not: V4 24 Oct);
	# venus (GVM_VENUS=1) backs every HOST_VISIBLE Vulkan allocation with a host blob -> gvm-vkblobtest.
	if [ "${GVM_VENUS:-0}" = 1 ]; then
		G 'gcc -O2 -o /tmp/gvm-vkblobtest /mnt/gvmshare/tools/gvm-vkblobtest.c -lvulkan && timeout 180 /tmp/gvm-vkblobtest 8 2>&1 | tail -n 5' > "$L/v4-blobtest.txt" 2>&1
	else
		G 'gcc -O2 -o /tmp/gvm-blobtest /mnt/gvmshare/tools/gvm-blobtest.c -lEGL -lOpenGL && EGL_PLATFORM=surfaceless timeout 120 /tmp/gvm-blobtest 8 2>&1 | tail -n 5' > "$L/v4-blobtest.txt" 2>&1
	fi
	cat "$L/v4-blobtest.txt" >> "$L/gvm.log"
	local na nf; na=$(grep -c 'gvm-accept: Accept.*done' "$L/crosvm-stderr.txt"); nf=$(grep -cE 'gvm-accept: (guest failed|could not take back|share of)' "$L/crosvm-stderr.txt")
	if grep -qE 'BLOBTEST PASS' "$L/v4-blobtest.txt" && [ "$na" -ge 1 ] && [ "$nf" = 0 ]; then
		row V4-5 PASS "host-visible blobs: $(grep -m1 -oE '(VK)?BLOBTEST PASS.*' "$L/v4-blobtest.txt" | cut -c1-90); $na accepts, 0 failures"
	elif grep -q 'no buffer storage' "$L/v4-blobtest.txt" && [ "$nf" = 0 ]; then
		row V4-5 INFO "virgl on this GLES host offers no GL buffer storage, so GL never maps host-visible blobs (accepts $na); test the blobs with GVM_VENUS=1 v4 or v4n"
	else
		row V4-5 FAIL "blobtest: $(grep -m1 -oE '(VK)?BLOBTEST.*' "$L/v4-blobtest.txt" || echo 'no result'); accepts $na, failures $nf"
	fi
	if [ "${GVM_VENUS:-0}" = 1 ]; then
		G 'vulkaninfo --summary 2>/dev/null | grep -m2 -iE "deviceName|driverName"' | tee -a "$L/gvm.log" | grep -qi venus \
			&& row V4-6 PASS "venus Vulkan device" || row V4-6 FAIL "no venus device"
	fi
	v4_end V4
}

v4n() {   # EXPERIMENTAL: msm DRM native context only (guest freedreno through the virtio KMD)
	[ "${GVM_V1B_PASSED:-0}" = 1 ] || die "V4N needs V1b PASS first (GVM_V1B_PASSED=1)"
	export GVM_CTX=${GVM_CTX:-drm}
	v4_guest
	G 'EGL_PLATFORM=surfaceless EGL_LOG_LEVEL=debug LIBGL_DEBUG=verbose FD_MESA_DEBUG=msgs eglinfo -B 2>&1 | grep -v drirc | head -n 80' > "$L/v4n-eglinfo.txt" 2>&1
	local r; r=$(grep -m1 -iE "profile renderer:" "$L/v4n-eglinfo.txt" | sed 's/.*renderer: *//')
	say "  native GL: $r"
	echo "$r" | grep -qiE 'FD8|Adreno|freedreno' && row V4N-2 PASS "msm native context: $r" || row V4N-2 FAIL "not the native context: $r"
	G 'sudo timeout 180 glmark2-es2-drm --off-screen -b build:use-vbo=true -b texture -b shading 2>&1 | tail -n 12' > "$L/v4n-glmark2.txt"
	grep -q 'glmark2 Score' "$L/v4n-glmark2.txt" && row V4N-4 INFO "glmark2: $(grep 'glmark2 Score' "$L/v4n-glmark2.txt")" || row V4N-4 INFO "glmark2 did not finish"
	G 'gcc -O2 -o /tmp/gvm-blobtest /mnt/gvmshare/tools/gvm-blobtest.c -lEGL -lOpenGL && EGL_PLATFORM=surfaceless timeout 120 /tmp/gvm-blobtest 8 2>&1 | tail -n 5' > "$L/v4n-blobtest.txt" 2>&1
	local na nf; na=$(grep -c 'gvm-accept: Accept.*done' "$L/crosvm-stderr.txt"); nf=$(grep -cE 'gvm-accept: (guest failed|could not take back|share of)' "$L/crosvm-stderr.txt")
	grep -q 'BLOBTEST PASS' "$L/v4n-blobtest.txt" && [ "$na" -ge 1 ] && [ "$nf" = 0 ] \
		&& row V4N-5 PASS "native-context blobs: $(grep -m1 -o 'BLOBTEST PASS.*' "$L/v4n-blobtest.txt" | cut -c1-80); $na accepts, 0 failures" \
		|| row V4N-5 FAIL "blobtest: $(grep -m1 -o 'BLOBTEST.*' "$L/v4n-blobtest.txt" || echo 'no result'); accepts $na, failures $nf"
	v4_end V4N
}

kwin_js() {   # $1 = list|close, $2 = caption substring: gvm-kwinprobe.py in the running Plasma session, as its
	# user with plasmashell's environment; KWin answers over D-Bus (its print() never reached the journal, vm-run 24 Oct)
	local P SU; P=$(pgrep -o -x plasmashell) || return 1
	SU=$(ps -o user= -p "$P" | tr -d ' ')
	local -a SENV; mapfile -t SENV < <(tr '\0' '\n' < /proc/"$P"/environ | grep -E '^(WAYLAND_DISPLAY|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|HOME|XDG_CURRENT_DESKTOP)=')
	runuser -u "$SU" -- env "${SENV[@]}" python3 "$D/gvm-kwinprobe.py" "$1" "$2" 2>&1 | tee -a "$L/kwin-probe.txt" | grep -a '^GVMWIN'
}

v5() {   # 3D desktop in the window (0.3-9 / 0.3-10): frame statistics on both sides, KWin window, close -> no hard exit
	[ "${GVM_V1B_PASSED:-0}" = 1 ] || die "V5 needs V1b PASS first (GVM_V1B_PASSED=1)"
	local P=V5; [ "${GVM_ZINK:-0}" = 1 ] && P=V5Z    # GVM_ZINK=1: the guest desktop through zink over venus
	[ "${GVM_WAYLAND:-0}" = 1 ] && P=V5W              # GVM_WAYLAND=1: a Wayland session (labwc) instead of Xorg
	# GVM_IMPORT=1 (V5I): DroidVM's display recipe: zero-copy import of the (now linear) scanout dmabuf into the host
	# compositor instead of the CPU copy (crosvm CROSVM_GVM_SCANOUT_IMPORT=1; 0.3-7 tried it with UBWC bos: black)
	[ "${GVM_IMPORT:-0}" = 1 ] && { P=V5I; export CROSVM_GVM_SCANOUT_IMPORT=1; }
	# GVM_2D=1 (V52D): the same desktop on crosvm's 2D virtio-gpu (no virgl; the boot console always showed through
	# this path) = DroidVM's software-display baseline; GL apps run on llvmpipe in the guest
	[ "${GVM_2D:-0}" = 1 ] && { P=V52D; export GVM_RUNMODE=--gpu GVM_NOGLAMOR=1; }
	# GVM_REFRESH_MS=N (V5R): the glamor desktop with crosvm re-presenting the scanout every N ms (timing hypothesis)
	[ -n "${GVM_REFRESH_MS:-}" ] && P=V5R
	export GVM_CTX=${GVM_CTX:-virgl:virgl2} GVM_VENUS=${GVM_VENUS:-1} GVM_AUTOLOGIN=1
	export GVM_TITLE="gvm: V5 desktop" CROSVM_GVM_DUMP_FRAME=$L/frames CROSVM_GVM_DUMP_EVERY=15 CROSVM_GVM_DUMP_MAX=12
	rm -rf "$L/frames"; mkdir -p "$L/frames"
	v4_guest
	# the guest's agent may predate a flag (zink): refresh it from the share and re-apply the flags before the DM starts
	[ "$P" = V5W ] && G 'rpm -q labwc > /dev/null 2>&1 || sudo dnf -y -q install labwc foot > /dev/null 2>&1; rpm -q labwc' > "$L/v5w-labwc.txt" 2>&1
	G 'sudo install -m 755 /mnt/gvmshare/tools/gvm-agent /usr/local/sbin/gvm-agent && sudo /usr/local/sbin/gvm-agent --setup; true'
	G 'cat /etc/lightdm/lightdm.conf.d/50-iceland-autologin.conf 2>/dev/null; ls /usr/share/wayland-sessions /usr/share/xsessions 2>/dev/null; ls /mnt/gvmshare/tools' > "$L/v5-session-config.txt" 2>&1
	G 'sudo systemctl start display-manager; true'
	if [ "$P" = V5Z ]; then
		sleep 30
		G 'grep -iE "glamor.*(renderer|GL_RENDERER)|zink" /var/log/Xorg.0.log ~/.local/share/xorg/Xorg.0.log 2>/dev/null | tail -n 3' > "$L/v5z-xorg.txt" 2>&1
		grep -qi zink "$L/v5z-xorg.txt" && row V5Z-0 PASS "guest Xorg glamor on zink: $(head -n1 "$L/v5z-xorg.txt" | cut -c1-120)" 			|| row V5Z-0 FAIL "Xorg not on zink: $(head -c 160 "$L/v5z-xorg.txt")"
	fi
	say "  V5: waiting 90 s for the guest desktop"; sleep 90
	if ! G true 2> "$L/v5-ssh.txt"; then   # v4 run: V5W lost the guest ("No route to host") after the session started
		row $P-0 FAIL "guest unreachable after the desktop start: $(head -c 100 "$L/v5-ssh.txt") | console: $(tail -n 400 "$L/console-run.txt" 2>/dev/null | grep -aE 'Kernel panic|Oops|BUG|Out of memory|reboot:|Power down|segfault|labwc' | tail -n 3 | tr '\n' ' ' | cut -c1-200)"
	fi
	G 'loginctl list-sessions --no-legend; loginctl show-session $(loginctl list-sessions --no-legend | awk "\$4==\"seat0\"{print \$1; exit}") -p Type -p Desktop 2>/dev/null' > "$L/v5-sessions.txt" 2>&1
	if [ "$P" = V5W ]; then   # v10f: V5W must really be the Wayland (labwc) session, else FAIL with lightdm's reason
		G 'sudo journalctl -b -u gvm-wayland-session --no-pager 2>/dev/null | tail -n 15; systemctl is-active gvm-wayland-session display-manager 2>/dev/null; sudo cat /var/log/lightdm/lightdm.log 2>/dev/null | grep -iE "session|labwc|wayland|fail|error" | head -n 20' > "$L/v5w-lightdm.txt" 2>&1
		grep -qiE 'Type=wayland' "$L/v5-sessions.txt" && row $P-1 PASS "guest Wayland session: $(grep -E 'Type=|Desktop=' "$L/v5-sessions.txt" | tr '\n' ' ')" \
			|| row $P-1 FAIL "not the Wayland session: $(grep -E 'Type=|Desktop=' "$L/v5-sessions.txt" | tr '\n' ' ') | session unit / lightdm: $(grep -iE "labwc|wayland|fail|error|active" "$L/v5w-lightdm.txt" | tail -n 4 | tr '\n' ';' | cut -c1-220)"
	else
	grep -qiE 'Type=(x11|wayland)' "$L/v5-sessions.txt" && row $P-1 PASS "guest graphical session: $(grep -E 'Type=|Desktop=' "$L/v5-sessions.txt" | tr '\n' ' ')" \
		|| row $P-1 FAIL "no graphical session in the guest (autologin / display manager): $(head -c 200 "$L/v5-sessions.txt")"
	fi
	G 'rpm -q xwd > /dev/null || sudo dnf -y -q install xwd' > /dev/null 2>&1
	if [ "$P" = V5W ]; then echo "GUEST-XWD skipped: Wayland session ($(cat "$L/v5w-labwc.txt" 2>/dev/null))" > "$L/v5-guest-xwd.txt"
	else   # v10n: up to 4 samples 20 s apart (v10b 0.016 / v10m 0.171 were partial desktops: xfdesktop / panel still
		# starting); the best sample counts, all are kept in the detail. A black desktop still fails every sample.
		local k best=-1 bl="" ns
		for k in 1 2 3 4; do
			G 'sudo python3 /mnt/gvmshare/tools/gvm-xwdstat.py :0' > "$L/v5-guest-xwd-$k.txt" 2>&1
			ns=$(grep -oE 'nonzero=[0-9.]+' "$L/v5-guest-xwd-$k.txt" | cut -d= -f2); bl="$bl ${ns:-?}"
			awk -v n="${ns:-0}" -v b="$best" 'BEGIN{exit !(n > b)}' && { best=$ns; cp "$L/v5-guest-xwd-$k.txt" "$L/v5-guest-xwd.txt"; }
			awk -v n="${ns:-0}" 'BEGIN{exit !(n > 0.3)}' && break
			sleep 20
		done
		[ -s "$L/v5-guest-xwd.txt" ] || cp "$L/v5-guest-xwd-1.txt" "$L/v5-guest-xwd.txt"
		echo "samples(nonzero):$bl" >> "$L/v5-guest-xwd.txt"
		G 'pgrep -a xfdesktop; pgrep -a xfce4-panel; pgrep -a xfwm4' > "$L/v5-xfce-procs.txt" 2>&1
	fi
	# v10c: the scanout resource read back from the host by the guest (TRANSFER_FROM_HOST in its own context)
	G 'test -x /tmp/gvm-fbread || gcc -O2 -o /tmp/gvm-fbread /mnt/gvmshare/tools/gvm-fbread.c; sudo /tmp/gvm-fbread' > "$L/v5-fbread.txt" 2>&1
	row $P-8 INFO "scanout read back by the guest: $(grep -m1 -E '^FBREAD' "$L/v5-fbread.txt" | cut -c1-200)"
	say "  $(cat "$L/v5-guest-xwd.txt" | head -c 200)"
	local gnz; gnz=$(grep -oE 'nonzero=[0-9.]+' "$L/v5-guest-xwd.txt" | cut -d= -f2)
	if [ "$P" = V5W ]; then row $P-2 INFO "$(head -c 160 "$L/v5-guest-xwd.txt")"
	else awk -v n="${gnz:-0}" 'BEGIN{exit !(n > 0.3)}' && row $P-2 PASS "the guest desktop is drawn ($(grep -o 'GUEST-XWD.*' "$L/v5-guest-xwd.txt" | head -n1); $(grep -o 'samples.*' "$L/v5-guest-xwd.txt"))" \
		|| row $P-2 FAIL "guest frame black or unreadable: $(head -c 160 "$L/v5-guest-xwd.txt") $(grep -o 'samples.*' "$L/v5-guest-xwd.txt") xfce: $(awk '{print $2}' "$L/v5-xfce-procs.txt" 2>/dev/null | xargs -r basename -a | tr '\n' ' ')"
	fi
	grep -a 'GVM-FRAME\|GVM-SCANOUT\|GVM-SET-SCANOUT\|GVM-FLUSH-OFFSCREEN' "$L/crosvm-stderr.txt" | sed 's/^.*GVM-/GVM-/' > "$L/v5-frames.txt"
	cat "$L/v5-frames.txt" >> "$L/gvm.log"
	# judge the LAST shown frame (the first ones are the boot console); the notes say which resources the guest
	# put on the scanout and which it flushed without showing them
	local last; last=$(grep 'shown=' "$L/v5-frames.txt" | tail -n1)
	local notes; notes=$(grep -E 'SET-SCANOUT|FLUSH-OFFSCREEN' "$L/v5-frames.txt" | cut -c1-90 | tr '\n' ';' | cut -c1-300)
	if echo "$last" | awk '{for (i=1;i<=NF;i++) {if ($i ~ /^mean=/) {split($i,a,"="); m=a[2]} if ($i ~ /^nonzero=/) {split($i,b,"="); z=b[2]}}} END{exit !(m > 0.1 && z > 0.3)}'; then
		row $P-3 PASS "host copy path shows a drawn frame (FD_MESA_DEBUG=${GVM_FD_DEBUG-noubwc,notile}): $(echo "$last" | grep -oE 'shown=.*' | cut -c1-60) | $notes"
	else
		row $P-3 INFO "frame dump black (diagnostic only since v10e; the verdict is the window screenshot $P-4 / $P-9): $(echo "$last" | cut -c1-90) | $(grep 'GVM-FRAME' "$L/v5-frames.txt" | grep -v shown= | tail -n1 | grep -oE 'res=[0-9]+ .*' | cut -c1-200) | $notes"
	fi
	local w; w=$(kwin_js list "V5 desktop")
	if [ -z "$w" ]; then row $P-4 FAIL "no crosvm window in KWin: no screenshot"
	elif command -v iceland-shot > /dev/null; then   # as root, like the Plasma kit (it takes the session from plasmashell)
		if iceland-shot --window "V5 desktop" "$L/v5-window.png" > "$L/v5-shot.txt" 2>&1; then
			local ps; ps=$(python3 "$D/gvm-pngstat.py" "$L/v5-window.png" 2>&1)
			say "  screenshot: $ps"
			awk -v n="$(echo "$ps" | grep -oE 'nonzero=[0-9.]+' | cut -d= -f2)" 'BEGIN{exit !(n > 0.3)}' 				&& row $P-4 PASS "crosvm window screenshot drawn ($ps)" || row $P-4 FAIL "crosvm window screenshot black ($ps)"
			# v10e opacity check: a full-screen magenta X window in the guest; the window content must be pure
			# magenta (~0.6 of the shot incl. border + title); a see-through window mixes in the host wallpaper
			if [ "$P" != V5W ]; then
				G 'sudo python3 /mnt/gvmshare/tools/gvm-solid.py :0 25' > "$L/v5-solid.txt" 2>&1 &
				local sp=$!; sleep 8
				if iceland-shot --window "V5 desktop" "$L/v5-window-solid.png" > "$L/v5-shot2.txt" 2>&1; then
					ps=$(python3 "$D/gvm-pngstat.py" "$L/v5-window-solid.png" 2>&1)
					awk -v n="$(echo "$ps" | grep -oE 'magenta=[0-9.]+' | cut -d= -f2)" 'BEGIN{exit !(n > 0.5)}' \
						&& row $P-9 PASS "window opaque: the guest's magenta screen shows unmixed ($ps)" \
						|| row $P-9 FAIL "window not pure magenta (see-through or not drawn): $ps | guest: $(head -c 100 "$L/v5-solid.txt")"
				else row $P-9 FAIL "iceland-shot: $(tail -n1 "$L/v5-shot2.txt" | cut -c1-140)"; fi
				wait $sp 2>/dev/null
			else
				# v10h: labwc / wlroots diagnosis. The wlroots debug log of the running session, then the session
				# restarted with one wlroots switch each (systemd drop-in in /run, gone at the next boot) and the
				# window judged again: V5W-10 base log, -11 gles2, -12 pixman, -13 no modifiers, -14 legacy KMS
				v5w_wlr() {   # $1 = row, $2 = what
					G 'sudo journalctl -b -u gvm-wayland-check --no-pager -o cat 2>/dev/null | tail -n 3; sudo journalctl -b -u gvm-wayland-session --no-pager -o cat 2>/dev/null | grep -iE "render|allocat|backend|drm|kms|gbm|seat|session|modifier|format|error|fail" | tail -n 40; sudo cat /sys/kernel/debug/dri/0/state 2>/dev/null | grep -E "crtc\\[|plane\\[|fb=|active" | head -n 12' > "$L/$1-wlr.txt" 2>&1
					local s=""; iceland-shot --window "V5 desktop" "$L/$1-window.png" > "$L/$1-shot.txt" 2>&1 && s=$(python3 "$D/gvm-pngstat.py" "$L/$1-window.png" 2>&1)
					local why; why=$(grep -iE "renderer|allocator|error|fail|backend" "$L/$1-wlr.txt" | tail -n 3 | tr '\n' ';' | cut -c1-200)
					if awk -v n="$(echo "$s" | grep -oE 'nonzero=[0-9.]+' | cut -d= -f2)" 'BEGIN{exit !(n > 0.3)}'; then row "$1" PASS "labwc $2: window drawn ($s) | $why"
					else row "$1" FAIL "labwc $2: window black (${s:-no shot}) | $why"; fi
				}
				v5w_wlr $P-10 "as started"
				local kv
				for kv in "11 WLR_RENDERER=gles2" "12 WLR_RENDERER=pixman" "13 WLR_DRM_NO_MODIFIERS=1" "14 WLR_DRM_NO_ATOMIC=1"; do
					G "sudo mkdir -p /run/systemd/system/gvm-wayland-session.service.d && printf '[Service]\nEnvironment=${kv#* }\n' | sudo tee /run/systemd/system/gvm-wayland-session.service.d/50-v5w.conf > /dev/null && sudo systemctl daemon-reload && sudo systemctl restart gvm-wayland-session; sleep 20" > /dev/null 2>&1
					v5w_wlr "$P-${kv%% *}" "${kv#* }"
				done
				G 'sudo rm -rf /run/systemd/system/gvm-wayland-session.service.d; sudo systemctl daemon-reload; true' > /dev/null 2>&1
			fi
		else
			row $P-4 FAIL "iceland-shot: $(tail -n1 "$L/v5-shot.txt" | cut -c1-140)"
		fi
	else
		row $P-4 NOT-RUN "no iceland-shot (the frame dumps in $L/frames are the picture)"
	fi
	if [ -n "$w" ]; then
		echo "$w" | grep -q 'desktopFile=org.iceland.VirtualMachines' && echo "$w" | grep -q 'noBorder=false' \
			&& row $P-5 PASS "KWin window: $(echo "$w" | head -n1 | cut -c1-160)" || row $P-5 FAIL "KWin window: $(echo "$w" | head -n1 | cut -c1-160)"
		kwin_js close "V5 desktop" > /dev/null; sleep 5
		grep -aq 'GVM-WINDOW-CLOSE' "$L/crosvm-stderr.txt" && crosvm_running \
			&& row $P-6 PASS "window close reported, VM still running (no hard exit)" \
			|| row $P-6 FAIL "close: $(grep -ac GVM-WINDOW-CLOSE "$L/crosvm-stderr.txt") reports, crosvm $(crosvm_running && echo running || echo gone)"
	else
		row $P-5 FAIL "no window with V5 desktop in KWin ($(tail -n 2 "$L/kwin-probe.txt" 2>/dev/null | tr '\n' ' ' | cut -c1-160))"; row $P-6 NOT-RUN "needs V5-5"
	fi
	crosvm_running || { row $P-7 NOT-RUN "crosvm gone"; return 0; }
	v4_end V5
}

v6_frame() {   # $1 = row, $2 = crosvm-stderr line where the probe began, $3 = what ran
	# v5: judge only frames OF the resources the probe put on the scanout (v4 judged the newest frame, which after a
	# probe exits is the restored boot console again: modetest looked "black" at the console's 6 %).
	local f=$L/crosvm-stderr.txt best notes newres
	# crosvm's notes are once per resource id for the whole run and the guest reuses ids (v8: glmark2 "no new
	# scanout resource" although it ran): also take the probe's resources from its frames, minus the console (2, 4)
	newres=$( { tail -n +"$2" "$f" | grep -a 'GVM-SET-SCANOUT' | sed -n 's/.*GVM-SET-SCANOUT res=\([0-9]*\).*/\1/p'
		tail -n +"$2" "$f" | grep -a 'GVM-FRAME [0-9]* res=' | sed -n 's/.*GVM-FRAME [0-9]* res=\([0-9]*\) .*/\1/p'; } |
		grep -vx '2' | grep -vx '4' | sort -u | tr '\n' ' ')
	notes=$(tail -n +"$2" "$f" | grep -aE 'GVM-SET-SCANOUT|GVM-FLUSH-OFFSCREEN' | sed 's/^.*GVM-/GVM-/' | cut -c1-60 | tr '\n' ';' | cut -c1-200)
	# frame N: "GVM-FRAME N res=R ..." then "GVM-FRAME N shown=... mean=M nonzero=Z": best (max nonzero) of the probe's resources
	best=$(tail -n +"$2" "$f" | grep -a 'GVM-FRAME' | sed 's/^.*GVM-FRAME /GVM-FRAME /' | awk -v want=" $newres " '
		$3 ~ /^res=/ {split($3, a, "="); res[$2] = a[2]; next}
		$3 ~ /^shown=/ && res[$2] != "" && index(want, " " res[$2] " ") {
			for (i = 4; i <= NF; i++) { if ($i ~ /^mean=/) {split($i, b, "="); m = b[2]} if ($i ~ /^nonzero=/) {split($i, c, "="); z = c[2]} }
			if (z + 0 >= bz + 0) { bz = z; bm = m; bn = $2; br = res[$2] }
		}
		END { if (bn != "") printf "frame %s res=%s mean=%s nonzero=%s", bn, br, bm, bz }')
	if [ -z "$newres" ]; then
		row "$1" FAIL "$3: no new scanout resource (the probe never displayed) | $(tail -n 2 "$L/$1.txt" 2>/dev/null | tr '\n' ' ' | cut -c1-140)"
	elif [ -z "$best" ]; then
		row "$1" FAIL "$3: no host frame of resource(s) $newres | $notes"
	elif echo "$best" | awk '{for (i=1;i<=NF;i++) if ($i ~ /^nonzero=/) {split($i,b,"="); z=b[2]}} END{exit !(z > 0.1)}'; then
		row "$1" PASS "$3: drawn: $best | $notes"
	else
		row "$1" FAIL "$3: black: $best | $notes"
	fi
}

v6_alive() {   # $1 = row: FAIL + stop the probes when the guest no longer answers ssh after a probe
	G true > /dev/null 2>&1 && return 0
	row "$1" FAIL "the guest stopped answering after this probe (froze?): $(tail -n 300 "$L/console-run.txt" 2>/dev/null | grep -aE 'Oops|BUG|panic|Call trace|virtio_gpu|drm' | tail -n 2 | tr '\n' ' ' | cut -c1-160)"
	row V6-X FAIL "V6 stopped after $1: guest unreachable; crosvm's last notes: $(grep -a 'GVM-' "$L/crosvm-stderr.txt" | tail -n 2 | sed 's/^.*GVM-/GVM-/' | cut -c1-100 | tr '\n' ';')"
	return 1
}

v6_pkg() {   # install one guest package, record the result (v3: one missing name made dnf install nothing)
	G "rpm -q $1 > /dev/null 2>&1 || sudo dnf -y -q install $1 > /dev/null 2>&1; rpm -q $1" >> "$L/v6-packages.txt" 2>&1
}

v6_trace() {   # $1 = row, $2 = what ran, $3 = guest command (gvm-drmtrace.sh v2): summary row + the guest's trace tarball
	local r=$1 w=$2 f=$L/$1.txt c
	G "$3" > "$f" 2>&1
	G 'sudo tar -C /tmp -czf - gvm-drmtrace' > "$L/$r-trace.tgz" 2>/dev/null
	fn() { awk -v k="$1" '$1 == "FN" && ($2 == k || (length($2) >= 30 && index(k, $2) == 1)) {n = $3} END {print n + 0}' "$f"; }
	if grep -q '^NO-FTRACE' "$f"; then
		row "$r" INFO "$w: guest kernel without ftrace (use bisect/Image-trace); $(sed -n '/^ERRORS:/{n;p}' "$f" | cut -c1-120)"
		return 0
	fi
	c="atomic $(fn drm_mode_atomic_ioctl) flip $(fn drm_mode_page_flip_ioctl) commit_work $(fn commit_work) fences-wait $(fn drm_atomic_helper_wait_for_fences)"
	c="$c plane-update $(fn virtio_gpu_primary_plane_update) set_scanout $(fn virtio_gpu_cmd_set_scanout) flush $(fn virtio_gpu_cmd_resource_flush)"
	c="$c crtc-flush $(fn virtio_gpu_crtc_atomic_flush) ev-armed $(fn drm_crtc_arm_vblank_event) ev-sent $(fn drm_crtc_send_vblank_event)"
	c="$c vbl-timer $(fn drm_vblank_timer_function) vbl-handle $(fn drm_handle_vblank) timer-start $(fn drm_crtc_vblank_start_timer) fence-wait $(fn dma_fence_default_wait)"
	row "$r" INFO "$w: $c; ev-delivered $(awk '$1 == "EV" && $2 == "drm_vblank_event_delivered" {print $3}' "$f") stack: $(sed -n '/^STACKS:/,/^BLOCKED:/p' "$f" | grep -m3 -E 'drm_|dma_fence|virtio' | tr -s ' 	' ' ' | tr '
' ';' | cut -c1-160)"
}

v6_fbread() {   # $1 = row, $2 = what, $3 = command started in the background (as root), $4 = seconds before the read
	local r=$1 w=$2 c=$3 t=$4 n
	G 'test -x /tmp/gvm-fbread || gcc -O2 -o /tmp/gvm-fbread /mnt/gvmshare/tools/gvm-fbread.c' > "$L/$r-cc.txt" 2>&1
	n=$(wc -l < "$L/crosvm-stderr.txt")
	G "sudo sh -c '($c) > /tmp/$r-client.txt 2>&1 & echo \$! > /tmp/$r.pid; sleep $t; /tmp/gvm-fbread; sleep 8; kill \$(cat /tmp/$r.pid) 2>/dev/null; pkill -x weston; pkill -x kmscube; sleep 2; pkill -9 -x weston; pkill -9 -x kmscube; rm -f /run/seatd.sock; true'" > "$L/$r.txt" 2>&1 &
	local gp=$! ps=""
	# v10e: the verdict is the crosvm window itself (KWin screenshot $t+3 s in, client still running); the frame
	# dumps only see copied frames at a limited rate and miss an idle compositor's last frame (v10d V6-3 / V6-6)
	sleep $((t + 3))
	if command -v iceland-shot > /dev/null && iceland-shot --window "V6 probes" "$L/$r-window.png" > "$L/$r-shot.txt" 2>&1; then
		ps=$(python3 "$D/gvm-pngstat.py" "$L/$r-window.png" 2>&1)
	fi
	wait $gp
	sleep 2; v6_alive "$r" || return 1
	if [ -z "$ps" ]; then row "$r" INFO "$w: no window screenshot ($(tail -n1 "$L/$r-shot.txt" 2>/dev/null | cut -c1-80)) | host: $(v6_lastframe "$n")"
	elif awk -v n="$(echo "$ps" | grep -oE 'nonzero=[0-9.]+' | cut -d= -f2)" 'BEGIN{exit !(n > 0.3)}'; then
		row "$r" PASS "$w: window drawn ($ps) | host dump: $(v6_lastframe "$n")"
	else row "$r" FAIL "$w: window black ($ps) | host dump: $(v6_lastframe "$n")"; fi
}
v6_lastframe() {   # $1 = crosvm-stderr line: the last GVM-FRAME statistics since then
	tail -n +"$1" "$L/crosvm-stderr.txt" | grep -a 'GVM-FRAME .* shown=' | tail -n1 | grep -oE 'GVM-FRAME [0-9]+ shown=[a-z0-9]+ mean=[0-9.]+ nonzero=[0-9.]+'
}

v6() {   # guest display stack probes: which guest path puts a drawn frame on the virtio-gpu scanout
	[ "${GVM_V1B_PASSED:-0}" = 1 ] || die "V6 needs V1b PASS first (GVM_V1B_PASSED=1)"
	export GVM_CTX=${GVM_CTX:-virgl:virgl2} GVM_VENUS=${GVM_VENUS:-1} GVM_AUTOLOGIN=1
	export CROSVM_GVM_TRACE_SCANOUT=1 GVM_TITLE="gvm: V6 probes" CROSVM_GVM_DUMP_FRAME=$L/frames6 CROSVM_GVM_DUMP_EVERY=3 CROSVM_GVM_DUMP_MAX=120
	rm -rf "$L/frames6" "$L/v6-packages.txt"; mkdir -p "$L/frames6"
	v4_guest                                       # display manager stopped
	local p; for p in drm-utils kmscube weston seatd; do v6_pkg $p; done
	row V6-P INFO "guest packages: $(tr '\n' ' ' < "$L/v6-packages.txt" | cut -c1-200)"
	G 'sudo modetest -M virtio_gpu -c 2>&1 | head -n 40; cat /sys/class/drm/card*-Virtual-1/modes 2>/dev/null | head -n 3' > "$L/v6-modetest-info.txt" 2>&1
	local conn; conn=$(awk '$3 == "connected" {print $1; exit}' "$L/v6-modetest-info.txt")
	row V6-0 INFO "connector ${conn:-?}; modes $(grep -m3 -E '^[0-9]+x[0-9]+' "$L/v6-modetest-info.txt" | tr '\n' ' ')"
	local n
	# (a) plain KMS, no GL, CPU-drawn dumb buffers: modetest's test pattern with page flips
	n=$(wc -l < "$L/crosvm-stderr.txt"); G "sleep 10 | sudo timeout 15 modetest -M virtio_gpu -s ${conn:-0}:1600x1000 2>&1 | tail -n 3" > "$L/V6-1.txt" 2>&1
	sleep 2; v6_alive V6-1 || { v4_end V6; return 0; }; v6_frame V6-1 "$n" "modetest pattern (dumb buffers, no GL)"
	# (b) KMS + GL (virgl): kmscube renders into GBM bos
	n=$(wc -l < "$L/crosvm-stderr.txt"); G 'sleep 20 | sudo timeout 15 kmscube -D /dev/dri/card0 2>&1 | tail -n 3' > "$L/V6-2.txt" 2>&1
	sleep 2; v6_alive V6-2 || { v4_end V6; return 0; }; v6_frame V6-2 "$n" "kmscube (GL via virgl)"
	# (c) weston on KMS through seatd-launch: GL renderer, then pixman (CPU)
	n=$(wc -l < "$L/crosvm-stderr.txt")
	G 'sudo sh -c "export XDG_RUNTIME_DIR=/run/gvm-weston; mkdir -p -m 700 \$XDG_RUNTIME_DIR; rm -f /run/seatd.sock; timeout 25 seatd-launch -- weston --backend=drm --continue-without-input --idle-time=0 2>&1 | tail -n 4"' > "$L/V6-3.txt" 2>&1
	sleep 2; v6_alive V6-3 || { v4_end V6; return 0; }; v6_frame V6-3 "$n" "weston drm, GL renderer"
	n=$(wc -l < "$L/crosvm-stderr.txt")
	G 'sudo sh -c "export XDG_RUNTIME_DIR=/run/gvm-weston; mkdir -p -m 700 \$XDG_RUNTIME_DIR; rm -f /run/seatd.sock; timeout 25 seatd-launch -- weston --backend=drm --renderer=pixman --continue-without-input --idle-time=0 2>&1 | tail -n 4"' > "$L/V6-6.txt" 2>&1
	sleep 2; v6_alive V6-6 || { v4_end V6; return 0; }; v6_frame V6-6 "$n" "weston drm, pixman renderer"
	# (c2) timing hypothesis (v5 run: kmscube drawn, weston-GL / glamor black, same format AB24 / mod 0 / size):
	# continuously rendering GL clients vs an idle compositor. glmark2 on KMS keeps rendering like kmscube;
	# weston-GL with an animating client (weston-simple-egl) keeps the compositor repainting.
	n=$(wc -l < "$L/crosvm-stderr.txt"); G 'sudo timeout 15 glmark2-es2-drm -b build:duration=12 2>&1 | tail -n 3' > "$L/V6-8.txt" 2>&1
	sleep 2; v6_alive V6-8 || { v4_end V6; return 0; }; v6_frame V6-8 "$n" "glmark2-es2-drm on KMS (continuous GL)"
	v6_pkg weston-demo
	n=$(wc -l < "$L/crosvm-stderr.txt")
	G 'sudo sh -c "export XDG_RUNTIME_DIR=/run/gvm-weston; mkdir -p -m 700 \$XDG_RUNTIME_DIR; (sleep 6; WAYLAND_DISPLAY=wayland-1 timeout 15 weston-simple-egl -f > /tmp/v6-egl.txt 2>&1) & timeout 25 seatd-launch -- weston --backend=drm --socket=wayland-1 --continue-without-input --idle-time=0 2>&1 | tail -n 4; cat /tmp/v6-egl.txt | tail -n 2"' > "$L/V6-9.txt" 2>&1
	sleep 2; v6_alive V6-9 || { v4_end V6; return 0; }; v6_frame V6-9 "$n" "weston GL + animating weston-simple-egl (continuous repaint)"
	# v10f: kmscube reads stdin and quits ("user interrupted!") when it is readable - an ssh stdin at EOF is: that is
	# why kmscube -A "never displayed" (it quit before its first atomic commit). Every kmscube gets a sleep pipe.
	# (c3) v8 run: kmscube drawn, weston-GL / glmark2-drm / glamor black: which kmscube variant turns black?
	# -A = atomic KMS (weston uses atomic), -m 0 = explicit LINEAR modifier through gbm_surface_create_with_modifiers
	n=$(wc -l < "$L/crosvm-stderr.txt"); G 'sleep 20 | sudo timeout 15 kmscube -A -D /dev/dri/card0 2>&1 | tail -n 3' > "$L/V6-10.txt" 2>&1
	sleep 2; v6_alive V6-10 || { v4_end V6; return 0; }; v6_frame V6-10 "$n" "kmscube -A (atomic KMS)"
	n=$(wc -l < "$L/crosvm-stderr.txt"); G 'sleep 20 | sudo timeout 15 kmscube -m 0 -D /dev/dri/card0 2>&1 | tail -n 3' > "$L/V6-11.txt" 2>&1
	sleep 2; v6_alive V6-11 || { v4_end V6; return 0; }; v6_frame V6-11 "$n" "kmscube -m 0 (explicit linear modifier)"
	n=$(wc -l < "$L/crosvm-stderr.txt"); G 'sleep 20 | sudo timeout 15 kmscube -A -m 0 -D /dev/dri/card0 2>&1 | tail -n 3' > "$L/V6-12.txt" 2>&1
	sleep 2; v6_alive V6-12 || { v4_end V6; return 0; }; v6_frame V6-12 "$n" "kmscube -A -m 0 (atomic + modifier)"
	# (c4) v9 run: atomic kmscube never put a buffer on the scanout (no SET_SCANOUT / flush reached crosvm) while
	# legacy kmscube did; weston-GL / glamor did set the scanout but read black. Guest-side DRM debug of both:
	v6_trace V6-13 "kmscube -A" 'sudo sh /mnt/gvmshare/tools/gvm-drmtrace.sh 10 kmscube -A -D /dev/dri/card0'
	v6_trace V6-14 "weston GL" 'sudo env XDG_RUNTIME_DIR=/run/gvm-weston sh -c "mkdir -p -m 700 /run/gvm-weston; rm -f /run/seatd.sock; sh /mnt/gvmshare/tools/gvm-drmtrace.sh 16 seatd-launch -- weston --backend=drm --continue-without-input --idle-time=0"'
	# (c5) vm-run v10c: what does the scanout resource hold on the HOST while the client runs? gvm-fbread reads the
	# CRTC's current fb back with TRANSFER_FROM_HOST (the client's own virgl context, not crosvm's ctx0).
	v6_fbread V6-17 "weston GL (12 s in)" 'export XDG_RUNTIME_DIR=/run/gvm-weston; mkdir -p -m 700 $XDG_RUNTIME_DIR; rm -f /run/seatd.sock; seatd-launch -- weston --backend=drm --continue-without-input --idle-time=0' 12
	v6_fbread V6-18 "weston pixman (12 s in)" 'export XDG_RUNTIME_DIR=/run/gvm-weston; mkdir -p -m 700 $XDG_RUNTIME_DIR; rm -f /run/seatd.sock; seatd-launch -- weston --backend=drm --renderer=pixman --continue-without-input --idle-time=0' 12
	v6_fbread V6-19 "kmscube legacy (5 s in)" 'sleep 40 | kmscube -D /dev/dri/card0' 5
	v6_fbread V6-23 "kmscube -A (5 s in)" 'sleep 40 | kmscube -A -D /dev/dri/card0' 5
	# v10d: texture uploads (virgl staging) - Mesa variants: no coherent (blob) staging, no transfer optimisation
	v6_fbread V6-21 "weston GL, VIRGL_DEBUG=nocoherent" 'export VIRGL_DEBUG=nocoherent XDG_RUNTIME_DIR=/run/gvm-weston; mkdir -p -m 700 $XDG_RUNTIME_DIR; rm -f /run/seatd.sock; seatd-launch -- weston --backend=drm --continue-without-input --idle-time=0' 12
	v6_fbread V6-22 "weston GL, VIRGL_DEBUG=xfer" 'export VIRGL_DEBUG=xfer XDG_RUNTIME_DIR=/run/gvm-weston; mkdir -p -m 700 $XDG_RUNTIME_DIR; rm -f /run/seatd.sock; seatd-launch -- weston --backend=drm --continue-without-input --idle-time=0' 12
	# (d) Xorg WITHOUT glamor (AccelMethod none): CPU rendering into dumb buffers
	G 'sudo mkdir -p /etc/X11/xorg.conf.d; printf "Section \"Device\"\n\tIdentifier \"iceland-probe\"\n\tDriver \"modesetting\"\n\tOption \"AccelMethod\" \"none\"\n\tOption \"PageFlip\" \"off\"\nEndSection\n" | sudo tee /etc/X11/xorg.conf.d/21-iceland-probe.conf > /dev/null'
	n=$(wc -l < "$L/crosvm-stderr.txt"); G 'sudo systemctl start display-manager'; sleep 60
	G 'grep -E "modeset\(0\): (Output|Using|glamor|ShadowFB|PageFlip)|AccelMethod|Virtual-1" /var/log/Xorg.0.log ~gvm/.local/share/xorg/Xorg.0.log 2>/dev/null | tail -n 8' > "$L/V6-4.txt" 2>&1
	v6_frame V6-4 "$n" "Xorg without glamor (AccelMethod none)"
	G 'sudo systemctl stop display-manager; sudo rm -f /etc/X11/xorg.conf.d/21-iceland-probe.conf'; sleep 3
	# (e) baseline: Xorg as configured (glamor, page flips)
	n=$(wc -l < "$L/crosvm-stderr.txt"); G 'sudo systemctl start display-manager'; sleep 60
	G 'grep -E "modeset\(0\): (Output|Using|glamor|PageFlip)|Virtual-1" /var/log/Xorg.0.log ~gvm/.local/share/xorg/Xorg.0.log 2>/dev/null | tail -n 8' > "$L/V6-5.txt" 2>&1
	v6_frame V6-5D "$n" "Xorg default (glamor), frame dumps (diagnostic)"
	# v10g: the verdict is the window (v10f: the frame dumps missed glamor's last frames, V6-17 style)
	local ps5=""
	command -v iceland-shot > /dev/null && iceland-shot --window "V6 probes" "$L/V6-5-window.png" > "$L/V6-5-shot.txt" 2>&1 \
		&& ps5=$(python3 "$D/gvm-pngstat.py" "$L/V6-5-window.png" 2>&1)
	if [ -z "$ps5" ]; then row V6-5 INFO "Xorg default (glamor): no window screenshot ($(tail -n1 "$L/V6-5-shot.txt" 2>/dev/null | cut -c1-80))"
	elif awk -v n="$(echo "$ps5" | grep -oE 'nonzero=[0-9.]+' | cut -d= -f2)" 'BEGIN{exit !(n > 0.3)}'; then row V6-5 PASS "Xorg default (glamor): window drawn ($ps5)"
	else row V6-5 FAIL "Xorg default (glamor): window black ($ps5)"; fi
	G 'sudo /tmp/gvm-fbread' > "$L/V6-20.txt" 2>&1
	row V6-20 INFO "Xorg glamor scanout read back from the host: $(grep -m1 -E '^FBREAD' "$L/V6-20.txt" | cut -c1-200)"
	G 'sudo systemctl stop display-manager; true'
	v4_end V6
}

v8() {   # the desktop on the simplefb software display (DroidVM's design in our crosvm; no virtio-gpu): guest simpledrm ->
	# shared framebuffer -> crosvm bridge -> KWin window. Rows: guest session, guest / host frame statistics, shot, window
	[ "${GVM_V1B_PASSED:-0}" = 1 ] || die "V8 needs V1b PASS first (GVM_V1B_PASSED=1)"
	local P=V8
	export GVM_RUNMODE=--simplefb GVM_NOGLAMOR=1 GVM_AUTOLOGIN=1 GVM_TITLE="gvm: V8 simplefb"
	v4_guest                                       # display manager stopped
	grep -a 'GVM-SIMPLEFB ' "$L/crosvm-stderr.txt" | sed 's/^.*GVM-/GVM-/' | head -n1 > "$L/v8-simplefb.txt"
	G 'for c in /sys/class/drm/card[0-9]; do echo "drm $c $(basename "$(readlink "$c/device/driver")")"; done; cat /proc/fb; sudo dmesg | grep -iE "simpledrm|simple-framebuffer|simplefb" | tail -n 4' > "$L/v8-guest-fb.txt" 2>&1
	grep -q 'simple-framebuffer' "$L/v8-guest-fb.txt" && row $P-0 PASS "guest simpledrm on the shared framebuffer: $(cat "$L/v8-simplefb.txt" | cut -c1-120)" \
		|| row $P-0 FAIL "no simpledrm device in the guest (CONFIG_DRM_SIMPLEDRM?): $(tr '\n' ' ' < "$L/v8-guest-fb.txt" | cut -c1-160) | host: $(cut -c1-100 "$L/v8-simplefb.txt")"
	G 'sudo install -m 755 /mnt/gvmshare/tools/gvm-agent /usr/local/sbin/gvm-agent && sudo /usr/local/sbin/gvm-agent --setup; true'
	G 'sudo systemctl start display-manager; true'
	say "  V8: waiting 90 s for the guest desktop"; sleep 90
	if ! G true 2> "$L/v8-ssh.txt"; then
		row $P-0 FAIL "guest unreachable after the desktop start: $(head -c 100 "$L/v8-ssh.txt") | console: $(tail -n 400 "$L/console-run.txt" 2>/dev/null | grep -aE 'Kernel panic|Oops|BUG|Out of memory|reboot:|Power down|segfault' | tail -n 3 | tr '\n' ' ' | cut -c1-200)"
	fi
	G 'loginctl list-sessions --no-legend; loginctl show-session $(loginctl list-sessions --no-legend | awk "\$4==\"seat0\"{print \$1; exit}") -p Type -p Desktop 2>/dev/null' > "$L/v8-sessions.txt" 2>&1
	grep -qiE 'Type=(x11|wayland)' "$L/v8-sessions.txt" && row $P-1 PASS "guest graphical session: $(grep -E 'Type=|Desktop=' "$L/v8-sessions.txt" | tr '\n' ' ')" \
		|| row $P-1 FAIL "no graphical session in the guest (autologin / display manager): $(head -c 200 "$L/v8-sessions.txt")"
	G 'rpm -q xwd > /dev/null || sudo dnf -y -q install xwd' > /dev/null 2>&1
	G 'sudo python3 /mnt/gvmshare/tools/gvm-xwdstat.py :0' > "$L/v8-guest-xwd.txt" 2>&1
	say "  $(head -c 200 "$L/v8-guest-xwd.txt")"
	local gnz; gnz=$(grep -oE 'nonzero=[0-9.]+' "$L/v8-guest-xwd.txt" | cut -d= -f2)
	awk -v n="${gnz:-0}" 'BEGIN{exit !(n > 0.3)}' && row $P-2 PASS "the guest desktop is drawn ($(grep -o 'GUEST-XWD.*' "$L/v8-guest-xwd.txt"))" \
		|| row $P-2 FAIL "guest frame black or unreadable: $(head -c 160 "$L/v8-guest-xwd.txt")"
	# host side: crosvm's bridge logs GVM-SIMPLEFB-FRAME <frames> t=<s> mean= nonzero= (every 10 s for a minute, then every
	# 60 s); wait for one more line so the newest one is from the desktop, then judge it
	local n0; n0=$(grep -ac 'GVM-SIMPLEFB-FRAME' "$L/crosvm-stderr.txt")
	local t=0; while [ $t -lt 75 ] && [ "$(grep -ac 'GVM-SIMPLEFB-FRAME' "$L/crosvm-stderr.txt")" = "$n0" ]; do sleep 5; t=$((t + 5)); done
	grep -a 'GVM-SIMPLEFB' "$L/crosvm-stderr.txt" | sed 's/^.*GVM-/GVM-/' > "$L/v8-frames.txt"
	cat "$L/v8-frames.txt" >> "$L/gvm.log"
	local last; last=$(grep 'GVM-SIMPLEFB-FRAME' "$L/v8-frames.txt" | tail -n1)
	if echo "$last" | awk '{for (i=1;i<=NF;i++) if ($i ~ /^nonzero=/) {split($i,b,"="); z=b[2]}} END{exit !(z > 0.3)}'; then
		row $P-3 PASS "host framebuffer drawn: $(echo "$last" | cut -c1-100)"
	else
		row $P-3 FAIL "host framebuffer black or no statistics: $(echo "${last:-no GVM-SIMPLEFB-FRAME line}" | cut -c1-100) | $(grep -a 'simplefb\|GVM-SIMPLEFB' "$L/crosvm-stderr.txt" | grep -iE 'error|stopped|fail' | tail -n1 | cut -c1-120)"
	fi
	local w; w=$(kwin_js list "V8 simplefb")
	if [ -z "$w" ]; then row V8-4 FAIL "no crosvm window in KWin: no screenshot"
	elif command -v iceland-shot > /dev/null; then   # as root, like the Plasma kit (it takes the session from plasmashell)
		if iceland-shot --window "V8 simplefb" "$L/v8-window.png" > "$L/v8-shot.txt" 2>&1; then
			local ps; ps=$(python3 "$D/gvm-pngstat.py" "$L/v8-window.png" 2>&1)
			say "  screenshot: $ps"
			awk -v n="$(echo "$ps" | grep -oE 'nonzero=[0-9.]+' | cut -d= -f2)" 'BEGIN{exit !(n > 0.3)}' \
				&& row $P-4 PASS "crosvm window screenshot drawn ($ps)" || row $P-4 FAIL "crosvm window screenshot black ($ps)"
		else
			row $P-4 FAIL "iceland-shot: $(tail -n1 "$L/v8-shot.txt" | cut -c1-140)"
		fi
	else
		row $P-4 NOT-RUN "no iceland-shot (V8-3 is the host-side picture)"
	fi
	if [ -n "$w" ]; then
		echo "$w" | grep -q 'desktopFile=org.iceland.VirtualMachines' && echo "$w" | grep -q 'noBorder=false' \
			&& row $P-5 PASS "KWin window: $(echo "$w" | head -n1 | cut -c1-160)" || row $P-5 FAIL "KWin window: $(echo "$w" | head -n1 | cut -c1-160)"
	else
		row $P-5 FAIL "no window with V8 simplefb in KWin ($(tail -n 2 "$L/kwin-probe.txt" 2>/dev/null | tr '\n' ' ' | cut -c1-160))"
	fi
	crosvm_running || { row $P-6 NOT-RUN "crosvm gone before the stop"; return 0; }
	clean_stop; wait
	dmesg | tail -n 80 | grep -E 'BUG|WARNING|Oops|SError|Internal error' | grep -vE 'gvm: |vm-run: |iceland-combo' && row K1 FAIL "host kernel warnings" || row K1 PASS "no host kernel warnings"
}

ses_run() {   # run "$@" as the Plasma session's user with its environment (like kwin_js)
	local P SU; P=$(pgrep -o -x plasmashell) || return 1
	SU=$(ps -o user= -p "$P" | tr -d ' ')
	local -a SENV; mapfile -t SENV < <(tr '\0' '\n' < /proc/"$P"/environ | grep -E '^(WAYLAND_DISPLAY|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|HOME|XDG_CURRENT_DESKTOP)=')
	runuser -u "$SU" -- env "${SENV[@]}" "$@"
}

vin_geo() {   # $1 = GVMWIN line, $2 = client|outgeo: "X Y W H"
	echo "$1" | grep -oE " $2=-?[0-9.]+,-?[0-9.]+,[0-9.]+,[0-9.]+" | head -n1 | cut -d= -f2 | tr ',' ' '   # KWin 6: may be fractional
}

vin_dev() { python3 "$IJ" inv "$FIT" "$1" "$2"; }   # output point (0..1) -> injector point (calibration fit)

kwin_watch() {   # $1 = seconds, $2 = caption: KWin activations / fullscreen / geometry changes -> $L/kwin-watch.txt (KWP)
	local P SU; P=$(pgrep -o -x plasmashell) || return 1
	SU=$(ps -o user= -p "$P" | tr -d ' ')
	local -a SENV; mapfile -t SENV < <(tr '\0' '\n' < /proc/"$P"/environ | grep -E '^(WAYLAND_DISPLAY|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|HOME|XDG_CURRENT_DESKTOP)=')
	runuser -u "$SU" -- env "${SENV[@]}" WATCH_SECONDS="$1" python3 "$D/gvm-kwinprobe.py" watch "$2" > "$L/kwin-watch.txt" 2>&1 &
	KWP=$!
}

vin_g() {   # $1 = row, $2 = gesture (judge), $3 = injector line, [$4 $5 = expected landing, 0..1 of the guest display]
	local id=$1 g=$2 line=$3 f t n0; shift 3
	f=$L/vin-$id.jsonl
	G "sudo timeout 20 python3 /mnt/gvmshare/tools/gvm-evrec.py ${VIN_SECS:-4}" > "$f" 2> "$f.err" &
	local rp=$!
	t=0; while ! grep -q '^READY' "$f" 2>/dev/null && [ $t -lt 150 ]; do sleep 0.1; t=$((t + 1)); done
	grep -q '^READY' "$f" || { wait $rp; row "$id" FAIL "guest recorder did not start: $(head -c 160 "$f.err")"; return 1; }
	n0=$(grep -c '' "$L/touch.log")
	local td0; td0=$(grep -ac 'GVM-TOUCH down' "$L/crosvm-stderr.txt")
	local kv0; kv0=$(grep -ac '^GVMEV' "$L/kwin-watch.txt" 2>/dev/null)
	echo "$line" >&8
	t=0; while [ "$(grep -c '' "$L/touch.log")" -le "$n0" ] && [ $t -lt 100 ]; do sleep 0.1; t=$((t + 1)); done
	wait $rp
	tail -n +"$((n0 + 1))" "$L/touch.log" | grep -q '^DONE' || { row "$id" FAIL "injector: $(tail -n1 "$L/touch.log" | cut -c1-140)"; return 1; }
	VIN_RES=$(python3 "$IJ" judge "$M" "$g" "$W" "$H" "$f" "$@" 2>&1)
	# p1 analysis: did crosvm get the touch at all (KWin -> wl_touch), and where on its surface?
	local td; td=$(grep -a 'GVM-TOUCH down' "$L/crosvm-stderr.txt" | tail -n +"$((td0 + 1))" | sed 's/^.*GVM-TOUCH //' | head -n 2 | tr '\n' ';')
	VIN_RES="$VIN_RES | crosvm: ${td:-no wl_touch down}"
	VIN_SURF=$(echo "$td" | grep -oE 'surface=[0-9.]+,[0-9.]+' | head -n1 | cut -d= -f2)   # p3: calibration source
	local kv; kv=$(grep -a '^GVMEV' "$L/kwin-watch.txt" 2>/dev/null | tail -n +"$((${kv0:-0} + 1))" | cut -d' ' -f3- | tr '\n' ';' | cut -c1-160)
	[ -n "$kv" ] && VIN_RES="$VIN_RES | KWin: $kv"
	say "  $id [$line] $VIN_RES"
	case "$VIN_RES" in PASS*) row "$id" PASS "${VIN_RES#PASS }" ;; *) row "$id" FAIL "${VIN_RES#FAIL }"; return 1 ;; esac
}

vin_at() { echo "$VIN_RES" | grep -oE 'at \([0-9.]+,[0-9.]+\)' | head -n1 | sed 's/^at (//; s/)$//'; }   # "x,y" of the last judge

vin_rot_json() {   # the first enabled output from kscreen-doctor -j: "name rotation autorotate-policy" (ints as kscreen has them)
	ses_run kscreen-doctor -j 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
for o in d.get("outputs", []):
    if o.get("enabled"):
        print(o.get("name"), o.get("rotation", 1), o.get("autoRotatePolicy", o.get("autoRotate", "")))
        break'
}

vin_rot_name() { case "$1" in 1) echo normal ;; 2) echo left ;; 4) echo inverted ;; 8) echo right ;; *) echo normal ;; esac; }
vin_ar_name() { case "$1" in 0|never|Never) echo never ;; 2|always|Always) echo always ;; *) echo in-tablet-mode ;; esac; }

vin_rot_set() {   # $1 = normal|left|inverted|right: rotation lock + that rotation for the test (VIN in portrait AND landscape
	# without hands, p3); the previous state goes to $R/vin-rot.save and vin_rot_restore puts it back
	local cur n r a out
	cur=$(vin_rot_json) || { row VI-R FAIL "kscreen-doctor -j unreadable: no rotation change"; return 1; }
	read -r n r a <<< "$cur"
	[ -f "$R/vin-rot.save" ] || echo "$n $r $a" > "$R/vin-rot.save"
	out=$(ses_run kscreen-doctor "output.$n.autorotate.never" "output.$n.rotation.$1" 2>&1 | tail -n 2 | tr '\n' ' ')
	sleep 4
	cur=$(vin_rot_json)
	row VI-R INFO "output $n rotation $(vin_rot_name "$r") -> $1 (now: $cur; was: $n $r $a) ${out:+kscreen-doctor: $out}"
}

vin_rot_restore() {   # back to the saved rotation + auto-rotate policy (also called by vm-run's cleanup)
	[ -f "$R/vin-rot.save" ] || return 0
	local n r a out
	read -r n r a < "$R/vin-rot.save"
	out=$(ses_run kscreen-doctor "output.$n.rotation.$(vin_rot_name "$r")" "output.$n.autorotate.$(vin_ar_name "$a")" 2>&1 | tail -n 2 | tr '\n' ' ')
	rm -f "$R/vin-rot.save"
	say "vin: rotation restored on $n ($(vin_rot_name "$r"), autorotate $(vin_ar_name "$a")) $out"
}

vin() {   # 0.2-6: input modes of the VM window, judged in the guest. A uinput touch screen on the host (KWin takes it
	# like the tablet's own) -> wl_touch -> crosvm's mode mapper (CROSVM_GVM_INPUT_MODE) -> virtio-input -> guest evdev
	# (gvm-evrec.py). GVM_INPUT_MODE=tablet|touchpad|touch; the window opens fullscreen (CROSVM_GVM_FULLSCREEN).
	[ "${GVM_V1B_PASSED:-0}" = 1 ] || die "VIN needs V1b PASS first (GVM_V1B_PASSED=1)"
	M=${GVM_INPUT_MODE:-tablet}; W=${GVM_W:-1600}; H=${GVM_H:-1000}
	IJ=$D/gvm-touchinject.py; FIT=$R/touch-fit.json
	[ -f "$IJ" ] || die "no $IJ"
	local cap="VIN $M"
	export GVM_INPUT_MODE=$M GVM_FULLSCREEN=1 GVM_TITLE="gvm: $cap" CROSVM_GVM_INPUT_LOG=1
	if [ "$M" = touchpad ] && [ -s "$R/vin-output.txt" ]; then export GVM_OUTPUT; GVM_OUTPUT=$(cat "$R/vin-output.txt"); fi   # by name
	local sid lk
	sid=$(for s in $(loginctl list-sessions --no-legend | awk '{print $1}'); do
		[ "$(loginctl show-session "$s" -p Seat --value)" = seat0 ] && [ "$(loginctl show-session "$s" -p Class --value)" = user ] && echo "$s"; done | head -n1)
	lk=$(loginctl show-session "$sid" -p LockedHint --value 2>/dev/null)
	[ "$lk" = yes ] && { row VI-0 NOT-RUN "the Plasma session on seat0 is locked: touch would reach the lock screen"; return 0; }
	ses_run kscreen-doctor --dpms on > "$L/vin-dpms.txt" 2>&1   # touch on a dark screen only wakes KWin
	modprobe uinput || die "no uinput module"
	# p3: GVM_VIN_ROTATION=normal|left|inverted|right runs the test in that output rotation (rotation lock on)
	[ -n "${GVM_VIN_ROTATION:-}" ] && vin_rot_set "$GVM_VIN_ROTATION"
	export GVM_RUNMODE=${GVM_RUNMODE:---gpu3d}
	v4_guest                                       # display manager stopped: the guest console is on the scanout
	kwin_watch 900 "$cap"                          # p1: tell owner interference from a bug (focus / fullscreen changes)
	# p1: KWin sent fullscreen configures 800x500 / 1696x1200 / 800x500 / 1696x1200 within seconds: wait until the
	# window really fills its output (up to 20 s), then judge
	local w cg og t0=0
	while :; do
		w=$(kwin_js activate "$cap" | head -n1)
		cg=$(vin_geo "$w" client); og=$(vin_geo "$w" outgeo)
		[ -n "$cg" ] && [ "$cg" = "$og" ] && break
		[ $t0 -ge 20 ] && break
		sleep 2; t0=$((t0 + 2))
	done
	grep -a 'GVM-INPUT\|GVM-FULLSCREEN\|GVM-CONFIGURE' "$L/crosvm-stderr.txt" | sed 's/^.*GVM-/GVM-/' > "$L/vin-crosvm.txt"
	row VI-0S INFO "fullscreen settled after ${t0} s; configures: $(grep 'GVM-CONFIGURE' "$L/vin-crosvm.txt" | sed 's/GVM-CONFIGURE //; s/ viewport=[01]//' | tr '\n' ' ' | cut -c1-200)"
	if echo "$w" | grep -q 'fullscreen=true' && [ -n "$cg" ] && [ "$cg" = "$og" ] && grep -q 'GVM-FULLSCREEN on' "$L/vin-crosvm.txt"; then
		row VI-0 PASS "fullscreen window fills its output ($og, $(echo "$w" | grep -oE 'output=[^ ]+')); crosvm: $(grep -m1 'GVM-FULLSCREEN on' "$L/vin-crosvm.txt")"
	else
		row VI-0 FAIL "window not fullscreen on its output: $(echo "${w:-no KWin window}" | grep -oE 'size=[^ ]+ client=[^ ]+ fullscreen=[^ ]+ active=[^ ]+ activeWindow=[^ ]+' | cut -c1-200) | KWin events: $(grep -a '^GVMEV' "$L/kwin-watch.txt" | tail -n 4 | cut -d' ' -f2- | tr '\n' ';' | cut -c1-200)"
	fi
	[ "$M" = tablet ] && echo "$w" | grep -oE 'output=[^ ]+' | head -n1 | cut -d= -f2 > "$R/vin-output.txt"
	if [ -n "${GVM_OUTPUT:-}" ]; then
		echo "$w" | grep -q "output=$GVM_OUTPUT " && row VI-0O PASS "CROSVM_GVM_OUTPUT=$GVM_OUTPUT: fullscreen on that output" \
			|| row VI-0O FAIL "CROSVM_GVM_OUTPUT=$GVM_OUTPUT but: $(echo "$w" | grep -oE 'output=[^ ]+')"
	fi
	# the injector
	rm -f "$R/touch.fifo"; mkfifo -m 600 "$R/touch.fifo"; : > "$L/touch.log"
	python3 "$IJ" serve "$R/touch.fifo" "$L/touch.log" 2>> "$L/touch.log" &
	local ijp=$!
	exec 8<> "$R/touch.fifo"                       # read-write: never blocks, keeps the injector's reader open
	local t=0; while ! grep -q '^READY' "$L/touch.log" && [ $t -lt 50 ]; do sleep 0.1; t=$((t + 1)); done
	if ! grep -q '^READY' "$L/touch.log"; then
		row VI-1 FAIL "touch injector did not start: $(tail -n 2 "$L/touch.log" | tr '\n' ' ' | cut -c1-160)"
		exec 8>&-; kill $ijp 2>/dev/null; clean_stop; wait; return 1
	fi
	sleep 2                                        # libinput / KWin add the new touch screen
	grep -A4 'gvm touch injector' /proc/bus/input/devices > "$L/vin-injector-dev.txt"
	# VI-1 the guest's devices for this mode (+ crosvm's mode line)
	G "sudo timeout 5 python3 /mnt/gvmshare/tools/gvm-evrec.py 0.5" > "$L/vin-devices.jsonl" 2>&1
	local r; r=$(python3 "$IJ" judge "$M" devices "$W" "$H" "$L/vin-devices.jsonl")
	case "$r" in PASS*) row VI-1 PASS "${r#PASS }; crosvm: $(grep -m1 'GVM-INPUT' "$L/vin-crosvm.txt" || echo 'touch mode (default, no mode line)')" ;; *) row VI-1 FAIL "${r#FAIL }" ;; esac
	ses_run kscreen-doctor -j > "$L/vin-kscreen.json" 2>/dev/null
	kwin_js activate "$cap" > /dev/null
	# VI-C calibration (p3): KWin turns the injector's coordinates with the output (any rotation / flip). Four taps,
	# each located where crosvm received it (GVM-TOUCH surface x,y on the fullscreen surface = output coordinates),
	# least-squares fit; works in every mode (also touchpad) and does not depend on evdev repeating unchanged axes.
	# A warm-up tap first (p1: the first tap after the injector appeared got lost).
	vin_g VI-C0 tap "tap 0.5 0.5" > /dev/null 2>&1 || true
	rm -f "$FIT"
	local pts=() k ow oh sx sy
	read -r _ _ ow oh <<< "$og"
	for k in "1 0.3 0.3" "2 0.7 0.3" "3 0.3 0.7" "4 0.7 0.7"; do
		set -- $k
		VIN_SURF=""
		vin_g "VI-C$1" tap "tap $2 $3" || true
		if [ -n "$VIN_SURF" ] && [ -n "$ow" ]; then
			read -r sx sy < <(echo "$VIN_SURF $ow $oh" | tr ',' ' ' | awk '{printf "%.4f %.4f", $1 / $3, $2 / $4}')
			pts+=("$2,$3,$sx,$sy")
		fi
	done
	if [ ${#pts[@]} -ge 3 ]; then
		r=$(python3 "$IJ" fit "$FIT" "${pts[@]}" 2>&1 | tail -n 1)
		case "$r" in PASS*) row VI-2 PASS "taps land where touched (${#pts[@]} taps, output ${ow}x${oh}): ${r#PASS }" ;; *) row VI-2 FAIL "taps do not map onto the output by a rotation / flip: ${r#FAIL } (${pts[*]})" ;; esac
	else
		row VI-2 FAIL "only ${#pts[@]} of 4 calibration taps reached crosvm (see VI-C1..4); output '${og}'"
	fi
	# the gestures, placed in output coordinates (the fit undoes the output's rotation)
	local c a b x2 y2 dx dy
	c=$(vin_dev 0.5 0.5)
	vin_g VI-3 tap "tap $c" 0.5 0.5
	vin_g VI-4 press "press $(vin_dev 0.4 0.6) 1000" 0.4 0.6   # not the centre again: evdev drops repeated ABS values
	a=$(vin_dev 0.4 0.5); b=$(vin_dev 0.6 0.5)
	vin_g VI-5 drag "drag $a $b 600"
	a=$(vin_dev 0.45 0.5); b=$(vin_dev 0.55 0.5)
	vin_g VI-6 tap2 "tap2 $a $b 100"
	a=$(vin_dev 0.45 0.4); b=$(vin_dev 0.55 0.4); read -r x2 y2 < <(vin_dev 0.45 0.6)
	read -r dx dy < <(echo "$a $x2 $y2" | awk '{printf "%.4f %.4f", $3 - $1, $4 - $2}')
	vin_g VI-7 scroll2 "scroll2 $a $b $dx $dy 600"
	# VI-W / VI-F (tablet): leave fullscreen at run time, a tap at the window's centre and lower-left quarter
	# must land there in the guest (surface -> buffer pixel scaling), then fullscreen again
	if [ "$M" = tablet ]; then
		kwin_js unfullscreen "$cap" > /dev/null; sleep 2
		w=$(kwin_js activate "$cap" | head -n1); cg=$(vin_geo "$w" client); og=$(vin_geo "$w" outgeo)
		if echo "$w" | grep -q 'fullscreen=false' && [ -n "$cg" ] && [ -n "$og" ]; then
			local sx sy
			read -r sx sy < <(echo "$cg $og" | awk '{printf "%.4f %.4f", ($1 + $3 * 0.6 - $5) / $7, ($2 + $4 * 0.4 - $6) / $8}')
			vin_g VI-W0 tap "tap $(vin_dev "$sx" "$sy")" > /dev/null 2>&1 || true   # warm-up after the state change (p1)
			row VI-W0 INFO "warm-up tap in the window: $VIN_RES"
			read -r sx sy < <(echo "$cg $og" | awk '{printf "%.4f %.4f", ($1 + $3 * 0.5 - $5) / $7, ($2 + $4 * 0.5 - $6) / $8}')
			vin_g VI-W1 tap "tap $(vin_dev "$sx" "$sy")" 0.5 0.5
			read -r sx sy < <(echo "$cg $og" | awk '{printf "%.4f %.4f", ($1 + $3 * 0.25 - $5) / $7, ($2 + $4 * 0.75 - $6) / $8}')
			vin_g VI-W2 tap "tap $(vin_dev "$sx" "$sy")" 0.25 0.75
			grep -aq 'GVM-FULLSCREEN off' "$L/crosvm-stderr.txt" && row VI-W3 PASS "crosvm left fullscreen (viewport back to the window size; client $cg)" \
				|| row VI-W3 FAIL "no GVM-FULLSCREEN off line"
		else
			row VI-W1 FAIL "the window did not leave fullscreen: $(echo "${w:-no window}" | cut -c1-200)"
		fi
		kwin_js fullscreen "$cap" > /dev/null; sleep 2
		w=$(kwin_js activate "$cap" | head -n1)
		if echo "$w" | grep -q 'fullscreen=true' && [ "$(vin_geo "$w" client)" = "$(vin_geo "$w" outgeo)" ]; then
			vin_g VI-F1 tap "tap $c" 0.5 0.5
		else
			row VI-F1 FAIL "fullscreen again failed: $(echo "${w:-no window}" | cut -c1-200)"
		fi
	fi
	# p1: what KWin saw during the gestures: activations of other windows = someone used the tablet
	if [ -n "${KWP:-}" ]; then
		kill -INT "$KWP" 2>/dev/null; sleep 2; kill "$KWP" 2>/dev/null
		local other; other=$(grep -a '^GVMEV' "$L/kwin-watch.txt" | awk '$3 == "activated" && $4 !~ /VIN/ {print $4}' | sort | uniq -c | tr '\n' ' ')
		row VI-K INFO "KWin during the test: $(grep -ac '^GVMEV' "$L/kwin-watch.txt") events, activations of other windows: ${other:-none}; fullscreen changes: $(grep -a '^GVMEV' "$L/kwin-watch.txt" | grep -c ' fullscreen=')"
	fi
	echo quit >&8; sleep 1; exec 8>&-
	kill $ijp 2>/dev/null; wait $ijp 2>/dev/null; rm -f "$R/touch.fifo"
	grep -q 'gvm touch injector' /proc/bus/input/devices && row VI-8 FAIL "the host injector device is still there" \
		|| row VI-8 PASS "host injector device removed"
	crosvm_running || { row VI-9 FAIL "crosvm gone before the stop"; return 0; }
	clean_stop; wait
	crosvm_running && row VI-9 FAIL "crosvm still running after the clean stop" || row VI-9 PASS "clean stop"
	[ -n "${GVM_VIN_ROTATION:-}" ] && vin_rot_restore
	dmesg | tail -n 80 | grep -E 'BUG|WARNING|Oops|SError|Internal error' | grep -vE 'gvm: |vm-run: |iceland-combo' && row K1 FAIL "host kernel warnings" || row K1 PASS "no host kernel warnings"
}

v9_g() {   # $1 = row, $2 = judge mode, $3 = judge gesture, $4 = sender (gvm-vncprobe.py args), [$5 $6 = expected landing]
	local id=$1 jm=$2 g=$3 snd=$4 f t; shift 4
	f=$L/v9-$id.jsonl
	G "sudo timeout 20 python3 /mnt/gvmshare/tools/gvm-evrec.py ${VIN_SECS:-4} '' kbd" > "$f" 2> "$f.err" &
	local rp=$!
	t=0; while ! grep -q '^READY' "$f" 2>/dev/null && [ $t -lt 150 ]; do sleep 0.1; t=$((t + 1)); done
	grep -q '^READY' "$f" || { wait $rp; row "$id" FAIL "guest recorder did not start: $(head -c 160 "$f.err")"; return 1; }
	# shellcheck disable=SC2086
	python3 "$VP" $snd > "$f.send" 2>&1
	wait $rp
	VIN_RES=$(python3 "$IJ" judge "$jm" "$g" "$W" "$H" "$f" "$@" 2>&1)
	say "  $id [$snd] $(cat "$f.send") | $VIN_RES"
	case "$VIN_RES" in PASS*) row "$id" PASS "${VIN_RES#PASS }" ;; *) row "$id" FAIL "${VIN_RES#FAIL } | sender: $(head -c 120 "$f.send")"; return 1 ;; esac
}

v9() {   # 0.2-7: the VM display over VNC (crosvm --vnc-server, LibVNCServer, ported from DroidVM) instead of a window.
	# GVM_RUNMODE=--gpu3d (default, V9) or --simplefb (V9S). Judged with our own RFB client (gvm-vncprobe.py) on
	# 127.0.0.1 and the guest's evdev recorder; no viewer, no eyes.
	[ "${GVM_V1B_PASSED:-0}" = 1 ] || die "V9 needs V1b PASS first (GVM_V1B_PASSED=1)"
	W=${GVM_W:-1600}; H=${GVM_H:-1000}; VP=$D/gvm-vncprobe.py; IJ=$D/gvm-touchinject.py
	local port=${GVM_VNC_PORT:-5900} host=127.0.0.1
	[ -f "$VP" ] || die "no $VP"
	export GVM_VNC=1 GVM_VNC_HOST=$host GVM_VNC_PORT=$port GVM_TITLE="gvm: V9 vnc" GVM_AUTOLOGIN=1
	export GVM_RUNMODE=${GVM_RUNMODE:---gpu3d}
	[ "$GVM_RUNMODE" = --simplefb ] && export GVM_NOGLAMOR=1
	if ss -ltn "sport = :$port" | grep -q LISTEN; then row V9-0 FAIL "port $port is already in use: $(ss -ltnp "sport = :$port" | tail -n +2 | head -n1)"; return 1; fi
	v4_guest                                       # display manager stopped
	local cp; cp=$(pgrep -x crosvm | head -n1)
	grep -a 'GVM-VNC' "$L/crosvm-stderr.txt" | sed 's/^.*GVM-/GVM-/' | head -n 3 > "$L/v9-crosvm.txt"
	ss -ltnp > "$L/v9-listen.txt" 2>&1
	if grep -q 'GVM-VNC listening' "$L/v9-crosvm.txt" && grep -E "127\.0\.0\.1:$port " "$L/v9-listen.txt" | grep -q crosvm \
		&& ! grep -E "(0\.0\.0\.0|\*|\[::\]):$port " "$L/v9-listen.txt" | grep -q .; then
		row V9-0 PASS "crosvm serves VNC on 127.0.0.1:$port only ($(head -n1 "$L/v9-crosvm.txt"))"
	else
		row V9-0 FAIL "VNC listener: $(tr '\n' ' ' < "$L/v9-crosvm.txt" | cut -c1-140) | $(grep ":$port " "$L/v9-listen.txt" | head -n 2 | tr '\n' ' ' | cut -c1-140)"
	fi
	local r
	r=$(python3 "$VP" security $host "$port" 2>&1); say "  $r"
	r=$(python3 "$VP" frame $host "$port" "$L/v9-console.ppm" 2>&1); say "  $r"
	if echo "$r" | grep -q "w=$W h=$H"; then row V9-1 PASS "RFB handshake + full frame: $r"
	else row V9-1 FAIL "RFB client: $r"; fi
	# the desktop, as V8 does it (autologin through the guest agent)
	G 'sudo install -m 755 /mnt/gvmshare/tools/gvm-agent /usr/local/sbin/gvm-agent && sudo /usr/local/sbin/gvm-agent --setup; true'
	G 'sudo systemctl start display-manager; true'
	say "  V9: waiting 90 s for the guest desktop"; sleep 90
	r=$(python3 "$VP" frame $host "$port" "$L/v9-desktop.ppm" 2>&1); say "  $r"
	local nz; nz=$(echo "$r" | grep -oE 'nonzero=[0-9.]+' | cut -d= -f2)
	awk -v n="${nz:-0}" 'BEGIN{exit !(n > 0.3)}' && row V9-2 PASS "desktop drawn over VNC: $r; crosvm: $(grep -a 'GVM-VNC-FRAME' "$L/crosvm-stderr.txt" | tail -n1 | sed 's/^.*GVM-/GVM-/')" \
		|| row V9-2 FAIL "VNC frame black: $r | guest: $(G 'loginctl list-sessions --no-legend' 2>&1 | head -n 2 | tr '\n' ' ')"
	v9_g V9-3 tablet key "key $host $port 0x61"
	v9_g V9-4 tablet tap "pointer $host $port $((W / 2)) $((H / 2)) 1" 0.5 0.5
	v9_g V9-5 tablet press "pointer $host $port $((W / 4)) $((H / 4)) 4" 0.25 0.25
	local nfd; nfd=$(ls /proc/"$cp"/fd 2>/dev/null | wc -l)
	[ "${nfd:-0}" -gt 0 ] && [ "$nfd" -lt 900 ] && row V9-6 PASS "crosvm holds $nfd descriptors (LibVNCServer uses select(): must stay below 1024)" \
		|| row V9-6 FAIL "crosvm holds ${nfd:-?} descriptors (select() limit 1024)"
	local w; w=$(kwin_js list "V9 vnc")
	[ -z "$w" ] && row V9-7 PASS "no VM window on the host (headless VNC display)" || row V9-7 FAIL "a window exists: $(echo "$w" | head -n1 | cut -c1-140)"
	crosvm_running || { row V9-9 FAIL "crosvm gone before the stop"; return 0; }
	clean_stop; wait
	crosvm_running && row V9-9 FAIL "crosvm still running after the clean stop" || row V9-9 PASS "clean stop"
	ss -ltn "sport = :$port" | grep -q LISTEN && row V9-10 FAIL "port $port still open after the stop" || row V9-10 PASS "VNC port closed with the VM"
	dmesg | tail -n 80 | grep -E 'BUG|WARNING|Oops|SError|Internal error' | grep -vE 'gvm: |vm-run: |iceland-combo' && row K1 FAIL "host kernel warnings" || row K1 PASS "no host kernel warnings"
}

v10_score() { grep -m1 -E "$2" "$1" 2>/dev/null | grep -oE '[0-9]+' | tail -n1; }   # $1 file, $2 line pattern

v10() {   # parity step 3: the 3D modes compared on one VM (virgl + venus, GuestAccept): virgl GL, Vulkan through venus, GL
	# through zink over venus, llvmpipe; GuestAccept cost per blob (GVM-ACCEPT-STATS) to decide on DroidVM-style pools
	[ "${GVM_V1B_PASSED:-0}" = 1 ] || die "V10 needs V1b PASS first (GVM_V1B_PASSED=1)"
	export GVM_CTX=virgl:virgl2 GVM_VENUS=1
	v4_guest                                       # display manager stopped (offscreen benchmarks)
	G 'rpm -q vkmark vulkan-tools mesa-vulkan-drivers > /dev/null || sudo dnf -y -q install vkmark vulkan-tools mesa-vulkan-drivers' > "$L/v10-dnf.txt" 2>&1
	G 'vulkaninfo --summary 2>&1 | grep -iE "deviceName|driverName|apiVersion" | head -n 6' > "$L/v10-vulkaninfo.txt" 2>&1
	grep -qi venus "$L/v10-vulkaninfo.txt" && row V10-0 PASS "venus Vulkan device: $(tr -s ' \n' ' ' < "$L/v10-vulkaninfo.txt" | cut -c1-160)" \
		|| row V10-0 FAIL "no venus device: $(tr -s ' \n' ' ' < "$L/v10-vulkaninfo.txt" | cut -c1-160)"
	local GLB='-b build:use-vbo=true -b texture -b shading -b bump -b effect2d -b refract -b conditionals'
	# V10-1 virgl GL (the default 3D mode)
	G "sudo timeout 300 glmark2-es2-drm --off-screen $GLB 2>&1 | tail -n 14" > "$L/v10-glmark2-virgl.txt" 2>&1
	local sv; sv=$(v10_score "$L/v10-glmark2-virgl.txt" 'glmark2 Score')
	[ -n "$sv" ] && row V10-1 PASS "glmark2 virgl: $sv" || row V10-1 FAIL "glmark2 virgl: no score ($(grep -m1 -iE 'error|fail' "$L/v10-glmark2-virgl.txt" | cut -c1-100))"
	# V10-2 Vulkan through venus (host-visible memory = runtime blobs through GuestAccept)
	local s0; s0=$(grep -ac 'GVM-ACCEPT-STATS' "$L/crosvm-stderr.txt")
	G 'timeout 300 vkmark --winsys headless -b vertex -b texture -b shading -b cube -b clear 2>&1 | tail -n 12' > "$L/v10-vkmark.txt" 2>&1
	local sk; sk=$(v10_score "$L/v10-vkmark.txt" 'vkmark Score')
	[ -n "$sk" ] && row V10-2 PASS "vkmark venus: $sk (host vkmark 34-36k, not comparable 1:1)" \
		|| row V10-2 FAIL "vkmark venus: no score ($(grep -m1 -iE 'error|fail|unsupported|winsys' "$L/v10-vkmark.txt" | cut -c1-120))"
	# V10-3 GL through zink over venus (the DroidVM-style GL path: no virgl GL)
	G 'MESA_LOADER_DRIVER_OVERRIDE=zink EGL_PLATFORM=surfaceless eglinfo -B 2>&1 | grep -m1 -iE "renderer"' > "$L/v10-zink-renderer.txt" 2>&1
	G "sudo env MESA_LOADER_DRIVER_OVERRIDE=zink timeout 300 glmark2-es2-drm --off-screen $GLB 2>&1 | tail -n 14" > "$L/v10-glmark2-zink.txt" 2>&1
	local sz; sz=$(v10_score "$L/v10-glmark2-zink.txt" 'glmark2 Score')
	if grep -qi zink "$L/v10-zink-renderer.txt" && [ -n "$sz" ]; then row V10-3 PASS "glmark2 zink over venus: $sz ($(cut -c1-90 "$L/v10-zink-renderer.txt"))"
	else row V10-3 FAIL "zink: ${sz:-no score}; renderer: $(head -c 120 "$L/v10-zink-renderer.txt")"; fi
	# V10-4 llvmpipe reference (same guest, same benchmarks)
	G "sudo env LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe timeout 300 glmark2-es2-drm --off-screen $GLB 2>&1 | tail -n 4" > "$L/v10-glmark2-llvmpipe.txt" 2>&1
	row V10-4 INFO "glmark2 llvmpipe: $(v10_score "$L/v10-glmark2-llvmpipe.txt" 'glmark2 Score'); virgl ${sv:-?} / zink ${sz:-?} / vkmark venus ${sk:-?}"
	# V10-5 GuestAccept cost (the case for pre-shared pools): stats since vkmark started
	local st; st=$(grep -a 'GVM-ACCEPT-STATS' "$L/crosvm-stderr.txt" | tail -n1 | sed 's/^.*GVM-/GVM-/')
	local nf; nf=$(grep -acE 'gvm-accept: (guest failed|could not take back|share of|.*timed out)' "$L/crosvm-stderr.txt")
	if [ -n "$st" ] && [ "$nf" = 0 ]; then row V10-5 PASS "GuestAccept without failures: $st ($(( $(grep -ac 'GVM-ACCEPT-STATS' "$L/crosvm-stderr.txt") - s0 )) stats lines during the benchmarks)"
	elif [ -z "$st" ]; then row V10-5 INFO "no runtime blob shares (nothing mapped host-visible memory)"
	else row V10-5 FAIL "$nf GuestAccept failures; $st"; fi
	v4_end V10
}

v11_net() {   # $1 = row prefix: TCP throughput guest -> host ("up") and host -> guest ("down") over the tap with python
	# sockets (nothing to install). The guest listens (the host's firewalld zone of the NM shared tap would refuse
	# connections to the host), the host connects; host CPU and crosvm's own CPU are sampled over the same 15 s.
	local id=$1 cp port=5201 res gip
	gip=$(guest_ip); cp=$(pgrep -x crosvm | head -n1)
	[ -n "$gip" ] && [ -n "$cp" ] || { row "$id-up" FAIL "no guest address or no crosvm"; return 1; }
	for dir in up down; do
		# guest: a one-shot server that sends for 15 s (up) or sinks until EOF (down)
		G "timeout 60 python3 -c 'import socket,time,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind((\"0.0.0.0\",$port)); s.listen(1)
c,_=s.accept(); b=b\"\\0\"*262144; n=0; t=time.time()
if \"$dir\"==\"up\":
    while time.time()-t<15: n+=c.send(b)
    c.shutdown(socket.SHUT_WR)
else:
    while True:
        r=c.recv(262144)
        if not r: break
        n+=len(r)
print(\"GUESTNET\",n)'" > "$L/v11-$id-$dir-guest.txt" 2>&1 &
		local gp=$!
		sleep 3
		local c0 h0 c1 h1 tck
		c0=$(awk '{print $14 + $15}' /proc/"$cp"/stat); h0=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5+$6}' /proc/stat)
		python3 - "$gip" "$port" "$dir" > "$L/v11-$id-$dir-host.txt" 2>&1 <<'PYEOF'
import socket, sys, time
host, port, d = sys.argv[1], int(sys.argv[2]), sys.argv[3]
c = socket.create_connection((host, port), timeout=30)
n = 0
t0 = time.time()
buf = b"\0" * 262144
if d == "up":
    while True:
        b = c.recv(262144)
        if not b:
            break
        n += len(b)
else:
    while time.time() - t0 < 15:
        n += c.send(buf)
    c.shutdown(socket.SHUT_WR)
    c.recv(1)
print("HOSTNET %s bytes=%d secs=%.2f" % (d, n, time.time() - t0))
PYEOF
		c1=$(awk '{print $14 + $15}' /proc/"$cp"/stat); h1=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5+$6}' /proc/stat)
		wait "$gp"
		tck=$(getconf CLK_TCK)
		res=$(awk -v l="$(grep -m1 '^HOSTNET' "$L/v11-$id-$dir-host.txt")" -v c0="$c0" -v c1="$c1" -v h0="$h0" -v h1="$h1" -v tck="$tck" -v n="$(nproc)" 'BEGIN{
			split(l, a, " "); split(a[3], b, "="); split(a[4], s, "="); split(h0, x, " "); split(h1, y, " ");
			if (s[2] <= 0) { print "no data"; exit }
			tot = y[1] - x[1]; idle = y[2] - x[2]; hc = 0; if (tot > 0) hc = (tot - idle) * 100 / tot;
			# fix run: a bare "tot > 0 ? ..." in the printf list is an output redirection to awk -> no numbers at all
			printf "%.1f MB/s (%.0f Mbit/s), crosvm CPU %.0f%% of one core, host CPU %.0f%% of %d cores", b[2] / s[2] / 1e6,
				b[2] * 8 / s[2] / 1e6, (c1 - c0) / tck / s[2] * 100, hc, n }')
		if grep -q '^HOSTNET' "$L/v11-$id-$dir-host.txt" && echo "$res" | grep -q 'MB/s'; then
			row "$id-$dir" PASS "$( [ "$dir" = up ] && echo "guest -> host" || echo "host -> guest" ): $res"
		else
			row "$id-$dir" FAIL "no transfer: $(tail -n1 "$L/v11-$id-$dir-host.txt" | cut -c1-100) | guest: $(tail -n1 "$L/v11-$id-$dir-guest.txt" | cut -c1-100)"
		fi
		port=$((port + 1))
	done
}

v11() {   # parity extra (c): crosvm network, userspace virtio-net vs vhost-net (--net ...,vhost-net): throughput
	# and CPU both ways. vhost-net needs the host kernel's CONFIG_VHOST_NET (/dev/vhost-net); without it V11-V is NOT-RUN.
	[ "${GVM_V1B_PASSED:-0}" = 1 ] || die "V11 needs V1b PASS first (GVM_V1B_PASSED=1)"
	export GVM_RUNMODE=--simplefb GVM_NOGLAMOR=1      # no GPU work in the way
	v4_guest
	v11_net V11-U
	clean_stop; wait
	modprobe vhost_net 2> /dev/null
	if [ -c /dev/vhost-net ]; then
		export GVM_VHOST_NET=1
		v4_guest
		v11_net V11-V
		grep -aq 'vhost' "$L/crosvm-stderr.txt" && row V11-V0 INFO "crosvm: $(grep -a -m1 -i 'vhost' "$L/crosvm-stderr.txt" | sed 's/^.*\] //' | cut -c1-140)"
		clean_stop; wait
		unset GVM_VHOST_NET
	else
		row V11-V NOT-RUN "no /dev/vhost-net: the host kernel has no CONFIG_VHOST_NET (kernel-iceland q90r: not set)"
	fi
	dmesg | tail -n 80 | grep -E 'BUG|WARNING|Oops|SError|Internal error' | grep -vE 'gvm: |vm-run: |iceland-combo' && row K1 FAIL "host kernel warnings" || row K1 PASS "no host kernel warnings"
}

pvm_boot() {   # $1 = row prefix: the boot shim's lines in crosvm's log (GH-SHIM) -> rows
	local e=$L/crosvm-stderr.txt
	grep -a 'GH-SHIM' "$e" | sed 's/^.*\] //' > "$L/$1-shim.txt"
	# the shim's own console bytes (it writes "SHIM ..." to the 8250 before Linux runs)
	# pvm49: only THIS run's console bytes (the console file keeps every earlier boot), every SHIM line, in order
	tail -c +$((${PVM_C0:-0} + 1)) "$L/console-run.txt" 2> /dev/null | grep -a 'SHIM' | tr -d '\r' > "$L/$1-shim-console.txt"
	[ -s "$L/$1-shim-console.txt" ] && row "$1-0" INFO "shim console ($(wc -l < "$L/$1-shim-console.txt") lines, last: $(tail -n1 "$L/$1-shim-console.txt" | cut -c1-120)): $(tr '\n' '|' < "$L/$1-shim-console.txt" | cut -c1-900)"
	grep -a 'GVM-PAGE-FAULT' "$e" | head -n 3 | sed 's/^.*\] //' > "$L/$1-pagefault.txt"
	[ -s "$L/$1-pagefault.txt" ] && row "$1-0F" INFO "host could not back a guest access: $(tr '\n' ' ' < "$L/$1-pagefault.txt" | cut -c1-200)"
	local w; w=$(grep -a -m1 'shared as .* parcel' "$L/$1-shim.txt")
	[ -n "$w" ] && row "$1-1" PASS "window shared after VM start: ${w#GH-SHIM: }" || row "$1-1" FAIL "no window share line: $(grep -a 'GH-SHIM\|GH_VM\|error' "$e" | tail -n2 | sed 's/^.*\] //' | tr '\n' ' ' | cut -c1-160)"
	if grep -q 'handing over to the payload' "$L/$1-shim.txt"; then
		row "$1-2" PASS "boot shim: $(grep -c . "$L/$1-shim.txt") GH-SHIM lines, accepted, /memory rewritten, jumped to the kernel"
	else
		row "$1-2" FAIL "boot shim did not hand over: $(grep -a 'gave up\|nothing written\|status' "$L/$1-shim.txt" | tail -n1 | cut -c1-160)"
	fi
}

pvm_disk() {   # $1 = row id: 256 MiB written with fsync and re-read cold, contents compared, write speed reported
	local io; io=$(G 'f=/var/tmp/pv-io; dd if=/dev/urandom of=$f bs=1M count=256 conv=fsync 2>&1 | tail -n1; a=$(md5sum < $f); sudo sh -c "echo 3 > /proc/sys/vm/drop_caches"; t0=$(date +%s%N); b=$(md5sum < $f); t1=$(date +%s%N); rm -f $f; echo "READ $(( 256 * 1000000000 / (t1 - t0 + 1) )) MB/s"; [ "$a" = "$b" ] && echo SAME || echo DIFF' 2>&1 | tr '\n' ' ')
	echo "$io" | grep -q SAME && row "$1" PASS "virtio-blk 256 MiB write + cold re-read identical: write $(echo "$io" | grep -oE '[0-9.]+ [MG]B/s' | head -n1), cold read $(echo "$io" | grep -oE 'READ [0-9]+ MB/s' | cut -d' ' -f2-)" \
		|| row "$1" FAIL "disk I/O: $(echo "$io" | cut -c1-140)"
}

pvm_guest() {   # $1 = row prefix: guest-side checks over ssh (needs G from v4_guest)
	if ! G true 2> /dev/null; then
		local r; for r in 3 4 5 6; do row "$1-$r" NOT-RUN "no guest (ssh failed): see $1-2"; done
		return 0
	fi
	local mt; mt=$(G 'awk "/MemTotal/{print int(\$2/1024)}" /proc/meminfo' 2>/dev/null)
	[ -n "$mt" ] && [ "$mt" -ge $((MEM * 85 / 100)) ] && row "$1-3" PASS "guest MemTotal $mt MiB of --mem $MEM (window = guest RAM)" \
		|| row "$1-3" FAIL "guest MemTotal ${mt:-?} MiB, want >= 85 % of $MEM"
	local rd; rd=$(G 'ls /proc/device-tree/reserved-memory 2>/dev/null | grep -ci restricted; sudo dmesg | grep -ci "restricted.*dma\|swiotlb.*restricted"; echo PV4-OK' 2>/dev/null)
	echo "$rd" | grep -q PV4-OK && rd=$(echo "$rd" | grep -v PV4-OK | awk '{n += $1} END {print n + 0}') || rd=""
	[ "${rd:-1}" = 0 ] && row "$1-4" PASS "no restricted DMA pool in the guest (no bounce buffers)" || row "$1-4" FAIL "restricted DMA pool still present (${rd:-?} hits)"
	pvm_disk "$1-5"
	v11_net "$1-N"      # release: network throughput guest <-> host in this mode (compare PV-R-N)
	# PV-6: the warning in the app is true: the host finds a marker the guest wrote into its RAM (tmpfs)
	local mk; mk="ICELAND-PV6-$(od -An -tx8 -N8 /dev/urandom | tr -d ' ')"
	G "printf '%s' '$mk' > /dev/shm/pv6; sync" 2>/dev/null
	local wl; wl=$(grep -a -m1 'shared as .* parcel' "$L/crosvm-stderr.txt")
	local ws hs pid; ws=$(echo "$wl" | grep -oE 'window 0x[0-9a-f]+\+0x[0-9a-f]+' | cut -d+ -f2); hs=$(echo "$wl" | grep -oE 'host=0x[0-9a-f]+' | cut -d= -f2)
	pid=$(pgrep -x crosvm | head -n1)
	if [ -n "$ws" ] && [ -n "$hs" ] && [ -n "$pid" ]; then
		local r; r=$(python3 "$D/gvm-memscan.py" "$pid" "$hs" "$ws" "$mk" 2>&1)
		echo "$r" | grep -q '^FOUND' && row "$1-6" PASS "host read the guest's marker from crosvm's window mapping ($r): shared mode really is host-readable" \
			|| row "$1-6" FAIL "marker not found in the window: $r"
	else
		row "$1-6" FAIL "no window host address / crosvm pid (${wl:-no line})"
	fi
	G 'rm -f /dev/shm/pv6' 2>/dev/null
}

pvm() {   # parity step 4: the opt-in shared memory mode (DroidVM pseudo-unprotected: boot shim + window shared after
	# VM start). PV-A: simplefb guest (no GPU); PV-B (GVM_PVM_3D=1): virgl 3D + GuestAccept blobs in the same mode.
	# Then PV-R: the default protected mode still boots (regression).
	[ "${GVM_V1B_PASSED:-0}" = 1 ] || die "PVM needs V1b PASS first (GVM_V1B_PASSED=1)"
	"$CROSVM" run --help 2>&1 | grep -q 'protected-vm-pseudo-unprotected' || die "crosvm has no --protected-vm-pseudo-unprotected"
	local d0; d0=$(dmesg | wc -l)
	export GVM_PVM=1 GVM_RUNMODE=--simplefb GVM_NOGLAMOR=1 GVM_NODIE=1 CROSVM_GVM_FAULT_INJECT=1
	PVM_C0=$(stat -c %s "$L/console-run.txt" 2> /dev/null || echo 0)
	v4_guest || say "pvm: no guest in the shared memory mode (rows below say why)"
	pvm_boot PV-A; pvm_guest PV-A
	clean_stop; wait
	grep -a 'could not take back\|reclaim' "$L/crosvm-stderr.txt" | tail -n2 | sed 's/^.*\] //' > "$L/pv-a-end.txt"
	[ -s "$L/pv-a-end.txt" ] && row PV-A-7 FAIL "teardown: $(tr '\n' ' ' < "$L/pv-a-end.txt" | cut -c1-140)" || row PV-A-7 PASS "clean stop, nothing left shared"
	if [ "${GVM_PVM_3D:-0}" = 1 ]; then
		export GVM_RUNMODE=--gpu3d
		PVM_C0=$(stat -c %s "$L/console-run.txt" 2> /dev/null || echo 0)
		v4_guest || say "pvm: no 3D guest in the shared memory mode"
		pvm_boot PV-B
		local gm; gm=$(G 'timeout 120 glmark2-es2-drm --off-screen -b build:use-vbo=true -b texture -b shading 2>&1 | grep -i score' 2>/dev/null)
		[ -n "$gm" ] && row PV-B-3 PASS "virgl GL in shared mode: $gm" || row PV-B-3 FAIL "glmark2 gave no score"
		grep -a 'GVM-ACCEPT-STATS' "$L/crosvm-stderr.txt" | tail -n1 | sed 's/^.*\] //' | cut -c1-160 > "$L/pv-b-acc.txt"
		[ -s "$L/pv-b-acc.txt" ] && row PV-B-4 INFO "$(cat "$L/pv-b-acc.txt")"
		v4_end PV-B
	fi
	unset GVM_PVM GVM_NODIE CROSVM_GVM_FAULT_INJECT; export GVM_RUNMODE=--simplefb
	v4_guest
	row PV-R PASS "the default protected mode still boots (ssh up, no GH-SHIM lines: $(grep -ac 'GH-SHIM' "$L/crosvm-stderr.txt"))"
	if G true 2> /dev/null; then pvm_disk PV-R-5; v11_net PV-R-N; fi    # release: the protected-mode numbers to compare
	clean_stop; wait
	dmesg | tail -n +$((d0 + 1)) | grep -E 'BUG|WARNING|Oops|SError|Internal error' | grep -vE 'gvm: |vm-run: |iceland-combo' && row K1 FAIL "host kernel warnings" || row K1 PASS "no host kernel warnings"
}

bis() {   # v6 regression bisect: one VM with the given crosvm (GVM_CROSVM) and guest Image (GVM_IMAGE)
	[ "${GVM_V1B_PASSED:-0}" = 1 ] || die "BIS needs V1b PASS first (GVM_V1B_PASSED=1)"
	local id=${GVM_BIS_ID:-BIS}
	export GVM_CTX=${GVM_CTX:-virgl:virgl2} GVM_VENUS=${GVM_VENUS:-1} GVM_AUTOLOGIN=1 GVM_NOGLAMOR=1
	export GVM_TITLE="gvm: $id" CROSVM_GVM_DUMP_FRAME=$L/frames-$id CROSVM_GVM_DUMP_EVERY=3 CROSVM_GVM_DUMP_MAX=60
	rm -rf "$L/frames-$id"; mkdir -p "$L/frames-$id"
	row "$id-0" INFO "crosvm $(sha256sum "$CROSVM" | cut -c1-12) ($CROSVM), guest Image $(sha256sum "$IMAGE" | cut -c1-12) ($IMAGE)"
	v4_guest
	v6_pkg kmscube
	local n; n=$(wc -l < "$L/crosvm-stderr.txt"); G 'sleep 20 | sudo timeout 15 kmscube -D /dev/dri/card0 2>&1 | tail -n 3' > "$L/$id-1.txt" 2>&1
	sleep 2; v6_alive "$id-1" || { v4_end "$id"; return 0; }; v6_frame "$id-1" "$n" "kmscube (GL via virgl)"
	n=$(wc -l < "$L/crosvm-stderr.txt"); G 'sudo systemctl start display-manager'; sleep 45
	if v6_alive "$id-2"; then row "$id-2" PASS "guest alive 45 s after the Xorg (glamor off) desktop start"; v6_frame "$id-3" "$n" "Xorg desktop (glamor off)"; fi
	# "gvm-accept: dma-buf share ... failed (EINVAL), trying the mapping" is the documented fallback (same in the
	# passing v5 run, the accept then succeeds): not an error; vcpu / other os errors are
	grep -a 'vcpu hit\|os error' "$L/crosvm-stderr.txt" | grep -v 'trying the mapping' | tail -n 2 | sed 's/^.*\] //' > "$L/$id-err.txt"
	[ -s "$L/$id-err.txt" ] && row "$id-E" FAIL "crosvm: $(tr '\n' ' ' < "$L/$id-err.txt" | cut -c1-160)" || row "$id-E" PASS "no vcpu / os errors from crosvm"
	crosvm_running && v4_end "$id"
	return 0
}

w1() {   # Windows track W1: the ACPI + ECAM edk2-gunyah firmware boots on crosvm with ECAM and the simplefb screen
	guard; load
	local fw=${GVM_FW:-$D/firmware/edk2-gunyah-ecam-debug.fd} con=$L/console-w1.txt img=$R/w1-empty.raw
	[ -f "$fw" ] || die "no firmware $fw"
	need_mem 4096
	crosvm_running && die "another crosvm is running"; rm -f "$SOCK" "$con"
	truncate -s 1G "$img"
	mv -f "$L/crosvm-stderr.txt" "$L/crosvm-stderr.prev.txt" 2>/dev/null
	export CROSVM_GVM_PCI_ECAM=1 CROSVM_GVM_WINDOW_TITLE="gvm: W1 firmware" CROSVM_GVM_APP_ID=org.iceland.VirtualMachines
	say "w1: firmware $fw ($(sha256sum "$fw" | cut -c1-12)), ECAM, simplefb, 4 vCPU / 4096 MiB / swiotlb 256"
	SWIOTLB=256 timeout 150 "$CROSVM" --log-level info $(SWIOTLB=256 base_args 4 4096) \
		--serial type=file,path=$con,hardware=serial,num=1,console,earlycon --block "$img" \
		--simplefb width=1600,height=1000 --wayland-sock "$(wl_sock)" "$fw" \
		>> "$L/crosvm-stdout.txt" 2>> "$L/crosvm-stderr.txt" &
	local pid=$! t=0
	while [ $t -lt 120 ] && kill -0 $pid 2>/dev/null; do
		grep -aqE 'Shell>|UEFI Interactive Shell|BdsDxe: No bootable option|Boot0' "$con" 2>/dev/null && break
		sleep 2; t=$((t + 2))
	done
	sleep 10
	grep -aiE 'RestrictedDmaPool|RDMA' "$con" | head -n 3 > "$L/w1-rdma.txt"
	[ -s "$L/w1-rdma.txt" ] && row W1-1 PASS "restricted DMA pool published to ACPI: $(head -n1 "$L/w1-rdma.txt" | cut -c1-120)" \
		|| row W1-1 FAIL "no RestrictedDmaPool / RDMA0000 line in the debug log"
	grep -aiE 'PciBus|PciRoot|PciHostBridge|Ecam|MCFG' "$con" | head -n 6 > "$L/w1-pci.txt"
	grep -aqiE 'PciBus: Discovered PCI|PciBus:.*Discovered' "$con" && row W1-2 PASS "PCI enumeration over ECAM: $(grep -aciE 'Discovered PCI' "$con") devices" \
		|| row W1-2 FAIL "no PCI device discovered (ECAM root not found?): $(head -n2 "$L/w1-pci.txt" | tr '\n' ' ' | cut -c1-120)"
	grep -aqiE 'MCFG' "$con" && row W1-3 PASS "MCFG table in the ACPI build log" || row W1-3 INFO "no MCFG line in the debug log (check the table dump)"
	grep -aqiE 'SimpleFb|simple-framebuffer|GraphicsOutput' "$con" && row W1-4 PASS "GOP on the simple framebuffer: $(grep -aim1 'SimpleFb' "$con" | cut -c1-100)" \
		|| row W1-4 FAIL "no SimpleFb GOP line"
	local fr; fr=$(grep -a 'GVM-SIMPLEFB-FRAME' "$L/crosvm-stderr.txt" | tail -n1 | grep -oE 'mean=[0-9.]+ nonzero=[0-9.]+')
	awk -v n="$(echo "$fr" | grep -oE 'nonzero=[0-9.]+' | cut -d= -f2)" 'BEGIN{exit !(n > 0.005)}' \
		&& row W1-5 PASS "the firmware screen is drawn in the shared framebuffer ($fr)" || row W1-5 FAIL "firmware screen black (${fr:-no frame line})"
	grep -aqE 'Shell>|UEFI Interactive Shell|BdsDxe|Boot0' "$con" && row W1-6 PASS "BDS / shell reached: $(grep -aE 'Shell>|BdsDxe|Boot0' "$con" | tail -n1 | cut -c1-100)" \
		|| row W1-6 FAIL "BDS not reached in 120 s"
	kill -0 $pid 2>/dev/null && row W1-7 PASS "crosvm alive" || row W1-7 FAIL "crosvm exited: $(grep -a 'GVM-EXIT\|vcpu hit\|error' "$L/crosvm-stderr.txt" | tail -n1 | sed 's/^.*\] //' | cut -c1-120)"
	"$CROSVM" stop "$SOCK" > /dev/null 2>&1; sleep 3; kill $pid 2>/dev/null; wait $pid 2>/dev/null
	rm -f "$img"
	dmesg | tail -n 80 | grep -E 'BUG|WARNING|Oops|SError|Internal error' | grep -vE 'gvm: |vm-run: |iceland-combo' && row K1 FAIL "host kernel warnings" || row K1 PASS "no host kernel warnings"
}

# ---- Windows 11 ARM64 (a prepared route A image, see the Windows image build notes) -------------------------------
# W2 boot off viostor-rdma, W3 first boot (specialize + OOBE, unattended) -> DHCP + RDP / ssh, W4 network + display +
# clean power off, W5 x86 / x64 emulation, W6 soak + restart (GVM_WIN_SOAK_MIN, default 0 = skipped).
# Windows reboots during setup (PSCI SYSTEM_RESET: crosvm exits, "GVM-EXIT type=2|3"): crosvm is started again, as the app does.
WIN_MAC=${GVM_WIN_MAC:-0a:1c:47:56:4d:02}
win_img() { echo "${GVM_WIN_IMAGE:-$(getent passwd "$(caller_user)" | cut -d: -f6)/.local/share/gvm/images/win11-arm64.raw}"; }
win_start() {   # starts crosvm in the background: sets wpid; $1 = boot number
	local fw=$1 net=""
	# v10d: crosvm's log goes to persistent storage ($WL; /run is lost when the host freezes, v10c) and is linked
	rm -f "$SOCK"; [ -s "$WL/crosvm-stderr.txt" ] && mv -f "$WL/crosvm-stderr.txt" "$WL/crosvm-stderr.boot$wboot.txt"
	: > "$WL/crosvm-stderr.txt"; ln -sfn "$WL/crosvm-stderr.txt" "$L/crosvm-stderr.txt"
	[ "${GVM_WIN_NET:-0}" = 1 ] && net="--net tap-name=$TAP,mac=$WIN_MAC"
	export CROSVM_GVM_PCI_ECAM=1 CROSVM_GVM_WINDOW_TITLE="gvm: Windows 11" CROSVM_GVM_APP_ID=org.iceland.VirtualMachines
	# v10c: a core dump on a crash (v10b: SIGBUS, "resource limits disable core dumping"), without the guest RAM
	# (shared memfd = coredump_filter bit 1 off; lent pages would fault again): private anonymous + ELF headers
	local ws; ws=$(wl_sock)
	(ulimit -c unlimited; echo 0x11 > /proc/self/coredump_filter
	 exec "$CROSVM" --log-level info $(SWIOTLB=256 base_args "$wcpu" "$wmem") \
		--serial type=file,path=$wcon,hardware=serial,num=1,console,earlycon --block "$wimg${GVM_BLK_OPTS:+,$GVM_BLK_OPTS}" \
		$net --simplefb width=${GVM_W:-1600},height=${GVM_H:-1000} --wayland-sock "$ws" "$fw" \
		>> "$L/crosvm-stdout.txt" 2>> "$WL/crosvm-stderr.txt") &
	wpid=$!; wboot=$((wboot + 1)); say "win: boot $wboot, crosvm pid $wpid, network $([ -n "$net" ] && echo on || echo off)"
	win_sampler "$wpid" &
}
win_sampler() {   # $1 = crosvm pid: one line per second, fsynced, so the last state before a host freeze survives
	local p=$1 f=$WL/sample.log t
	while kill -0 "$p" 2>/dev/null; do
		{
			printf '%s load %s mem %s' "$(date +%T.%N | cut -c1-12)" "$(cut -d' ' -f1-3 /proc/loadavg)" "$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)"
			printf ' guard %s rx %s' "$(grep -ac 'GVM-DMA-GUARD #' "$WL/crosvm-stderr.txt")" "$(awk -v d="$TAP:" '$1 == d {print $2 "/" $10}' /proc/net/dev)"
			# per crosvm thread: name:state:cpu time:the CPU it last ran on (v10j: which physical CPU locks up)
			for t in /proc/$p/task/*; do printf " %s" "$(awk -v c="$(cat "$t/comm" 2>/dev/null)" '{print c ":" $3 ":" $14 + $15 ":cpu" $39}' "$t/stat" 2>/dev/null)"; done
			# arch timer interrupts per CPU: a CPU stuck in the hypervisor stops counting
			printf " timer %s" "$(awk '/arch_timer/ {s = ""; for (i = 2; i <= 9; i++) s = s $i ","; print s; exit}' /proc/interrupts)"
			# v10k: cumulative kprobe hits (scm assign / demand page / donate) and the 2 MiB shmem folios in use
			printf " probes %s shmemhuge %s" "$(awk '$1 ~ /^gvmw_/ {printf "%s,", $2}' /sys/kernel/tracing/kprobe_profile 2>/dev/null)" \
				"$(awk '/ShmemHugePages/ {print $2}' /proc/meminfo)"
			echo
		} >> "$f" 2>/dev/null
		sync "$f" "$WL/crosvm-stderr.txt" 2>/dev/null
		sleep 1
	done
}
win_wait() {   # $1 = seconds, $2 = condition command; restarts crosvm after a guest reset; 0 = condition met
	local t=0 lim=$1; shift
	while [ $t -lt "$lim" ]; do
		"$@" && return 0
		if ! kill -0 "$wpid" 2>/dev/null; then
			wait "$wpid" 2>/dev/null
			if grep -a 'GVM-EXIT type=' "$L/crosvm-stderr.txt" | tail -n1 | grep -q 'type=[23] '; then
				[ $wboot -ge 8 ] && { say "win: 8 boots, giving up"; return 2; }
				win_start "$wfw"
			else say "win: crosvm exited ($(grep -a 'GVM-EXIT\|vcpu hit\|rror' "$L/crosvm-stderr.txt" | tail -n1 | sed 's/^.*\] //' | cut -c1-100))"; return 2; fi
		fi
		grep -aq 'vcpu hit unknown error' "$L/crosvm-stderr.txt" && return 3
		sleep 5; t=$((t + 5))
	done
	return 1
}
win_ip() { awk -v m="$WIN_MAC" 'tolower($2) == m {print $3}' /var/lib/NetworkManager/dnsmasq-$TAP.leases 2>/dev/null | tail -n1; }
WG() { sudo -u "$(caller_user)" ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=4 "${GVM_WIN_USER:-gvm}@$wip" "$@"; }
win_rdp_open() { wip=$(win_ip); [ -n "$wip" ] && timeout 3 bash -c "</dev/tcp/$wip/3389" 2>/dev/null; }
win_ssh_ok() { wip=$(win_ip); [ -n "$wip" ] && WG ver > "$L/win-ver.txt" 2>&1; }
win_gone() { ! kill -0 "$wpid" 2>/dev/null; }
win() {
	guard; load
	wimg=$(win_img); wfw=${GVM_FW:-$D/firmware/edk2-gunyah-ecam-release.fd}; wcon=$L/console-win.txt
	# v10d safety defaults after the v10c host freeze: 2 vCPUs pinned to 6-7 (vm-run moves the IRQs off them),
	# 3 GiB, no network unless GVM_WIN_NET=1 (the freeze came 5 s after the first DHCP exchange), crosvm's DMA
	# guard on (descriptors outside the swiotlb are refused, GVM-DMA-GUARD), logs + a 1 s sample on disk
	# v10l (WINH1 PASS): the host freezes were the 4 KiB on-demand lend storm (a TrustZone call per page); guest
	# RAM in 2 MiB THP folios is the default now (GVM_HUGEPAGES=0 = the old 4 KiB lends), 4 vCPU / 4 GiB unpinned
	wmem=${GVM_WIN_MEM:-4096}; wcpu=${GVM_WIN_CPUS:-4}; wboot=0; wpid=; wip=
	export GVM_HUGEPAGES=${GVM_HUGEPAGES:-1}
	export GVM_AFFINITY=${GVM_AFFINITY-}      # set = pinned (e.g. 6,7); default unpinned
	WL=/var/lib/gvm/win-log-$(date +%Y%m%d-%H%M%S); mkdir -p "$WL"; ln -sfn "$WL" "$L/win-log"
	local soak=${GVM_WIN_SOAK_MIN:-0} pr k0 rd fr r
	[ -f "$wfw" ] || die "no firmware $wfw"
	[ -f "$wimg" ] || die "no Windows image $wimg (tablet/winvm/win-image-transfer.sh)"
	SWIOTLB=256 need_mem "$wmem"
	crosvm_running && die "another crosvm is running"
	pr=${wimg%.raw}.pristine.raw
	if [ ! -e "$pr" ]; then cp --reflink=always "$wimg" "$pr" 2>/dev/null && say "win: pristine reflink copy $pr" || say "win: no reflink copy (not btrfs?): no pristine copy kept"
	elif [ "${GVM_WIN_KEEP:-0}" != 1 ]; then
		# v10j: every run starts from the pristine image (a freeze mid-setup left Windows' first boot half done:
		# "The computer restarted unexpectedly ... installation cannot proceed"); GVM_WIN_KEEP=1 keeps the disk
		cp --reflink=always "$pr" "$wimg" 2>/dev/null || cp --sparse=always "$pr" "$wimg" || die "cannot reset $wimg from $pr"
		say "win: disk reset from the pristine copy $pr"
	fi
	# the image the run used: the pristine copy's sha256 (computed once, ~2 min for the 48 GiB sparse file)
	[ -s "$pr.sha256" ] || { [ -e "$pr" ] && sha256sum "$pr" | cut -d' ' -f1 > "$pr.sha256"; }
	row W-IMG INFO "disk $(basename "$wimg") from pristine sha256 $(cut -c1-16 "$pr.sha256" 2>/dev/null || echo ?) ($([ "${GVM_WIN_KEEP:-0}" = 1 ] && echo kept || echo reset)); disk io ${GVM_BLK_OPTS:-epoll}"
	[ "${GVM_WIN_NET:-0}" = 1 ] && net_up
	k0=$(dmesg | wc -l); rm -f "$wcon"
	say "win: $wimg, firmware $(basename "$wfw") ($(sha256sum "$wfw" | cut -c1-12)), ECAM, simplefb, $wcpu vCPU (affinity $GVM_AFFINITY) / $wmem MiB / swiotlb 256, logs $WL"
	thp_prep                 # GVM_HUGEPAGES=1: 2 MiB shmem folios, lent as 2 MiB blocks
	win_probes on
	wt0=$(date +%s)
	win_start "$wfw"
	# W2: the Windows kernel boots off viostor-rdma: crosvm alive 5 min, sustained disk reads, no lent-memory faults
	win_wait 300 false; r=$?
	rd=$(awk '/^read_bytes/{print int($2/1048576)}' /proc/$wpid/io 2>/dev/null)
	if [ $r = 1 ] || [ $r = 0 ]; then
		grep -aqE 'host access to lent memory' "$L/crosvm-stderr.txt" && row W2 FAIL "host access to lent memory (viostor-rdma not used?)" \
			|| row W2 PASS "Windows up 5 min after $wboot boot(s), disk reads ${rd:-?} MiB this boot; serial: $(grep -aoE 'SAC|Computer is booting|EMS' "$wcon" | sort -u | tr '\n' ' ')"
	else row W2 FAIL "crosvm stopped during the boot (rc $r, boot $wboot): $(grep -a 'GVM-EXIT\|vcpu hit\|rror' "$L/crosvm-stderr.txt" | tail -n1 | sed 's/^.*\] //' | cut -c1-120)"; fi
	fr=$(grep -a 'GVM-SIMPLEFB-FRAME' "$L/crosvm-stderr.txt" | tail -n1 | grep -oE 'mean=[0-9.]+ nonzero=[0-9.]+')
	row W2-D INFO "screen (BasicDisplay on the GOP framebuffer): ${fr:-no frame line}"
	ps -T -p "$wpid" -o tid=,comm= > "$L/win-threads.txt" 2>/dev/null
	if [ $r -ge 2 ]; then win_crash; win_end "$k0"; return 0; fi
	if [ "${GVM_WIN_NET:-0}" != 1 ]; then   # v10d WINN: does it stay up without network? (soak, then stop)
		local nm=${GVM_WIN_NONET_MIN:-15}
		win_wait $((nm * 60)) false; r=$?
		if [ $r = 1 ]; then row W2-N PASS "alive $nm more min without network (boots: $wboot, DMA-guard refusals: $(grep -ac 'GVM-DMA-GUARD #' "$WL/crosvm-stderr.txt"))"
		else row W2-N FAIL "crosvm ended without network after $(( $(date +%s) - wt0 )) s (boots: $wboot)"; win_crash; fi
		[ $r = 1 ] && win_display W-D
		row W-G INFO "DMA guard: $(grep -a 'GVM-DMA-GUARD' "$WL/crosvm-stderr.txt" | sed 's/^.*GVM-DMA-GUARD/GVM-DMA-GUARD/' | head -n 3 | tr '\n' ';' | cut -c1-240)"
		win_end "$k0"; return 0
	fi
	# W3: first boot done: DHCP lease + RDP port (40 min for specialize + OOBE + reboots), then ssh when the image has it
	if win_wait 2400 win_rdp_open; then
		row W3-1 PASS "first boot complete: lease $wip for the VM's MAC, RDP port open (boots: $wboot)"
		# v10m: the RDP server really answers (X.224 connection request with TLS + CredSSP; no credentials sent)
		local rdp
		rdp=$(python3 -c '
import socket, sys
req = bytes([3, 0, 0, 19, 14, 0xe0, 0, 0, 0, 0, 0, 1, 0, 8, 0, 3, 0, 0, 0])
s = socket.create_connection((sys.argv[1], 3389), 5); s.sendall(req); r = s.recv(64)
ok = len(r) >= 11 and r[0] == 3 and r[5] == 0xd0
proto = r[15] if len(r) >= 19 and r[11] == 2 else -1
print(("confirm" if ok else "no-confirm") + " protocol=%d bytes=%d" % (proto, len(r)))' "$wip" 2>&1 | tail -n1)
		case "$rdp" in confirm*) row W3-R PASS "RDP answers: X.224 connection confirm ($rdp; 1 = TLS, 2 = CredSSP/NLA)" ;;
			*) row W3-R FAIL "RDP port open but no X.224 confirm: $rdp" ;; esac
		if win_wait 600 win_ssh_ok; then
			row W3-2 PASS "ssh: $(tr -d '\r' < "$L/win-ver.txt" | grep -m1 -i 'windows' | cut -c1-80)"
			WG 'pnputil /enum-devices /connected' > "$L/win-pnp.txt" 2>&1
			# v10m: ask the service control manager per driver service (the INF AddService names); v10l's grep of the
			# pnputil text missed rdmapool / viostor / netkvm, whose device names do not contain the service name
			local svc st
			for svc in rdmapool viostor netkvm VirtioInput viohidkmdf pvmpower; do
				st=$(WG "sc query $svc" 2>/dev/null | tr -d '\r' | awk '/STATE/ {print $4; exit}')
				echo "$svc=${st:-absent}"
			done > "$L/win-drv.txt"
			local nrun; nrun=$(grep -cE '^(rdmapool|viostor|netkvm|pvmpower|VirtioInput|viohidkmdf)=RUNNING$' "$L/win-drv.txt")
			row W3-3 "$(grep -qE '^(rdmapool|viostor|netkvm)=RUNNING$' "$L/win-drv.txt" && [ "$(grep -cE '^(rdmapool|viostor|netkvm)=RUNNING$' "$L/win-drv.txt")" = 3 ] && echo PASS || echo FAIL)" \
				"driver services ($nrun running): $(tr '\n' ' ' < "$L/win-drv.txt")"
		else row W3-2 FAIL "no ssh in 10 min (image without gvm-sshd.ps1, or no network for the OpenSSH capability)"; fi
	else
		r=$?; wip=$(win_ip)
		if [ $r = 1 ]; then row W3-1 FAIL "no RDP port in 40 min (lease: ${wip:-none}, boots: $wboot)"
		else row W3-1 FAIL "crosvm ended during the first boot after $(( $(date +%s) - wt0 )) s (lease: ${wip:-none}, boots: $wboot)"; win_crash; fi
		win_end "$k0"; return 0
	fi
	fr=$(grep -a 'GVM-SIMPLEFB-FRAME' "$L/crosvm-stderr.txt" | tail -n1 | grep -oE 'mean=[0-9.]+ nonzero=[0-9.]+')
	win_display W4-1
	if [ -s "$L/win-ver.txt" ] && grep -qi windows "$L/win-ver.txt"; then
		r=$(WG 'curl.exe -s -o NUL -w "%{http_code}" https://www.microsoft.com' 2>/dev/null | tr -d '\r')
		[ "$r" = 200 ] && row W4-2 PASS "guest HTTPS through the NAT (200)" || row W4-2 FAIL "guest HTTPS: ${r:-no answer}"
		# W5: emulation. x86 through the inbox SysWOW64 binaries; x64 only with GVM_WIN_X64 (a path in the guest)
		WG 'C:\Windows\SysWOW64\cmd.exe /c echo x86-ok' 2>&1 | tr -d '\r' | grep -q x86-ok && row W5-1 PASS "x86 emulation (SysWOW64 cmd.exe)" || row W5-1 FAIL "SysWOW64 cmd.exe did not run"
		if [ -n "${GVM_WIN_X64:-}" ]; then WG "$GVM_WIN_X64" > "$L/win-x64.txt" 2>&1 && row W5-2 PASS "x64 under Prism: $(tr -d '\r' < "$L/win-x64.txt" | tail -n1 | cut -c1-100)" || row W5-2 FAIL "x64 tool failed: $(tail -n1 "$L/win-x64.txt" | cut -c1-100)"
		else row W5-2 NOT-RUN "no x64 tool given (GVM_WIN_X64=<command in the guest>, from the owner's copy)"; fi
		[ "${GVM_WIN_LOAD_MIN:-0}" -gt 0 ] && win_load "$GVM_WIN_LOAD_MIN"
		if [ "$soak" -gt 0 ]; then   # W6: soak, then a restart through Windows
			local m=0; while [ $m -lt "$soak" ] && kill -0 "$wpid" 2>/dev/null; do WG 'C:\Windows\SysWOW64\cmd.exe /c ver' > /dev/null 2>&1; sleep 60; m=$((m + 1)); done
			if [ $m -ge "$soak" ]; then
				WG 'shutdown /r /t 0' > /dev/null 2>&1; sleep 20
				win_wait 900 win_ssh_ok && row W6 PASS "soak $soak min, then shutdown /r came back (boots: $wboot)" || row W6 FAIL "no ssh after shutdown /r"
			else row W6 FAIL "crosvm ended after $m of $soak min"; fi
		else row W6 NOT-RUN "soak skipped (GVM_WIN_SOAK_MIN=60 runs it)"; fi
		WG 'shutdown /s /t 0' > /dev/null 2>&1
		if win_wait 90 win_gone; then
			grep -a 'GVM-EXIT type=' "$L/crosvm-stderr.txt" | tail -n1 | grep -q 'type=[23] ' && row W4-3 FAIL "shutdown /s ended as a reset" || row W4-3 PASS "shutdown /s: crosvm exited (power off) in 90 s"
		else row W4-3 FAIL "still running 90 s after shutdown /s"; fi
	else row W4-2 NOT-RUN "no ssh: HTTPS / W5 / power-off rows need the image's OpenSSH"; fi
	row W-G INFO "DMA guard: $(grep -a 'GVM-DMA-GUARD' "$WL/crosvm-stderr.txt" | sed 's/^.*GVM-DMA-GUARD/GVM-DMA-GUARD/' | head -n 3 | tr '\n' ';' | cut -c1-240)"
	win_end "$k0"
}
win_display() {   # $1 = row id: the VM window screenshot (KWin) + the last simplefb frame statistics
	local r=$1 fr ps=""
	fr=$(grep -a 'GVM-SIMPLEFB-FRAME' "$L/crosvm-stderr.txt" | tail -n1 | grep -oE 't=[0-9]+s mean=[0-9.]+ nonzero=[0-9.]+')
	if command -v iceland-shot > /dev/null && iceland-shot --window "Windows 11" "$L/$r-window.png" > "$L/$r-shot.txt" 2>&1; then
		ps=$(python3 "$D/gvm-pngstat.py" "$L/$r-window.png" 2>&1)
	fi
	if [ -z "$ps" ]; then row "$r" INFO "no window screenshot ($(tail -n1 "$L/$r-shot.txt" 2>/dev/null | cut -c1-80)); last frame ${fr:-none}"
	elif awk -v n="$(echo "$ps" | grep -oE 'nonzero=[0-9.]+' | cut -d= -f2)" 'BEGIN{exit !(n > 0.3)}'; then
		row "$r" PASS "Windows drawn in the VM window ($ps; last frame $fr)"
	else row "$r" FAIL "VM window black ($ps; last frame ${fr:-none})"; fi
}
win_load() {   # $1 = minutes of CPU + disk load inside Windows over ssh (winsat), the host must stay up
	local m=$1 t0 n=0
	t0=$(date +%s)
	while [ $(( $(date +%s) - t0 )) -lt $((m * 60)) ] && kill -0 "$wpid" 2>/dev/null; do
		WG 'winsat cpuformal > NUL 2>&1 & winsat disk -drive c -seq -read > NUL 2>&1 & winsat mem > NUL 2>&1' > /dev/null 2>&1 && n=$((n + 1))
	done
	if kill -0 "$wpid" 2>/dev/null && win_ssh_ok; then row W6-L PASS "$m min of CPU / disk / memory load in Windows (winsat x$n), host and guest alive"
	else row W6-L FAIL "crosvm or ssh gone during the load (after $(( ($(date +%s) - t0) / 60 )) min, $n rounds)"; fi
}

win_crash() {   # after an unexpected crosvm end: the GVM-SIGBUS report (thread, address, the mapping it falls in)
	local l a t m
	l=$(grep -a 'GVM-SIGBUS signal' "$L/crosvm-stderr.txt" | tail -n1)
	if [ -z "$l" ]; then
		row W-CRASH INFO "crosvm ended without a GVM-SIGBUS report: $(grep -a 'GVM-EXIT\|vcpu hit\|rror' "$L/crosvm-stderr.txt" | tail -n1 | sed 's/^.*\] //' | cut -c1-120)"
		return 0
	fi
	a=$(echo "$l" | grep -oE 'addr 0x[0-9a-f]+' | cut -d' ' -f2); t=$(echo "$l" | grep -oE 'thread [^ ]+' | cut -d' ' -f2)
	m=$(awk -v a="$a" '/^[0-9a-f]+-[0-9a-f]+ / { split($1, r, "-"); if (strtonum("0x" r[1]) <= strtonum(a) && strtonum(a) < strtonum("0x" r[2])) { print; exit } }' "$L/crosvm-stderr.txt")
	row W-CRASH FAIL "crosvm $(echo "$l" | grep -oE 'signal 0x[0-9a-f]+' | sed 's/0x7$/SIGBUS/;s/0xb$/SIGSEGV/') at $a in thread $t; mapping: ${m:-none found}; threads: $(tr '\n' ' ' < "$L/win-threads.txt" 2>/dev/null | cut -c1-120)"
}
probe_hist() {   # from the trace sample: donation sizes and the guest 2 MiB regions that fault most
	local T=/sys/kernel/tracing
	awk '/gvmw_donate/ { f = ""; for (i = 1; i <= NF; i++) { if ($i ~ /^flags=/) f = substr($i, 7) "/"; if ($i ~ /^size=/) sz[f substr($i, 6)]++ } }
		/gvmw_dpage/ { for (i = 1; i <= NF; i++) if ($i ~ /^gpa=/) { g = strtonum(substr($i, 5)); r[sprintf("%x", int(g / 2097152) * 2097152)]++ } }
		END { printf "donate_flags/sizes:"; for (k in sz) printf " %s x%d", k, sz[k];
		      n = 0; printf " | top_fault_2M_regions:"; PROCINFO["sorted_in"] = "@val_num_desc";
		      for (k in r) { if (n++ >= 5) break; printf " 0x%s x%d", k, r[k] } }' $T/trace 2>/dev/null
}
probe_counts() {   # gvmw_* kprobe hits since win_probes on (kprobe_profile keeps counting across runs: v10l's
	# W-P showed 6.5M because the counters had run since an earlier group; the baseline is taken at "on")
	awk -v base="${PROBE_BASE:-}" 'BEGIN { n = split(base, b, " "); for (i = 1; i <= n; i++) { split(b[i], kv, "="); B[kv[1]] = kv[2] } }
		$1 ~ /^gvmw_/ { printf "%s=%d ", $1, $2 - B[$1] }' /sys/kernel/tracing/kprobe_profile 2>/dev/null
}
win_probes() {   # on|off: kprobe hit counters of the protected-VM memory path, sampled every second (v10k:
	# hypothesis = every guest page the host lends on demand costs a TrustZone call (qcom_scm_assign_mem in the
	# q90r Gunyah driver's pre_demand_page hook); Windows touches all its RAM at once -> a storm that stalls the host)
	local T=/sys/kernel/tracing
	[ -d $T/events ] || mount -t tracefs nodev $T 2>/dev/null
	if [ "$1" = on ]; then
		echo '-:gvmwin/gvmw_scm' >> $T/kprobe_events 2>/dev/null; echo '-:gvmwin/gvmw_dpage' >> $T/kprobe_events 2>/dev/null
		echo '-:gvmwin/gvmw_donate' >> $T/kprobe_events 2>/dev/null
		echo 'p:gvmwin/gvmw_scm qcom_scm_assign_mem' >> $T/kprobe_events 2>/dev/null
		# v10m: with arguments, so the end of the run can tell which guest region faults (dpage gpa) and how big the
		# donations are (4 KiB vs 2 MiB): a 4 MiB-per-CPU trace buffer keeps the last events (a sample)
		echo 'p:gvmwin/gvmw_dpage gunyah_demand_page gpa=$arg2:x64' >> $T/kprobe_events 2>/dev/null \
			|| echo 'p:gvmwin/gvmw_dpage gunyah_demand_page' >> $T/kprobe_events 2>/dev/null
		echo 'p:gvmwin/gvmw_donate gunyah_hypercall_memextent_donate flags=$arg1:x32 size=$arg5:x64' >> $T/kprobe_events 2>/dev/null \
			|| echo 'p:gvmwin/gvmw_donate gunyah_hypercall_memextent_donate' >> $T/kprobe_events 2>/dev/null
		echo 4096 > $T/buffer_size_kb 2>/dev/null; echo > $T/trace 2>/dev/null
		echo 1 > $T/events/gvmwin/enable 2>/dev/null
		say "win: kprobe counters $(grep -c gvmwin $T/kprobe_events 2>/dev/null) (scm assign, demand page, memextent donate)"
		PROBE_BASE=$(awk '$1 ~ /^gvmw_/ {printf "%s=%s ", $1, $2}' $T/kprobe_profile 2>/dev/null); export PROBE_BASE
	else
		echo 0 > $T/events/gvmwin/enable 2>/dev/null
		for e in scm dpage donate; do echo "-:gvmwin/gvmw_$e" >> $T/kprobe_events 2>/dev/null; done
		echo > $T/trace 2>/dev/null; echo 1408 > $T/buffer_size_kb 2>/dev/null   # give the buffer memory back
	fi
}
win_end() {   # $1 = dmesg line count at the start
	if kill -0 "$wpid" 2>/dev/null; then "$CROSVM" stop "$SOCK" > /dev/null 2>&1; sleep 10; kill "$wpid" 2>/dev/null; sleep 3; kill -9 "$wpid" 2>/dev/null; fi
	wait "$wpid" 2>/dev/null
	row W-P INFO "memory path totals: $(probe_counts) ShmemHugePages $(awk '/ShmemHugePages/ {print $2}' /proc/meminfo) kB"
	row W-PH INFO "$(probe_hist | cut -c1-300)"
	win_probes off
	row W-B INFO "boots $wboot; host MemAvailable $(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo) MiB after stop"
	dmesg | tail -n +$(($1 + 1)) | grep -E 'BUG|WARNING|Oops|SError|Internal error|rcu.*stall' | grep -vE 'gvm: |vm-run: |iceland-combo' && row K1 FAIL "host kernel warnings" || row K1 PASS "no host kernel warnings"
}

# ---- optimisation measurements (0.3-36): one Linux VM, the same workload, rows OPT-<tag>-* -----------------------
# GVM_OPT_TAG names the variant; the variant itself comes from the usual knobs: GVM_HUGEPAGES (lend size),
# GVM_BLK_OPTS / GVM_SWIOTLB (disk), GVM_AFFINITY / GVM_VMM_CPUS (placement). Every number is an INFO row
# "key=value ..."; vm-run prints the table of all variants at the end (OPT-TABLE).
opt_jitter() {   # host wake-up latency: 1 ms sleeps for $1 s -> p99 / max oversleep in ms (smoothness proxy)
	python3 -c '
import sys, time
end = time.monotonic() + float(sys.argv[1]); d = []
while time.monotonic() < end:
    t = time.monotonic(); time.sleep(0.001); d.append((time.monotonic() - t - 0.001) * 1000)
d.sort(); print("p99=%.2f max=%.2f n=%d" % (d[int(len(d) * 0.99)], d[-1], len(d)))' "$1"
}
thp_vm() {   # shmem THP counters (/proc/vmstat): file THP allocations and fallbacks to 4 KiB pages
	awk '$1 == "thp_file_alloc" {a = $2} $1 == "thp_file_fallback" {f = $2} END {print a + 0, f + 0}' /proc/vmstat
}
thp_delta() {   # $1 = output of thp_vm at the start ("alloc fallback")
	thp_vm | awk -v base="$1" '{ split(base, b, " "); printf "thp_file_alloc=+%d thp_file_fallback=+%d", $1 - b[1], $2 - b[2] }'
}
free2m() {   # free 2 MiB blocks in the host buddy allocator (order 9 + 2 x order 10)
	awk '$3 == "zone" { n += $14 + 2 * $15 } END { print n + 0 }' /proc/buddyinfo
}
opt() {
	[ "${GVM_V1B_PASSED:-0}" = 1 ] || die "OPT needs V1b PASS first (GVM_V1B_PASSED=1)"
	local tag=${GVM_OPT_TAG:-base} t0 t1 out
	export GVM_RUNMODE=--gpu GVM_TITLE="gvm: OPT $tag"
	say "opt $tag: hugepages=$GVM_HUGEPAGES blk='${GVM_BLK_OPTS:-}' swiotlb=$SWIOTLB vcpu-affinity='${GVM_AFFINITY:-}' vmm-cpus='${GVM_VMM_CPUS:-}' cpus=$CPUS mem=${GVM_MEM:-2048}"
	win_probes on
	# v10n: the v10m touch oddity (8-9 s with 80k TrustZone calls in H1 / Dd, 0.3 s with 1k in Du / Dw / Pp): are
	# the guest's pages 2 MiB THP or 4 KiB fallbacks? (shmem THP counters + free 2 MiB blocks before the start)
	local th0 f2; th0=$(thp_vm); f2=$(free2m)
	t0=$(date +%s.%N)
	v4_guest                                     # 2D window, display manager stopped
	t1=$(date +%s.%N)
	row "OPT-$tag-BOOT" INFO "boot_to_ssh_s=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }') hugepages=$GVM_HUGEPAGES blk=${GVM_BLK_OPTS:-default} swiotlb=$SWIOTLB affinity=${GVM_AFFINITY:-none} vmm=${GVM_VMM_CPUS:-all} free_2M_blocks_before=$f2 $(thp_delta "$th0")"
	row "OPT-$tag-LEND" INFO "after_boot $(probe_counts)"
	# memory: touch 1 GiB of fresh guest RAM (every touch of an unlent block = one lend)
	out=$(G 'python3 -c "import time; t = time.time(); b = bytearray(1 << 30); n = len(b)
for i in range(0, n, 4096): b[i] = 1
print(\"%.2f\" % (time.time() - t))"' 2>&1 | tail -n1)
	row "OPT-$tag-MEM" INFO "touch_1GiB_s=$out $(probe_counts) $(thp_delta "$th0") ShmemHugePages=$(awk '/ShmemHugePages/ {print $2}' /proc/meminfo)kB"
	# disk: 2 GiB sequential read of the disk, 1 GiB direct write + fsync
	local rd wr
	rd=$(G 'sudo sh -c "echo 3 > /proc/sys/vm/drop_caches; dd if=/dev/vda of=/dev/null bs=1M count=2048 iflag=direct 2>&1 | tail -n1"' 2>&1 | grep -oE '[0-9.,]+ [MG]B/s' | tail -n1)
	wr=$(G 'dd if=/dev/zero of=/var/tmp/gvm-opt bs=1M count=1024 oflag=direct conv=fsync 2>&1 | tail -n1; rm -f /var/tmp/gvm-opt' 2>&1 | grep -oE '[0-9.,]+ [MG]B/s' | tail -n1)
	row "OPT-$tag-DISK" INFO "read_2GiB=${rd:-?} write_1GiB_direct=${wr:-?}"
	# CPU: sha256 of 2 GiB per vCPU in parallel (guest throughput) while the host measures its wake-up latency
	local idle load cpu
	idle=$(opt_jitter 10)
	G "t=\$(date +%s%N); for i in \$(seq $CPUS); do (dd if=/dev/zero bs=1M count=2048 2>/dev/null | sha256sum > /dev/null) & done; wait; echo \$(( (\$(date +%s%N) - t) / 10000000 ))" > "$L/opt-$tag-cpu.txt" 2>&1 &
	local gp=$!
	sleep 2; load=$(opt_jitter 10); wait $gp
	cpu=$(tail -n1 "$L/opt-$tag-cpu.txt" | awk '$1 ~ /^[0-9]+$/ {printf "%.2f", $1 / 100}')   # centiseconds -> s
	row "OPT-$tag-CPU" INFO "sha256_${CPUS}x2GiB_s=${cpu:-?} MBps=$(awk -v n="$CPUS" -v s="${cpu:-0}" 'BEGIN { if (s > 0) printf "%d", n * 2048 / s; else print "?" }')"
	row "OPT-$tag-JIT" INFO "host_jitter_idle $idle | host_jitter_under_vm_load $load"
	G 'sudo systemctl start display-manager 2>/dev/null; true'
	clean_stop; wait
	row "OPT-$tag-TOTAL" INFO "lend totals $(probe_counts)"
	row "OPT-$tag-HIST" INFO "$(probe_hist | cut -c1-300)"
	win_probes off
	dmesg | tail -n 80 | grep -E 'BUG|WARNING|Oops|SError|Internal error' | grep -vE 'gvm: |vm-run: |iceland-combo' && row K1 FAIL "host kernel warnings" || row K1 PASS "no host kernel warnings"
}

case "$STEP" in
check) guard; crosvm_running && say "a crosvm is running" || say "no crosvm running" ;;
load) guard; load ;;
unload) unload ;;
v1) v1 v1 ;;
v1b) v1 v1b ;;
shell) v1 shell ;;
net-up) net_up ;;
net-down) net_down ;;
seed) seed ;;
v2) v2 ;;
run) run_vm "${1:-}" ;;
v3) v3 ;;
v4) v4 ;;
v4n) v4n ;;
v5) v5 ;;
v6) v6 ;;
v8) v8 ;;
vin) vin ;;
vin-rot-restore) [ "$(id -u)" = 0 ] || die "not root"; vin_rot_restore ;;
v9) v9 ;;
v10) v10 ;;
v11) v11 ;;
pvm) pvm ;;
bis) bis ;;
w1) w1 ;;
win) win ;;
opt) opt ;;
stop) [ "$(id -u)" = 0 ] || die "not root"; clean_stop ;;
make-pristine) make_pristine "${1:-}" ;;
reset-disk) reset_disk ;;
*) sed -n '3,47p' "$0"; exit 2 ;;
esac
