# iceland-gvm: protected Gunyah VMs on the OnePlus Pad 4

The virtual machine stack for the OnePlus Pad 4 (`iceland`, Qualcomm SM8850 "Kaanapali") on mainline Linux and
Fedora 44. It is the base of the [Virtual Machines app (iceland-vms)](https://github.com/mzakamin-hub/iceland-vms)
and can also be used on its own from a terminal.

The SoC's hypervisor is Qualcomm's **Gunyah**: it owns EL2, so there is no KVM. VMs run with **crosvm**'s Gunyah
backend as **protected VMs** (the firmware refuses unprotected ones): the guest's memory is lent to it and the host
reaches only a shared bounce buffer (the restricted DMA pool) and the shared regions crosvm sets up.

Current version: **0.3-49** (package `iceland-gvm`, Fedora 44 aarch64), released together with iceland-vms 0.2-17.

## What works

- **Linux VMs**: protected Gunyah VMs with the tablet's guest kernel; Fedora 44 Cloud images with cloud-init, NAT
  networking with port forwards, virtio disks, shared folders, a clean shutdown through the guest agent.
- **3D graphics**: virgl (OpenGL) and venus (Vulkan) on the Adreno GPU, with GPU-composited desktops (Xorg with glamor,
  weston, the labwc Wayland session) drawn in the crosvm window. This needs the guest kernel patch that syncs every GPU
  command buffer through the restricted DMA pool (`guest-kernel/patches/0002`).
- **Software display fallback**: a framebuffer in memory shared with the host (crosvm `--simplefb`, after DroidVM's
  design) for guests without 3D drivers, and a 2D virtio-gpu display.
- **Touch input modes** on the VM window: tablet (tap = click, long press = right click), touchpad (relative pointer,
  two-finger scroll and tap) and touch screen (multitouch passthrough), in portrait and landscape; fullscreen scaled to
  the chosen output.
- **VNC display**: crosvm `--vnc-server` serves the VM's display over VNC (local only, or on the network with a
  password).
- **Fast networking**: the in-kernel virtio-net path (vhost-net) is on by default. Measured on the tablet (TCP over
  the NAT tap, 15 s each way):

  | | guest -> host | host -> guest |
  |---|---|---|
  | crosvm's own network | 2420 MB/s | 1959 MB/s |
  | vhost-net (default) | 2877 MB/s | 4761 MB/s |
- **Performance defaults**: guest memory lent in 2 MiB pages; io_uring for every disk; the shared I/O bounce buffer
  limited to 320 MiB (larger pools cannot be set up by the guest kernel).
- **Windows 11 (arm64)**: a prepared image boots on the ACPI + ECAM UEFI firmware; network, Remote Desktop and the
  image's OpenSSH server work. Shut Windows down from inside Windows, or use Force Off.
- A DMA guard in crosvm refuses virtio buffers outside the shared regions instead of touching lent memory.

Requirements: kernel-iceland q90u or newer with the Gunyah modules (vhost-net needs q90s or newer; older kernels fall
back to crosvm's own network). One VM at a time.

## What is in the package

| Part | Where it comes from |
|---|---|
| `crosvm` | upstream crosvm `96e84c3f680e` plus the 26 patches in [`crosvm/patches/`](crosvm/patches), built with the features `gunyah,virgl_renderer,vnc` |
| guest kernel `guest/Image` + modules | Linux 7.3.0-next-20261020 (the [iceland-linux](https://github.com/mzakamin-hub/iceland-linux) queue q90j as the source tree) with the guest config and two patches, see [`guest-kernel/`](guest-kernel) (unchanged since 0.3-27) |
| `guest/initramfs-gvm.cpio.gz` | busybox 1.37.0 (Fedora 44's `busybox` package) and [`initramfs/init.sh`](initramfs/init.sh), packed by `initramfs/mkcpio.py` |
| `gvm.sh` and its helpers | [`gvm/`](gvm): the command-line tool, its window, touch, VNC and memory helpers |
| guest tools | [`guest-tools/`](guest-tools): the guest agent (`gvm-agent`), its installer, the guest kernel installer and the input recorder |
| `firmware/edk2-gunyah-ecam-*.fd` | DroidVM's edk2-gunyah, ACPI + ECAM build, see [`firmware/BUILD.md`](firmware/BUILD.md) |
| launcher and polkit action | [`gvm/integ/`](gvm/integ) |

The host side, the Gunyah VM manager (`gunyah.ko` and its companions), is part of the kernel since iceland-linux q90m.

## Use

```bash
sudo dnf install ./iceland-gvm-0.3-49.fc44.aarch64.rpm
```

`gvm.sh` lives in `/usr/libexec/iceland-gvm/`. The everyday commands:

```bash
sudo /usr/libexec/iceland-gvm/gvm.sh check                # guards: kernel, checksums, power, memory, no other crosvm
sudo /usr/libexec/iceland-gvm/gvm.sh load                 # load the kernel's Gunyah modules
sudo /usr/libexec/iceland-gvm/gvm.sh make-pristine F.raw.zst   # keep a pristine copy of a Fedora Cloud disk
sudo /usr/libexec/iceland-gvm/gvm.sh run --gpu3d          # start the Fedora VM with the 3D display (virgl + venus)
sudo /usr/libexec/iceland-gvm/gvm.sh run --simplefb       # ... or with the software display
sudo /usr/libexec/iceland-gvm/gvm.sh stop                 # clean stop through the guest agent, then crosvm stop
```

The VM disk and its seed live in `/var/lib/gvm` (created with `chattr +C`), logs in `/run/gvm/log/`. The other
subcommands of `gvm.sh` are the probes used while the stack was brought up; `gvm.sh` without arguments lists them.
For managing VMs, Windows included, use the app.

## Build

- **crosvm:** check out upstream crosvm at `96e84c3f680e34e82e932ef911ae97d734121758`, `git am crosvm/patches/*.patch`,
  then on Fedora 44 aarch64 (with `libvncserver-devel`) `cargo build --release --features gunyah,virgl_renderer,vnc`
  and strip the binary. Patch 0019 carries the boot shim `hypervisor/src/gunyah/shim.bin` as a binary; to rebuild it
  from source (Fedora's `rust-std-static-aarch64-unknown-none-softfloat`):
  `cd droidvm-shim && cargo build --release --target aarch64-unknown-none-softfloat && objcopy -O binary
  target/aarch64-unknown-none-softfloat/release/droidvm-shim ../hypervisor/src/gunyah/shim.bin`.
- **Guest kernel:** see [`guest-kernel/README.md`](guest-kernel/README.md).
- **initramfs:** `python3 -I initramfs/mkcpio.py initramfs-gvm.cpio.gz /path/to/busybox initramfs/init.sh`.
- **Firmware:** see [`firmware/BUILD.md`](firmware/BUILD.md).
- **Package:** see [`packaging/README.md`](packaging/README.md).

## Licences

- crosvm: BSD-3-Clause (upstream `LICENSE`, [`LICENSES/crosvm-BSD-3-Clause`](LICENSES/crosvm-BSD-3-Clause)). The
  simple-framebuffer display, the VNC bridge and the pseudo-unprotected mode with its boot shim are ported from
  DroidVM's crosvm fork and keep its GPL-2.0-or-later headers with DroidVM's additional permissions
  ([`LICENSES/droidvm-crosvm-ADDITIONAL-PERMISSIONS`](LICENSES/droidvm-crosvm-ADDITIONAL-PERMISSIONS)); the
  droidvm-shim sources keep their own headers. The binary links the system LibVNCServer (GPL-2.0-or-later). See
  [`crosvm/CREDITS`](crosvm/CREDITS).
- Guest kernel: GPL-2.0 (Linux). `gunyah_guest` comes unchanged from DroidVM's
  [droidvm-guest-additions](https://github.com/Droid-VM/droidvm-guest-additions) `cccd907` (GPL-2.0-or-later with
  DroidVM's additional permissions,
  [`LICENSES/droidvm-guest-additions-ADDITIONAL-PERMISSIONS`](LICENSES/droidvm-guest-additions-ADDITIONAL-PERMISSIONS)).
- `gvm.sh`, the guest tools, `initramfs/`: GPL-2.0-only (`LICENSE`). busybox: GPL-2.0 (Fedora's source package).
- edk2-gunyah firmware: BSD-2-Clause-Patent (its licence texts are installed with it).

Related: [iceland-vms](https://github.com/mzakamin-hub/iceland-vms) (the app),
[iceland-linux](https://github.com/mzakamin-hub/iceland-linux) (the host and guest kernel source),
[iceland-mainline](https://github.com/mzakamin-hub/iceland-mainline) (the project). Thanks to the
[DroidVM](https://github.com/Droid-VM) project, whose Gunyah work (edk2-gunyah, gunyah_guest, the shared framebuffer,
the VNC bridge, the boot shim) this stack builds on.
