#!/usr/bin/env bash
# build-ubuntu-template.sh: build a Proxmox VM template from the official Ubuntu
# cloud image, ready to clone for k3s nodes.
#
# Run on a Proxmox node as root:
#   ./build-ubuntu-template.sh                 # VMID 8001, tpl-ubuntu-2404-cloud, on local-lvm
#   VMID=8002 STORAGE=cephpool1 ./build-ubuntu-template.sh
#   ./build-ubuntu-template.sh --replace       # destroy and rebuild an existing template of the same VMID+name
#
# What it does:
#   1. Downloads <release>-server-cloudimg-amd64.img from cloud-images.ubuntu.com
#      (cached in CACHE_DIR) and verifies its SHA256 against the published SHA256SUMS.
#   2. Creates the VM (virtio-scsi, serial console, guest agent, cloud-init drive),
#      imports the image as scsi0 and grows it to DISK_SIZE.
#   3. Boots it once with a build-only cloud-init user-data snippet that does
#      apt full-upgrade and installs qemu-guest-agent + KERNEL_PKG (+ EXTRA_PKGS).
#   4. Through the guest agent: waits for cloud-init to finish, verifies the
#      packages, records the versions, then cleans the image for cloning
#      (cloud-init state, machine-id, SSH host keys, apt cache, fstrim).
#   5. Shuts down, swaps the build user-data for normal Proxmox cloud-init
#      settings (CI_USER, SSH keys from SSH_KEYS_FILE, DHCP), writes the build
#      details into the VM description, and converts it to a template.
#
# Clone it with e.g.:
#   qm clone 8001 118 --name k3s-08 --full --storage local-lvm
#   qm set 118 --ipconfig0 ip=192.168.10.45/24,gw=192.168.10.1 --memory 16384 --cores 8
#   qm start 118
#
# Requirements:
#   * SNIPPET_STORAGE must allow "snippets" content. The script checks and stops
#     if not; enable it on the default "local" storage with:
#       pvesm set local --content vztmpl,backup,iso,snippets
#   * Outbound HTTPS from this node and from the VM (for apt).
#
# Environment (defaults in brackets):
#   VMID             [8001]
#   NAME             [tpl-ubuntu-2404-cloud]
#   RELEASE          [noble]                    Ubuntu codename for the cloud image
#   KERNEL_PKG       [linux-generic-hwe-24.04]  kernel metapackage to preinstall (empty = keep the image's)
#   EXTRA_PKGS       []                         space-separated extra packages to bake in
#   STORAGE          [local-lvm]                where the template disk + cloud-init drive go
#   SNIPPET_STORAGE  [local]
#   BRIDGE           [vmbr0]
#   DISK_SIZE        [20G]
#   MEMORY           [2048]                     MiB, used for the build and as the clone default
#   CORES            [2]
#   CPU_TYPE         [x86-64-v2-AES]            migration-safe across the Xeon/Ryzen hosts
#   CI_USER          [root]                     cloud-init user for clones
#   SSH_KEYS_FILE    [/root/.ssh/authorized_keys]  public keys baked into the template's cloud-init
#   CACHE_DIR        [/var/lib/vz/template/cloudimg]
#   BUILD_TIMEOUT    [1800]                     seconds to wait for the first-boot build

set -euo pipefail

VMID="${VMID:-8001}"
NAME="${NAME:-tpl-ubuntu-2404-cloud}"
RELEASE="${RELEASE:-noble}"
KERNEL_PKG="${KERNEL_PKG-linux-generic-hwe-24.04}"
EXTRA_PKGS="${EXTRA_PKGS:-}"
STORAGE="${STORAGE:-local-lvm}"
SNIPPET_STORAGE="${SNIPPET_STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr0}"
DISK_SIZE="${DISK_SIZE:-20G}"
MEMORY="${MEMORY:-2048}"
CORES="${CORES:-2}"
CPU_TYPE="${CPU_TYPE:-x86-64-v2-AES}"
CI_USER="${CI_USER:-root}"
SSH_KEYS_FILE="${SSH_KEYS_FILE:-/root/.ssh/authorized_keys}"
CACHE_DIR="${CACHE_DIR:-/var/lib/vz/template/cloudimg}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-1800}"
IMAGE_BASE="https://cloud-images.ubuntu.com/$RELEASE/current"
IMAGE_FILE="$RELEASE-server-cloudimg-amd64.img"

REPLACE=0
for a in "$@"; do
  case "$a" in
    --replace) REPLACE=1 ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 1 ;;
  esac
done

log() { echo "$(date '+%F %T') $*"; }
die() { log "ERROR: $*"; exit 1; }
SNIPPET_VOL=""
on_exit() {
  local rc=$?
  [ -n "$SNIPPET_VOL" ] && rm -f "$(pvesm path "$SNIPPET_VOL" 2>/dev/null)" 2>/dev/null || true
  if [ $rc -ne 0 ] && qm status "$VMID" >/dev/null 2>&1; then
    log "Build failed. VM $VMID was left in place for inspection (console: qm terminal $VMID)."
    log "Re-run with --replace to start over."
  fi
}
trap on_exit EXIT

# guest-exec CMD...: run a command in the VM through the guest agent; prints its stdout,
# returns its exit code. Output also captured in $GX_ERR (stderr).
GX_ERR=""
gexec() {
  local json
  json=$(qm guest exec "$VMID" --timeout "$BUILD_TIMEOUT" -- "$@") || return 125
  GX_ERR=$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("err-data",""), end="")')
  printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("out-data",""), end="")'
  return "$(printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("exitcode", 125) if d.get("exited") else 124)')"
}

# ------------------------------------------------------------------ preflight
[ "$(id -u)" = 0 ] || die "run as root on a Proxmox node"
command -v qm >/dev/null && command -v pvesm >/dev/null || die "qm/pvesm not found; run this on a Proxmox node"
for c in curl python3 sha256sum; do command -v $c >/dev/null || die "missing command: $c"; done

pvesm status --content images 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$STORAGE" \
  || die "storage '$STORAGE' doesn't exist on this node or doesn't allow disk images"
if ! pvesm status --content snippets 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$SNIPPET_STORAGE"; then
  cur=$(pvesh get "/storage/$SNIPPET_STORAGE" --output-format json 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("content",""))' 2>/dev/null || true)
  die "storage '$SNIPPET_STORAGE' doesn't allow snippets. Enable it with:
    pvesm set $SNIPPET_STORAGE --content ${cur:+$cur,}snippets"
fi
[ -s "$SSH_KEYS_FILE" ] || die "SSH_KEYS_FILE '$SSH_KEYS_FILE' is missing or empty"

if qm status "$VMID" >/dev/null 2>&1; then
  existing=$(qm config "$VMID" | awk '/^name:/{print $2}')
  [ "$REPLACE" = 1 ] || die "VMID $VMID already exists ($existing). Use --replace to rebuild it, or set VMID."
  [ "$existing" = "$NAME" ] || die "VMID $VMID is '$existing', not '$NAME'; refusing to replace it"
  log "replacing existing VM $VMID ($existing)"
  qm destroy "$VMID" --purge >/dev/null || die "could not destroy VM $VMID (does it have linked clones?)"
elif pvesh get /cluster/resources --type vm --output-format json | python3 -c "import json,sys; sys.exit(0 if any(v.get('vmid')==$VMID for v in json.load(sys.stdin)) else 1)"; then
  die "VMID $VMID is in use on another cluster node"
fi

# ------------------------------------------------------------------ image
mkdir -p "$CACHE_DIR"
log "fetching $IMAGE_BASE/SHA256SUMS"
sums=$(curl -fsSL "$IMAGE_BASE/SHA256SUMS") || die "could not download SHA256SUMS"
want=$(printf '%s\n' "$sums" | awk -v f="$IMAGE_FILE" '$2=="*"f || $2==f {print $1}')
[ -n "$want" ] || die "no checksum for $IMAGE_FILE in SHA256SUMS"
serial=$(curl -fsSL "$IMAGE_BASE/unpacked/build-info.txt" 2>/dev/null | awk -F= '/^serial=/{print $2}') || true
img="$CACHE_DIR/${IMAGE_FILE%.img}-${serial:-${want:0:12}}.img"
if [ -f "$img" ] && [ "$(sha256sum "$img" | cut -d' ' -f1)" = "$want" ]; then
  log "using cached image $img"
else
  log "downloading $IMAGE_FILE (serial ${serial:-unknown})"
  curl -fL --progress-bar -o "$img.part" "$IMAGE_BASE/$IMAGE_FILE" || die "download failed"
  [ "$(sha256sum "$img.part" | cut -d' ' -f1)" = "$want" ] || { rm -f "$img.part"; die "SHA256 mismatch for downloaded image"; }
  mv "$img.part" "$img"
  log "image verified: sha256 $want"
fi

# ------------------------------------------------------------------ build-time user-data
SNIPPET_VOL="$SNIPPET_STORAGE:snippets/$NAME-$VMID-build.yaml"
snippet_path=$(pvesm path "$SNIPPET_VOL")
mkdir -p "$(dirname "$snippet_path")"
{
  echo "#cloud-config"
  echo "package_update: true"
  echo "package_upgrade: true"
  echo "packages:"
  echo "  - qemu-guest-agent"
  [ -n "$KERNEL_PKG" ] && echo "  - $KERNEL_PKG"
  for p in $EXTRA_PKGS; do echo "  - $p"; done
  echo "runcmd:"
  echo "  - [systemctl, start, qemu-guest-agent]"
} > "$snippet_path"

# ------------------------------------------------------------------ create VM
log "creating VM $VMID ($NAME) on $STORAGE"
qm create "$VMID" --name "$NAME" --ostype l26 --memory "$MEMORY" --cores "$CORES" --cpu "$CPU_TYPE" \
  --net0 "virtio,bridge=$BRIDGE" --scsihw virtio-scsi-pci --serial0 socket --vga serial0 \
  --agent enabled=1,fstrim_cloned_disks=1 >/dev/null

log "importing disk"
qm disk import "$VMID" "$img" "$STORAGE" --format raw >/dev/null
vol=$(qm config "$VMID" | awk -F': ' '/^unused0:/{print $2}')
[ -n "$vol" ] || die "imported disk not found in VM config"
qm set "$VMID" --scsi0 "$vol,discard=on,ssd=1" --boot order=scsi0 --ide2 "$STORAGE:cloudinit" >/dev/null
qm disk resize "$VMID" scsi0 "$DISK_SIZE" >/dev/null
qm set "$VMID" --ipconfig0 ip=dhcp --cicustom "user=$SNIPPET_VOL" >/dev/null

# ------------------------------------------------------------------ first boot
log "booting for the build (apt full-upgrade + ${KERNEL_PKG:-no kernel change}${EXTRA_PKGS:+ + $EXTRA_PKGS}); timeout ${BUILD_TIMEOUT}s"
qm start "$VMID"
end=$(( $(date +%s) + BUILD_TIMEOUT ))
until qm agent "$VMID" ping >/dev/null 2>&1; do
  [ "$(date +%s)" -lt "$end" ] || die "guest agent never came up (cloud-init may have failed to install packages; check: qm terminal $VMID)"
  qm status "$VMID" | grep -q running || die "VM stopped during the build"
  sleep 10
done
log "guest agent is up; waiting for cloud-init to finish"
set +e
ci_out=$(gexec cloud-init status --wait --long); ci_rc=$?
set -e
case $ci_rc in
  0) log "cloud-init: done" ;;
  2) log "WARNING: cloud-init finished with recoverable errors:"; printf '%s\n' "$ci_out" | sed 's/^/    /' ;;
  *) printf '%s\n%s\n' "$ci_out" "$GX_ERR" | sed 's/^/    /'; die "cloud-init failed (exit $ci_rc)" ;;
esac

pkgs="qemu-guest-agent $KERNEL_PKG $EXTRA_PKGS"
versions=$(gexec dpkg-query -W -f='${Package} ${Version} ${Status}\n' $pkgs) || die "package check failed: $GX_ERR"
printf '%s\n' "$versions" | grep -v "install ok installed" | grep -q . && die "packages not installed:
$versions"
os=$(gexec sh -c '. /etc/os-release; echo $PRETTY_NAME')
newest_kernel=$(gexec sh -c 'ls /boot/vmlinuz-* | sed "s|/boot/vmlinuz-||" | sort -V | tail -1')
log "built: $os, newest kernel $newest_kernel"
printf '%s\n' "$versions" | awk '{print "    " $1, $2}'

log "cleaning the image for cloning"
gexec sh -c 'apt-get clean && rm -rf /var/lib/apt/lists/* \
  && cloud-init clean --logs --seed --machine-id \
  && rm -f /etc/ssh/ssh_host_* /etc/netplan/50-cloud-init.yaml \
  && truncate -s0 /root/.bash_history 2>/dev/null; fstrim -av >/dev/null; sync' >/dev/null \
  || die "cleanup inside the VM failed: $GX_ERR"

log "shutting down"
qm shutdown "$VMID" --timeout 180 || die "VM did not shut down cleanly"

# ------------------------------------------------------------------ finalize
qm set "$VMID" --delete cicustom >/dev/null
qm set "$VMID" --ciuser "$CI_USER" --sshkeys "$SSH_KEYS_FILE" --ipconfig0 ip=dhcp >/dev/null
desc="Ubuntu cloud template built by build-ubuntu-template.sh on $(hostname) at $(date -u '+%F %TZ').

Source: $IMAGE_BASE/$IMAGE_FILE
Serial: ${serial:-unknown}
SHA256: $want

$os, newest kernel $newest_kernel
$(printf '%s\n' "$versions" | awk '{print $1, $2}')"
qm set "$VMID" --description "$desc" >/dev/null
qm template "$VMID"
log "DONE: template $VMID ($NAME) on $STORAGE"
log "Clone with: qm clone $VMID <newid> --name <name> --full --storage <storage>"
