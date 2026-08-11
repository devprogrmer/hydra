# hydra v3.0.0

Multi-exit gaming tunnel with FEC, faketcp obfuscation and automatic latency-based
failover. **v2 rewrite: one script, interactive menu, curl install.**

تونل گیمینگ چند-خروجی با FEC، پنهان‌سازی faketcp و فیل‌اوور خودکار بر پایه‌ی تأخیر.
**بازنویسی نسخه‌ی ۲: یک اسکریپت، منوی تعاملی، نصب با curl.**

---

## English


### New in v3.0.0

- **English interface.** The whole menu, every prompt and every message.
- **Two-phase pairing.** Exit private keys are generated on the exit and never
  transmitted. The hub sends an invite; the exit answers with only its public key.
- **Hardened tokens.** SHA-256 checksum, 30-minute expiry (configurable), bound to a
  one-time pairing id, `shred`ed after use, and parsed without `eval`.
- **Ingress lock.** Each exit accepts its tunnel port only from the hub's IP.
- **Client isolation.** Clients cannot reach each other or any private network. On by
  default, toggleable.
- **Binary integrity.** Hashes recorded on first install, re-checked on reinstall.
- **Security screen** in both menus showing all of the above at a glance.
- `umask 077` throughout; configs and logs `0600`.

### Features

- **Multi-exit** — one hub server maintains simultaneous independent tunnels to up to
  250 foreign servers. Each gets its own WireGuard interface, keypair, preshared key,
  port range and passwords.
- **Forward Error Correction** — UDPspeeder with Reed-Solomon parity, configured with
  `--timeout 0` so no batching latency is introduced. Lost packets are reconstructed
  rather than retransmitted.
- **faketcp obfuscation** — udp2raw wraps datagrams in synthetic TCP with a real
  three-way handshake, plus AES-128-CBC and HMAC-SHA1.
- **Automatic failover** — `hydra-watch` scores every exit every 5 s as
  `rtt + 2×jitter + 20×loss%`, with a 15% improvement threshold and 3-check hysteresis
  to prevent route flapping. Switching rewrites a single default route; tunnels stay warm.
- **Kernel tuning** — BBR, `fq` qdisc, enlarged socket buffers, `rp_filter=2` for
  asymmetric multi-exit routing, and low-latency TCP settings.
- **Three modes** — `full` (WG→FEC→faketcp), `fec` (WG→FEC), `plain` (WG only).
- **Token-based provisioning** — `hydra add-exit` emits a single validated token;
  `hydra-exit apply <token>` configures the foreign side. No manual key copying.
- **Client management** — WireGuard peer generation with QR output.
- **Port forwarding** — DNAT any number of ports to a chosen exit, comma-separated with
  ranges (`50820,51820,2097,2096,443,80` or `27015,7777-7784`). Collapsed into `multiport`
  rules, auto-split past the 15-entry limit, held in dedicated iptables chains, reapplied
  on boot. Warns before forwarding a port the server needs (SSH, client WireGuard, udp2raw).
- **No Docker** — plain binaries and systemd units.
- **Single script, menu-driven** — one file serves both roles; it asks whether the machine
  is the hub or an exit and shows the right menu. Installed with one curl line.

### Known limitations

- Not tested against live network conditions. Review the script before production use.
- `install.sh` has a `REPO=` line you must set to your own GitHub path before publishing.
- An unpaired invite is a live credential until it expires or is re-issued.
- BBR governs TCP only; it does not directly control the UDP tunnel itself. See the
  README section on this.
- IPv6 exits are not yet handled by the failover prober.
- arm64 hosts fall back to the 32-bit arm binaries of udp2raw/UDPspeeder.

### Requirements

Debian/Ubuntu or RHEL/Rocky/Alma, kernel ≥ 4.9, root access, `x86_64` or `arm`.

---

## فارسی


### تازه‌های نسخه‌ی ۳.۰.۰

- **رابط انگلیسی.** کل منو، همه‌ی پرسش‌ها و همه‌ی پیام‌ها.
- **پیرینگ دومرحله‌ای.** کلید خصوصی خروجی روی خودِ خروجی ساخته می‌شود و هرگز منتقل
  نمی‌شود. هاب دعوت‌نامه می‌فرستد؛ خروجی فقط کلید عمومی‌اش را برمی‌گرداند.
- **توکن‌های سخت‌شده.** چک‌سام SHA-256، انقضای ۳۰ دقیقه‌ای (قابل تنظیم)، گره‌خورده به
  شناسه‌ی یک‌بارمصرف پیرینگ، بعد از استفاده `shred` می‌شود، و بدون `eval` پارس می‌شود.
- **قفل ورودی.** هر خروجی پورت تونلش را فقط از آی‌پی هاب می‌پذیرد.
- **ایزوله‌سازی کاربران.** کاربرها نه به هم می‌رسند نه به شبکه‌های خصوصی. پیش‌فرض روشن.
- **جامعیت باینری.** هش‌ها در نصب اول ثبت و در نصب مجدد بررسی می‌شوند.
- **صفحه‌ی امنیت** در هر دو منو که همه‌ی این‌ها را یک‌جا نشان می‌دهد.
- `umask 077` در کل اسکریپت؛ کانفیگ‌ها و لاگ `0600`.

### ویژگی‌ها

- **چند-خروجی** — یک سرور هاب هم‌زمان تا ۲۵۰ تونل مستقل به سرورهای خارج نگه می‌دارد.
  هرکدام اینترفیس وایرگارد، جفت‌کلید، کلید مشترک، بازه‌ی پورت و رمزهای مخصوص خود را دارد.
- **تصحیح خطای رو به جلو** — UDPspeeder با پاریتی Reed-Solomon و پرچم `--timeout 0`
  تا هیچ تأخیر دسته‌بندی اضافه نشود. پکت گم‌شده بازسازی می‌شود، نه ارسال مجدد.
- **پنهان‌سازی faketcp** — udp2raw دیتاگرام‌ها را در TCP مصنوعی با دست‌دهی سه‌مرحله‌ای
  واقعی می‌پیچد، به‌علاوه‌ی AES-128-CBC و HMAC-SHA1.
- **فیل‌اوور خودکار** — `hydra-watch` هر ۵ ثانیه به هر خروجی امتیاز
  `پینگ + ۲×جیتر + ۲۰×لاست` می‌دهد، با آستانه‌ی بهبود ۱۵٪ و هیسترزیس ۳ مرحله‌ای برای
  جلوگیری از جابه‌جایی مداوم مسیر. سوییچ فقط یک مسیر پیش‌فرض را بازنویسی می‌کند و بقیه‌ی
  تونل‌ها گرم می‌مانند.
- **تیونینگ کرنل** — BBR، صف‌بندی `fq`، بافرهای بزرگ‌تر، `rp_filter=2` برای مسیریابی
  نامتقارن چند-خروجی، و تنظیمات TCP کم‌تأخیر.
- **سه مود** — `full` (وایرگارد→FEC→faketcp)، `fec` (وایرگارد→FEC)، `plain` (فقط وایرگارد).
- **راه‌اندازی توکنی** — `hydra add-exit` یک توکن اعتبارسنجی‌شده می‌دهد و
  `hydra-exit apply <token>` سمت خارج را پیکربندی می‌کند. کپی دستی کلید لازم نیست.
- **مدیریت کاربران** — ساخت پیر وایرگارد همراه با خروجی QR.
- **فوروارد پورت** — DNAT هر تعداد پورت به خروجی دلخواه، جداشده با کاما و با پشتیبانی از
  بازه (`50820,51820,2097,2096,443,80` یا `27015,7777-7784`). در رول‌های `multiport` جمع
  می‌شود، بالای سقف ۱۵ خودکار تکه می‌شود، در چین‌های اختصاصی iptables می‌نشیند و بعد از
  ریبوت دوباره اعمال می‌شود. قبل از فوروارد پورت‌های حیاتی سرور (SSH، وایرگارد کاربران،
  udp2raw) هشدار می‌دهد.
- **بدون داکر** — باینری ساده و یونیت‌های systemd.
- **تک‌اسکریپت و منومحور** — یک فایل هر دو نقش را پوشش می‌دهد؛ می‌پرسد این ماشین هاب است
  یا خروجی و منوی مناسب را نشان می‌دهد. نصب با یک خط curl.

### محدودیت‌های شناخته‌شده

- در شرایط شبکه‌ی زنده تست نشده است. قبل از استفاده‌ی تولیدی اسکریپت را بخوانید.
- در `install.sh` یک خط `REPO=` هست که قبل از انتشار باید با مسیر گیت‌هاب خودت پرش کنی.
- یک دعوت‌نامه‌ی جفت‌نشده تا وقتی منقضی یا دوباره صادر نشده، یک اعتبارنامه‌ی زنده است.
- BBR فقط بر TCP حاکم است و مستقیماً خودِ تونل UDP را کنترل نمی‌کند. بخش مربوطه در
  README را ببینید.
- خروجی‌های IPv6 هنوز توسط پروب فیل‌اوور پشتیبانی نمی‌شوند.
- روی میزبان‌های arm64 به باینری‌های ۳۲ بیتی arm برمی‌گردد.

### پیش‌نیازها

دبیان/اوبونتو یا RHEL/Rocky/Alma، کرنل ≥ ۴.۹، دسترسی root، معماری `x86_64` یا `arm`.
