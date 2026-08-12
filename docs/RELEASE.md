# hydra v3.4.0

Multi-exit gaming tunnel with FEC, faketcp obfuscation and automatic latency-based
failover. English interface, one-line curl install, no Docker.

تونل گیمینگ چند-خروجی با FEC، پنهان‌سازی faketcp و فیل‌اوور خودکار بر پایه‌ی تأخیر.
رابط انگلیسی، نصب یک‌خطی با curl، بدون داکر.

---

## English

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
