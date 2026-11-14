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
- `OLLAMA_CONTEXT_LENGTH=131072` (was 32768). One Open WebUI research turn
  with ~10 searches and page fetches reached 32k tokens (2026-11-14). Ollama
  then dropped messages from the front, including the user's question
  (`no user query found in messages`), and the next turn had ~700 tokens
  left for thinking plus the answer. The KV cost is small here (see the
  comment in deployment.yaml), but reading a long prompt still runs at
  500-1000 tok/s.
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

## Models that don't fit as published: qwen3.8-flash-next

Installed models (2026-11-12): `qwen3:30b-a3b`, `qwen3-coder:30b`,
`gpt-oss:120b`, `qwen3.8-flash-next:125b-a6b-ud-q3_k_xl`.

Ollama's own `qwen3.8-flash-next` builds can't run here. `q4_K_M` is
111.8 GiB, more than the 96 GiB GTT pool. `nvfp4` is safetensors for
Ollama's MLX engine, not the Vulkan/llama.cpp runner, and needs 0.40.16+.

Instead it's unsloth's `UD-Q3_K_XL` GGUF (83.3 GiB) from Hugging Face,
imported by hand:

1. **Download.** `ollama pull hf.co/...` refuses sharded GGUFs. A one-off
   Job on k3s-07 mounts the `ollama-models` PVC (RWO works for a second pod
   on the same node) and downloads the 4 shards plus `mmproj-F16.gguf` into
   `/models/staging`. Use `ghcr.io/ggml-org/llama.cpp:full-b11960`.
   - One curl connection to Hugging Face gets ~13 MB/s. Parallel byte
     ranges (`curl -r`) get ~110 MB/s.
   - HTTP/2 streams sometimes reset mid-file, so retry each range until its
     size is exact.
   - Check the shards with `sha256sum` against the LFS oids from
     `https://huggingface.co/api/models/<repo>/tree/main/<dir>`.
2. **Merge.** Run
   `LD_LIBRARY_PATH=/app /app/llama-gguf-split --merge <first shard> merged.gguf`.
   It was OOM-killed at 4 Gi and 18 Gi memory limits and completed at
   64 Gi, with no model loaded.
3. **Import.** In the ollama pod, write a Modelfile, run `ollama create`,
   then delete `/models/staging`. The Modelfile copies the official build's
   renderer, parser and sampling settings (from its registry config and
   params blobs):

       FROM /models/staging/qwen3.8-flash-next/merged.gguf
       FROM /models/staging/qwen3.8-flash-next/mmproj-F16.gguf
       RENDERER qwen3.8
       PARSER qwen3.5
       PARAMETER temperature 1
       PARAMETER top_k 20
       PARAMETER top_p 0.95
       PARAMETER min_p 0
       PARAMETER presence_penalty 0
       PARAMETER repeat_penalty 1

Peak disk use was ~250 GiB: the shards, the merged file, and Ollama's copy
of it.

Measured on the 8060S (32k context, `ollama ps` says 100% GPU): ~490 tok/s prompt and
~25 tok/s generation. Context7 tool calls were 6/6 (see
`apps/open-webui/README.md`). Thinking defaults to `medium`.

`ollama ps` says 100% GPU, but llama-server reports a 27 GiB **CPU** model
buffer next to 57.5 GiB on Vulkan0. That buffer is one tensor,
`per_layer_token_embd.weight` (26.8 GiB IQ4_NL). It's an n-gram hash
embedding: 16 tables of 20M rows x 160 values. Each token reads a few rows
from it, so llama.cpp keeps it in host RAM, like `token_embd`.

During generation (2026-11-14) the GPU was 94-95% busy
(`gpu_busy_percent`) and llama-server's CPU was idle, so the buffer costs
nothing. ~25 tok/s is the GPU's limit with this architecture and quant:
- 10 of 512 experts per token, mostly IQ3_XXS/IQ4_NL
- hyper-connection and SSM layers
- "fused top-k mask not supported" on Vulkan, so the fused routing op is
  off
Upgrading to 0.40.16 (newer llama.cpp) didn't help; the fused op is still
unsupported. Same benchmark before and after (2026-11-14): 400-token
generation and a fresh ~3k-token prompt, `think: false`, temperature 0.

| Model | 0.40.12 gen / prompt | 0.40.16 gen / prompt |
|---|---|---|
| qwen3:30b-a3b | 69.4 / 1358 tok/s | 63.8-71.6 / 1385-1478 tok/s |
| gpt-oss:120b | 34.2 / 695 | 31.0-33.9 / 662-723 |
| qwen3.8-flash-next UD-Q3_K_XL | 25.9 / 501 | 23.7-23.8 / 468 |

qwen3 and gpt-oss are within run-to-run noise. flash-next was ~8% slower in
two runs. Context7 tool calls stayed 6/6 on all three. The script is a
plain `/api/generate` loop (any client in the cluster can run it).
