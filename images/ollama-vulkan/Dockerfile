# Ollama + Mesa RADV, for the Strix Halo iGPU (gfx1151) on k3s-07.
#
# The upstream image ships the Vulkan loader (libvulkan1) and Ollama's Vulkan
# backend, but no Vulkan driver, so the backend finds no GPU. The -rocm image
# is deliberately not used: on gfx1151 ROCm only sees the 512M BIOS carve-out
# (ollama#13681) and leaks KV state between requests (ollama#17847).
#
# Build + push (amd64 only):
#   docker buildx build --platform linux/amd64 \
#     -t ghcr.io/emcniece/ollama-vulkan:0.40.16 --push images/ollama-vulkan
ARG OLLAMA_VERSION=0.40.16
FROM ollama/ollama:${OLLAMA_VERSION}

RUN apt-get update \
 && apt-get install -y --no-install-recommends mesa-vulkan-drivers vulkan-tools \
 && rm -rf /var/lib/apt/lists/*

LABEL org.opencontainers.image.source="https://github.com/emcniece/homelab"
LABEL org.opencontainers.image.description="ollama/ollama with Mesa RADV Vulkan driver"
