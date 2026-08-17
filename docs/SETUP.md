# hydra step-by-step setup

Assumes two servers: one at home (the hub) and one abroad (the exit). No prior knowledge
needed.

---

## Before you start

| Requirement | Detail |
|---|---|
| Two servers | one hub, one exit |
| OS | Ubuntu 20.04+ or Debian 11+ |
| Access | root on both |
| Kernel | 4.9 or newer (`uname -r`) |

**Read this first:** if your provider has its own firewall panel (Hetzner Cloud Firewall,
OVH, AWS security groups), hydra cannot touch it. You must open the port there yourself.
The firewall *inside* the server (ufw, firewalld) is opened automatically.

---

## Step 1 — Install on both servers

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/devprogrmer/hydra/main/install.sh)
```

It asks what the server is:

```
   1) Home server      the hub. Clients connect here.
   2) Foreign server   an exit.
```

Pick `1` on the hub, `2` on the exit.

On the hub it also asks for the **public address**. If it shows two different values and
warns you, your outbound IP is not stable — remember that for step 2.

---

## Step 2 — Connection direction (hub only)

Only if you got the changing-IP warning. Menu → `13` → `2` (reverse).

By default the hub dials out, which requires the hub's address to be stable. In reverse
mode the exit dials in and the hub's address can change freely.

---

## Step 3 — Create the tunnel (on the hub)

Menu → `1` (Create new tunnel). It asks for a name, the exit's IP, and a mode:

- **`1` full** — WireGuard + FEC + faketcp. The default. Use when UDP is shaped or blocked.
- **`2` fec** — no faketcp. Use if full mode fails on that VPS.
- **`3` plain** — WireGuard only. Clean routes, multi-exit only.

It prints a long **invite token**. Copy all of it. It expires in 30 minutes; if it lapses,
menu → `2` → `2` (Re-issue invite).

---

## Step 4 — Apply the token (on the exit)

```bash
hydra apply TOKEN
```

No angle brackets — paste the real string. The exit generates its own private key (never
transmitted), configures itself, **opens the required port in its local firewall**, and
prints a shorter **reply token**. Copy that.

---

## Step 5 — Finish pairing (back on the hub)

Menu → `2` → `1` (Finish pairing), paste the reply.

It waits up to 25 seconds and tells you whether the handshake completed. On failure it
lists the likely causes in order.

---

## Step 6 — Check the firewall

Menu → `14` (Firewall) on **both** servers. It shows which ports are needed and whether
they are open; option `1` opens them.

If you use a cloud firewall panel, open the same port there too.

---

## Step 7 — Add users

**Direct WireGuard:** menu → `3` → `1`, gives a config and a QR code.

**Via a panel on the exit:** install the panel on the exit, make the inbound listen on
`0.0.0.0` (not `127.0.0.1`), then on the hub menu → `5` → `1` to forward the ports. Set
the client config address to the hub's IP.

Do not forward `51820` — that is your own clients' WireGuard port.

---

## Step 8 — Turn on self-healing

Menu → `11`, enable options `1` and `3`. The scheduled reset restarts everything every
6 hours; the watchdog restarts any link whose handshake goes quiet.

---

## Step 9 — Tune FEC

Menu → `4` → `8` (Measure the link and recommend).

**Set the same value on both ends.** A mismatch stops the link from coming up, and it is
the most common mistake. On a single-core VPS prefer the `2:1` / `2:4` profiles — same
protection, half the CPU work.

---

## Troubleshooting

Menu → `9` (Diagnose a tunnel) checks each layer and names the broken one.

| Symptom | Cause | Fix |
|---|---|---|
| `not paired` | step 5 never completed | re-issue the invite and pair again |
| all `active` but `0 B received` | FEC differs between ends | make them identical |
| no handshake | port closed | menu → `14` on both, and check your cloud panel |
| handshake fine, pages will not load | MTU | menu → `4` → `7` |
| service restart loop | read the log | `journalctl -u hydra-spd@NAME -n 20` |
| broken after manual edits | inconsistent state | menu → `2` → `7` (Rebuild) |

Do not hand-edit config files. It nearly always makes things worse — rebuild instead.

---

## Honest limitations

**FEC does not lower ping.** It hides loss. Ping is distance and route quality; no tunnel
beats a direct path.

**FEC lowers throughput.** At `4:8` only 33% of your line carries real data. Irrelevant for
game traffic, significant for downloads.

**BBR only governs TCP.** Your game traffic is UDP inside WireGuard. BBR helps TCP flows
inside the tunnel; it is not a magic ping fix.

**If the route itself is bad, no setting saves it.** Build a second exit in another
datacentre and let the watchdog pick. That is what multi-exit is for.
