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

## Security

What the design actually guarantees, and what it does not.

### Key handling

Exit private keys are **generated on the exit** and never transmitted. The hub's invite
carries the hub's *public* key, the preshared key and the udp2raw/UDPspeeder passwords;
the exit answers with only its own public key. Neither token ever contains a WireGuard
private key.

### Token safety

| Property | How |
|---|---|
| Integrity | SHA-256 checksum inside the token; a truncated or edited paste is rejected |
| Expiry | 30 minutes by default, configurable 1–1440 in the Security menu |
| Single use | Bound to a random pairing id; wiped with `shred` once pairing completes |
| Injection-proof | Only `KEY=VALUE` lines with a restricted charset are accepted; never `eval`'d |

If an invite leaks while still valid, whoever holds it can complete the pairing in your
place — so treat an unpaired invite as a live credential, move it over a channel you
trust, and use **Re-issue invite** if you are unsure. Re-issuing rotates the pairing id
and kills the old invite immediately.

### Encryption on the wire

- WireGuard: ChaCha20-Poly1305, Curve25519, plus a **preshared key** on every peer, which
  adds a symmetric layer against future quantum attacks on the key exchange.
- udp2raw: AES-128-CBC with HMAC-SHA1 authentication over the faketcp frames.

Two independent layers, so breaking the outer one still leaves WireGuard intact.

### Network hardening

- **Ingress lock.** Each exit accepts its tunnel port *only* from the hub's IP; everything
  else is dropped in a dedicated `HYDRA_IN` chain. Port scanners see nothing.
- **Client isolation** (on by default). Clients cannot reach each other, this server's
  LAN, or any RFC1918 / link-local / CGNAT range. Toggle it in the Security menu if you
  actually want LAN access.
- **Port-forward guard.** Forwarding a port the server needs — SSH, the client WireGuard
  port, a tunnel's own udp2raw port — triggers a named warning that defaults to no.

### Local hygiene

`umask 077` for everything the script writes; all config `0600`; the event log `0600`.
Binary hashes are recorded on first install (trust-on-first-use) and re-checked on every
reinstall, so a swapped `udp2raw` or `speederv2` shows up as a warning.

### What this does not protect against

- A compromised hub or exit. Root on either end sees the plaintext.
- Traffic analysis. faketcp hides that it is UDP; it does not hide that a long-lived
  encrypted flow exists between two addresses.
- A leaked invite that is still within its expiry window.
- Anything upstream of the tunnel: your game client, your OS, your browser.

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

One line, on **both** the home server and each foreign server. No git clone.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/devprogrmer/hydra/main/install.sh)
```

It installs the dependencies, downloads the binaries, applies the kernel tuning and opens
an interactive menu (English). The first thing it asks is what this server is:

```
   1) Home server      the hub. Clients connect here; it tunnels out to many exits.
   2) Foreign server   an exit. Joins a hub using the token the hub prints.
```

### Creating a tunnel — two steps

**On the hub:** menu → **Create new tunnel** → name, IP, mode. It prints an invite and a
ready-to-paste line:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/devprogrmer/hydra/main/install.sh) apply <INVITE>
```

**On the foreign server:** run that line. It generates its own WireGuard private key,
configures itself, locks its port to the hub's IP, and prints a short **reply token**.

**Back on the hub:** menu → **Manage tunnels** → **Finish pairing** → paste the reply.
The link comes up.

Two steps instead of one, on purpose: it means the exit's private key is created on the
exit and never travels anywhere. See Security below.

Repeat for each foreign server, then menu → **Manage clients** → **New client** for a
WireGuard config with a QR code. Afterwards just run `hydra` to get the menu back.

### The menu

```
   1) Create new tunnel       add a foreign server
   2) Manage tunnels          pair, delete, pin, restart
   3) Manage clients          WireGuard config + QR
   4) FEC settings            current: 10:5
   5) Port forwarding         many ports at once, comma-separated
   6) Security                keys, isolation, tokens
   7) Re-apply BBR and tuning
   8) Events and logs
   9) Uninstall
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

### Diagnosing loss before treating it

Raising FEC is only correct for one of the three things that look like packet loss. Menu →
**Link tuning** → **Where is the loss coming from?** separates them:

| What it finds | What it means | The fix |
|---|---|---|
| Large packets lost, small ones fine | MTU, not loss | Find the working MTU. FEC makes this worse. |
| Raw path clean, tunnel lossy | The tunnel is creating it | **Lower** FEC, or check CPU |
| Raw path lossy too | Genuine path loss | Raise FEC, or use a different route |
| Residual loss zero | FEC is already absorbing it | Nothing |

The counter-intuitive case is the middle one. If FEC overhead saturates your uplink, or FEC
encoding saturates a single-core VPS, the tunnel manufactures the loss it was installed to
prevent — and every step up in parity makes it worse. **CPU headroom** and **Throughput
test** on the same menu tell you whether you are in that situation.

### Tuning for a lossy link

The FEC ratio is `data:parity`. What matters is that `parity/(data+parity)` exceeds your
loss rate with headroom, because loss arrives in bursts, not evenly.

| Setting | Tolerates | Bandwidth cost |
|---|---|---|
| `20:5` | ~20% loss | +25% |
| `10:5` | ~33% loss | +50% |
| `8:8` | ~50% loss | +100% |
| `6:9` | ~60% loss | +150% |
| `4:8` | ~67% loss | +200% |
| `2:6` | ~75% loss | +300% |

Menu → **Link tuning** → **Measure the link and recommend** sends 100 packets through the
tunnel and reports *residual* loss — what is still lost after FEC has done its work. If
that number is above zero, the current profile is not strong enough. Step up one level and
measure again.

Set the same value on both ends. A mismatch stops the link from coming up.

Also on that screen: UDPspeeder's batching mode (try `1` when loss is bursty rather than
steady), the FEC timeout (leave at `0` for gaming — anything higher trades latency for
bandwidth), and the reconstruction queue length (raise it when loss and latency are both
high).

**Be honest with yourself about the cost.** At `4:8` you are sending three bytes for every
byte of game traffic. That is the right trade for a 60-byte position update; it is a poor
trade if you also push downloads through the same tunnel. If you need both, run a second
exit in `plain` mode for bulk traffic and pin it.

---

## Modes

| Mode | Chain | Use when |
|---|---|---|
| `full` | WG → FEC → faketcp | Default. UDP is shaped or blocked. |
| `fec` | WG → FEC | faketcp fails on that VPS (raw socket restrictions). |
| `plain` | WG only | Clean route, just want multi-exit + failover. |

---

## Testing a customer's ping before they ever get a config

Menu → **Game latency test**. No game client, no WireGuard config, nobody has to install
anything. It pings well-known game endpoints *through* a chosen exit and reports each leg
separately.

```
GAME                   REGION        EXIT>SRV LOSS    EST PING  RATING
Dota 2                 Europe West   31ms     0%      94ms      playable
CS2 / CSGO             Europe East   44ms     1.2%    107ms     playable
Valorant               Europe        no reply -       -         filtered
```

Four modes: one game in detail, every game through one exit, the same game across every
exit (so you know which to pin), or any custom host.

### What it can and cannot tell you

The full path is `player → hub → exit → game server`. This measures the last two legs —
everything you control. **It cannot measure the player's own latency to the hub**, because
that depends on their ISP and their distance, neither of which is visible from the server.

So the detailed view prints the server-side total and then adds typical player latencies:

```
server-side total      69ms

Tehran fibre           +10ms  =   79ms  good
Tehran ADSL            +25ms  =   94ms  playable
Mobile 4G              +45ms  =  114ms  playable
```

That is the number that makes support tractable: if a customer reports 180ms while the
table says 94ms, the extra 86ms is on their side — their wifi, their ISP, their distance —
not your tunnel. And if the table itself looks bad, you know before they ever complain.

### Two honest caveats

**Many game servers filter ICMP.** `no reply` means that endpoint does not answer ping, not
that the route is broken. Use a region that does answer, or **Test a custom host** with an
address you have seen your own traffic use.

**The bundled endpoints are best-effort.** Publishers change IPs without notice. For numbers
you can rely on, edit the list (menu → option 5) and replace them with addresses you have
verified yourself. The estimates are only as good as the endpoints behind them.

---

## When the link drops every few hours

Some routes will not stay up regardless of configuration. The hub's public address
changes, a udp2raw session dies without notice, or an ISP resets long-lived flows. Menu →
**Self-healing** handles both shapes of this problem:

**Scheduled reset** restarts every tunnel on a timer, 6 hours by default. It is a blunt
instrument, and that is the point — it clears any stale state, including a peer entry
pointing at a hub address that no longer exists.

**Handshake watchdog** is the targeted version. It checks each tunnel every minute and
restarts only the one whose handshake has gone quiet for more than four minutes. Two
consecutive failures are required before it acts, so one missed keepalive will not send it
into a restart loop.

Run both. The watchdog catches most failures within a couple of minutes; the scheduled
reset catches whatever the watchdog cannot see.

---

## Troubleshooting

| Symptom | Check |
|---|---|
| Everything looks `active` but `0 B received` | FEC settings differ between the two ends. They must match exactly. |
| Tunnel `down`, `Diagnose` says `not paired` | Finish pairing was never completed on the hub. Re-issue the invite and redo it. |
| Handshake works, large transfers stall | MTU. Menu → Link tuning → Find the working MTU. |
| Service restarts in a loop | `journalctl -u hydra-spd@NAME -n 20` — the FEC binary prints its reason. |
| Downloads fail during install | DNS. Try a different resolver in `/etc/resolv.conf`. |
| Nothing works after several manual fixes | Menu → Manage tunnels → Rebuild a tunnel, then recreate it through the menu without hand-editing. |
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
