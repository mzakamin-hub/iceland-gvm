# Packaging

`iceland-gvm.spec` builds the Fedora 44 aarch64 package from one source, `gvm-payload.tar`, which holds a directory
`gvm/` with the finished payload (no compilation happens in the spec):

| Payload path | From |
|---|---|
| `gvm/crosvm` | the stripped crosvm build (README, Build) |
| `gvm/CREDITS-crosvm` | `crosvm/CREDITS` |
| `gvm/gvm.sh`, `gvm/gvm-kwinprobe.py`, `gvm/gvm-pngstat.py`, `gvm/gvm-touchinject.py`, `gvm/gvm-vncprobe.py`, `gvm/gvm-memscan.py` | `gvm/` |
| `gvm/integ/` | `gvm/integ/` (launcher, polkit action) |
| `gvm/guest/Image`, `gvm/guest/modules-<release>.tar.gz` | the guest kernel build (`guest-kernel/README.md`) |
| `gvm/guest/extra/gunyah_guest.ko` | droidvm-guest-additions `cccd907` `gunyah_guest/`, built out of tree against the guest kernel (with `-ffile-prefix-map` / `-fmacro-prefix-map` to `/build`) |
| `gvm/guest/initramfs-gvm.cpio.gz` | `initramfs/mkcpio.py` with Fedora 44's busybox and `initramfs/init.sh` |
| `gvm/guest/tools/` | `guest-tools/` |
| `gvm/firmware/` | the edk2-gunyah ECAM build and its two licence files (`firmware/BUILD.md`) |

Everything lands in `/usr/libexec/iceland-gvm/`; the launcher and the polkit action go to `/usr/share`.

```bash
tar --owner=0 --group=0 -cf ~/rpmbuild/SOURCES/gvm-payload.tar gvm
rpmbuild -bb packaging/iceland-gvm.spec
```
