# iceland-gvm - protected Gunyah VMs on the OnePlus Pad 4 (crosvm + guest kernel + gvm.sh + launcher).
# Built from gvm-payload.tar (see packaging/README.md); no compilation in the spec.
%global debug_package %{nil}
%global __strip /bin/true
Name:           iceland-gvm
Version:        0.3
Release:        27%{?dist}
Summary:        Protected Gunyah virtual machines (crosvm) for the OnePlus Pad 4
License:        BSD-3-Clause AND GPL-2.0-only AND GPL-2.0-or-later AND BSD-2-Clause-Patent
ExclusiveArch:  aarch64
Source0:        gvm-payload.tar
Requires:       kmod, virglrenderer, libwayland-client, libcap, NetworkManager, dnsmasq, dosfstools, zstd, openssl, polkit

%description
crosvm (upstream 96e84c3f680e + gvm-v4 GuestAccept, BSD-3-Clause), a guest kernel for protected VMs (restricted DMA pool), gvm.sh, guest tools and a GNOME launcher.
0.3: the guest module install no longer replaces /lib (V2 fix), root=PARTUUID, clean stop through the guest
agent on hvc0, make-pristine / reset-disk.

%prep
%setup -q -c -n gvm-payload

%install
mkdir -p %{buildroot}/usr/libexec/iceland-gvm %{buildroot}/usr/share/applications %{buildroot}/usr/share/polkit-1/actions
cp -a gvm/crosvm gvm/gvm.sh gvm/gvm-pngstat.py gvm/gvm-kwinprobe.py gvm/CREDITS-crosvm gvm/bisect gvm/firmware gvm/guest %{buildroot}/usr/libexec/iceland-gvm/
install -m 644 gvm/integ/iceland-gvm-fedora.desktop %{buildroot}/usr/share/applications/
install -m 644 gvm/integ/org.iceland.gvm.policy %{buildroot}/usr/share/polkit-1/actions/

%files
/usr/libexec/iceland-gvm
/usr/share/applications/iceland-gvm-fedora.desktop
/usr/share/polkit-1/actions/org.iceland.gvm.policy

%changelog
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
