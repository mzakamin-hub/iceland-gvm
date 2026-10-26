# virglrenderer 1.3.0-1.iceland1

Fedora 44's `virglrenderer` 1.3.0 (its spec, with the release changed) plus four fixes from upstream virglrenderer's
`main` branch for Venus (Vulkan in the VM), backported to 1.3.0. crosvm in iceland-gvm uses it for 3D in the VMs
(virgl and venus); the RPMs are attached to the iceland-gvm 0.3-58 release.

| Patch | Upstream commit | What |
|---|---|---|
| `0001-vkr-avoid-leaking-shm-fd-on-the-import-path.patch` | `e18f8c00a9` | vkr: no leaked shared-memory fd on the import path |
| `0002-proxy-old_busy_mask-bookkeep-should-be-lock-protecte.patch` | `fd10f6dec3` | proxy: the old busy mask is updated under the lock |
| `0003-server-fix-a-memcpy-UB-when-no-fds-are-received.patch` | `06abc4f68c` | server: no undefined memcpy when no fds are received |
| `0004-vkr-expose-restricted-amount-of-memoryHeaps-for-each.patch` | `e0a1caf3b1` (the virglrenderer part only) | vkr: a restricted memory heap list per guest |

## Build (Fedora 44 aarch64)

```bash
spectool -g -R virglrenderer.spec          # virglrenderer-1.3.0.tar.bz2 from freedesktop.org
cp *.patch ~/rpmbuild/SOURCES/
rpmbuild -ba virglrenderer.spec
```

## Licence

MIT, as upstream ([`COPYING`](COPYING)).
