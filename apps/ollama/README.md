# Ollama (GPU)

Ollama on **k3s-07** using pve4's passed-through Radeon 8060S iGPU (Strix Halo,
`gfx1151`) through the **Vulkan** (Mesa RADV) backend. Up to 96 GiB of guest RAM
is usable as GPU memory.

- API (LAN, HTTPS only): https://ollama.lab.emc2.build. No auth, so it is
  restricted to 192.168.0.0/16 by the `lan-only` middleware and has no public
  hostname.
- In-cluster: `http://ollama.ollama.svc.cluster.local:11434`
- Image: `ghcr.io/emcniece/ollama-vulkan` (`images/ollama-vulkan/`)

Not to be confused with glyphdex's CPU-only `glyphdex-ollama` StatefulSet.

```sh
kubectl apply -f apps/ollama/
kubectl -n ollama exec deploy/ollama -- ollama pull qwen3:30b-a3b
kubectl -n ollama exec deploy/ollama -- ollama ps    # PROCESSOR should be 100% GPU
```

## Why Vulkan and not ROCm

`ollama/ollama:*-rocm` is the obvious choice for an AMD GPU but is wrong here:

- On gfx1151, ROCm only reports the 512M BIOS carve-out as VRAM
  (ollama#13681), so Ollama offloads most layers to the CPU.
- The ROCm backend leaks KV state between sequential requests on gfx1151,
  so responses describe the previous prompt (ollama#17847, open since 0.32).
- With two or more resident models the GPU stays at full clock while idle
  (ollama#17958).

The plain image has Ollama's Vulkan backend but no Vulkan driver, hence the
thin `images/ollama-vulkan` image that adds `mesa-vulkan-drivers`. Two env vars
are required with it:

- `OLLAMA_VULKAN=1`
- `OLLAMA_IGPU_ENABLE=1`. Without it, 0.40.x logs "dropping integrated GPU" and
  runs on the CPU.

Check the startup log for:
`inference compute ... library=Vulkan ... "Radeon 8060S Graphics (RADV GFX1151)" type=iGPU total="96.5 GiB"`.

## Memory layout

| Layer | Setting |
|---|---|
| pve4 BIOS UMA carve-out | 512M (left small on purpose) |
| VM 117 RAM | 112 GiB (`qm set 117 --memory 114688`), all pinned by VFIO |
| Guest GTT limit | 96 GiB: `ttm.pages_limit=25165824 ttm.page_pool_size=25165824` in `/etc/default/grub.d/90-gpu-gtt.cfg` |
| Pod | requests `memory: 88Gi`, limit `104Gi` |

GTT is allocated by the kernel driver, not the container, so the scheduler
can't see it. The 88Gi request reserves room for it on the node. k3s-07 also
has a `gpu=true:PreferNoSchedule` taint so other workloads prefer other
nodes.

Changing the GTT size: edit the grub.d file, `update-grub`, then reboot
**pve4** rather than just the VM. A guest-only reboot risks the iGPU failing
to reset.

## Storage

Models live on a dedicated 400G virtual disk (VM 117 `scsi1`, pve4
`local-lvm` NVMe), ext4 `LABEL=ollama-models`, mounted by the guest's fstab at
`/var/lib/ollama`, exposed as the static local PV `ollama-models-k3s-07`
(`storage.yaml`). It is separate from the root disk so model pulls can't
cause DiskPressure.

## Tuning (deployment.yaml)

- `OLLAMA_FLASH_ATTENTION=1` + `OLLAMA_KV_CACHE_TYPE=q8_0`: the KV cache is
  about half size, so long contexts fit.
- `OLLAMA_CONTEXT_LENGTH=32768`: the default. Raise per request or model if
  needed.
- `OLLAMA_NUM_PARALLEL=1`, `OLLAMA_MAX_LOADED_MODELS=1`: generation is
  memory-bandwidth bound (~210 GB/s), so parallel slots only split context. One
  resident model keeps memory use predictable.
- `OLLAMA_KEEP_ALIVE=30m`.

Prefer MoE models. Speed scales with active parameters, not total size.
Dense 70B models run at only a few tok/s.

## Image updates

```sh
# bump OLLAMA_VERSION in images/ollama-vulkan/Dockerfile, then:
docker buildx build --platform linux/amd64 \
  -t ghcr.io/emcniece/ollama-vulkan:<ver> --push images/ollama-vulkan
# update the tag in deployment.yaml and apply
```
