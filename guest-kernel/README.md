# The guest kernel

`guest/Image` of iceland-gvm 0.3-27 is a Linux 7.3.0-next-20261020 kernel for protected Gunyah VMs run by crosvm.
Kernel release `7.3.0-next-20261020-gvm+` (`kernel.release`); its exact `.config` is
`config-7.3.0-next-20261020-gvm+`.

## Source

- **Base tree:** the iceland-linux patch queue q90j, commit `2e12aad` on the branch `iceland-7.3-rc7-next` of
  [iceland-linux](https://github.com/mzakamin-hub/iceland-linux) (linux-next `next-20261020` + the queue). Its
  `scripts/prepare.sh` rebuilds the tree and checks the tree hashes in `kernel.pin`. `source-commit` records the
  commit of that tree in our build.
- **`patches/0001-virt-gunyah_guest-built-in-DroidVM-guest-RM-client.diff`:** DroidVM's `gunyah_guest`
  (droidvm-guest-additions `cccd907`, GPL-2.0-or-later, code unchanged) as `drivers/virt/gunyah_guest`, built in
  (`CONFIG_GUNYAH_GUEST=y`): the guest's client of the hypervisor's resource manager and the virtio "gvm-accept"
  device that accepts host-visible blobs shared at run time (crosvm GuestAccept, crosvm patch 0001).
- **`patches/0002-drm-virtio-sync-execbuffer-buffers-for-the-device.diff`:** in a protected VM the host reaches the
  guest's buffers only through the restricted DMA pool (swiotlb bounce buffers). The TRANSFER_TO_HOST paths already
  sync them; an EXECBUFFER did not, so Mesa virgl's texture uploads (a staging buffer plus COPY_TRANSFER3D inside the
  command stream) reached the host as zeros and every compositor that samples textures stayed black. Before the
  submit, every virgl PIPE_BUFFER of the buffer list with a shmem backing is synced DMA_TO_DEVICE.

## Config

`gvm-guest.config` is the fragment on top of arm64 `defconfig` (everything needed to reach the root file system
built in, no initramfs needed; `CONFIG_DMA_RESTRICTED_POOL=y`, the one option most distribution kernels lack);
`gvm-guest-gg.config` is the same plus `CONFIG_GUNYAH_GUEST=y`.

## Build

```bash
git clone --branch iceland-7.3-rc7-next https://github.com/mzakamin-hub/iceland-linux
cd iceland-linux && git checkout 2e12aad
scripts/prepare.sh ./src                     # next-20261020 + the q90j queue, tree hashes checked
cd src
patch -p1 < ../../iceland-gvm/guest-kernel/patches/0001-virt-gunyah_guest-built-in-DroidVM-guest-RM-client.diff
patch -p1 < ../../iceland-gvm/guest-kernel/patches/0002-drm-virtio-sync-execbuffer-buffers-for-the-device.diff
make O=../gout ARCH=arm64 LLVM=1 LOCALVERSION=+ defconfig
scripts/kconfig/merge_config.sh -m -O ../gout ../gout/.config ../../iceland-gvm/guest-kernel/gvm-guest-gg.config
make O=../gout ARCH=arm64 LLVM=1 LOCALVERSION=+ olddefconfig
make O=../gout ARCH=arm64 LLVM=1 LOCALVERSION=+ -j"$(nproc)" Image modules
```

The result's `.config` matches `config-7.3.0-next-20261020-gvm+`. Modules: `make ... INSTALL_MOD_PATH=DIR
INSTALL_MOD_STRIP=1 modules_install`, packed as `modules-7.3.0-next-20261020-gvm+.tar.gz` (the guest tools install
them into the guest disk). The package also carries `guest/extra/gunyah_guest.ko`, the same driver built as an
out-of-tree module, as a fallback for a guest kernel without it built in.
