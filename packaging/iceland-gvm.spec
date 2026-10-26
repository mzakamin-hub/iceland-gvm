# iceland-gvm - protected Gunyah VMs on the OnePlus Pad 4 (crosvm + guest kernel + gvm.sh + launcher).
# Built from gvm-payload.tar (see packaging/README.md); no compilation in the spec.
%global debug_package %{nil}
%global __strip /bin/true
Name:           iceland-gvm
Version:        0.3
Release:        55%{?dist}
Summary:        Protected Gunyah virtual machines (crosvm) for the OnePlus Pad 4
License:        BSD-3-Clause AND GPL-2.0-only AND GPL-2.0-or-later AND BSD-2-Clause-Patent
ExclusiveArch:  aarch64
Source0:        gvm-payload.tar
Requires:       kmod, virglrenderer, libvncserver, libwayland-client, libcap, NetworkManager, dnsmasq, dosfstools, zstd, openssl, polkit

%description
crosvm (upstream 96e84c3f680e + gvm-v4 GuestAccept, BSD-3-Clause), a guest kernel for protected VMs (restricted DMA pool), gvm.sh, guest tools and a GNOME launcher.
0.3: the guest module install no longer replaces /lib (V2 fix), root=PARTUUID, clean stop through the guest
agent on hvc0, make-pristine / reset-disk.

%prep
%setup -q -c -n gvm-payload

%install
mkdir -p %{buildroot}/usr/libexec/iceland-gvm %{buildroot}/usr/share/applications %{buildroot}/usr/share/polkit-1/actions
cp -a gvm/crosvm gvm/gvm.sh gvm/gvm-pngstat.py gvm/gvm-kwinprobe.py gvm/gvm-touchinject.py gvm/gvm-vncprobe.py gvm/gvm-memscan.py gvm/CREDITS-crosvm gvm/firmware gvm/guest %{buildroot}/usr/libexec/iceland-gvm/
install -m 644 gvm/integ/iceland-gvm-fedora.desktop %{buildroot}/usr/share/applications/
install -m 644 gvm/integ/org.iceland.gvm.policy %{buildroot}/usr/share/polkit-1/actions/

%files
/usr/libexec/iceland-gvm
/usr/share/applications/iceland-gvm-fedora.desktop
/usr/share/polkit-1/actions/org.iceland.gvm.policy

%changelog
* Mon Oct 26 2026 mzak <mzak.amin@gmail.com> - 0.3-55
- release: the shared memory mode works (pvm53 on q90u: PV-A-1..7 PASS): crosvm --protected-vm-pseudo-unprotected
  boots a guest whose RAM is shared at run time and accepted by the boot shim (no bounce buffers; the host can read
  the guest's memory); crosvm = 0.3-53's (release branch, private path free)
- gvm.sh pvm: disk and network numbers in the shared mode (PV-A-5, PV-A-N) and the protected mode (PV-R-5, PV-R-N)

* Mon Oct 26 2026 mzak <mzak.amin@gmail.com> - 0.3-53
- shared memory mode (still behind its flag): crosvm requests the RM-RPC message queue (vm-config vdevice rm-rpc, the
  resource manager then adds /hypervisor/qcom,resource-mgr) in this mode too; pvm51 showed the shim a /hypervisor node
  with doorbells but no RM node, because the queue was only requested with the 3D display's GuestAccept

* Mon Oct 26 2026 mzak <mzak.amin@gmail.com> - 0.3-51
- shared memory mode diagnostics (mode still behind its flag): the boot shim is linked at its load address
  (0x80000000; a table of &str had held absolute pointers near 0, and reading one faulted the VM) and prints a
  numbered SHIM[n] line before / after every step (entry pc, dtb, RM lookup, capids, each drained message, accept,
  /memory rewrite, jump); crosvm logs GVM-PAGE-FAULT with the guest address and, with CROSVM_GVM_FAULT_INJECT=1
  (gvm.sh pvm), injects the abort so the shim's exception vector reports it; gvm.sh pvm shows all of this run's
  shim lines (PV-A-0) and the page faults (PV-A-0F)

* Mon Oct 26 2026 mzak <mzak.amin@gmail.com> - 0.3-49
- repack, no code change: guest kernel Image relinked with a neutral build user, gunyah_guest.ko and the edk2-gunyah ECAM
  firmware rebuilt from neutral build paths, so no build-machine path or user name is inside a packaged file; two
  comments no longer name the Windows image tooling's path; a privacy scan of the finished rpm gates the build

* Mon Oct 26 2026 mzak <mzak.amin@gmail.com> - 0.3-48
- packaging only (no code change from 0.3-47): the bisect payload (old guest kernels and crosvm kept for the v6
  regression bisect) is no longer packaged; built with _buildhost iceland-builder

* Mon Oct 26 2026 mzak <mzak.amin@gmail.com> - 0.3-47
- gvm.sh V11: the summary has its numbers again (MB/s, Mbit/s, crosvm and host CPU; an awk "a > b ? .." inside the
  printf list was an output redirection, so the fix run's rows were empty)
- boot shim (shared memory mode, still behind its flag): prints the RM node it took and its capids, drain bounded

* Mon Oct 26 2026 mzak <mzak.amin@gmail.com> - 0.3-45
- release fix: gvm.sh V11 passes vhost-net as crosvm's bare flag (",vhost-net"; "vhost-net=true" was refused:
  "expected ','" in the release run)
- boot shim (shared memory mode, still behind its flag): the resource-manager node is also looked up by the Qualcomm
  compatibles, and the whole /hypervisor subtree is printed when it is not found
- vm-run: rerun group default V1B WINAPP V11

* Mon Oct 26 2026 mzak <mzak.amin@gmail.com> - 0.3-43
- release: the consolidated parity (0.3-29..41) + Windows (0.3-30..42) work in one build; crosvm dd077fe
- vm-run release kit (group RELEASE order V1B V5 V8 VINX V9 V11 PVM WINAPP, K-ALL)

* Sun Oct 25 2026 mzak <mzak.amin@gmail.com> - 0.3-42
- gvm.sh (Windows agent, v10n): io_uring disks by default (GVM_BLK_OPTS, also the Windows disk); swiotlb at most 320 MiB
  (the guest's restricted DMA pool slot array is one kmalloc, 4 MiB max: 512 MiB never booted); V4-1 NOT-RUN outside
  the 3D mode (no GuestAccept); V5-2 samples the guest desktop up to 4 times; OPT rows with THP alloc / fallback deltas

* Sun Oct 25 2026 mzak <mzak.amin@gmail.com> - 0.3-41
- boot shim (shared memory mode, p6): cleans the device tree's cache lines before parsing it. The shim runs with the
  MMU off and read the tree as crosvm wrote it, without the resource manager's /hypervisor nodes ("no
  gunyah-resource-manager node"; the handoff fix of 0.3-39 worked: the shim read the parcel handles). On failure it now
  prints the tree's root nodes. Cleans the tree again after rewriting /memory.
- gvm.sh pvm: a guest that never comes up no longer ends the step (p6 printed no PV rows: v4_guest's die); the wait
  stops as soon as the shim gives up
- vm-run: diag sysctls restored one at a time (q90s refuses the saved max_rcu_stall_to_panic)

* Sun Oct 25 2026 mzak <mzak.amin@gmail.com> - 0.3-39
- crosvm (shared memory mode, p5 PV-A-2): the handoff page is described in the guest's /memory like the swiotlb and
  the framebuffer (plus a no-map reserved-memory node); left out, the boot shim's first read of it took a synchronous
  external abort (esr 0x96000010, far 0x80400000) that never reached the host. ICELAND_SHIM_HANDOFF_MEMORY=0 restores
  the p5 layout (diagnostic).
- packaging: gvm-memscan.py is installed (p5 PV-A-6 found it missing); gvm.sh pvm: guest rows are NOT-RUN without ssh
  (PV-A-4 had passed on an empty answer), the shim's console lines (SHIM ...) become row PV-A-0
- contains the Windows agent's 0.3-38

* Sun Oct 25 2026 mzak <mzak.amin@gmail.com> - 0.3-38
- gvm.sh (Windows agent): W3-3 checks the DroidVM driver services with sc query (rdmapool, viostor, netkvm must run);
  kprobe counts are deltas since the probes were armed; the demand-page probe records the gpa and the donate probe
  the flags and size, reported as rows W-PH and OPT-<tag>-HIST (donation sizes, most-faulting guest 2 MiB regions)

* Sun Oct 25 2026 mzak <mzak.amin@gmail.com> - 0.3-37
- crosvm: opt-in shared memory mode --protected-vm-pseudo-unprotected (after DroidVM dvm-crosvm 849e05f): only a
  4 MiB boot region (boot shim + device tree) is lent; the guest RAM window is shared after GH_VM_START with
  GH_VM_PROTECTED_SHARE (R/W/X) and accepted by the boot shim (droidvm-shim, compiled in), which rewrites /memory and
  starts the kernel; no swiotlb. THE HOST CAN READ THE VM'S MEMORY in this mode. GH-SHIM log lines.
- crosvm: touch mode also sends ABS_X / ABS_Y for the first contact (single-touch pointer emulation, p4 VINX)
- gvm.sh: pvm rows (PV-A/PV-B/PV-R, gvm-memscan.py proves host readability), v11 network rows; VIN judge reads a
  touch screen's MT position (p4 VINX read the never-sent ABS_X), recorder reports only the device's own axes
* Sun Oct 25 2026 mzak <mzak.amin@gmail.com> - 0.3-36
- (Windows agent, on the parity agent's 0.3-35) 2 MiB lends for every VM by default (GVM_HUGEPAGES=0 = 4 KiB);
  gvm.sh opt: one workload per variant (boot to ssh, 1 GiB memory touch, disk read / direct write, sha256 on every
  vCPU, host wake-up jitter idle / under load, lend counters); GVM_BLK_OPTS (crosvm --block options), GVM_VMM_CPUS
  (crosvm's own threads); Windows row W3-R: the RDP server answers an X.224 connection request

* Sun Oct 25 2026 mzak <mzak.amin@gmail.com> - 0.3-35
- contains the Windows agent's 0.3-32 / 0.3-34 (2 MiB lends by default for Windows, display / load / soak rows)
- crosvm: a fullscreen size from the window's creation roundtrip is applied to the new viewport (p3: the window first
  mapped at 800x500 and KWin answered with an 800x500 configure)
- crosvm touchpad mode: a horizontal two-finger scroll goes to the tablet device's horizontal wheel (the virtio mouse
  has none; p3 VI-7 on the rotated tablet scrolled sideways and the guest saw nothing)
- VIN after the p3 run (portrait, hands off): calibration from crosvm's own touch coordinates in every mode (any
  rotation: p3 measured rot90), the guest recorder reports the current axes (evdev drops unchanged values), one D-Bus
  name per KWin probe (the watcher took the probes' answers: 'no window'), the fit never tracebacks;
  GVM_VIN_ROTATION + vm-run group VINROT: VIN with rotation lock in portrait and landscape, restored afterwards

* Sun Oct 25 2026 mzak <mzak.amin@gmail.com> - 0.3-33
- crosvm (parity/3d): GVM-ACCEPT-STATS lines (runtime blob shares: count, average / max map and unmap time,
  mapped MiB), the measurement behind the DroidVM-style pre-shared GPU pool decision
- gvm.sh v10 (V10 rows): virgl GL vs venus Vulkan (vkmark headless) vs GL through zink over venus vs llvmpipe on one
  VM, GuestAccept cost without failures
- VIN fixes after the p12 tablet run: crosvm logs every xdg configure (GVM-CONFIGURE) and, with
  CROSVM_GVM_INPUT_LOG=1, every wl_touch down (GVM-TOUCH); gvm.sh vin waits for the fullscreen window to settle,
  calibrates with a warm-up + four taps (least squares; the tablet maps the injector transposed), presses away
  from the previous tap (evdev drops repeated ABS values) and reports what crosvm received per gesture

* Sun Oct 25 2026 mzak <mzak.amin@gmail.com> - 0.3-31
- crosvm (parity/vnc, built with the vnc feature): --vnc-server host=,port=,password-file= serves the virtio-gpu
  scanout or the --simplefb framebuffer over VNC (LibVNCServer bridge ported from DroidVM dvm-crosvm 849e05f,
  GPL-2.0-or-later, CPU transport; see CREDITS-crosvm); RFB pointer -> the gvm absolute tablet, keys -> keyboard;
  default host 127.0.0.1; GVM-VNC listening / GVM-VNC-FRAME lines
- gvm.sh v9 (V9 rows, iceland-vms 0.2-7): GVM_VNC=1 runs a VM with the VNC display; gvm-vncprobe.py, a minimal RFB
  client (handshake, raw frame statistics, key, pointer) judges it; guest gvm-evrec.py can record keyboards
- contains 0.3-30 (Windows: pristine image per run)
* Sun Oct 25 2026 mzak <mzak.amin@gmail.com> - 0.3-34
- gvm.sh win: guest RAM in 2 MiB THP folios by default (WINH1 PASS: the host freezes were the 4 KiB on-demand
  lend storm, one TrustZone call per page), 4 vCPU / 4 GiB unpinned by default; display rows from the VM window
  screenshot (W-D, W4-1); W6-L: CPU / disk / memory load inside Windows (winsat over ssh) before the soak

* Sun Oct 25 2026 mzak <mzak.amin@gmail.com> - 0.3-32
- gvm.sh win: GVM_HUGEPAGES=1 now also prepares shmem THP (2 MiB folios lent as 2 MiB blocks); kprobe counters of
  the lend path (qcom_scm_assign_mem, gunyah_demand_page, memextent_donate) in the 1 s sample and row W-P
  (fresh-disk WINN1 / WINN4 froze the host as soon as Windows touched memory fast)

* Sun Oct 25 2026 mzak <mzak.amin@gmail.com> - 0.3-30
- gvm.sh win: every run starts from the pristine image (reflink, else sparse copy; GVM_WIN_KEEP=1 keeps the disk):
  a freeze in the middle of the first boot had left Windows' setup half done; row W-IMG logs the pristine sha256

* Sun Oct 25 2026 mzak <mzak.amin@gmail.com> - 0.3-29
- crosvm (parity/input): fullscreen keeps the guest resolution and scales it to the output with the viewport;
  input is mapped back per axis; leaving fullscreen at run time restores the window size (GVM-FULLSCREEN on/off);
  the input region covers any surface size
- gvm.sh vin (VIN rows, iceland-vms 0.2-6): the window's input modes judged in the guest: a host uinput touch screen
  (gvm-touchinject.py: injector, judge, calibration) -> KWin -> crosvm -> guest evdev (guest tool gvm-evrec.py);
  GVM_INPUT_MODE / GVM_FULLSCREEN / GVM_OUTPUT pass to crosvm
- gvm-kwinprobe.py: fullscreen / unfullscreen actions (the app's fullscreen button, VI-W / VI-F rows)

* Sun Oct 25 2026 mzak <mzak.amin@gmail.com> - 0.3-28
- crosvm 55fd317: window input modes (CROSVM_GVM_INPUT_MODE touch / tablet / touchpad), real multi-finger touch,
  pointer coordinates scaled to buffer pixels, CROSVM_GVM_FULLSCREEN / CROSVM_GVM_OUTPUT (iceland-vms 0.2-6)
- gvm.sh win: GVM_AFFINITY set but empty = unpinned; the 1 s sample records the CPU each crosvm thread last ran on
  and the per-CPU arch-timer interrupt counts (the WINN hard lockup: a CPU that stops counting is stuck in Gunyah)

* Sun Oct 25 2026 mzak <mzak.amin@gmail.com> - 0.3-27
- gvm-wayland-session: ordered after / conflicting with lightdm and getty@tty1 (both stopped before the start);
  gvm-wayland-check restarts the session once per boot when the scanout framebuffer is not labwc's after 12 s
  (v10h: the first start after the VT handover stayed black, every restart drew)

* Sun Oct 25 2026 mzak <mzak.amin@gmail.com> - 0.3-26
- gvm-wayland-session: switch to tty1 before labwc starts (the logind session gets DRM master only on the active
  VT; v10g: labwc ran, the CRTC kept the console framebuffer), labwc -d (wlroots log in the journal)
- gvm.sh V5W-10..14: the wlroots log + the window with WLR_RENDERER=gles2 / pixman, WLR_DRM_NO_MODIFIERS=1,
  WLR_DRM_NO_ATOMIC=1 (runtime drop-ins)

* Sun Oct 25 2026 mzak <mzak.amin@gmail.com> - 0.3-25
- gvm-agent: the Wayland desktop bypasses lightdm (Fedora's lightdm ran Xfce despite every labwc setting, v10f):
  gvm-wayland-session.service logs the user in on tty1 (PAM login, logind session type wayland) and runs labwc
  with a foot terminal; lightdm is masked for that boot only (--runtime); without the flag everything is undone
- gvm.sh: V6-5 (glamor) judged from the window screenshot (frame dumps as V6-5D); V5W-1 shows the session unit log

* Sun Oct 25 2026 mzak <mzak.amin@gmail.com> - 0.3-24
- gvm-agent: the Wayland autologin choice is unambiguous (lightdm sessions-directory incl. wayland-sessions,
  user-session, the user's AccountsService Session / XSession and ~/.dmrc); v10e still logged into Xfce
- gvm.sh: V5W-1 requires Type=wayland and reports lightdm's reason otherwise; every kmscube gets a never-readable
  stdin (kmscube quits at once when stdin is readable - the reason kmscube -A "never displayed"); V6-23 kmscube -A

* Sun Oct 25 2026 mzak <mzak.amin@gmail.com> - 0.3-23
- guest/Image is now the dmasync kernel (EXECBUFFER buffers synced through the swiotlb): vm-run v10d drew Xorg
  glamor, weston GL and the Xfce desktop in the window; the previous guest kernel is bisect/Image-0.3-22
- vm rows: the window screenshot is the verdict (V6-17..22 window checks, V5-3 frame dump informational), V5-9
  window opacity check (gvm-solid.py: a full-screen magenta X window in the guest, the window must show pure
  magenta); gvm-agent writes labwc's missing session file (v10d's "labwc" rows had run Xfce)

* Sun Oct 25 2026 mzak <mzak.amin@gmail.com> - 0.3-22
- bisect/Image-dmasync: guest kernel candidate, the buffers of an EXECBUFFER (virgl staging / vertex / index /
  constant) are synced to the swiotlb before the submit, as the TRANSFER paths already were (v10c: everything that
  samples uploaded textures was black - weston GL, glamor - while kmscube and the CPU paths were drawn); same
  config and kernel.release as the shipped guest kernel
- crosvm: DMA guard for protected VMs - a virtio descriptor outside the swiotlb / shared framebuffer is refused
  and logged (GVM-DMA-GUARD with the device thread) instead of touching memory lent to the guest (v10b SIGBUS,
  v10c host freeze with a Windows guest); CROSVM_GVM_DMA_GUARD=0 turns it off
- gvm.sh win: safety defaults (2 vCPU pinned to 6-7, 3 GiB, no network unless GVM_WIN_NET=1), crosvm log and a
  fsynced 1 s sample in /var/lib/gvm/win-log-*, W2-N / W-G rows; gvm-fbread: stride 0 (v10c read EINVAL)
- gvm.sh V6-21 / V6-22: weston GL with VIRGL_DEBUG=nocoherent / xfer

* Sun Oct 25 2026 mzak <mzak.amin@gmail.com> - 0.3-21
- crosvm d8e6a8e: the virtio-gpu copy path retries a frame it had to defer because the compositor still held the
  next buffer (30 ms timer; v10b: an idle guest kept an old, often black, frame in the window); a SIGBUS / SIGSEGV
  report (thread, address, mappings) - v10b's Windows crosvm died with SIGBUS and no log line
- guest tool gvm-fbread.c: reads the CRTC's scanout back from the host (TRANSFER_FROM_HOST); gvm.sh rows
  V6-17..20 (weston GL / pixman, kmscube, Xorg glamor) and V5-8; stale /run/seatd.sock removed before weston
- gvm.sh win: core dumps without guest RAM, crosvm thread list, W-CRASH row, W3-1 tells a crosvm end from a timeout
- bisect/Image-evnow removed (v10b: no effect)

* Sat Oct 24 2026 mzak <mzak.amin@gmail.com> - 0.3-20
- bisect/Image-trace: the guest kernel with ftrace (function tracer + profiler, 2 MiB log buffer), no driver
  change; bisect/Image-evnow: + the candidate fix (virtio-gpu sends the flip event at atomic_flush instead of on
  the simulated vblank timer). Both boot without modules (own kernel.release)
- gvm-drmtrace.sh v2: function hit counts / timeline / vblank + fence events / client stacks / blocked tasks
  (v1's drm.debug log overflowed the 128 KiB guest log buffer); gvm.sh V6-13..16 rows from it, trace tarballs kept
- gvm.sh win: Windows 11 ARM64 rows W2-W6 (release ECAM firmware, simplefb screen, reboots through PSCI reset
  restart crosvm, DHCP lease + RDP port, ssh rows when the image has OpenSSH, optional soak)

* Sat Oct 24 2026 mzak <mzak.amin@gmail.com> - 0.3-19
- crosvm: per-VM PCIe ECAM (CROSVM_GVM_PCI_ECAM=1, after DroidVM 7d4712a) for Windows guests; GVM-EXIT type=N
  marker per Gunyah exit (reboot detection without a console line); CROSVM_GVM_TRACE_SCANOUT=1 trace
- firmware/edk2-gunyah-ecam-{release,debug}.fd: edk2-gunyah 90c4d52 ACPI build with ECAM (PCI_CAM_MODE=FALSE),
  BSD-2-Clause-Patent (licence files next to them); gvm.sh step w1 (Windows track W1)
- bisect/Image-dmgfix: the guest kernel with the candidate virtio-gpu fix (a new fb always reaches the host);
  gvm.sh V6-13 / V6-14 guest DRM debug (gvm-drmtrace.sh); reboot detection from GVM-EXIT type=2|3

* Sat Oct 24 2026 mzak <mzak.amin@gmail.com> - 0.3-18
- v6: V6-10..12 kmscube -A (atomic) / -m 0 (linear modifier) / both, to split the GL-compositor black;
  probe resources also taken from the frames (crosvm's notes are once per id and ids are reused)

* Sat Oct 24 2026 mzak <mzak.amin@gmail.com> - 0.3-17
- bis: the dma-buf share fallback line (harmless, also in passing runs) no longer counts as a crosvm error
- (same crosvm 20892b4 / guest kernel as 0.3-15: the v7 bisect cleared both; the v6 failures came with a
  crash-looping DroidLoom SurfaceFlinger and the hypervisor state left by the first crashed VM)

* Sat Oct 24 2026 mzak <mzak.amin@gmail.com> - 0.3-16
- bisect payload for the v6 regression: bisect/crosvm-640ac8b (the 0.3-14 crosvm) and bisect/Image-0.3-14;
  gvm.sh GVM_CROSVM / GVM_IMAGE overrides and step "bis"
- ssh to the guest with ConnectTimeout / ServerAlive (a dead guest no longer hangs a row); V5-4 / V8-4 only
  screenshot a window KWin found; V6 judging ignores frames without a resource

* Sat Oct 24 2026 mzak <mzak.amin@gmail.com> - 0.3-15
- crosvm: --simplefb software display (DroidVM's default screen, ported from dvm-crosvm 849e05f, GPL-2.0-or-later
  parts with their headers; CREDITS): a framebuffer in host-shared memory below the swiotlb, guest simpledrm, shown
  in the Wayland window with keyboard / touch as virtio-input; CROSVM_GVM_REFRESH_MS periodic re-present
- guest kernel: CONFIG_DRM_SIMPLEDRM=y
- gvm.sh: run --simplefb + v8 rows; V5R (glamor + refresh); V6-8 glmark2 on KMS, V6-9 weston-GL + animating client

* Sat Oct 24 2026 mzak <mzak.amin@gmail.com> - 0.3-14
- v6: judge only frames of the resources the probe put on the scanout (v4 judged the restored boot console)
- v5: GVM_IMPORT=1 = V5I (zero-copy scanout import into the host compositor, DroidVM's default display path);
  a FAIL row with the guest console's last errors when ssh to the guest is lost after the desktop start
- v6: modetest without page flips (v4: modetest -v froze the guest), a guest-alive check after every probe
- v5: GVM_2D=1 = V52D (the desktop on the 2D virtio-gpu)

* Sat Oct 24 2026 mzak <mzak.amin@gmail.com> - 0.3-13
- crosvm 640ac8b: scanout-change frame dumps at most once a second; the dmabuf source in dumps only with
  CROSVM_GVM_DUMP_DMABUF=1; gvm.sh reads 3D scanouts through ctx0 only (GVM_SCANOUT_READ=auto restores auto)
- v6: real probes (drm-utils / kmscube / weston + seatd installed one by one; v3's PASS rows were the boot console),
  PASS needs a new scanout resource; weston pixman; Xorg without glamor; v5: GVM_WAYLAND=1 = V5W (labwc session)
- V4-1: the built-in counts when the client is up with no gunyah_guest module loaded (modules.builtin is info)

* Sat Oct 24 2026 mzak <mzak.amin@gmail.com> - 0.3-12
- crosvm a62d7a7: GVM-SET-SCANOUT / GVM-FLUSH-OFFSCREEN notes (which resource the guest shows / flushes),
  CROSVM_GVM_DUMP_EVERY / CROSVM_GVM_DUMP_MAX and a frame dump on every scanout resource change
  (run 2: the 5 dumps of the first 25 s only saw the boot console, readback itself works)
- v5: the last frame is judged; KWin probe over D-Bus (gvm-kwinprobe.py); GVM_ZINK=1 = V5Z, the guest desktop on
  zink over venus (guest agent flag zink); K1 ignores our own kmsg lines
- guest kernel 7.3.0-next-20261020-gvm+ rebuilt with gunyah_guest BUILT IN (CONFIG_GUNYAH_GUEST=y, DroidVM's code
  unchanged): no module load per boot; extra/gunyah_guest.ko is copied only for a kernel without the built-in;
  V4-1 checks the built-in
- v6: guest display stack probes (modetest, kmscube, weston, Xorg PageFlip off + ShadowFB, Xorg default) judged by
  the host frames; gvm-pngstat.py reads PPM too

* Sat Oct 24 2026 mzak <mzak.amin@gmail.com> - 0.3-11
- gvm.sh unload is a no-op ("kept loaded (pm-notifier bug, fixed in q90o)"); GVM_ALLOW_UNLOAD=1 on a fixed kernel
- 3D: FD_MESA_DEBUG=noubwc,notile for crosvm (the virgl scanout was a UBWC bo no copy path can read: the black
  window); GVM_FD_DEBUG overrides
- v5: KWin scripting with the plasmashell session environment (answer from kwin_wayland's journal), iceland-shot
  --window as root + gvm-pngstat.py statistics, 24 bpp guest xwd

* Sat Oct 24 2026 mzak <mzak.amin@gmail.com> - 0.3-10
- crosvm 26475ab: server-side window frame on KWin (xdg-decoration; CROSVM_GVM_NO_SSD=1 disables), a compositor
  close prints GVM-WINDOW-CLOSE instead of a hard VM exit (CROSVM_GVM_CLOSE=exit = upstream)
- gvm.sh: Wayland socket of the active seat0 user session (GNOME or Plasma, skips the greeter, wayland-N);
  v5 = 3D desktop rows (guest xwd / host frame statistics, KWin window, close); guest tool gvm-xwdstat.py

* Sat Oct 24 2026 mzak <mzak.amin@gmail.com> - 0.3-9
- crosvm gvm-v4 + 349441f + gvm_scanout: the copy path of a 3D (virgl) scanout picks a working source
  (CROSVM_GVM_SCANOUT_READ=auto|ctx0|dmabuf|backing; auto = the first non-black of virglrenderer ctx0
  readback, linear dmabuf mmap, guest backing); CROSVM_GVM_DUMP_FRAME=<dir> logs GVM-FRAME statistics of
  every source every 5 s (max 5) and writes the shown frame as PPM (the 0.3-8 desktop window was black)
* Sat Oct 24 2026 mzak <mzak.amin@gmail.com> - 0.3-8
- v4: V4-2 reads the renderer line (it read the vendor line); V4-5 = gvm-vkblobtest with GVM_VENUS=1 (HOST_VISIBLE Vulkan memory = host blobs), INFO for plain virgl on a GLES host (no GL buffer storage)
- v4n: V4N-5 = GL persistent buffers + accept count (native context allocates every BO as a blob)
- guest/tools/gvm-vkblobtest.c
- crosvm gvm-v4 + 349441f: virtio-gpu scanout through the copy path (the dmabuf import of virgl scanouts gave a
  black / frozen window on Mutter), window title / app id from CROSVM_GVM_WINDOW_TITLE / CROSVM_GVM_APP_ID
- gvm-agent --setup before the display manager: autologin (default) and noglamor (GVM_NOGLAMOR=1) flags from the share
- run: one crosvm log per run (crosvm-stderr.prev.txt), window title gvm: Fedora 44

* Sat Oct 24 2026 mzak <mzak.amin@gmail.com> - 0.3-7
- 3D default = virgl (context-types virgl:virgl2; V4 A/B: virgl GL on the Adreno 840, the native context fails in guest Mesa)
- v4 = virgl rows + V4-5 host-visible blob test (guest/tools/gvm-blobtest.c, persistent coherent GL buffers); v4n = native context (experimental)
- GVM_CTX override; fixed a stray \n in the v3 ssh check

* Sat Oct 24 2026 mzak <mzak.amin@gmail.com> - 0.3-6
- gvm.sh: GVM_LOGLEVEL (crosvm / rutabaga debug), egl-utils in the V4 package set (eglinfo moved there in Fedora)

* Sat Oct 24 2026 mzak <mzak.amin@gmail.com> - 0.3-5
- no host modules any more: the Gunyah VM-manager modules come with kernel-iceland (q90m+, CONFIG_GUNYAH=m);
  gvm.sh loads them with modprobe (kernel-version independent) and stops with a clear message without them

* Fri Oct 23 2026 mzak <mzak.amin@gmail.com> - 0.3-4.q90j
- gvm.sh v4: stop the display manager for the GL rows, EGL_PLATFORM=surfaceless eglinfo with full logs, glmark2 as root

* Fri Oct 23 2026 mzak <mzak.amin@gmail.com> - 0.3-3.q90j
- gvm.sh: restart on a guest reboot (crosvm exits 0 on Gunyah: detect "reboot: Restarting system" of the current run)
- gvm.sh: grow the Fedora disk to GVM_DISK_GB (default 20) before every start

* Fri Oct 23 2026 mzak <mzak.amin@gmail.com> - 0.3-2.q90j
- gvm.sh: GVM_HUGEPAGES=1 (shmem THP advise + crosvm --hugepages), GVM_AFFINITY (vCPU pinning) after the 23 Oct host hang

* Fri Oct 23 2026 mzak <mzak.amin@gmail.com> - 0.3-1.q90j
- gvm.sh: guest module install extracts into /usr when /lib is a symlink (V2: tar had replaced /lib -> no exec)
- gvm.sh: root=PARTUUID (no initramfs), clean stop through the guest agent on hvc0, make-pristine / reset-disk
- guest/tools: gvm-agent (+ unit, installer), gvm-guest-kernel-install.sh

* Fri Oct 23 2026 mzak <mzak.amin@gmail.com> - 0.2-1.q90j
- V4 candidate: 3D through virglrenderer (virgl + msm native context, venus opt-in) with runtime GuestAccept

* Fri Oct 23 2026 mzak <mzak.amin@gmail.com> - 0.1-1.q90j
- first candidate (gvm agent): crosvm gunyah, modules 0001-0008 for q90j, guest kernel, gvm.sh, launcher
