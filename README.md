# iceland-gvm: protected Gunyah VMs on the OnePlus Pad 4

The virtual machine stack for the OnePlus Pad 4 (`iceland`, Qualcomm SM8850 "Kaanapali") on mainline Linux and
Fedora 44. It is the base of the [Virtual Machines app (iceland-vms)](https://github.com/mzakamin-hub/iceland-vms)
and can also be used on its own from a terminal.

The SoC's hypervisor is Qualcomm's **Gunyah**: it owns EL2, so there is no KVM. VMs run with **crosvm**'s Gunyah
backend as **protected VMs** (the firmware refuses unprotected ones): the guest's memory is lent to it and the host
reaches only a shared bounce buffer (the restricted DMA pool) and the shared regions crosvm sets up.

Current version: **0.3-27** (package `iceland-gvm`, Fedora 44 aarch64).

## What is in the package

| Part | Where it comes from |
|---|---|
| `crosvm` | upstream crosvm `96e84c3f680e` plus the 12 patches in [`crosvm/patches/`](crosvm/patches) (built with the `gunyah` and `virgl_renderer` features) |
| guest kernel `guest/Image` + modules | Linux 7.3.0-next-20261020 (the [iceland-linux](https://github.com/mzakamin-hub/iceland-linux) queue q90j as the source tree) with the guest config and two patches, see [`guest-kernel/`](guest-kernel) |
| `guest/initramfs-gvm.cpio.gz` | busybox 1.37.0 (Fedora 44's `busybox` package) and [`initramfs/init.sh`](initramfs/init.sh), packed by `initramfs/mkcpio.py` |
| `gvm.sh`, `gvm-kwinprobe.py`, `gvm-pngstat.py` | [`gvm/`](gvm): the command-line tool and its window helpers |
| guest tools | [`guest-tools/`](guest-tools): the guest agent (`gvm-agent`, clean power-off / reboot over `hvc0`, the desktop session setup), its installer and the guest kernel installer |
| `firmware/edk2-gunyah-ecam-*.fd` | DroidVM's edk2-gunyah, ACPI + ECAM build, see [`firmware/BUILD.md`](firmware/BUILD.md) |
| launcher and polkit action | [`gvm/integ/`](gvm/integ) |

The host side, the Gunyah VM manager (`gunyah.ko` and its companions), is part of the kernel since iceland-linux q90m;
`gvm.sh load` and the app load these modules.

## What works

- Protected VMs with crosvm: Fedora 44 Cloud (and other cloud images) on virtio disks, with NAT networking,
  virtio-console and virtio-rng, booted with our guest kernel.
- 3D in the guest: OpenGL through virgl and Vulkan through venus on the Adreno 840. GPU-composited desktops (Xorg with
  glamor, weston GL, the labwc Wayland session) draw in the crosvm window, which is opaque and has a server-side frame
  under KWin. This needs the guest kernel patch that syncs every GPU command buffer through the restricted DMA pool
  (`guest-kernel/patches/0002`), and the host kernel q90r or later.
- The software display (crosvm `--simplefb`: the guest's simpledrm draws into memory shared with the host, after
  DroidVM's design) and a 2D virtio-gpu display.
- Host-visible GPU blobs shared into the protected guest at run time (crosvm GuestAccept with the guest's built-in
  `gunyah_guest` driver).
- A clean shutdown through the guest agent, a restart when the guest reboots, and a DMA guard in crosvm that refuses
  virtio buffers outside the shared regions instead of touching lent memory.

Not supported yet: Windows guests, sound, USB / PCI passthrough.

## Use

Install the package (and, for the app, iceland-vms):

```bash
sudo dnf install ./iceland-gvm-0.3-27.fc44.aarch64.rpm
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
For managing several VMs, use the app.

## Build

- **crosvm:** check out upstream crosvm at `96e84c3f680e34e82e932ef911ae97d734121758`, `git am crosvm/patches/*.patch`,
  then on Fedora 44 aarch64 (or its chroot) `cargo build --release --features gunyah,virgl_renderer` and strip the
  binary.
- **Guest kernel:** see [`guest-kernel/README.md`](guest-kernel/README.md).
- **initramfs:** `python3 -I initramfs/mkcpio.py initramfs-gvm.cpio.gz /path/to/busybox initramfs/init.sh`.
- **Firmware:** see [`firmware/BUILD.md`](firmware/BUILD.md).
- **Package:** see [`packaging/README.md`](packaging/README.md).

## Licences

- crosvm: BSD-3-Clause (upstream `LICENSE`). Two files of patch 0007 (`aarch64/src/simplefb.rs`,
  `src/crosvm/sys/linux/simplefb_display.rs`) are a reduced port of DroidVM's crosvm fork and keep its
  GPL-2.0-or-later header (with DroidVM's additional permissions,
  [`LICENSES/droidvm-crosvm-ADDITIONAL-PERMISSIONS`](LICENSES/droidvm-crosvm-ADDITIONAL-PERMISSIONS)); see
  [`crosvm/CREDITS`](crosvm/CREDITS).
- Guest kernel: GPL-2.0 (Linux). `gunyah_guest` comes unchanged from DroidVM's
  [droidvm-guest-additions](https://github.com/Droid-VM/droidvm-guest-additions) `cccd907` (GPL-2.0-or-later with DroidVM's additional permissions,
  [`LICENSES/droidvm-guest-additions-ADDITIONAL-PERMISSIONS`](LICENSES/droidvm-guest-additions-ADDITIONAL-PERMISSIONS)).
- `gvm.sh`, the guest tools, `initramfs/`: GPL-2.0-only (`LICENSE`). busybox: GPL-2.0 (Fedora's source package).
- edk2-gunyah firmware: BSD-2-Clause-Patent (its licence texts are installed with it).

Related: [iceland-vms](https://github.com/mzakamin-hub/iceland-vms) (the app),
[iceland-linux](https://github.com/mzakamin-hub/iceland-linux) (the host and guest kernel source),
[iceland-mainline](https://github.com/mzakamin-hub/iceland-mainline) (the project). Thanks to the
[DroidVM](https://github.com/Droid-VM) project, whose Gunyah work (edk2-gunyah, gunyah_guest, the shared framebuffer)
this stack builds on.
