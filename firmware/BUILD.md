# edk2-gunyah firmware in iceland-gvm (ACPI + ECAM build)

iceland-gvm carries `firmware/edk2-gunyah-ecam-release.fd` and `edk2-gunyah-ecam-debug.fd`: DroidVM's edk2 port for
Gunyah in its ACPI + PCIe ECAM configuration, for guests that need ACPI (crosvm's per-VM ECAM, crosvm patch 0009,
`CROSVM_GVM_PCI_ECAM=1`). The device-tree (CAM) build used by the app for ISO guests is described in
[iceland-vms fw/BUILD.md](https://github.com/mzakamin-hub/iceland-vms/blob/main/fw/BUILD.md).

## Sources

| What | Commit |
|---|---|
| [edk2-gunyah](https://github.com/Droid-VM/edk2-gunyah) | `90c4d52c7d11485318bbb4fb9291a15ea1550ab2` |
| edk2 submodule | `b7a715f7c03c45c6b4575bf88596bfd79658b8ce`, sub-submodules at their pinned commits |

Nothing is changed.

## Commands

Ubuntu 24.04 x86_64, aarch64-linux-gnu-gcc 13.3.0, iasl 20230628, `uuid-dev`, GNU Make, Python 3:

```sh
git clone https://github.com/Droid-VM/edk2-gunyah && cd edk2-gunyah
git checkout 90c4d52c7d11485318bbb4fb9291a15ea1550ab2 && git submodule update --init --recursive
EDK2_TARGET=RELEASE bash ./build.sh -D PCI_CAM_MODE=FALSE       # -> edk2-gunyah-ecam-release.fd
EDK2_TARGET=DEBUG   bash ./build.sh -D PCI_CAM_MODE=FALSE       # -> edk2-gunyah-ecam-debug.fd
```

Hashes of the files in 0.3-49, built in `/build/edk2-gunyah` (PrePi embeds the build date and the build path, so a
rebuild elsewhere differs):

```
2f749b377c96c3d39d1afc5fff8d89ec894d999311f67e0426c0783a9a9a1c10  edk2-gunyah-ecam-release.fd
82acdf937b2f4633a3c52a8f41ae1ea2b98dd0e56955e84d76a44a0f73dd110b  edk2-gunyah-ecam-debug.fd
```

Licence: BSD-2-Clause-Patent (`edk2-License.txt`, `edk2-gunyah-LICENSE`, installed next to the firmware).
