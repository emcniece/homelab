# pve-gpu-passthrough

Host side of passing pve4's Strix Halo iGPU (Radeon 8060S, PCI `c2:00.0`, and
its HDMI audio `c2:00.1`) to k3s-07 (VM 117). The background and the reason
for each step are in `infra/amd-gpu-device-plugin/README.md`.

What it does:

- `/etc/modprobe.d/vfio.conf` and `vfio*` in `/etc/modules`, so vfio-pci
  claims the GPU before amdgpu does.
- `GRUB_CMDLINE_LINUX_DEFAULT="quiet iommu=pt initcall_blacklist=sysfb_init"`.
- Checks that `/usr/share/kvm/strixhalo-vbios.rom` is present and matches
  its sha256.
- `qm set` for `machine`, `bios`, `hostpci0/1`, `balloon` and `memory` on
  VM 117, only where they differ. It fails if the VM has no `efidisk0`.

It never reboots anything. The handlers print what needs restarting: pve4
after boot config changes, VM 117 (a full stop and start) after VM config
changes.

## Re-dumping the VBIOS

The romfile can only be read while the **host** amdgpu owns the GPU:

1. Move `/etc/modprobe.d/vfio.conf` aside, run `update-initramfs -u -k all`,
   then reboot pve4 (stop VM 117 first).
2. `cat /sys/kernel/debug/dri/0000:c2:00.0/amdgpu_vbios > /usr/share/kvm/strixhalo-vbios.rom`
   (17408 bytes, `113-STRXLGEN-001`).
3. Put `vfio.conf` back (or run this role), then reboot.
4. Update `pve_gpu_romfile_sha256` in `defaults/main.yml`.

A copy of the ACPI VFCT table is at `/root/vfct.bin` on pve4.
