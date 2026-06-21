# container-from-scratch

A Linux container runtime built entirely from raw kernel primitives — no Docker, no `runc`, no third-party container libraries. Every isolation mechanism (namespaces, cgroups, chroot, overlay filesystem, virtual networking) is implemented by hand in Bash, calling the same Linux kernel features that Docker uses internally.

```bash
sudo ./container.sh
```

That single command spins up a fully isolated container — its own process tree, its own filesystem, its own network identity, and enforced resource limits — and supports **multiple simultaneous containers**, each completely isolated from the others and from the host.

---

## Why this project exists

Most engineers who use Docker daily have never seen what's underneath it. This project was built to answer one question directly: **what does `docker run` actually do at the kernel level?**

Rather than reading about namespaces and cgroups, this project implements them — directly, by hand, using nothing but core Linux tools (`unshare`, `chroot`, `ip`, `iptables`, and the `/sys/fs/cgroup` and `/sys/fs/overlay` virtual filesystems).

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                         HOST                              │
│                                                             │
│   br0 (bridge, 10.0.0.1)                                  │
│    │                                                       │
│    ├── v0-<id1> ──cable── v1-<id1>  ──┐                   │
│    ├── v0-<id2> ──cable── v1-<id2>  ──┤                   │
│    └── v0-<id3> ──cable── v1-<id3>  ──┤                   │
│                                         │                   │
│   /sys/fs/cgroup/mycontainer            │                   │
│    memory.max | cpu.max | pids.max     │                   │
│                                         │                   │
│   iptables NAT (MASQUERADE) ───── eth0 (real internet)     │
│                                                             │
└─────────────────────────────────────────┼──────────────────┘
                                           │
        ┌──────────────────────────────────┼─────────────────┐
        │              CONTAINER (one of N, fully isolated)    │
        │                                                       │
        │   PID namespace    → own process tree (PID 1 = bash) │
        │   Mount namespace  → own /proc, own mounts            │
        │   Network namespace → own veth, own IP (10.0.0.x)     │
        │   Overlay filesystem:                                 │
        │     rootfs/ (shared, read-only)                       │
        │       + upper/<id> (private, writable)                │
        │       = merged/<id> (what the container sees as /)    │
        │   Cgroup limits: 256MB RAM, 50% CPU, 20 PIDs max       │
        │                                                       │
        └───────────────────────────────────────────────────────┘
```

Every container gets a **unique ID** (Unix timestamp), and from that ID, a unique veth pair, a unique overlay filesystem layer, and a unique IP address — allowing any number of containers to run side by side without colliding.

---

## What's implemented

| Kernel feature | What it provides | Linux primitive used |
|---|---|---|
| PID namespace | Isolated process tree — container's first process becomes PID 1 | `unshare --pid --fork` |
| Mount namespace | Private mount table — container's `/proc` doesn't leak to host | `unshare --mount` |
| Network namespace | Private network stack — own interfaces, own routing table | `unshare --net` |
| Chroot jail | Filesystem root confinement — container can't see above its root | `chroot` |
| Overlay filesystem | Per-container writable layer over a shared read-only base (copy-on-write) | `mount -t overlay` |
| Cgroups v2 | Hard limits on memory, CPU, and process count, enforced by the kernel | `/sys/fs/cgroup/*.max` |
| Bridge networking | Virtual switch connecting all containers to the host network | `ip link add type bridge` |
| veth pairs | Virtual ethernet cable, one end per container, one end on the bridge | `ip link add type veth peer` |
| NAT / IP forwarding | Lets containers reach the real internet via the host's interface | `iptables -t nat -A POSTROUTING -j MASQUERADE` |

---

## How it works, end to end

1. **Root check** — refuses to run without `sudo`, since every operation below requires root.
2. **Bridge setup** — creates `br0` once; reused by every container that starts afterward.
3. **Cgroup setup** — creates `/sys/fs/cgroup/mycontainer` and writes memory/CPU/PID limits.
4. **Unique container ID** — generated from the current Unix timestamp.
5. **Overlay filesystem** — mounts a fresh `upper` + `work` + `merged` set for this container, layered on top of the shared, read-only `rootfs/` (built once via `debootstrap`).
6. **Unique veth pair** — created and named using the container ID, then plugged into the bridge.
7. **IP forwarding + NAT** — enabled once, idempotently checked on every run.
8. **Unique IP address** — assigned from a small on-disk counter file, so no two containers ever collide.
9. **Container launch** — `unshare` creates the namespaces and `chroot`s into this container's private `merged` view, running in the background.
10. **Host/container handshake** — the container signals readiness by touching `/tmp/ready`; the host waits for that signal, then performs host-only setup (moving the veth into the container's network namespace, attaching the container's PID to the cgroup) before signaling back via `/tmp/go`.
11. **Interactive shell** — once signaled, the container configures its own IP/routing and `exec`s into an interactive `bash`, handed directly to the user's terminal.
12. **Cleanup on exit** — when the shell exits, the script unmounts the overlay, deletes that container's folders, and removes its veth pair. The shared bridge, rootfs, and NAT rule persist for the next container.

```bash
# The core of the isolation — one line, four namespaces, one filesystem jail
unshare --pid --fork --mount --net chroot overlay/$CONTAINER_ID/merged /bin/bash
```

```bash
# The core of the filesystem isolation — copy-on-write via overlayfs
mount -t overlay overlay \
    -o lowerdir=rootfs,upperdir=overlay/$CONTAINER_ID/upper,workdir=overlay/$CONTAINER_ID/work \
    overlay/$CONTAINER_ID/merged
```

Full script: [`container.sh`](./container.sh)

---

## Verified behavior

Every isolation guarantee below was manually tested, including running **two containers simultaneously**:

- A process inside the container sees itself as PID 1 and cannot see any host process.
- `cd /../../..` from inside the container always resolves to `/` — no escape from the filesystem jail.
- A container cannot allocate more memory, CPU, or processes than its cgroup limits allow; exceeding the PID limit produces `fork: Resource temporarily unavailable`, caught directly from the kernel.
- Files written inside one container are invisible to a second, simultaneously running container — proven via overlay's private upper layers.
- Each container reaches the public internet (verified against `8.8.8.8` and DNS resolution of `google.com`) through its own NAT-translated, uniquely-IP'd connection — without interfering with any other running container.

---

## Known limitations

Documenting these honestly is part of understanding the project, not a weakness:

- **No image layering** — a single flat `rootfs/` (built with `debootstrap`) acts as the shared base; there's no concept of pulling/caching multiple image layers like Docker Hub provides.
- **No persistent volumes** — a container's writable layer is deleted when it exits; nothing survives a container's lifetime by design.
- **No port mapping or DNS server** — containers reach the internet outbound via NAT, but there's no `-p 8080:80` equivalent or internal DNS service.
- **Manual lifecycle only** — no `ps`/`logs`/`stop` equivalents; a container's lifetime is tied directly to the script process that started it.
- **WSL2-specific workarounds** — built and tested on WSL2 (Ubuntu 22.04); a couple of `debootstrap` flags (`--variant=minbase`, `--no-check-gpg`) were needed to work around WSL2's restricted device-file creation.

---

## Requirements

- Linux with cgroups v2 (tested on WSL2, Ubuntu 22.04 "jammy")
- `debootstrap`, `iproute2`, `iptables`
- Root privileges

## Usage

```bash
git clone https://github.com/Harini-Raja7/container-from-scratch.git
cd container-from-scratch

# One-time setup: build the base filesystem
sudo debootstrap --arch=amd64 --variant=minbase --no-check-gpg jammy rootfs http://archive.ubuntu.com/ubuntu
sudo chroot rootfs apt-get update
sudo chroot rootfs apt-get install -y iproute2 iputils-ping

# Run a container
sudo ./container.sh

# Run another, in a separate terminal, at the same time
sudo ./container.sh
```

---

## What this project demonstrates

- Linux namespaces (PID, mount, network, UTS) and how the kernel maintains per-namespace views of process IDs, filesystems, and network stacks
- Cgroups v2 resource control — and how the kernel actually enforces it (OOM kills, fork-time PID rejection, CPU throttling)
- chroot-based filesystem jails and their limitations
- Overlay filesystems and copy-on-write — the same mechanism behind every Docker image layer
- Linux bridge and veth-based virtual networking, IP forwarding, and NAT/MASQUERADE
- Process coordination across namespace boundaries using a file-based signaling handshake
- Writing idempotent, defensive Bash — safe to re-run, with proper cleanup on exit

---
