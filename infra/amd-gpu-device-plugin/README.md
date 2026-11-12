# AMD GPU device plugin

Advertises `amd.com/gpu` on nodes labelled `gpu=true`. Today that is only
**k3s-07** (VMID 117 on pve4), which has pve4's Strix Halo iGPU
(Ryzen AI Max+ 395 / Radeon 8060S, `gfx1151`, PCI `c2:00.0`) passed through.

```sh
kubectl apply -f infra/amd-gpu-device-plugin/daemonset.yaml
```

Request it from a workload:

```yaml
nodeSelector: {gpu: "true"}
resources:
  limits: {amd.com/gpu: 1}
```

Smoke test (ROCm >= 6.4 is needed for gfx1151; `rocm/dev-ubuntu-24.04:7.2.4` works):
`rocminfo | grep gfx` should show `gfx1151`.

The `allocator init failed ... p2pWeights` error in the plugin log is
harmless with a single GPU (it falls back to kubelet default allocation).

## How the passthrough is set up

Each of these was needed; skipping any one breaks it.

### pve4 host

- `/etc/modprobe.d/vfio.conf` binds the GPU and its HDMI audio to vfio-pci
  before amdgpu can claim them:
  ```
  options vfio-pci ids=1002:1586,1002:1640 disable_vga=1
  softdep amdgpu pre: vfio-pci
  softdep snd_hda_intel pre: vfio-pci
  ```
  plus `vfio`, `vfio_iommu_type1`, `vfio_pci` in `/etc/modules`.
- GRUB: `GRUB_CMDLINE_LINUX_DEFAULT="quiet iommu=pt initcall_blacklist=sysfb_init"`.
  `initcall_blacklist=sysfb_init` matters: without it the host's `simpledrm`
  boot framebuffer (BOOTFB) holds the GPU's 512M BAR0, QEMU logs
  `Failed to mmap 0000:c2:00.0 BAR 0`, and the guest's amdgpu fails with
  `PSP: Failed to load toc`.
- VBIOS dumped while the host amdgpu still owned the GPU:
  `cat /sys/kernel/debug/dri/0000:c2:00.0/amdgpu_vbios > /usr/share/kvm/strixhalo-vbios.rom`
  (17408 bytes, `113-STRXLGEN-001`). A copy of the ACPI VFCT table is at
  `/root/vfct.bin`. To re-dump, temporarily remove `vfio.conf`, rebuild the
  initramfs and reboot.
- After any of the above: `update-grub && update-initramfs -u -k all`, reboot.

### VM 117 (k3s-07)

- `machine: q35`, `bios: ovmf` + `efidisk0`. SeaBIOS hangs silently (no
  serial output at all) executing the iGPU option ROM.
- `hostpci0: 0000:c2:00.0,pcie=1,romfile=strixhalo-vbios.rom`
- `hostpci1: 0000:c2:00.1,pcie=1`
- `balloon: 0` (passthrough pins all guest RAM).

The VM can't live-migrate. If pve4 goes down, k3s-07 goes with it.

### Guest

- Ubuntu **24.04** with the HWE kernel (`linux-generic-hwe-24.04`, 7.0). The
  other k3s nodes are still on 22.04 / 5.15, which has no gfx1151 support.
- GPU firmware copied from pve4's `pve-firmware` into
  `/lib/firmware/updates/amdgpu/` (overrides Ubuntu's `linux-firmware`):
  `gc_11_5_1_*`, `psp_14_0_1_*`, `sdma_6_1_1*`, `vcn_4_0_6*`, `dcn_3_5_1_*`,
  `vpe_6_1_1*`, `isp_4_1_1*`. Then `update-initramfs -u`.

### Memory

VRAM is only the BIOS UMA carve-out (512M). Compute workloads use GTT, which
amdgpu sizes at ~half of guest RAM (~47 GiB of 96 GiB). To give the GPU more,
raise the UMA size in pve4's BIOS, or set `ttm.pages_limit` /
`amdgpu.gttsize` on the guest kernel cmdline.
