<div align="center">

# 🐉 hydra

**One head at home. Many heads abroad.**

A multi-exit, FEC-protected, BBR-tuned gaming tunnel.

[فارسی](README.fa.md) · [Release notes](docs/RELEASE.md)

</div>

---

## What problem does this solve?

A normal server-to-server tunnel gives you **one** path. If that path degrades — and on
congested international routes it degrades constantly — your ping spikes and you lose the
fight. You have no fallback, no packet-loss recovery, and if the tunnel uses plain UDP
your traffic gets shaped or dropped by middleboxes.

hydra fixes all three:

1. **Many exits, not one.** One home server maintains simultaneous, independent tunnels to
   as many foreign servers as you want. Traffic rides whichever one is healthiest right now.
2. **Forward Error Correction.** Lost packets are *reconstructed* from redundancy data
   instead of being retransmitted. Retransmission is what turns 2% packet loss into a
   200 ms spike; FEC removes that entirely.
3. **Obfuscation + double encryption.** UDP is disguised as a TCP stream, so shapers that
   throttle or block UDP don't see UDP.

---

## What it actually does, packet by packet

Here is the complete journey of a single game packet in the default `full` mode.

```
 Your game client
      │
      │  ① UDP game packet, ~60 bytes
      ▼
 ┌──────────────────────────────────────────────┐
 │  wg0   —  WireGuard, 10.77.0.0/24            │
 │  ② encrypt: ChaCha20-Poly1305, +32B overhead │
 └──────────────────────────────────────────────┘
      │
      ▼
 ╔══════════════════════════════════════════════════════════╗
 ║              HOME SERVER (hub)                           ║
 ║                                                          ║
 ║  ③ policy routing: `ip rule from 10.77.0.0/24 → table    ║
 ║     hydra`, whose default route points at the exit       ║
 ║     hydra-watch currently rates best                     ║
 ║                                                          ║
 ║  ④ wg-de1  —  a second WireGuard layer, one per exit.    ║
 ║     Its Endpoint is 127.0.0.1, so the encrypted packet   ║
 ║     is handed to a local userspace process instead of    ║
 ║     going straight out the NIC.                          ║
 ║                                                          ║
 ║  ⑤ UDPspeeder  —  FEC. Collects 10 packets, computes 5   ║
 ║     Reed-Solomon parity packets, sends 15. `--timeout 0` ║
 ║     means it never *waits* to fill a batch, so it adds   ║
 ║     zero latency.                                        ║
 ║                                                          ║
 ║  ⑥ udp2raw  —  wraps each datagram in a synthetic TCP    ║
 ║     header (faketcp), completes a real 3-way handshake   ║
 ║     so stateful firewalls see a legitimate TCP flow,     ║
 ║     then encrypts with AES-128-CBC + HMAC-SHA1.          ║
 ╚══════════════════════════════════════════════════════════╝
      │
      │  ⑦ crosses the international link looking like TCP
      ▼
 ╔══════════════════════════════════════════════════════════╗
 ║              FOREIGN SERVER (exit)                       ║
 ║  ⑧ udp2raw strips faketcp, decrypts                      ║
 ║  ⑨ UDPspeeder reconstructs any packets lost in ⑦         ║
 ║  ⑩ wg-de1 decrypts, NAT to the public interface          ║
 ╚══════════════════════════════════════════════════════════╝
      │
      ▼
 Game server
```

The return path is the mirror image.

### The failover loop, running in parallel

Every 5 seconds `hydra-watch` pings the inner IP of **every** exit through its own tunnel
interface and computes:

```
score = mean_rtt  +  2 × jitter  +  20 × loss%      (lower is better)
```

Jitter and loss are weighted far more heavily than raw latency, because a stable 90 ms
link beats a 60 ms link that stutters. A new exit only wins if it is **15% better** and
stays better for **3 consecutive checks** — that hysteresis is what stops the route from
flapping back and forth.

When it switches, it rewrites one line: the default route inside routing table `hydra`.
Existing tunnels stay warm, so failover is a sub-second route change, not a reconnect.

### What each layer is genuinely for

| Layer | Job | What breaks without it |
|---|---|---|
| WireGuard | Confidentiality, integrity, in-kernel speed | Traffic readable; slow userspace crypto |
| UDPspeeder | Reed-Solomon FEC | Every lost packet becomes a stall or retransmit spike |
| udp2raw | faketcp obfuscation + 2nd cipher layer | UDP shapers throttle or drop the tunnel |
| Policy routing | Steers client subnet to the chosen exit | Only one exit usable |
| hydra-watch | Health scoring + failover | Degraded exit stays selected |
| BBR + sysctl | Congestion control, buffer sizing | Bufferbloat; loss misread as congestion |

### A note on BBR, honestly

BBR is a **TCP** congestion control algorithm. Your game traffic is UDP, and it rides
inside WireGuard, so BBR does not directly control it. What BBR actually buys you here:

- TCP flows *inside* the tunnel (downloads, web, voice-chat signalling) stop filling
  buffers and stop inflating everyone else's latency.
- `faketcp` frames are raw sockets, so BBR does not apply to them either — but the
  `fq` qdisc it enables does pace all egress traffic, which measurably reduces jitter.

So: BBR is worth enabling, and the sysctl bundle around it (buffer sizes,
`rp_filter=2` for asymmetric multi-exit routing, `tcp_slow_start_after_idle=0`) matters
more for this workload than BBR itself. Anyone selling you BBR as a magic ping fix is
overselling it.

---

## Compared to a single-link tunnel

| | Typical single-link tunnel | hydra |
|---|---|---|
| Foreign servers | 1 | up to 250, simultaneous |
| Packet-loss recovery | none | Reed-Solomon FEC |
| Automatic failover | none | ping + jitter + loss scored, 5 s interval |
| Encryption | usually one layer | ChaCha20-Poly1305 + AES-128-CBC/HMAC-SHA1 |
| UDP shaping evasion | varies | faketcp with real handshake |
| Kernel tuning | none | BBR, fq, buffers, rp_filter |
| Runtime | often Docker | plain binaries + systemd |

---

## Install

One line, on **both** the home server and each foreign server:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/devprogrmer/hydra/main/install.sh)
```

It installs the dependencies, downloads the binaries, applies the kernel tuning and opens
an interactive menu. The first thing it asks is what this server is:

```
   1) Home server (hub)  — clients connect here, it tunnels out to many exits
   2) Foreign server     — an exit; joins a hub using a token
```

### Then, on the home server

Menu → **Create new tunnel** → enter a name and the foreign server's IP → pick a mode.
It prints one ready-to-paste line. Run that line on the foreign server and the link comes up:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/devprogrmer/hydra/main/install.sh) apply <TOKEN>
```

Repeat for each foreign server. Then menu → **Manage users** → **New user** to get a
WireGuard config with a QR code.

Afterwards just run `hydra` any time to get the menu back.

### The menu

```
   1) Create new tunnel        add a foreign server
   2) Manage tunnels           remove, pin, restart, show token
   3) Manage users             WireGuard config + QR
   4) FEC settings             current: 10:5
   5) Game port forwarding
   6) Re-apply BBR and tuning
   7) Events and logs
   8) Uninstall
   0) Quit
```

The main screen shows a live table of every exit with ping, jitter, loss and which one is
currently carrying traffic.

## Daily use

Run `hydra` for the menu. Everything is in there — status, pinning an exit, adding users,
port forwarding, FEC, logs.

A couple of things are also available non-interactively, for scripts and monitoring:

```bash
hydra status                      # the live exit table
tail -f /var/log/hydra.log        # switch history
journalctl -u hydra-raw@de1 -f    # a specific tunnel's logs
```

---

## Tuning FEC — the setting that matters most

Menu → **FEC settings**. It restarts both ends' FEC processes for you. Format `data:parity`:

| Measured loss | Setting | Bandwidth overhead |
|---|---|---|
| under 1% | `20:5` | 25% |
| 1–5% | `10:5` (default) | 50% |
| 5–15% | `8:8` | 100% |
| over 15% | `4:8` | 200% |

Set the **same value on both ends** — a mismatch stops the link from coming up. Game
traffic is tiny, so the overhead rarely matters unless you also push bulk downloads through.

---

### Game port forwarding

Menu → **Port forwarding**. Enter as many ports as you like, comma-separated, ranges with
a hyphen:

```
50820,51820,2097,2096,443,80
27015,7777-7784
```

Traffic hitting those ports on the home server's public IP is DNAT'd to the exit you
choose. TCP, UDP, or both.

Ports are collapsed into `multiport` rules — the six ports above become **one** iptables
rule per protocol, not six. Lists longer than the 15-entry multiport limit are split
automatically (a range counts as two entries).

Rules live in dedicated `HYDRA_PRE` / `HYDRA_POST` / `HYDRA_FWD` chains, so they can be
rebuilt cleanly and never accumulate duplicates. They are reapplied on boot and whenever
a tunnel restarts.

**A warning you should not click past:** the tool checks your list against the ports this
server needs to stay reachable — SSH, the client WireGuard port (51820 by default), and
each tunnel's own udp2raw port. Forwarding `51820` sends your own clients' WireGuard
traffic to the exit and disconnects everyone; forwarding your SSH port locks you out of
the box. You get an explicit confirmation prompt naming the conflicting ports, and the
default answer is no.

---

## Modes

| Mode | Chain | Use when |
|---|---|---|
| `full` | WG → FEC → faketcp | Default. UDP is shaped or blocked. |
| `fec` | WG → FEC | faketcp fails on that VPS (raw socket restrictions). |
| `plain` | WG only | Clean route, just want multi-exit + failover. |

---

## Troubleshooting

| Symptom | Check |
|---|---|
| No handshake | `journalctl -u hydra-raw@NAME -n 50` — usually the TCP port is closed in the exit's firewall |
| udp2raw won't connect | Add `--lower-level auto` to the service (some VPS iptables setups conflict) |
| Ping fine, no traffic | `ip rule show` and `ip route show table hydra` |
| Sites won't load | Lower `WG_MTU` in `/etc/hydra/exits.d/NAME.conf`: 1280 → 1240 → 1200 |
| BBR not active | Kernel too old; `uname -r` should be ≥ 4.9 |

---

## Security notes

- The exit's WireGuard private key is generated on the hub and travels inside the token.
  Move tokens over a secure channel, then `shred -u /etc/hydra/token-*.txt`.
- `hydra-exit apply` accepts only `KEY=VALUE` lines and rejects tampered tokens.
- All config files are written `chmod 600`.
- **Read the scripts before running them on a production server.** They have not been
  tested against live network conditions.

## Credits

Built on [wangyu-/UDPspeeder](https://github.com/wangyu-/UDPspeeder) and
[wangyu-/udp2raw](https://github.com/wangyu-/udp2raw). Conceptually inspired by
[Dnt3e/Narnia](https://github.com/Dnt3e/Narnia), rewritten for multi-exit operation.

## License

MIT
