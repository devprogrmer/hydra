# hydra v3.7.0

Multi-exit gaming tunnel with FEC, faketcp obfuscation and automatic latency-based
failover. English interface, one-line curl install, no Docker.

تونل گیمینگ چند-خروجی با FEC، پنهان‌سازی faketcp و فیل‌اوور خودکار بر پایه‌ی تأخیر.
رابط انگلیسی، نصب یک‌خطی با curl، بدون داکر.

---

## English

### New in 3.7.0 — reverse mode and cheaper FEC

**Reverse tunnels.** Normally the hub dials out to each exit. In reverse mode the exit
dials in and the hub listens. The payload is identical; only the direction of the
connection changes. This matters because on many Iranian links the hub's public address
is not stable — it can differ between reboots or even between requests — which breaks the
exit's peer entry and its ingress filter. In reverse mode the hub's address becomes
irrelevant. Menu → **Connection direction**. Use direct only if the hub sits behind NAT
with no forwarded port.

**Small-block FEC profiles.** `2:1`, `2:2`, `2:3`, `2:4` alongside the existing large-block
ratios. These give identical loss protection at identical bandwidth cost, but with much
smaller blocks:

| Setting | Tolerates | Bandwidth | Block size |
|---|---|---|---|
| `4:8` | ~67% | 3.0x | 12 packets |
| `2:4` | ~67% | 3.0x | **6 packets** |

Half the encoding work per block for the same protection. On a single-core VPS the CPU cost
of FEC can itself create the packet loss it was installed to prevent, so the recommendation
engine now prefers small blocks when `nproc` reports one core.

**Transport tuning.** WireGuard keepalive interval, socket buffer size and udp2raw retry
delay are now adjustable rather than hardcoded.

Both the reverse-tunnel pattern and the small-ratio FEC style are taken from
[Musixal/GamingVPN](https://github.com/Musixal/GamingVPN) and
[Azumi67/udp_tun](https://github.com/Azumi67/udp_tun).

### New in 3.6.0 — self-healing

Some links drop every few hours no matter how well they are configured. A changing hub
address, a udp2raw session that dies quietly, an ISP that resets long-lived flows — none
of these are fixed by tuning. They are fixed by periodic action.

- **Scheduled reset.** A systemd timer restarts every tunnel on an interval (6 hours by
  default, 1–168 configurable). Blunt, but it clears stale sessions and a hub address that
  has changed underneath a peer entry.
- **Handshake watchdog.** Targeted rather than blunt: checks every tunnel each minute and
  restarts only the one whose handshake has been quiet for over four minutes. Requires two
  consecutive failures before acting, so a single missed keepalive does not cause a
  restart loop.
- **Overview screen.** Role, public address, load, every hydra service, every tunnel with
  its handshake age and transfer counters, and recent events — on one screen instead of
  spread across three menus.

The reset-timer approach is taken from [Azumi67's tunnel
projects](https://github.com/Azumi67), where the same pattern appears across several
repositories precisely because the underlying problem is so common on these routes.

### New in 3.5.0 — fewer ways to get stuck

This release is a direct response to a long, painful setup session. Every item here
corresponds to something that actually cost hours.

- **Preflight checks** before creating or joining a tunnel. Verifies the binaries exist,
  that UDPspeeder actually *starts* (a bad flag used to make it exit instantly and take
  the whole tunnel down silently), that the WireGuard module loads, that DNS resolves —
  a real cause of failed downloads on Iranian servers — and whether the hub's public
  address is stable, which `plain` mode requires.
- **Pairing now verifies itself.** It waits up to 25 seconds for a real handshake and
  says whether it succeeded. On failure it lists the likely causes in order — closed
  firewall port, mismatched FEC, filtered path — instead of reporting success and leaving
  you to discover `down` in the status table.
- **`--fix-gro`** on both udp2raw services, which resolves the "huge packet" failure seen
  on many VPS providers.
- **Rebuild a tunnel** — one action that tears down services, orphaned processes,
  interfaces, iptables rules and keys, then tells you exactly how to recreate it. Manual
  half-cleanups were the cause of several of the hardest failures.

Credit where due: the `--fix-gro` fix and the always-uninstall-before-reconfiguring
discipline come from studying [Azumi67's tunnel projects](https://github.com/Azumi67),
which cover this problem space thoroughly.

### New in 3.4.0 — game latency testing

Test what a customer's ping will be before handing them a config, without anyone installing
a game or a VPN client. Pings known game endpoints through a chosen exit and reports each
leg of the path separately: hub to exit, exit to game server.

- **Test one game** — detailed breakdown plus estimated final ping for typical Iranian
  connection types (Tehran fibre, ADSL, mobile, remote province).
- **Test all games** — full table through one exit.
- **Compare exits for a game** — which exit to pin for a given title.
- **Test a custom host** — for endpoints you have verified yourself.
- **Editable endpoint list** at `/etc/hydra/games.conf`.

The player's own latency to the hub cannot be measured from the server, so it is added as
a labelled estimate rather than folded silently into the total. That distinction is the
point: when a customer reports a worse ping than the table predicts, the difference is on
their side.

Endpoints that filter ICMP are reported as `filtered`, not as failures.

### New in 3.3.0 — diagnosing loss instead of guessing at it

More FEC is not always the answer, and applying it blindly to the wrong kind of loss makes
things worse. These tools tell you which kind you have:

- **Where is the loss coming from?** Measures raw path loss outside the tunnel, residual
  loss inside it, and small-packet vs large-packet loss, then gives a verdict:
  MTU problem, tunnel-induced loss, genuine path loss, or healthy. Each has a different fix.
- **Find the working MTU.** Binary-searches the path MTU, then derives `SPD_MTU` and
  `WG_MTU` with the right header budget for the mode. MTU-induced loss looks identical to
  path loss on a summary ping and is completely immune to FEC.
- **CPU headroom.** FEC encoding is CPU work; a saturated core drops packets on its own and
  that loss cannot be fixed with more parity. Warns when the parity ratio is too high for
  the hardware.
- **Throughput test.** Runs iperf3 through the tunnel and states what fraction of the link
  your current FEC setting is consuming.

### New in 3.2.0

**Built for lossy links.** The FEC profiles now go far past the old ceiling, because a
route losing 25% of packets needs far more redundancy than the previous maximum offered:

| Setting | Tolerates | Bandwidth cost |
|---|---|---|
| `20:5` | ~20% loss | +25% |
| `10:5` | ~33% loss | +50% |
| `8:8` | ~50% loss | +100% |
| `6:9` | ~60% loss | +150% |
| `4:8` | ~67% loss | +200% |
| `2:6` | ~75% loss | +300% |

- **Measure and recommend.** Sends 100 packets through the tunnel, reports residual loss,
  latency and jitter, and suggests a profile. Residual loss above zero means the current
  FEC is not keeping up.
- **Link tuning screen.** UDPspeeder batching mode, timeout and queue length are now
  adjustable per deployment instead of hardcoded, plus a one-shot high-loss preset.
- **Handshake-aware failover.** A tunnel with no WireGuard handshake in the last five
  minutes is excluded from selection rather than merely scored badly, so traffic stops
  being routed onto a dead link.
- **Lower default MTUs** (1240 in full mode), because fragmentation compounds badly once
  loss is high.

### Fixed

- `--report 0` made UDPspeeder exit immediately with `report_interval must be >0`. The FEC
  layer never started, so WireGuard never came up and every tunnel showed as `down`. The
  flag is gone.
- A failed binary download no longer passes silently — install stops and names what is
  missing.
- The ingress lock added an ACCEPT rule in faketcp mode, which let the kernel answer the
  synthetic SYN with an RST and kill the session. faketcp ports are now only DROPped for
  the kernel; udp2raw reads from a raw socket and is unaffected.
- Port-forward rules no longer print raw iptables output into the success message.
- `exit_lock` clears its previous rules before re-adding, instead of stacking duplicates.

### Added

- **Diagnose a tunnel** — walks binaries, services, WireGuard and pairing state, and names
  the layer that is broken instead of just reporting `down`.
- **Hub public address** is asked for at install time and stored, rather than guessed from
  an outbound IP lookup that can differ from the address exits actually see.
- `HUB_ALLOW` accepts a comma-separated list for hubs with more than one uplink.
- The ingress lock can be turned off entirely for hubs without a stable address.

### Known limitations

- Not tested against every network condition. Read the script before production use.
- FEC settings must match on both ends or the link will not come up.
- An unpaired invite is a live credential until it expires or is re-issued.
- BBR governs TCP only; it does not directly control the UDP tunnel.
- IPv6 exits are not handled by the failover prober.

---

## فارسی

### تازه‌های ۳.۲.۰

**ساخته‌شده برای لینک‌های پرلاست.** پروفایل‌های FEC حالا خیلی فراتر از سقف قبلی می‌روند،
چون مسیری که ۲۵٪ پکت از دست می‌دهد به افزونگی بسیار بیشتری از حداکثر قبلی نیاز دارد:

| تنظیم | تحمل | هزینه‌ی پهنای باند |
|---|---|---|
| `20:5` | ~۲۰٪ لاست | ۲۵٪+ |
| `10:5` | ~۳۳٪ لاست | ۵۰٪+ |
| `8:8` | ~۵۰٪ لاست | ۱۰۰٪+ |
| `6:9` | ~۶۰٪ لاست | ۱۵۰٪+ |
| `4:8` | ~۶۷٪ لاست | ۲۰۰٪+ |
| `2:6` | ~۷۵٪ لاست | ۳۰۰٪+ |

- **اندازه‌گیری و پیشنهاد.** ۱۰۰ پکت از تونل می‌فرستد، لاست باقی‌مانده و تأخیر و جیتر را
  گزارش می‌دهد و یک پروفایل پیشنهاد می‌کند. لاست باقی‌مانده‌ی بالای صفر یعنی FEC فعلی کافی نیست.
- **صفحه‌ی تنظیم لینک.** مود دسته‌بندی، تایم‌اوت و طول صف UDPspeeder حالا قابل تنظیم‌اند،
  به‌علاوه‌ی یک پریست آماده برای لینک‌های خیلی بد.
- **فیل‌اوور آگاه از handshake.** تونلی که پنج دقیقه handshake نداشته از انتخاب کنار
  گذاشته می‌شود، نه اینکه فقط امتیاز بد بگیرد.
- **MTU پیش‌فرض پایین‌تر** (۱۲۴۰ در مود full)، چون تکه‌تکه شدن پکت در لاست بالا وضع را بدتر می‌کند.

### رفع شد

- `--report 0` باعث می‌شد UDPspeeder بلافاصله با خطای `report_interval must be >0` بمیرد.
  لایه‌ی FEC هرگز بالا نمی‌آمد، پس وایرگارد هم بالا نمی‌آمد و همه‌ی تونل‌ها `down` بودند.
- دانلود ناموفق باینری دیگر بی‌سروصدا رد نمی‌شود.
- قفل ورودی در مود faketcp یک رول ACCEPT می‌گذاشت که باعث می‌شد کرنل به SYN جعلی جواب RST
  بدهد و سشن را بکشد. حالا فقط DROP می‌گذارد.
- `exit_lock` قبل از افزودن، رول‌های قبلی را پاک می‌کند.

### افزوده شد

- **Diagnose a tunnel** — باینری‌ها، سرویس‌ها، وایرگارد و وضعیت جفت‌سازی را بررسی می‌کند و
  می‌گوید کدام لایه خراب است، به‌جای گفتن صرفِ `down`.
- **آدرس عمومی هاب** موقع نصب پرسیده و ذخیره می‌شود، نه حدس زده.
- `HUB_ALLOW` چند آی‌پی با کاما می‌پذیرد.

### محدودیت‌ها

- در همه‌ی شرایط شبکه تست نشده. قبل از استفاده‌ی تولیدی اسکریپت را بخوانید.
- تنظیم FEC باید در هر دو سر یکی باشد وگرنه لینک بالا نمی‌آید.
- دعوت‌نامه‌ی جفت‌نشده تا انقضا یک اعتبارنامه‌ی زنده است.
