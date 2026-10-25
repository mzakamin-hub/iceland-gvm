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
	[ "$avail" -ge $(( $1 + SWIOTLB + 1024 )) ] || die "MemAvailable $avail MiB < guest $1 + swiotlb $SWIOTLB + 1024 MiB"
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
base_args() {
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
		"--block $DISK --block $SEED,ro=true --shared-dir $SHARE:gvmshare:type=p9 --net tap-name=$TAP,mac=$MAC" "--serial type=file,path=$L/agent-out.txt,input=$AGENT_IN,hardware=virtio-console,num=1"
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
		sleep 5; t=$((t + 5))
	done
	[ -n "$ip" ] || die "no guest address on $TAP for MAC $MAC"
	if sudo -u "$(caller_user)" ssh -o BatchMode=yes -o ConnectTimeout=5 "gvm@$ip" true 2>/dev/null; then row N1 PASS "ssh gvm@$ip"
	else row N1 FAIL "ssh gvm@$ip failed (key / sshd): the guest checks below cannot run"; fi
	G() { sudo -u "$(caller_user)" ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=4 "gvm@$ip" "$@"; }
	G 'sudo dmesg | grep -E "gunyah_guest|gunyah_accept"' | tee -a "$L/gvm.log" > "$L/v4-guest-accept.txt"
	# 0.3-12: gunyah_guest is built into the guest kernel (no module load); the .ko is only a fallback
	# v3 run: builtin=0 although the client came up without a module -> the built-in is what counts: RM client +
	# accept transport up with NO gunyah_guest module loaded; modules.builtin / the kernel build are info only
	G 'r=$(uname -r); echo "module=$(grep -c "^gunyah_guest " /proc/modules) builtin-list=$(cat /lib/modules/$r/modules.builtin /usr/lib/modules/$r/modules.builtin 2>/dev/null | grep -c gunyah_guest) kernel=$(uname -v | cut -c1-40)"' > "$L/v4-guest-builtin.txt" 2>&1
	if [ "${GVM_RUNMODE:-}" = --simplefb ]; then   # V8: no virtio-gpu, so no GuestAccept (CROSVM_GVM_ACCEPT unset)
		row V4-1 NOT-RUN "simplefb mode: no GuestAccept transport in this run mode"
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
	else G 'sudo python3 /mnt/gvmshare/tools/gvm-xwdstat.py :0' > "$L/v5-guest-xwd.txt" 2>&1; fi
	# v10c: the scanout resource read back from the host by the guest (TRANSFER_FROM_HOST in its own context)
	G 'test -x /tmp/gvm-fbread || gcc -O2 -o /tmp/gvm-fbread /mnt/gvmshare/tools/gvm-fbread.c; sudo /tmp/gvm-fbread' > "$L/v5-fbread.txt" 2>&1
	row $P-8 INFO "scanout read back by the guest: $(grep -m1 -E '^FBREAD' "$L/v5-fbread.txt" | cut -c1-200)"
	say "  $(cat "$L/v5-guest-xwd.txt" | head -c 200)"
	local gnz; gnz=$(grep -oE 'nonzero=[0-9.]+' "$L/v5-guest-xwd.txt" | cut -d= -f2)
	if [ "$P" = V5W ]; then row $P-2 INFO "$(head -c 160 "$L/v5-guest-xwd.txt")"
	else awk -v n="${gnz:-0}" 'BEGIN{exit !(n > 0.3)}' && row $P-2 PASS "the guest desktop is drawn ($(grep -o 'GUEST-XWD.*' "$L/v5-guest-xwd.txt"))" \
		|| row $P-2 FAIL "guest frame black or unreadable: $(head -c 160 "$L/v5-guest-xwd.txt")"
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

# ---- Windows 11 ARM64 (experimental, not supported yet) ---------------------------------------------------------------
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
		--serial type=file,path=$wcon,hardware=serial,num=1,console,earlycon --block "$wimg" \
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
			for t in /proc/$p/task/*; do printf ' %s:%s:%s' "$(cat "$t/comm" 2>/dev/null)" "$(awk '{print $3}' "$t/stat" 2>/dev/null)" "$(awk '{print $14 + $15}' "$t/stat" 2>/dev/null)"; done
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
	wmem=${GVM_WIN_MEM:-3072}; wcpu=${GVM_WIN_CPUS:-2}; wboot=0; wpid=; wip=
	export GVM_AFFINITY=${GVM_AFFINITY:-6,7}
	WL=/var/lib/gvm/win-log-$(date +%Y%m%d-%H%M%S); mkdir -p "$WL"; ln -sfn "$WL" "$L/win-log"
	local soak=${GVM_WIN_SOAK_MIN:-0} pr k0 rd fr r
	[ -f "$wfw" ] || die "no firmware $wfw"
	[ -f "$wimg" ] || die "no Windows image $wimg (tablet/winvm/win-image-transfer.sh)"
	SWIOTLB=256 need_mem "$wmem"
	crosvm_running && die "another crosvm is running"
	pr=${wimg%.raw}.pristine.raw
	if [ ! -e "$pr" ]; then cp --reflink=always "$wimg" "$pr" 2>/dev/null && say "win: pristine reflink copy $pr" || say "win: no reflink copy (not btrfs?): no pristine copy kept"
	elif [ "${GVM_WIN_FRESH:-0}" = 1 ]; then cp --reflink=always "$pr" "$wimg" && say "win: disk reset from $pr"; fi
	[ "${GVM_WIN_NET:-0}" = 1 ] && net_up
	k0=$(dmesg | wc -l); rm -f "$wcon"
	say "win: $wimg, firmware $(basename "$wfw") ($(sha256sum "$wfw" | cut -c1-12)), ECAM, simplefb, $wcpu vCPU (affinity $GVM_AFFINITY) / $wmem MiB / swiotlb 256, logs $WL"
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
		row W-G INFO "DMA guard: $(grep -a 'GVM-DMA-GUARD' "$WL/crosvm-stderr.txt" | sed 's/^.*GVM-DMA-GUARD/GVM-DMA-GUARD/' | head -n 3 | tr '\n' ';' | cut -c1-240)"
		win_end "$k0"; return 0
	fi
	# W3: first boot done: DHCP lease + RDP port (40 min for specialize + OOBE + reboots), then ssh when the image has it
	if win_wait 2400 win_rdp_open; then
		row W3-1 PASS "first boot complete: lease $wip for the VM's MAC, RDP port open (boots: $wboot)"
		if win_wait 600 win_ssh_ok; then
			row W3-2 PASS "ssh: $(tr -d '\r' < "$L/win-ver.txt" | grep -m1 -i 'windows' | cut -c1-80)"
			WG 'pnputil /enum-devices /connected' > "$L/win-pnp.txt" 2>&1
			for k in rdmapool viostor netkvm vioinput pvmpower; do grep -qi "$k" "$L/win-pnp.txt" && echo "$k"; done > "$L/win-drv.txt"
			row W3-3 "$([ "$(wc -l < "$L/win-drv.txt")" -ge 4 ] && echo PASS || echo FAIL)" "drivers started: $(tr '\n' ' ' < "$L/win-drv.txt")"
		else row W3-2 FAIL "no ssh in 10 min (image without gvm-sshd.ps1, or no network for the OpenSSH capability)"; fi
	else
		r=$?; wip=$(win_ip)
		if [ $r = 1 ]; then row W3-1 FAIL "no RDP port in 40 min (lease: ${wip:-none}, boots: $wboot)"
		else row W3-1 FAIL "crosvm ended during the first boot after $(( $(date +%s) - wt0 )) s (lease: ${wip:-none}, boots: $wboot)"; win_crash; fi
		win_end "$k0"; return 0
	fi
	fr=$(grep -a 'GVM-SIMPLEFB-FRAME' "$L/crosvm-stderr.txt" | tail -n1 | grep -oE 'mean=[0-9.]+ nonzero=[0-9.]+')
	awk -v n="$(echo "$fr" | grep -oE 'nonzero=[0-9.]+' | cut -d= -f2)" 'BEGIN{exit !(n > 0.02)}' \
		&& row W4-1 PASS "the desktop is drawn in the window (software display: $fr)" || row W4-1 FAIL "screen black (${fr:-no frame line})"
	if [ -s "$L/win-ver.txt" ] && grep -qi windows "$L/win-ver.txt"; then
		r=$(WG 'curl.exe -s -o NUL -w "%{http_code}" https://www.microsoft.com' 2>/dev/null | tr -d '\r')
		[ "$r" = 200 ] && row W4-2 PASS "guest HTTPS through the NAT (200)" || row W4-2 FAIL "guest HTTPS: ${r:-no answer}"
		# W5: emulation. x86 through the inbox SysWOW64 binaries; x64 only with GVM_WIN_X64 (a path in the guest)
		WG 'C:\Windows\SysWOW64\cmd.exe /c echo x86-ok' 2>&1 | tr -d '\r' | grep -q x86-ok && row W5-1 PASS "x86 emulation (SysWOW64 cmd.exe)" || row W5-1 FAIL "SysWOW64 cmd.exe did not run"
		if [ -n "${GVM_WIN_X64:-}" ]; then WG "$GVM_WIN_X64" > "$L/win-x64.txt" 2>&1 && row W5-2 PASS "x64 under Prism: $(tr -d '\r' < "$L/win-x64.txt" | tail -n1 | cut -c1-100)" || row W5-2 FAIL "x64 tool failed: $(tail -n1 "$L/win-x64.txt" | cut -c1-100)"
		else row W5-2 NOT-RUN "no x64 tool given (GVM_WIN_X64=<command in the guest>, from the owner's copy)"; fi
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
win_end() {   # $1 = dmesg line count at the start
	if kill -0 "$wpid" 2>/dev/null; then "$CROSVM" stop "$SOCK" > /dev/null 2>&1; sleep 10; kill "$wpid" 2>/dev/null; sleep 3; kill -9 "$wpid" 2>/dev/null; fi
	wait "$wpid" 2>/dev/null
	row W-B INFO "boots $wboot; host MemAvailable $(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo) MiB after stop"
	dmesg | tail -n +$(($1 + 1)) | grep -E 'BUG|WARNING|Oops|SError|Internal error|rcu.*stall' | grep -vE 'gvm: |vm-run: |iceland-combo' && row K1 FAIL "host kernel warnings" || row K1 PASS "no host kernel warnings"
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
bis) bis ;;
w1) w1 ;;
win) win ;;
stop) [ "$(id -u)" = 0 ] || die "not root"; clean_stop ;;
make-pristine) make_pristine "${1:-}" ;;
reset-disk) reset_disk ;;
*) sed -n '3,39p' "$0"; exit 2 ;;
esac
