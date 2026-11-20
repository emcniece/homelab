# Wolf (game streaming)

[Wolf](https://games-on-whales.github.io/wolf/stable/) streams Steam and other
apps from **k3s-07** to Moonlight clients. Rendering and the stream's video
encoding use pve4's Radeon 8060S. The GPU is shared with Ollama.

- Connect Moonlight to **192.168.10.44** (k3s-07). It may also appear
  automatically as "Wolf" through mDNS.
- Pairing: Moonlight shows a PIN. Wolf logs a URL like
  `http://localhost:47989/pin/#XXXXXXXX`. Open it as
  `http://192.168.10.44:47989/pin/#XXXXXXXX` and enter the PIN there:
  `kubectl -n wolf logs deploy/wolf -c wolf | grep pin`
- Moonlight lists **Steam** directly. **Wolf UI** leads to the other apps
  (Firefox, RetroArch, Lutris, ...).

```sh
kubectl apply -f apps/wolf/
```

## How it's put together

Wolf starts each app as a Docker container through a Docker API socket.
k3s-07 runs only containerd, so a privileged **docker:dind sidecar** provides
that socket at `/docker-sock/docker.sock`. Paths Wolf passes to dockerd for
bind mounts are resolved in the sidecar's filesystem. For that reason,
`/etc/wolf`, `/tmp/sockets`, `/dev` and `/run/udev` are mounted at identical
paths in both containers.

- `hostNetwork: true` is needed for Moonlight's UDP ports and for the udev
  netlink events that virtual gamepad hotplug depends on. Ports: TCP
  47984/47989/48010, UDP 47999/48100/48200.
- The sidecar is started with `command: [dind, dockerd]` so that it skips
  `dockerd-entrypoint.sh`. With TLS off, that entrypoint adds
  `--host=tcp://0.0.0.0:2375`, which on the host network is an unauthenticated
  root API on the LAN. Check after any change:
  `ssh root@192.168.10.44 'ss -ltn | grep 2375'` should print nothing.
- The sidecar gets its own emptyDir at `/tmp`. Without it, the `dind` wrapper
  mounts a tmpfs over `/tmp`, which hides the shared `/tmp/sockets`. Every app
  then exits immediately (Steam: sway `Could not connect to remote display`,
  Wolf UI: exit 139), because Docker bind-mounts empty directories in place of
  the Wayland/Pulse sockets.
- The sidecar has a 4 GiB memory-backed `/dev/shm`. Apps use `IpcMode: host`,
  which means the sidecar's `/dev/shm`, and the kubelet default is 64M.
  Steam's CEF UI fills that and shows a black screen.
- dockerd runs with `--bridge=none --iptables=false`, so it never touches the
  host's iptables. If Docker created docker0, it would set FORWARD to DROP and
  break pod networking. As a result, an app container gets only loopback
  unless its `base_create_json` sets `"NetworkMode": "host"`.

## State (k3s-07 root disk)

| Host path | What |
|---|---|
| `/var/lib/wolf/etc` → `/etc/wolf` | `cfg/config.toml`, certs, paired clients, per-app home dirs **including the Steam library** |
| `/var/lib/wolf/docker` | dind image store (Steam image ~3 GB) |

Games install onto the root disk, which had 113G free at setup. Kubelet evicts
pods on DiskPressure, so watch it. If the library grows, give it a dedicated
virtual disk as was done for Ollama (`apps/ollama/storage.yaml`).

## config.toml changes

Wolf generates `/etc/wolf/cfg/config.toml` on first start and rewrites it
(e.g. when clients pair), so it is not stored in the repo. Its defaults were
patched as follows (the original is kept at `config.toml.orig`):

1. Added `"NetworkMode": "host",` to every app's `HostConfig` (see above).
2. Changed the Wolf UI mount `/var/run/wolf/wolf.sock:...` to
   `/tmp/sockets/wolf.sock:/var/run/wolf/wolf.sock`. Wolf's API socket is
   in `XDG_RUNTIME_DIR`, and Wolf can't infer mounts ("No valid container ID
   found in mountinfo") because it isn't running under Docker.
3. Copied the Steam app into the `moonlight-profile` profile.

Any new app also needs (1). Restart after editing:
`kubectl -n wolf rollout restart deploy/wolf`.

## Host prep (k3s-07, done once)

- `/etc/udev/rules.d/85-wolf.rules` from Wolf's repo
  (`curl -fsSL https://raw.githubusercontent.com/games-on-whales/wolf/stable/85-wolf.rules`),
  then `udevadm control --reload-rules && udevadm trigger`.
- `/dev/uinput` and `/dev/uhid` exist (built into the HWE kernel).
- AppArmor profile `/etc/apparmor.d/wolf-steam`, loaded with
  `apparmor_parser -r /etc/apparmor.d/wolf-steam` (it persists across reboots):
  ```
  abi <abi/4.0>,
  include <tunables/global>
  profile wolf-steam flags=(unconfined) {
    userns,
  }
  ```
  Without it, Steam shows "Steam now requires user namespaces to be enabled".
  Ubuntu 24.04's `kernel.apparmor_restrict_unprivileged_userns=1` sends
  bwrap into the `unprivileged_userns` profile, and that profile denies it.
  The nested dockerd doesn't apply AppArmor profiles, so the profile goes on
  the dind container through the pod annotation, and app containers inherit
  it. The node-wide sysctl stays on. If the profile isn't loaded, the pod
  fails to start.

## Sharing the GPU with Ollama

Wolf doesn't request `amd.com/gpu`. The device plugin advertises only one,
and Ollama holds it. Wolf reaches `/dev/dri` through the privileged
containers. Games and Ollama share the 96 GiB GTT pool and the GPU's compute:
- A large resident model (`OLLAMA_KEEP_ALIVE=30m`) can leave a game short of
  GPU memory. Check with `kubectl -n ollama exec deploy/ollama -- ollama ps`
  and unload with `ollama stop <model>`, or scale Ollama to 0 while playing.
- An inference request in the middle of a game causes stutter.

Anti-cheat titles that block Linux/VMs won't run. Most Proton games do.
