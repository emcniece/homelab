#!/usr/bin/env bash
# k3s-os-upgrade.sh: rolling OS upgrade of the k3s VMs, one node at a time.
#
# For each node it brings Ubuntu up to TARGET_VERSION (one LTS hop at a time
# via do-release-upgrade) and the running kernel up to MIN_KERNEL (by
# installing KERNEL_PKG). It works from whatever release and kernel a node has:
# a node that already meets both targets is marked done and left alone.
#
# Every step is recorded in a state file. If the script stops (an error, a
# failed health check, Ctrl-C, a lost laptop connection), run it again with the
# same arguments and it picks up where it left off. Long-running remote steps
# (apt, do-release-upgrade) run detached on the node under systemd-run, so they
# keep going if this script dies and are re-attached on the next run.
#
# Runs from a workstation with kubectl access to the cluster, root SSH to the
# nodes, and SSH to a Proxmox node (for VM snapshots).
# bash 3.2 compatible (macOS /bin/bash).
#
# Usage:
#   k3s-os-upgrade.sh [options] [node ...]
#
#   With no nodes given: control-plane nodes first, then workers, each in name order.
#
# Options:
#   --plan            Show each node's current state and what would be done; change nothing.
#   --yes             Don't ask for confirmation before disrupting each node.
#   --no-snapshot     Skip the Proxmox VM snapshot and k3s etcd snapshot.
#   --state FILE      State file (default: ./k3s-os-upgrade.state). The log goes next to it.
#   --reset NODE      Forget all recorded progress for NODE, then exit.
#   -h, --help        Show this help.
#
# Environment (defaults in brackets):
#   TARGET_VERSION  [24.04]                    Ubuntu VERSION_ID to end on
#   MIN_KERNEL      [7.0]                      minimum running kernel (major.minor)
#   KERNEL_PKG      [linux-generic-hwe-24.04]  package that provides it on TARGET_VERSION
#   SSH_USER        [root]                     user for SSH to the nodes (needs root or passwordless sudo)
#   PVE_JUMP        [pve1]                     Proxmox node to run pvesh on
#   MIN_FREE_GB     [6]                        free space on / required before a release upgrade
#   DRAIN_TIMEOUT   [600s]                     kubectl drain timeout
#   SETTLE_SECONDS  [60]                       wait after each node before starting the next
#   BACKUP_STORAGE  [pbs]                      vzdump target when a VM's storage can't snapshot (empty = stop instead)
#   BACKUP_TIMEOUT  [10800]                    seconds to allow that backup
#
# Phases per node, in order (each one checks the real system before acting):
#   precheck → drain → snapshot → apt-upgrade → release-upgrade → kernel → verify → uncordon → done
#
# Notes:
#   * Drain respects PodDisruptionBudgets. If a PDB would block (e.g. a CNPG primary),
#     the script stops before draining and tells you which; switch over or scale it, then re-run.
#   * Pods using node-pinned local-path volumes can't move; they are listed and will be
#     down until their node is back.
#   * Proxmox snapshots (named pre-os-upgrade-<date>) are kept for rollback. Delete them
#     once you're happy:  qm delsnapshot <vmid> <name>   (thin-LVM snapshots grow over time).

set -uo pipefail

TARGET_VERSION="${TARGET_VERSION:-24.04}"
MIN_KERNEL="${MIN_KERNEL:-7.0}"
KERNEL_PKG="${KERNEL_PKG:-linux-generic-hwe-24.04}"
SSH_USER="${SSH_USER:-root}"
PVE_JUMP="${PVE_JUMP:-pve1}"
MIN_FREE_GB="${MIN_FREE_GB:-6}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-600s}"
SETTLE_SECONDS="${SETTLE_SECONDS:-60}"
BACKUP_STORAGE="${BACKUP_STORAGE-pbs}"
BACKUP_TIMEOUT="${BACKUP_TIMEOUT:-10800}"

STATE="./k3s-os-upgrade.state"
PLAN=0; YES=0; SNAPSHOT=1; RESET=""
NODES=""
PHASES="precheck drain snapshot apt-upgrade release-upgrade kernel verify uncordon"

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --plan) PLAN=1 ;;
    --yes) YES=1 ;;
    --no-snapshot) SNAPSHOT=0 ;;
    --state) shift; STATE="${1:?--state needs a file}" ;;
    --reset) shift; RESET="${1:?--reset needs a node}" ;;
    -h|--help) usage 0 ;;
    -*) echo "unknown option: $1" >&2; usage 1 ;;
    *) NODES="$NODES $1" ;;
  esac
  shift
done
LOG="${STATE%.state}.log"
LOCK="$STATE.lock"

# ---------------------------------------------------------------- logging/state
ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log()  { echo "$(ts) $*" | tee -a "$LOG"; }
CUR_NODE=""; CUR_PHASE=""
die() {
  log "ERROR: $*"
  [ -n "$CUR_NODE" ] && [ -n "$CUR_PHASE" ] && state_set "$CUR_NODE" "$CUR_PHASE" failed "$*"
  log "Stopped. Fix the problem and re-run the same command to resume (state: $STATE)."
  exit 1
}

# State file: append-only, tab-separated: time node phase status detail.
# The current status of (node, phase) is its last line.
state_set() { printf '%s\t%s\t%s\t%s\t%s\n' "$(ts)" "$1" "$2" "$3" "${4:-}" >> "$STATE"; }
state_get() { [ -f "$STATE" ] || return 0
  awk -F'\t' -v n="$1" -v p="$2" '$2==n && $3==p {s=$4} END {print s}' "$STATE"; }
state_detail() { [ -f "$STATE" ] || return 0
  awk -F'\t' -v n="$1" -v p="$2" '$2==n && $3==p {s=$5} END {print s}' "$STATE"; }

# ---------------------------------------------------------------- helpers
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
# ver_ge A B: true if version A >= B
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }
kmajmin() { echo "$1" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/'; }

node_ip()   { kubectl get node "$1" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'; }
is_server() { [ "$(kubectl get node "$1" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null)" = true ]; }

SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
# rsh never reads our stdin (so it can't swallow input meant for the confirmation prompt);
# rsh_in passes stdin through, for uploading job scripts.
rsh()    { local n=$1; shift; ssh -n $SSH_OPTS "$SSH_USER@$(node_ip "$n")" "$@"; }
rsh_in() { local n=$1; shift; ssh $SSH_OPTS "$SSH_USER@$(node_ip "$n")" "$@"; }
pve()    { ssh -n $SSH_OPTS "$PVE_JUMP" "$@"; }

remote_release() { rsh "$1" '. /etc/os-release; echo $VERSION_ID'; }
remote_kernel()  { rsh "$1" 'uname -r'; }
remote_bootid()  { rsh "$1" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null; }
k3s_unit()       { rsh "$1" 'systemctl list-units --no-legend --state=active "k3s*.service" | awk "{print \$1}" | head -1'; }

node_ready() { [ "$(kubectl get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ]; }
api_ready()  { [ "$(kubectl --server "https://$(node_ip "$1"):6443" get --raw /readyz 2>/dev/null)" = ok ]; }
etcd_ready() { [ "$(kubectl --server "https://$(node_ip "$1"):6443" get --raw /readyz/etcd 2>/dev/null)" = ok ]; }

servers() { kubectl get nodes -l node-role.kubernetes.io/control-plane=true -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort; }
workers() { kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort; }

control_plane_healthy() {
  local s
  for s in $(servers); do node_ready "$s" && api_ready "$s" && etcd_ready "$s" || return 1; done
}

# wait_until SECONDS DESCRIPTION CMD...   (polls every 10s; dies on timeout)
wait_until() {
  local secs=$1 what=$2; shift 2
  local end=$(( $(date +%s) + secs ))
  while ! "$@" >/dev/null 2>&1; do
    [ "$(date +%s)" -ge "$end" ] && die "timed out after ${secs}s waiting for: $what"
    sleep 10
  done
}

pods_on_node_ready() {
  kubectl get pods -A --field-selector "spec.nodeName=$1" -o json | python3 -c '
import json,sys
bad=[p["metadata"]["name"] for p in json.load(sys.stdin)["items"]
     if p["status"].get("phase")!="Succeeded"
     and not any(c["type"]=="Ready" and c["status"]=="True" for c in p["status"].get("conditions",[]))]
sys.exit(1 if bad else 0)'
}

# Pods on NODE that a drain would be blocked by (PDB with 0 disruptions allowed), and
# pods pinned to NODE by local-path volumes. Prints "pdb ns/pod (pdb-name)" / "pinned ns/pod".
drain_blockers() {
  local node=$1
  { kubectl get pods -A --field-selector "spec.nodeName=$node" -o json
    echo '#SPLIT#'
    kubectl get pdb -A -o json
    echo '#SPLIT#'
    kubectl get pv -o json
  } | python3 -c '
import json,sys
pods_s,pdb_s,pv_s=sys.stdin.read().split("#SPLIT#")
pods=json.loads(pods_s)["items"]; pdbs=json.loads(pdb_s)["items"]; pvs=json.loads(pv_s)["items"]
local={}
for pv in pvs:
    c=pv["spec"].get("claimRef") or {}
    if pv["spec"].get("storageClassName")=="local-path" or "local" in pv["spec"] or "hostPath" in pv["spec"]:
        local[(c.get("namespace"),c.get("name"))]=True
for p in pods:
    ns=p["metadata"]["namespace"]; name=p["metadata"]["name"]; lbl=p["metadata"].get("labels",{})
    if any(o["kind"]=="DaemonSet" for o in p["metadata"].get("ownerReferences",[])): continue
    for d in pdbs:
        if d["metadata"]["namespace"]!=ns: continue
        sel=d["spec"].get("selector",{}).get("matchLabels",{})
        if sel and all(lbl.get(k)==v for k,v in sel.items()) and d.get("status",{}).get("disruptionsAllowed",1)==0:
            cnpg=lbl.get("cnpg.io/cluster")
            print("pdb %s/%s (%s)%s" % (ns,name,d["metadata"]["name"], " cnpg=%s" % cnpg if cnpg else ""))
    for v in p["spec"].get("volumes",[]):
        c=v.get("persistentVolumeClaim")
        if c and (ns,c["claimName"]) in local: print("pinned %s/%s" % (ns,name)); break
'
}

# VMID and Proxmox node of the VM whose name matches the k8s node name.
vm_locate() {
  pve "pvesh get /cluster/resources --type vm --output-format json" | python3 -c '
import json,sys
m=[v for v in json.load(sys.stdin) if v.get("name")==sys.argv[1] and v.get("type")=="qemu"]
print("%s %s" % (m[0]["vmid"], m[0]["node"]) if len(m)==1 else "")' "$1"
}

# Reboot NODE and wait until it is back with a new boot id, k3s running, and the node Ready.
reboot_node() {
  local n=$1 before after
  before=$(remote_bootid "$n") || die "$n: cannot read boot id over SSH"
  log "$n: rebooting"
  rsh "$n" 'systemctl reboot' >/dev/null 2>&1 || true
  local end=$(( $(date +%s) + 900 ))
  while :; do
    sleep 15
    after=$(remote_bootid "$n") && [ -n "$after" ] && [ "$after" != "$before" ] && break
    [ "$(date +%s)" -ge "$end" ] && die "$n did not come back from reboot within 15 minutes (check the Proxmox console)"
  done
  log "$n: back up (kernel $(remote_kernel "$n"))"
  wait_until 300 "$n k3s service active" k3s_active "$n"
  wait_until 600 "$n Ready in Kubernetes" node_ready "$n"
}
k3s_active() { [ -n "$(k3s_unit "$1")" ]; }

# Run a long job detached on the node via systemd-run, and wait for it.
# remote_job NODE NAME TIMEOUT_SECS RETRY(0|1) SCRIPT
# The job writes /var/log/k3s-os-upgrade-NAME.log ending with EXIT=<code>.
# If the job is still running from an earlier invocation it is re-attached, not restarted.
# If it already finished, its exit code is reused unless RETRY=1 (the phase previously failed).
remote_job() {
  local n=$1 name=$2 timeout=$3 retry=$4 script=$5
  local unit="k3s-os-upgrade-$name" logf="/var/log/k3s-os-upgrade-$name.log"
  local status
  status=$(rsh "$n" "if systemctl is-active -q $unit; then echo running; elif grep -q '^EXIT=' $logf 2>/dev/null; then echo finished; else echo none; fi") \
    || die "$n: SSH failed while checking job $name"
  if [ "$status" = finished ] && [ "$retry" = 1 ]; then status=none; fi
  case "$status" in
    running)  log "$n: re-attaching to running job $name" ;;
    finished) log "$n: job $name already finished earlier; using its result" ;;
    none)
      log "$n: starting job $name (log on node: $logf)"
      printf '%s\n' "$script" | rsh_in "$n" "cat >/root/k3s-os-upgrade-$name.sh && systemctl reset-failed $unit 2>/dev/null; \
        systemd-run --unit=$unit --collect -E DEBIAN_FRONTEND=noninteractive -E RELEASE_UPGRADER_NO_SCREEN=1 \
        /bin/sh -c 'sh /root/k3s-os-upgrade-$name.sh > $logf 2>&1; echo EXIT=\$? >> $logf'" >/dev/null \
        || die "$n: could not start job $name"
      ;;
  esac
  local end=$(( $(date +%s) + timeout )) last=""
  while :; do
    local out
    out=$(rsh "$n" "systemctl is-active -q $unit && echo running; tail -1 $logf 2>/dev/null" 2>/dev/null) || out="ssh-error"
    case "$out" in
      *EXIT=*) break ;;
    esac
    [ "$out" != "$last" ] && [ -n "$out" ] && echo "    $(echo "$out" | tail -1 | cut -c1-150)"
    last=$out
    [ "$(date +%s)" -ge "$end" ] && die "$n: job $name still not finished after ${timeout}s (check $logf on the node)"
    sleep 20
  done
  local code
  code=$(rsh "$n" "grep '^EXIT=' $logf | tail -1 | cut -d= -f2")
  [ "$code" = 0 ] || die "$n: job $name failed with exit code $code; last lines of $logf:
$(rsh "$n" "tail -15 $logf" 2>/dev/null)"
  log "$n: job $name finished OK"
}

# ---------------------------------------------------------------- phases
# Each phase_* function is idempotent: it checks the real state first.

phase_precheck() {
  local n=$1
  rsh "$n" true || die "$n: cannot SSH as $SSH_USER@$(node_ip "$n")"
  rsh "$n" '[ "$(id -u)" = 0 ] || sudo -n true' || die "$n: $SSH_USER is not root and has no passwordless sudo"
  rsh "$n" 'command -v do-release-upgrade >/dev/null || apt-get install -y ubuntu-release-upgrader-core >/dev/null' \
    || die "$n: do-release-upgrade is missing and could not be installed"
  rsh "$n" '. /etc/os-release; [ "$ID" = ubuntu ]' || die "$n: not Ubuntu; this script only handles Ubuntu"
  [ -n "$(k3s_unit "$n")" ] || die "$n: no active k3s*.service found"
  control_plane_healthy || die "control plane not healthy (a server is NotReady or its apiserver/etcd isn't ready); not starting $n"
  local other
  for other in $(kubectl get nodes -o jsonpath='{range .items[?(@.spec.unschedulable==true)]}{.metadata.name}{"\n"}{end}'); do
    [ "$other" = "$n" ] || die "node $other is cordoned; finish or uncordon it before starting $n"
  done
}

phase_drain() {
  local n=$1 blockers
  blockers=$(drain_blockers "$n") || die "$n: could not evaluate drain blockers"
  if echo "$blockers" | grep -q '^pdb '; then
    local hints="" line ns cl
    for line in $(echo "$blockers" | grep -oE '^pdb [^/]+/[^ ]+ .* cnpg=[^ ]+' | sed -E 's#^pdb ([^/]+)/[^ ]+ .* cnpg=(.+)$#\1:\2#'); do
      ns=${line%%:*}; cl=${line#*:}
      hints="$hints
    # CNPG cluster $ns/$cl: pick a replica on another node, then make it primary
    kubectl -n $ns get pods -l cnpg.io/cluster=$cl -L cnpg.io/instanceRole -o wide
    kubectl -n $ns patch cluster $cl --type merge --subresource status -p '{\"status\":{\"targetPrimary\":\"<replica-pod-name>\"}}'
    kubectl -n $ns get cluster $cl -w   # wait for the new primary and \"Cluster in healthy state\""
    done
    die "$n: drain would be blocked by PodDisruptionBudgets:
$(echo "$blockers" | grep '^pdb ' | sed -e 's/^pdb /    /' -e 's/ cnpg=.*//')
  Move the protected pod(s) off $n first, then re-run this script.${hints:-
  (No CNPG cluster detected; scale or relocate the pod, or relax its PDB.)}"
  fi
  kubectl cordon "$n" >/dev/null || die "$n: cordon failed"
  log "$n: draining (timeout $DRAIN_TIMEOUT)"
  kubectl drain "$n" --ignore-daemonsets --delete-emptydir-data --timeout="$DRAIN_TIMEOUT" 2>&1 \
    | grep -vE '^(evicting pod|pod/.* evicted)' | tee -a "$LOG"
  [ "${PIPESTATUS[0]}" = 0 ] || die "$n: drain failed (see above). The node is still cordoned."
}

phase_snapshot() {
  local n=$1
  if [ "$SNAPSHOT" = 0 ]; then log "$n: snapshots disabled (--no-snapshot)"; return 0; fi
  if is_server "$n"; then
    local snapname="pre-os-upgrade-$n-$(date +%Y%m%d-%H%M%S)"
    rsh "$n" "k3s etcd-snapshot save --name $snapname >/dev/null 2>&1 || k3s etcd-snapshot --name $snapname >/dev/null 2>&1" \
      || die "$n: k3s etcd snapshot failed"
    log "$n: k3s etcd snapshot saved ($snapname, under /var/lib/rancher/k3s/server/db/snapshots)"
  fi
  local loc vmid host name
  loc=$(vm_locate "$n") || die "could not query Proxmox via $PVE_JUMP"
  [ -n "$loc" ] || die "$n: no unique Proxmox VM named $n found"
  vmid=${loc% *}; host=${loc#* }
  name="pre-os-upgrade-$(date +%Y%m%d)"
  if pve "pvesh get /nodes/$host/qemu/$vmid/snapshot --output-format json" | grep -q "\"name\":\"pre-os-upgrade-"; then
    log "$n: Proxmox snapshot pre-os-upgrade-* already exists on VM $vmid; not taking another"
    return 0
  fi
  local cap
  cap=$(pve "pvesh get /nodes/$host/qemu/$vmid/feature --feature snapshot --output-format json" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("hasFeature",0))') || die "$n: could not query snapshot support for VM $vmid"
  if [ "$cap" = 1 ]; then
    log "$n: taking Proxmox snapshot $name of VM $vmid on $host"
    pve_task "$host" 600 "snapshot of VM $vmid" \
      "pvesh create /nodes/$host/qemu/$vmid/snapshot --snapname $name --description 'before k3s-os-upgrade.sh'"
    snapshot_exists "$host" "$vmid" "$name" || die "$n: snapshot task finished but $name is not listed on VM $vmid"
    log "$n: Proxmox snapshot $name taken"
  elif [ -n "$BACKUP_STORAGE" ]; then
    # e.g. disks on thick LVM, which can't be snapshotted. A vzdump to PBS is the
    # rollback point instead; with a recent backup and a running VM it's incremental.
    log "$n: VM $vmid's storage doesn't support snapshots; backing it up to '$BACKUP_STORAGE' instead"
    pve_task "$host" "$BACKUP_TIMEOUT" "vzdump of VM $vmid to $BACKUP_STORAGE" \
      "pvesh create /nodes/$host/vzdump --vmid $vmid --storage $BACKUP_STORAGE --mode snapshot --notes-template 'pre-os-upgrade {{guestname}}'"
    log "$n: backup of VM $vmid to $BACKUP_STORAGE done (restore with qmrestore / the PBS UI if needed)"
  else
    die "$n: VM $vmid's storage doesn't support snapshots and BACKUP_STORAGE is empty.
  Set BACKUP_STORAGE=<pve backup storage>, or re-run with --no-snapshot to proceed without a rollback point."
  fi
}
snapshot_exists() {
  pve "pvesh get /nodes/$1/qemu/$2/snapshot --output-format json" | grep -q "\"name\":\"$3\""
}

# pve_task HOST TIMEOUT DESCRIPTION "pvesh create ..."
# Starts a Proxmox task and waits for it to finish; dies unless it ends with status OK.
# (pvesh returns as soon as the task is queued, so its exit code alone means nothing.)
pve_task() {
  local host=$1 timeout=$2 what=$3 cmd=$4 out upid
  out=$(pve "$cmd" 2>&1) || die "$what: could not start ($out)"
  upid=$(printf '%s\n' "$out" | grep -oE 'UPID:[^ "]+' | head -1)
  if [ -z "$upid" ]; then   # pvesh ran it synchronously and printed the task log
    printf '%s\n' "$out" | grep -q 'TASK OK' && return 0
    die "$what failed: $(printf '%s\n' "$out" | tail -3)"
  fi
  local end=$(( $(date +%s) + timeout )) st
  while :; do
    st=$(pve "pvesh get /nodes/$host/tasks/$upid/status --output-format json" \
         | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("status",""), d.get("exitstatus",""))') || st="? ?"
    case "$st" in
      "stopped OK") return 0 ;;
      stopped*) die "$what failed: ${st#stopped }
$(pve "pvesh get /nodes/$host/tasks/$upid/log --output-format json" | python3 -c 'import json,sys; [print("    "+l["t"]) for l in json.load(sys.stdin)[-6:]]' 2>/dev/null)" ;;
    esac
    [ "$(date +%s)" -ge "$end" ] && die "$what still running after ${timeout}s (task $upid)"
    sleep 10
  done
}

APT_SCRIPT='set -e
dpkg --configure -a
apt-get update
apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
apt-get -y autoremove --purge
apt-get clean'

phase_apt_upgrade() {
  local n=$1 retry=$2
  remote_job "$n" apt 3600 "$retry" "$APT_SCRIPT"
  if rsh "$n" 'test -f /var/run/reboot-required'; then reboot_node "$n"; fi
}

phase_release_upgrade() {
  local n=$1 retry=$2 rel hop=0
  while :; do
    rel=$(remote_release "$n") || die "$n: cannot read /etc/os-release"
    if ver_ge "$rel" "$TARGET_VERSION"; then log "$n: release is $rel"; return 0; fi
    hop=$((hop+1)); [ $hop -le 3 ] || die "$n: still on $rel after 3 release upgrades; stopping"
    local free
    free=$(rsh "$n" "df -BG --output=avail / | tail -1 | tr -dc 0-9")
    [ "${free:-0}" -ge "$MIN_FREE_GB" ] || die "$n: only ${free}G free on /, need ${MIN_FREE_GB}G for a release upgrade.
  Free space (e.g. journalctl --vacuum-size=200M; remove old kernels; grow the disk), then re-run."
    rsh "$n" "sed -i 's/^Prompt=.*/Prompt=lts/' /etc/update-manager/release-upgrades" || die "$n: could not set Prompt=lts"
    if rsh "$n" 'test -f /var/run/reboot-required'; then reboot_node "$n"; fi
    log "$n: upgrading from $rel to the next LTS release (this takes a while)"
    remote_job "$n" "release-from-$rel" 7200 "$retry" \
      'do-release-upgrade -f DistUpgradeViewNonInteractive'
    retry=0
    reboot_node "$n"
    local newrel
    newrel=$(remote_release "$n")
    [ "$newrel" != "$rel" ] || die "$n: do-release-upgrade reported success but the release is still $rel (see /var/log/dist-upgrade/ on the node)"
    log "$n: now on $newrel"
  done
}

phase_kernel() {
  local n=$1 k
  k=$(remote_kernel "$n") || die "$n: cannot read kernel version"
  if ver_ge "$(kmajmin "$k")" "$MIN_KERNEL"; then log "$n: kernel $k meets $MIN_KERNEL"; return 0; fi
  rsh "$n" "apt-cache policy $KERNEL_PKG | grep -q 'Candidate: [0-9]'" \
    || die "$n: package $KERNEL_PKG is not available on $(remote_release "$n"); set KERNEL_PKG"
  log "$n: kernel $k is older than $MIN_KERNEL; installing $KERNEL_PKG"
  remote_job "$n" kernel 1800 1 "set -e
apt-get update
apt-get install -y $KERNEL_PKG"
  local newest
  newest=$(rsh "$n" "ls /boot/vmlinuz-* | sed 's|/boot/vmlinuz-||' | sort -V | tail -1")
  ver_ge "$(kmajmin "$newest")" "$MIN_KERNEL" || die "$n: newest installed kernel is $newest, still older than $MIN_KERNEL"
  reboot_node "$n"
  k=$(remote_kernel "$n")
  ver_ge "$(kmajmin "$k")" "$MIN_KERNEL" || die "$n: rebooted but running kernel is $k (expected $newest; check the GRUB default)"
  log "$n: running kernel $k"
}

phase_verify() {
  local n=$1
  wait_until 300 "$n k3s service active" k3s_active "$n"
  wait_until 600 "$n Ready" node_ready "$n"
  if is_server "$n"; then
    wait_until 300 "$n apiserver /readyz" api_ready "$n"
    wait_until 300 "$n etcd /readyz/etcd" etcd_ready "$n"
  fi
  wait_until 300 "control plane healthy" control_plane_healthy
  local rel k
  rel=$(remote_release "$n"); k=$(remote_kernel "$n")
  ver_ge "$rel" "$TARGET_VERSION" || die "$n: release is $rel, expected $TARGET_VERSION"
  ver_ge "$(kmajmin "$k")" "$MIN_KERNEL" || die "$n: kernel is $k, expected >= $MIN_KERNEL"
  log "$n: verified: Ubuntu $rel, kernel $k, $(k3s_unit "$n") active, node Ready"
}

phase_uncordon() {
  local n=$1
  kubectl uncordon "$n" >/dev/null || die "$n: uncordon failed"
  wait_until 900 "all pods on $n Ready" pods_on_node_ready "$n"
  log "$n: uncordoned, all pods on it Ready"
}

# ---------------------------------------------------------------- per-node driver
node_meets_target() {
  local n=$1 rel k
  rel=$(remote_release "$n" 2>/dev/null) || return 1
  k=$(remote_kernel "$n" 2>/dev/null) || return 1
  ver_ge "$rel" "$TARGET_VERSION" && ver_ge "$(kmajmin "$k")" "$MIN_KERNEL"
}

describe_node() {
  local n=$1 role rel k pend free ph s
  is_server "$n" && role=server || role=agent
  rel=$(remote_release "$n" 2>/dev/null || echo '?'); k=$(remote_kernel "$n" 2>/dev/null || echo '?')
  free=$(rsh "$n" "df -BG --output=avail / | tail -1 | tr -dc 0-9" 2>/dev/null || echo '?')
  pend=$(rsh "$n" "apt-get -s -o Debug::NoLocking=1 full-upgrade 2>/dev/null | grep -c ^Inst; true" 2>/dev/null || echo '?')
  printf '%-8s %-6s Ubuntu %-6s kernel %-22s %3s pending pkgs  %sG free on /\n' "$n" "$role" "$rel" "$k" "$pend" "$free"
  local done_list=""
  for ph in $PHASES done; do
    s=$(state_get "$n" "$ph"); [ -n "$s" ] && done_list="$done_list $ph=$s"
  done
  [ -n "$done_list" ] && echo "         state:$done_list"
  if [ "$(state_get "$n" done)" = done ]; then echo "         → already done"
  elif [ "$rel" != '?' ] && [ "$k" != '?' ] && ver_ge "$rel" "$TARGET_VERSION" && ver_ge "$(kmajmin "$k")" "$MIN_KERNEL"; then
    echo "         → already meets target; would be marked done without changes"
  else
    local steps=""
    ver_ge "$rel" "$TARGET_VERSION" 2>/dev/null || steps="${steps} release-upgrade(${rel} -> ${TARGET_VERSION})"
    ver_ge "$(kmajmin "$k")" "$MIN_KERNEL" 2>/dev/null || steps="$steps kernel(→$MIN_KERNEL via $KERNEL_PKG unless the new release already provides it)"
    echo "         → would: drain, snapshot, apt full-upgrade,$steps, verify, uncordon"
    [ "$free" != '?' ] && [ "$free" -lt "$MIN_FREE_GB" ] && ! ver_ge "$rel" "$TARGET_VERSION" && \
      echo "         ! only ${free}G free on /; the release upgrade needs ${MIN_FREE_GB}G"
    local b; b=$(drain_blockers "$n" 2>/dev/null)
    [ -n "$b" ] && echo "$b" | sed 's/^/         ! /'
  fi
  return 0
}

confirm_node() {
  local n=$1
  [ "$YES" = 1 ] && return 0
  [ -t 0 ] || die "not running interactively; pass --yes to proceed without confirmation"
  echo
  describe_node "$n"
  printf 'Proceed with %s? [y/N] ' "$n"
  local a; read -r a
  case "$a" in y|Y|yes) return 0 ;; *) log "$n: skipped by user; stopping"; exit 0 ;; esac
}

upgrade_node() {
  local n=$1 ph s fn
  CUR_NODE=$n
  if [ "$(state_get "$n" done)" = done ]; then log "$n: already done"; return 0; fi
  # A node that meets the target and was never started needs nothing.
  if [ -z "$(state_get "$n" precheck)" ] && node_meets_target "$n"; then
    log "$n: already Ubuntu >= $TARGET_VERSION with kernel >= $MIN_KERNEL; nothing to do"
    state_set "$n" done done "already at target"
    return 0
  fi
  if [ -z "$(state_get "$n" drain)" ] || [ "$(state_get "$n" drain)" = failed ]; then confirm_node "$n"; fi
  log "=== $n"
  for ph in $PHASES; do
    s=$(state_get "$n" "$ph")
    [ "$s" = done ] && continue
    local retry=0; [ "$s" = failed ] && retry=1
    CUR_PHASE=$ph
    [ -n "$s" ] && log "$n: resuming phase $ph (was: $s)"
    state_set "$n" "$ph" running
    fn="phase_$(echo "$ph" | tr - _)"
    "$fn" "$n" "$retry"
    state_set "$n" "$ph" done
  done
  CUR_PHASE=""
  state_set "$n" done done
  WORKED=1
  log "$n: DONE"
}

# ---------------------------------------------------------------- main
need kubectl; need ssh; need python3; need awk; need sort

if [ -n "$RESET" ]; then
  [ -f "$STATE" ] && { grep -v "	$RESET	" "$STATE" > "$STATE.tmp"; mv "$STATE.tmp" "$STATE"; }
  echo "Cleared recorded progress for $RESET in $STATE"; exit 0
fi

kubectl get nodes >/dev/null 2>&1 || { echo "kubectl cannot reach the cluster" >&2; exit 1; }
[ -n "${NODES// }" ] || NODES="$(servers) $(workers)"
for n in $NODES; do kubectl get node "$n" >/dev/null 2>&1 || { echo "unknown node: $n" >&2; exit 1; }; done

if [ "$PLAN" = 1 ]; then
  echo "Target: Ubuntu $TARGET_VERSION, kernel >= $MIN_KERNEL ($KERNEL_PKG). State: $STATE"
  echo "Order: $(echo $NODES)"
  echo
  for n in $NODES; do describe_node "$n"; done
  exit 0
fi

if ! mkdir "$LOCK" 2>/dev/null; then
  echo "Another run holds $LOCK (pid $(cat "$LOCK/pid" 2>/dev/null || echo '?')). If it is not running, remove $LOCK." >&2
  exit 1
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT
trap 'log "interrupted"; [ -n "$CUR_NODE" ] && [ -n "$CUR_PHASE" ] && state_set "$CUR_NODE" "$CUR_PHASE" interrupted; exit 130' INT TERM

log "start: target Ubuntu $TARGET_VERSION, kernel >= $MIN_KERNEL; nodes: $(echo $NODES)"
WORKED=0   # set by upgrade_node when it actually upgraded a node
for n in $NODES; do
  if [ "$WORKED" = 1 ] && [ "$(state_get "$n" done)" != done ]; then
    log "settling ${SETTLE_SECONDS}s before $n"; sleep "$SETTLE_SECONDS"
    wait_until 300 "control plane healthy before $n" control_plane_healthy
    WORKED=0
  fi
  upgrade_node "$n"
done
log "all nodes done: $(echo $NODES)"
log "Remember to delete the Proxmox snapshots (pre-os-upgrade-*) once you're satisfied."
