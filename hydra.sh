#!/usr/bin/env bash
# ============================================================================
#  hydra — Multi-Exit Gaming Tunnel
#  یک اسکریپت، هم برای سرور ایران (هاب) هم سرور خارج (خروجی)
#
#  نصب:  bash <(curl -fsSL https://raw.githubusercontent.com/USER/hydra/main/install.sh)
#  اجرا: hydra
# ============================================================================
set -uo pipefail

VERSION="2.0.0"
DIR="/etc/hydra"
EXITS="$DIR/exits.d"          # هاب: هر سرور خارج یک فایل
LINKS="$DIR/links.d"          # خروجی: هر هاب یک فایل
CLIENTS="$DIR/clients"
CONF="$DIR/hydra.conf"
ROLE_FILE="$DIR/role"
STATE="/run/hydra"
BINDIR="/usr/local/bin"
RT_ID=200; RT_NAME="hydra"
LOG="/var/log/hydra.log"

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[36m'; M=$'\e[35m'; W=$'\e[97m'; D=$'\e[90m'; N=$'\e[0m'
BLD=$'\e[1m'

# ---------------------------------------------------------------- helpers --
msg()  { echo -e "${B}::${N} $*"; }
ok()   { echo -e "${G}✔${N} $*"; }
warn() { echo -e "${Y}!${N} $*"; }
err()  { echo -e "${R}✘${N} $*" >&2; }
die()  { err "$*"; exit 1; }
logit(){ echo "$(date '+%F %T') $*" >>"$LOG" 2>/dev/null || true; }

ask() {  # ask "سوال" "پیش‌فرض"  -> مقدار روی stdout
  local p="$1" d="${2:-}" v
  printf "${B}?${N} %s%s: " "$p" "${d:+ ${D}[$d]${N}}" >&2
  read -r v </dev/tty
  echo "${v:-$d}"
}
askyn() { # askyn "سوال" [y|n]  -> 0/1
  local p="$1" d="${2:-y}" v
  printf "${B}?${N} %s ${D}[%s/%s]${N}: " "$p" "$([[ $d == y ]] && echo Y || echo y)" "$([[ $d == n ]] && echo N || echo n)" >&2
  read -r v </dev/tty; v="${v:-$d}"
  [[ "${v,,}" == y* ]]
}
pause() { printf "\n${D}Enter برای برگشت به منو…${N}" >&2; read -r </dev/tty; }
hr()    { printf "${D}"; printf '─%.0s' $(seq 1 62); printf "${N}\n"; }

valid_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [[ "$1" =~ ^[0-9a-fA-F:]+$ ]]; }

banner() {
cat <<EOF
${M}${BLD}
   ▄▄   ▄▄ ▄▄  ▄▄ ▄▄▄▄  ▄▄▄▄   ▄▄▄
   ██   ██ ██  ██ ██  ██ ██  ██ ██▄▄
   ██▄▄▄██ ▀█▄▄█▀ ██▄▄█▀ ██▄▄█▀ ██▄▄▄
   ██   ██   ██   ██  ██ ██  ██ ██  ██   ${N}${D}v$VERSION${N}
${N}${D}   تونل گیمینگ چند-خروجی · FEC · faketcp · BBR${N}
EOF
}

[[ $EUID -eq 0 ]] || die "با root اجرا کن:  sudo hydra"

# ---------------------------------------------------------------- defaults --
CLIENT_NET="10.77.0.0/24"; CLIENT_ADDR="10.77.0.1"; CLIENT_PREFIX="10.77.0"
CLIENT_WG_PORT="51820"; LINK_PREFIX="10.66"
RAW_PORT_BASE="39000"; SPD_LOCAL_BASE="44000"; RAW_LOCAL_BASE="33000"
FEC="10:5"; SWITCH_MARGIN="15"; CHECK_INTERVAL="5"; HYSTERESIS="3"; PUBLIC_IF=""
[[ -f "$CONF" ]] && . "$CONF"

save_conf() {
  mkdir -p "$DIR"
  cat >"$CONF" <<EOF
CLIENT_NET=$CLIENT_NET
CLIENT_ADDR=$CLIENT_ADDR
CLIENT_PREFIX=$CLIENT_PREFIX
CLIENT_WG_PORT=$CLIENT_WG_PORT
LINK_PREFIX=$LINK_PREFIX
RAW_PORT_BASE=$RAW_PORT_BASE
SPD_LOCAL_BASE=$SPD_LOCAL_BASE
RAW_LOCAL_BASE=$RAW_LOCAL_BASE
FEC=$FEC
SWITCH_MARGIN=$SWITCH_MARGIN
CHECK_INTERVAL=$CHECK_INTERVAL
HYSTERESIS=$HYSTERESIS
PUBLIC_IF=$PUBLIC_IF
EOF
  chmod 600 "$CONF"
}

detect_if() { ip -4 route show default 2>/dev/null | awk '/default/{print $5; exit}'; }
pub_ip() {
  curl -s --max-time 6 https://api.ipify.org 2>/dev/null \
    || ip -4 addr show "$(detect_if)" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1
}
role() { cat "$ROLE_FILE" 2>/dev/null || echo ""; }

# ============================================================== نصب پایه ====
install_deps() {
  msg "نصب پیش‌نیازها…"
  if command -v apt-get >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq wireguard-tools iproute2 iptables iputils-ping curl tar \
                           qrencode ca-certificates >/dev/null 2>&1
  elif command -v dnf >/dev/null; then
    dnf install -y -q wireguard-tools iproute iptables iputils curl tar qrencode >/dev/null 2>&1
  elif command -v yum >/dev/null; then
    yum install -y -q wireguard-tools iproute iptables iputils curl tar qrencode >/dev/null 2>&1
  else
    die "فقط Debian/Ubuntu و RHEL/Rocky/Alma پشتیبانی می‌شن."
  fi
  ok "پیش‌نیازها نصب شدن."
}

install_binaries() {
  local arch tmp
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64|armv7l|armv6l) arch=arm ;;
    *) die "معماری $(uname -m) پشتیبانی نمی‌شه." ;;
  esac
  tmp="$(mktemp -d)"
  if [[ ! -x "$BINDIR/udp2raw" ]]; then
    msg "دانلود udp2raw…"
    curl -fsSL -o "$tmp/u.tgz" https://github.com/wangyu-/udp2raw/releases/latest/download/udp2raw_binaries.tar.gz \
      && tar -xzf "$tmp/u.tgz" -C "$tmp" && install -m755 "$tmp/udp2raw_$arch" "$BINDIR/udp2raw" \
      || warn "دانلود udp2raw ناموفق بود."
  fi
  if [[ ! -x "$BINDIR/speederv2" ]]; then
    msg "دانلود UDPspeeder…"
    curl -fsSL -o "$tmp/s.tgz" https://github.com/wangyu-/UDPspeeder/releases/latest/download/speederv2_binaries.tar.gz \
      && tar -xzf "$tmp/s.tgz" -C "$tmp" && install -m755 "$tmp/speederv2_$arch" "$BINDIR/speederv2" \
      || warn "دانلود UDPspeeder ناموفق بود."
  fi
  rm -rf "$tmp"
  [[ -x "$BINDIR/udp2raw" && -x "$BINDIR/speederv2" ]] && ok "باینری‌ها آماده‌ان."
}

apply_tune() {
  msg "اعمال BBR و تیونینگ کرنل…"
  modprobe tcp_bbr 2>/dev/null || true
  echo tcp_bbr >/etc/modules-load.d/hydra-bbr.conf
  cat >/etc/sysctl.d/99-hydra.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_no_metrics_save = 1
net.netfilter.nf_conntrack_max = 262144
EOF
  sysctl --system >/dev/null 2>&1
  local cc; cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  [[ "$cc" == bbr ]] && ok "BBR فعال شد." || warn "الگوریتم فعلی: $cc (کرنل BBR نداره)"
  [[ -n "${PUBLIC_IF:-}" ]] && tc qdisc replace dev "$PUBLIC_IF" root fq 2>/dev/null
  return 0
}

install_units() {
  cat >/etc/systemd/system/hydra-raw@.service <<'EOF'
[Unit]
Description=hydra udp2raw client (%i)
After=network-online.target
[Service]
EnvironmentFile=/etc/hydra/exits.d/%i.conf
ExecStart=/usr/local/bin/udp2raw -c -l 127.0.0.1:${RAW_LOCAL} -r ${EXIT_IP}:${RAW_PORT} -k ${RAW_PASS} --raw-mode faketcp --cipher-mode aes128cbc --auth-mode hmac_sha1 -a
Restart=always
RestartSec=2
Nice=-10
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
  cat >/etc/systemd/system/hydra-spd@.service <<'EOF'
[Unit]
Description=hydra UDPspeeder FEC client (%i)
After=network-online.target
[Service]
EnvironmentFile=/etc/hydra/exits.d/%i.conf
ExecStart=/usr/local/bin/speederv2 -c -l 127.0.0.1:${SPD_LOCAL} -r ${SPD_REMOTE} -f ${FEC} --mode 0 --timeout 0 --mtu ${SPD_MTU} -k ${SPD_PASS} --report 0
Restart=always
RestartSec=2
Nice=-10
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
  cat >/etc/systemd/system/hydra-link@.service <<'EOF'
[Unit]
Description=hydra link to exit %i
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/hydra _link-up %i
ExecStop=/usr/local/bin/hydra _link-down %i
[Install]
WantedBy=multi-user.target
EOF
  cat >/etc/systemd/system/hydra-exit-raw@.service <<'EOF'
[Unit]
Description=hydra udp2raw server (%i)
After=network-online.target
[Service]
EnvironmentFile=/etc/hydra/links.d/%i.conf
ExecStart=/usr/local/bin/udp2raw -s -l 0.0.0.0:${RAW_PORT} -r 127.0.0.1:${SPD_LOCAL} -k ${RAW_PASS} --raw-mode faketcp --cipher-mode aes128cbc --auth-mode hmac_sha1 -a
Restart=always
RestartSec=2
Nice=-10
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
  cat >/etc/systemd/system/hydra-exit-spd@.service <<'EOF'
[Unit]
Description=hydra UDPspeeder FEC server (%i)
After=network-online.target
[Service]
EnvironmentFile=/etc/hydra/links.d/%i.conf
ExecStart=/usr/local/bin/speederv2 -s -l ${SPD_LISTEN} -r 127.0.0.1:${WG_PORT} -f ${FEC} --mode 0 --timeout 0 --mtu ${SPD_MTU} -k ${SPD_PASS} --report 0
Restart=always
RestartSec=2
Nice=-10
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
  cat >/etc/systemd/system/hydra-exit-link@.service <<'EOF'
[Unit]
Description=hydra exit link %i
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/hydra _elink-up %i
ExecStop=/usr/local/bin/hydra _elink-down %i
[Install]
WantedBy=multi-user.target
EOF
  cat >/etc/systemd/system/hydra-ports.service <<'EOF'
[Unit]
Description=hydra port forwarding rules
After=network-online.target hydra-rule.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/hydra _ports-apply
[Install]
WantedBy=multi-user.target
EOF
  cat >/etc/systemd/system/hydra-watch.service <<'EOF'
[Unit]
Description=hydra health-check and failover
After=network-online.target
[Service]
ExecStart=/usr/local/bin/hydra _watch
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

# =============================================================== نصب هاب ====
setup_hub() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}راه‌اندازی سرور ایران (هاب)${N}"; hr; echo
  install_deps; install_binaries
  mkdir -p "$EXITS" "$CLIENTS" "$STATE" /etc/wireguard
  chmod 700 "$DIR" /etc/wireguard
  PUBLIC_IF="$(detect_if)"; save_conf
  echo "hub" >"$ROLE_FILE"
  apply_tune; install_units

  grep -qE "^\s*$RT_ID\s+$RT_NAME\b" /etc/iproute2/rt_tables 2>/dev/null \
    || echo "$RT_ID $RT_NAME" >>/etc/iproute2/rt_tables
  cat >/etc/systemd/system/hydra-rule.service <<EOF
[Unit]
Description=hydra policy routing
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=-/sbin/ip rule add from $CLIENT_NET lookup $RT_NAME pref 100
ExecStartPost=-/sbin/iptables -t nat -A POSTROUTING -s $CLIENT_NET -o wg-+ -j MASQUERADE
ExecStartPost=-/sbin/iptables -A FORWARD -i wg0 -j ACCEPT
ExecStartPost=-/sbin/iptables -A FORWARD -o wg0 -j ACCEPT
ExecStop=-/sbin/ip rule del from $CLIENT_NET lookup $RT_NAME pref 100
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now hydra-rule >/dev/null 2>&1

  if [[ ! -f /etc/wireguard/wg0.conf ]]; then
    msg "ساخت اینترفیس کاربران (wg0)…"
    local priv pub; priv="$(wg genkey)"; pub="$(echo "$priv" | wg pubkey)"
    echo "$pub" >"$DIR/wg0.pub"
    cat >/etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $priv
Address    = $CLIENT_ADDR/24
ListenPort = $CLIENT_WG_PORT
MTU        = 1280
EOF
    chmod 600 /etc/wireguard/wg0.conf
    systemctl enable --now "wg-quick@wg0" >/dev/null 2>&1
  fi
  systemctl enable --now hydra-watch >/dev/null 2>&1
  systemctl enable --now hydra-ports >/dev/null 2>&1
  echo; ok "سرور ایران آماده‌ست."
  echo -e "  ${D}حالا از منو گزینه‌ی «ساخت تونل جدید» رو بزن.${N}"
  pause
}

setup_exit() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}راه‌اندازی سرور خارج (خروجی)${N}"; hr; echo
  install_deps; install_binaries
  mkdir -p "$LINKS" "$STATE" /etc/wireguard
  chmod 700 "$DIR" /etc/wireguard
  PUBLIC_IF="$(detect_if)"; save_conf
  echo "exit" >"$ROLE_FILE"
  apply_tune; install_units
  echo; ok "سرور خارج آماده‌ست."
  echo -e "  ${D}حالا توکنی که سرور ایران داده رو با گزینه‌ی «اتصال به هاب» وارد کن.${N}"
  pause
}

# ========================================================= ساخت تونل (هاب) ==
next_idx() {
  local i
  for i in $(seq 1 250); do
    grep -qs "^IDX=$i$" "$EXITS"/*.conf 2>/dev/null || { echo "$i"; return; }
  done
  echo 0
}

create_tunnel() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}ساخت تونل جدید به یک سرور خارج${N}"; hr; echo

  local name eip mode
  name="$(ask "یک نام برای این سرور خارج (مثلاً de1، nl1)")"
  [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || { err "نام فقط حروف انگلیسی، عدد، خط‌تیره."; pause; return; }
  [[ -f "$EXITS/$name.conf" ]] && { err "تونلی با نام «$name» از قبل هست."; pause; return; }

  eip="$(ask "آی‌پی سرور خارج")"
  valid_ip "$eip" || { err "آی‌پی نامعتبره."; pause; return; }

  echo
  echo -e "  ${W}حالت تونل:${N}"
  echo -e "   ${G}1${N}) ${W}full${N}  ${D}— وایرگارد + FEC + faketcp  (پیشنهادی، ضدشکل‌دهی UDP)${N}"
  echo -e "   ${G}2${N}) ${W}fec${N}   ${D}— وایرگارد + FEC          (اگه faketcp روی اون VPS کار نکرد)${N}"
  echo -e "   ${G}3${N}) ${W}plain${N} ${D}— فقط وایرگارد            (مسیر تمیزه، فقط چند-خروجی می‌خوای)${N}"
  echo
  case "$(ask "انتخاب" "1")" in
    2) mode=fec ;; 3) mode=plain ;; *) mode=full ;;
  esac

  local idx; idx="$(next_idx)"
  [[ "$idx" == 0 ]] && { err "ظرفیت پر شده."; pause; return; }

  local hub_priv hub_pub exit_priv exit_pub psk raw_pass spd_pass
  hub_priv="$(wg genkey)";  hub_pub="$(echo "$hub_priv" | wg pubkey)"
  exit_priv="$(wg genkey)"; exit_pub="$(echo "$exit_priv" | wg pubkey)"
  psk="$(wg genpsk)"
  raw_pass="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
  spd_pass="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"

  local raw_port=$((RAW_PORT_BASE+idx)) raw_local=$((RAW_LOCAL_BASE+idx))
  local spd_local=$((SPD_LOCAL_BASE+idx)) wg_port=$((51900+idx))
  local hub_in="$LINK_PREFIX.$idx.1" exit_in="$LINK_PREFIX.$idx.2"
  local wg_mtu spd_mtu spd_remote wg_endpoint
  case "$mode" in
    full)  wg_mtu=1280; spd_mtu=1200; spd_remote="127.0.0.1:$raw_local"; wg_endpoint="127.0.0.1:$spd_local" ;;
    fec)   wg_mtu=1330; spd_mtu=1250; spd_remote="$eip:$raw_port";       wg_endpoint="127.0.0.1:$spd_local" ;;
    plain) wg_mtu=1420; spd_mtu=1250; spd_remote="-";                    wg_endpoint="$eip:$wg_port" ;;
  esac

  cat >"$EXITS/$name.conf" <<EOF
NAME=$name
IDX=$idx
MODE=$mode
EXIT_IP=$eip
HUB_IN=$hub_in
EXIT_IN=$exit_in
RAW_PORT=$raw_port
RAW_LOCAL=$raw_local
SPD_LOCAL=$spd_local
SPD_REMOTE=$spd_remote
WG_PORT=$wg_port
WG_MTU=$wg_mtu
SPD_MTU=$spd_mtu
FEC=$FEC
RAW_PASS=$raw_pass
SPD_PASS=$spd_pass
ENABLED=1
EOF
  chmod 600 "$EXITS/$name.conf"

  cat >"/etc/wireguard/wg-$name.conf" <<EOF
[Interface]
PrivateKey = $hub_priv
Address    = $hub_in/30
MTU        = $wg_mtu
Table      = off

[Peer]
PublicKey    = $exit_pub
PresharedKey = $psk
Endpoint     = $wg_endpoint
AllowedIPs   = 0.0.0.0/0
PersistentKeepalive = 15
EOF
  chmod 600 "/etc/wireguard/wg-$name.conf"

  systemctl enable --now "hydra-link@$name" >/dev/null 2>&1
  systemctl enable --now hydra-watch >/dev/null 2>&1
  logit "created tunnel $name -> $eip mode=$mode"

  local token
  token="$(printf '%s\n' \
    "NAME=$name" "IDX=$idx" "MODE=$mode" "HUB_IP=$(pub_ip)" \
    "HUB_IN=$hub_in" "EXIT_IN=$exit_in" "RAW_PORT=$raw_port" \
    "SPD_LOCAL=$spd_local" "WG_PORT=$wg_port" "WG_MTU=$wg_mtu" \
    "SPD_MTU=$spd_mtu" "FEC=$FEC" "RAW_PASS=$raw_pass" "SPD_PASS=$spd_pass" \
    "PSK=$psk" "EXIT_PRIV=$exit_priv" "HUB_PUB=$hub_pub" | base64 -w0)"
  echo "$token" >"$DIR/token-$name.txt"; chmod 600 "$DIR/token-$name.txt"

  clear; banner; echo; hr
  ok "تونل «$name» ساخته شد."
  hr; echo
  echo -e "  ${W}${BLD}حالا این یک خط رو روی سرور خارج ($eip) اجرا کن:${N}"; echo
  echo -e "${G}bash <(curl -fsSL $INSTALL_URL) apply $token${N}"
  echo
  hr
  case "$mode" in
    full)  echo -e "  ${Y}پورت TCP $raw_port${N} رو روی فایروال سرور خارج باز کن." ;;
    fec)   echo -e "  ${Y}پورت UDP $raw_port${N} رو روی فایروال سرور خارج باز کن." ;;
    plain) echo -e "  ${Y}پورت UDP $wg_port${N} رو روی فایروال سرور خارج باز کن." ;;
  esac
  echo -e "  ${D}توکن در $DIR/token-$name.txt ذخیره شد (گزینه‌ی «نمایش توکن»).${N}"
  pause
}

# ============================================================ اتصال (خروجی) ==
connect_hub() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}اتصال به سرور ایران${N}"; hr; echo
  echo -e "  ${D}توکنی که سرور ایران بهت داد رو اینجا پیست کن:${N}"; echo
  local token; token="$(ask "توکن")"
  [[ -n "$token" ]] || { err "توکن خالیه."; pause; return; }
  apply_token "$token"
  pause
}

apply_token() {
  local token="$1" dec line k v
  dec="$(echo "$token" | tr -d ' \n' | base64 -d 2>/dev/null)" || { err "توکن نامعتبره."; return 1; }
  if grep -qvE '^[A-Z_]+=[A-Za-z0-9+/=:._-]*$' <<<"$dec"; then err "توکن خراب یا دستکاری‌شده‌ست."; return 1; fi
  while read -r line; do
    [[ -z "$line" ]] && continue
    k="${line%%=*}"; v="${line#*=}"      # نه IFS، وگرنه = آخر کلیدهای base64 می‌پره
    printf -v "$k" '%s' "$v"
  done <<<"$dec"
  [[ -n "${NAME:-}" && -n "${EXIT_PRIV:-}" ]] || { err "توکن ناقصه."; return 1; }

  [[ -d "$LINKS" ]] || { msg "اول نصب پایه…"; install_deps; install_binaries
                         mkdir -p "$LINKS" "$STATE" /etc/wireguard; chmod 700 "$DIR" /etc/wireguard
                         PUBLIC_IF="$(detect_if)"; save_conf; echo exit >"$ROLE_FILE"
                         apply_tune; install_units; }

  local pif spd_listen; pif="$(detect_if)"
  [[ "$MODE" == "full" ]] && spd_listen="127.0.0.1:$SPD_LOCAL" || spd_listen="0.0.0.0:$RAW_PORT"

  cat >"$LINKS/$NAME.conf" <<EOF
NAME=$NAME
IDX=$IDX
MODE=$MODE
HUB_IP=$HUB_IP
HUB_IN=$HUB_IN
EXIT_IN=$EXIT_IN
RAW_PORT=$RAW_PORT
SPD_LOCAL=$SPD_LOCAL
SPD_LISTEN=$spd_listen
WG_PORT=$WG_PORT
WG_MTU=$WG_MTU
SPD_MTU=$SPD_MTU
FEC=$FEC
RAW_PASS=$RAW_PASS
SPD_PASS=$SPD_PASS
PUBLIC_IF=$pif
EOF
  chmod 600 "$LINKS/$NAME.conf"

  cat >"/etc/wireguard/wg-$NAME.conf" <<EOF
[Interface]
PrivateKey = $EXIT_PRIV
Address    = $EXIT_IN/30
ListenPort = $WG_PORT
MTU        = $WG_MTU
Table      = off
PostUp   = iptables -t nat -A POSTROUTING -s $HUB_IN/32 -o $pif -j MASQUERADE; iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s $HUB_IN/32 -o $pif -j MASQUERADE; iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT

[Peer]
PublicKey    = $HUB_PUB
PresharedKey = $PSK
AllowedIPs   = $HUB_IN/32
PersistentKeepalive = 15
EOF
  chmod 600 "/etc/wireguard/wg-$NAME.conf"

  systemctl enable --now "hydra-exit-link@$NAME" >/dev/null 2>&1
  logit "applied token for hub link $NAME"
  echo; ok "لینک «$NAME» فعال شد (مود $MODE)."
  case "$MODE" in
    full)  echo -e "  ${Y}پورت TCP $RAW_PORT${N} باید روی فایروال این سرور باز باشه." ;;
    fec)   echo -e "  ${Y}پورت UDP $RAW_PORT${N} باید روی فایروال این سرور باز باشه." ;;
    plain) echo -e "  ${Y}پورت UDP $WG_PORT${N} باید روی فایروال این سرور باز باشه." ;;
  esac
}

# ================================================================ link ctl ==
_link_up() {
  local n="$1" f="$EXITS/$1.conf"; [[ -f "$f" ]] || exit 1; . "$f"
  case "$MODE" in
    full) systemctl start "hydra-raw@$n"; sleep 1; systemctl start "hydra-spd@$n" ;;
    fec)  systemctl start "hydra-spd@$n" ;;
  esac
  sleep 1; wg-quick up "wg-$n" 2>/dev/null
  [[ -f "$EXITS/$n.ports" ]] && pf_apply_all >/dev/null 2>&1
  if ! ip route show table "$RT_NAME" 2>/dev/null | grep -q default; then
    ip route replace default dev "wg-$n" table "$RT_NAME" 2>/dev/null
    mkdir -p "$STATE"; echo "$n" >"$STATE/active"
  fi
  exit 0
}
_link_down() { wg-quick down "wg-$1" 2>/dev/null; systemctl stop "hydra-spd@$1" 2>/dev/null; systemctl stop "hydra-raw@$1" 2>/dev/null; exit 0; }
_elink_up() {
  local n="$1" f="$LINKS/$1.conf"; [[ -f "$f" ]] || exit 1; . "$f"
  case "$MODE" in
    full) systemctl start "hydra-exit-raw@$n"; sleep 1; systemctl start "hydra-exit-spd@$n" ;;
    fec)  systemctl start "hydra-exit-spd@$n" ;;
  esac
  sleep 1; wg-quick up "wg-$n" 2>/dev/null; exit 0
}
_elink_down() { wg-quick down "wg-$1" 2>/dev/null; systemctl stop "hydra-exit-spd@$1" 2>/dev/null; systemctl stop "hydra-exit-raw@$1" 2>/dev/null; exit 0; }

# ================================================================== probe ===
probe() { # iface peer -> "avg mdev loss"
  local out loss avg mdev
  out="$(ping -I "$1" -c 4 -i 0.2 -W 1 -q "$2" 2>/dev/null)" || { echo "- - 100"; return; }
  loss="$(sed -n 's/.*, \([0-9.]*\)% packet loss.*/\1/p' <<<"$out")"
  avg="$(sed -n 's#.*= [0-9.]*/\([0-9.]*\)/[0-9.]*/\([0-9.]*\) ms.*#\1#p' <<<"$out")"
  mdev="$(sed -n 's#.*= [0-9.]*/\([0-9.]*\)/[0-9.]*/\([0-9.]*\) ms.*#\2#p' <<<"$out")"
  echo "${avg:--} ${mdev:--} ${loss:-100}"
}

show_status_hub() {
  local active pin cc
  active="$(cat "$STATE/active" 2>/dev/null || echo '-')"
  pin="$(cat "$DIR/pin" 2>/dev/null || echo '')"
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  echo -e "  BBR: ${W}$cc${N}   خروجی فعال: ${G}${active}${N}$([[ -n $pin ]] && echo "  ${Y}(پین دستی)${N}")"
  echo
  printf "  ${W}%-10s %-16s %-6s %-9s %-9s %-7s %s${N}\n" "NAME" "IP" "MODE" "PING" "JITTER" "LOSS" "وضعیت"
  hr
  local any=0 f
  for f in "$EXITS"/*.conf; do
    [[ -f "$f" ]] || continue; any=1
    ( . "$f"
      read -r avg mdev loss < <(probe "wg-$NAME" "$EXIT_IN")
      local st col
      if [[ "$loss" == "100" ]]; then st="قطع"; col="$R"
      elif (( $(echo "${loss%.*}" ) > 5 )); then st="ضعیف"; col="$Y"
      else st="سالم"; col="$G"; fi
      [[ "$NAME" == "$active" ]] && st="$st ◀"
      printf "  %-10s %-16s %-6s %-9s %-9s %-7s ${col}%s${N}\n" \
        "$NAME" "$EXIT_IP" "$MODE" "${avg}ms" "${mdev}ms" "${loss}%" "$st" )
  done
  [[ $any == 0 ]] && echo -e "  ${D}هنوز تونلی ساخته نشده.${N}"
}

show_status_exit() {
  printf "  ${W}%-12s %-6s %-16s %-16s %s${N}\n" "LINK" "MODE" "HUB" "HANDSHAKE" "سرویس"
  hr
  local any=0 f
  for f in "$LINKS"/*.conf; do
    [[ -f "$f" ]] || continue; any=1
    ( . "$f"
      local hs col
      hs="$(wg show "wg-$NAME" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)"
      if [[ -n "$hs" && "$hs" != "0" ]]; then hs="$(( $(date +%s) - hs ))s ago"; col="$G"
      else hs="—"; col="$R"; fi
      printf "  %-12s %-6s %-16s ${col}%-16s${N} %s\n" \
        "$NAME" "$MODE" "$HUB_IP" "$hs" "$(systemctl is-active "hydra-exit-link@$NAME" 2>/dev/null)" )
  done
  [[ $any == 0 ]] && echo -e "  ${D}هنوز به هیچ هابی وصل نشدی.${N}"
}

# ================================================================ watchdog ==
_watch() {
  mkdir -p "$STATE"
  local cand="" streak=0 current best best_score cur_score need name sc f
  current="$(cat "$STATE/active" 2>/dev/null || echo '')"
  while :; do
    local pin; pin="$(cat "$DIR/pin" 2>/dev/null || echo '')"
    if [[ -n "$pin" ]]; then
      if [[ "$pin" != "$current" ]] && ip route replace default dev "wg-$pin" table "$RT_NAME" 2>/dev/null; then
        current="$pin"; echo "$current" >"$STATE/active"; logit "pinned -> $pin"
      fi
      sleep "$CHECK_INTERVAL"; continue
    fi
    best=""; best_score=9999999; cur_score=9999999; : >"$STATE/scores.tmp"
    for f in "$EXITS"/*.conf; do
      [[ -f "$f" ]] || continue
      ( . "$f"; [[ "${ENABLED:-1}" == 1 ]] || exit 0
        read -r a m l < <(probe "wg-$NAME" "$EXIT_IN")
        if [[ "$a" == "-" || "$l" == "100" ]]; then echo "$NAME 9999999"
        else awk -v n="$NAME" -v a="$a" -v m="${m:-0}" -v l="$l" \
               'BEGIN{printf "%s %d\n", n, (a+2*m+20*l)*100}'; fi ) >>"$STATE/scores.tmp"
    done
    mv -f "$STATE/scores.tmp" "$STATE/scores" 2>/dev/null
    while read -r name sc; do
      [[ -z "$name" ]] && continue
      [[ "$name" == "$current" ]] && cur_score="$sc"
      (( sc < best_score )) && { best_score="$sc"; best="$name"; }
    done <"$STATE/scores" 2>/dev/null
    if [[ -n "$best" ]] && (( best_score < 9999999 )); then
      if [[ -z "$current" ]]; then
        ip route replace default dev "wg-$best" table "$RT_NAME" 2>/dev/null \
          && { current="$best"; echo "$current" >"$STATE/active"; logit "start -> $best"; }
      else
        need=$(( cur_score * (100 - SWITCH_MARGIN) / 100 ))
        if [[ "$best" != "$current" ]] && { (( cur_score >= 9999999 )) || (( best_score < need )); }; then
          [[ "$best" == "$cand" ]] && streak=$((streak+1)) || { cand="$best"; streak=1; }
          if (( streak >= HYSTERESIS )) || (( cur_score >= 9999999 )); then
            ip route replace default dev "wg-$best" table "$RT_NAME" 2>/dev/null \
              && { logit "switch $current -> $best ($cur_score -> $best_score)"
                   current="$best"; echo "$current" >"$STATE/active"; cand=""; streak=0; }
          fi
        else cand=""; streak=0; fi
      fi
    fi
    sleep "$CHECK_INTERVAL"
  done
}

# ================================================================ کاربران ===
client_add() {
  clear; banner; echo; hr; echo -e "  ${W}${BLD}کاربر جدید${N}"; hr; echo
  local n; n="$(ask "نام کاربر")"
  [[ "$n" =~ ^[a-zA-Z0-9_-]+$ ]] || { err "نام نامعتبر."; pause; return; }
  [[ -f "$CLIENTS/$n.conf" ]] && { err "کاربر هست."; pause; return; }
  local last=2 ipn priv pub psk f
  for f in "$CLIENTS"/*.ip; do [[ -f "$f" ]] && { local u; u="$(cat "$f")"; (( u > last )) && last=$u; }; done
  ipn=$((last+1)); (( ipn < 255 )) || { err "آی‌پی تموم شد."; pause; return; }
  priv="$(wg genkey)"; pub="$(echo "$priv" | wg pubkey)"; psk="$(wg genpsk)"
  echo "$ipn" >"$CLIENTS/$n.ip"
  wg set wg0 peer "$pub" preshared-key <(echo "$psk") allowed-ips "$CLIENT_PREFIX.$ipn/32" 2>/dev/null
  wg-quick save wg0 2>/dev/null
  cat >"$CLIENTS/$n.conf" <<EOF
[Interface]
PrivateKey = $priv
Address    = $CLIENT_PREFIX.$ipn/32
DNS        = 1.1.1.1, 8.8.8.8
MTU        = 1280

[Peer]
PublicKey    = $(cat "$DIR/wg0.pub" 2>/dev/null)
PresharedKey = $psk
Endpoint     = $(pub_ip):$CLIENT_WG_PORT
AllowedIPs   = 0.0.0.0/0
PersistentKeepalive = 15
EOF
  chmod 600 "$CLIENTS/$n.conf"
  clear; ok "کاربر «$n» ساخته شد → $CLIENT_PREFIX.$ipn"; echo
  command -v qrencode >/dev/null && qrencode -t ansiutf8 <"$CLIENTS/$n.conf"
  echo; hr; cat "$CLIENTS/$n.conf"; hr
  pause
}

client_menu() {
  while :; do
    clear; banner; echo; hr; echo -e "  ${W}${BLD}مدیریت کاربران${N}"; hr; echo
    local i=0 f
    printf "  ${W}%-4s %-16s %s${N}\n" "#" "NAME" "IP"
    for f in "$CLIENTS"/*.ip; do [[ -f "$f" ]] || continue; i=$((i+1))
      printf "  %-4s %-16s %s\n" "$i" "$(basename "$f" .ip)" "$CLIENT_PREFIX.$(cat "$f")"; done
    [[ $i == 0 ]] && echo -e "  ${D}کاربری نیست.${N}"
    echo; hr
    echo -e "   ${G}1${N}) کاربر جدید      ${G}2${N}) نمایش QR       ${G}3${N}) حذف کاربر"
    echo -e "   ${G}0${N}) بازگشت"; echo
    case "$(ask "انتخاب")" in
      1) client_add ;;
      2) local n; n="$(ask "نام کاربر")"
         [[ -f "$CLIENTS/$n.conf" ]] && { clear; qrencode -t ansiutf8 <"$CLIENTS/$n.conf"; echo; cat "$CLIENTS/$n.conf"; } || err "پیدا نشد."
         pause ;;
      3) local n; n="$(ask "نام کاربر برای حذف")"
         if [[ -f "$CLIENTS/$n.conf" ]]; then
           local pk; pk="$(grep -oP '(?<=^PrivateKey = ).*' "$CLIENTS/$n.conf" | wg pubkey)"
           wg set wg0 peer "$pk" remove 2>/dev/null; wg-quick save wg0 2>/dev/null
           rm -f "$CLIENTS/$n.conf" "$CLIENTS/$n.ip"; ok "حذف شد."
         else err "پیدا نشد."; fi; pause ;;
      0|"") return ;;
    esac
  done
}

# ============================================================ سایر گزینه‌ها ==
tunnel_menu() {
  while :; do
    clear; banner; echo; hr; echo -e "  ${W}${BLD}مدیریت تونل‌ها${N}"; hr; echo
    show_status_hub; echo; hr
    echo -e "   ${G}1${N}) حذف تونل        ${G}2${N}) نمایش توکن     ${G}3${N}) ری‌استارت همه"
    echo -e "   ${G}4${N}) پین روی یک خروجی  ${G}5${N}) برگشت به خودکار"
    echo -e "   ${G}0${N}) بازگشت"; echo
    case "$(ask "انتخاب")" in
      1) local n; n="$(ask "نام تونل برای حذف")"
         if [[ -f "$EXITS/$n.conf" ]]; then
           systemctl disable --now "hydra-link@$n" >/dev/null 2>&1
           rm -f "$EXITS/$n.conf" "$EXITS/$n.ports" "/etc/wireguard/wg-$n.conf" "$DIR/token-$n.txt"
           pf_apply_all >/dev/null 2>&1
           ok "حذف شد."
         else err "پیدا نشد."; fi; pause ;;
      2) local n; n="$(ask "نام تونل")"
         if [[ -f "$DIR/token-$n.txt" ]]; then
           clear; echo -e "${W}روی سرور خارج اجرا کن:${N}\n"
           echo -e "${G}bash <(curl -fsSL $INSTALL_URL) apply $(cat "$DIR/token-$n.txt")${N}"
         else err "توکن نیست."; fi; pause ;;
      3) local f; for f in "$EXITS"/*.conf; do [[ -f "$f" ]] && systemctl restart "hydra-link@$(basename "$f" .conf)"; done
         ok "همه ری‌استارت شدن."; pause ;;
      4) local n; n="$(ask "نام خروجی")"
         if [[ -f "$EXITS/$n.conf" ]]; then echo "$n" >"$DIR/pin"
           ip route replace default dev "wg-$n" table "$RT_NAME" 2>/dev/null
           mkdir -p "$STATE"; echo "$n" >"$STATE/active"; ok "پین شد روی «$n»."
         else err "پیدا نشد."; fi; pause ;;
      5) rm -f "$DIR/pin"; ok "انتخاب خودکار فعال شد."; pause ;;
      0|"") return ;;
    esac
  done
}

fec_menu() {
  clear; banner; echo; hr; echo -e "  ${W}${BLD}تنظیم FEC${N}  ${D}(فعلی: $FEC)${N}"; hr; echo
  echo -e "  ${D}فرمت «داده:پاریتی» — هرچه پاریتی بیشتر، تحمل لاست بیشتر، مصرف بیشتر.${N}"; echo
  echo -e "   ${G}1${N}) ${W}20:5${N}   ${D}لاست زیر ۱٪    — سربار ۲۵٪${N}"
  echo -e "   ${G}2${N}) ${W}10:5${N}   ${D}لاست ۱ تا ۵٪   — سربار ۵۰٪  (پیش‌فرض)${N}"
  echo -e "   ${G}3${N}) ${W}8:8${N}    ${D}لاست ۵ تا ۱۵٪  — سربار ۱۰۰٪${N}"
  echo -e "   ${G}4${N}) ${W}4:8${N}    ${D}لاست بالای ۱۵٪ — سربار ۲۰۰٪${N}"
  echo -e "   ${G}5${N}) دستی        ${G}0${N}) بازگشت"; echo
  local new
  case "$(ask "انتخاب")" in
    1) new="20:5" ;; 2) new="10:5" ;; 3) new="8:8" ;; 4) new="4:8" ;;
    5) new="$(ask "مقدار (مثلاً 12:6)")" ;;
    *) return ;;
  esac
  [[ "$new" =~ ^[0-9]+:[0-9]+$ ]] || { err "فرمت اشتباهه."; pause; return; }
  FEC="$new"; save_conf
  local f
  for f in "$EXITS"/*.conf; do [[ -f "$f" ]] && sed -i "s/^FEC=.*/FEC=$new/" "$f"; done
  for f in "$LINKS"/*.conf; do [[ -f "$f" ]] && sed -i "s/^FEC=.*/FEC=$new/" "$f"; done
  systemctl daemon-reload
  for f in "$EXITS"/*.conf; do [[ -f "$f" ]] && systemctl restart "hydra-spd@$(basename "$f" .conf)" 2>/dev/null; done
  for f in "$LINKS"/*.conf; do [[ -f "$f" ]] && systemctl restart "hydra-exit-spd@$(basename "$f" .conf)" 2>/dev/null; done
  ok "FEC روی $new تنظیم شد."
  warn "همین مقدار رو روی سمت مقابل هم ست کن، وگرنه لینک بالا نمیاد."
  pause
}

# ========================================================== فوروارد پورت ====
#  ذخیره در $EXITS/<name>.ports  — هر خط:  <proto> <لیست پورت>
#  اعمال در چین‌های اختصاصی، پس همیشه قابل flush و بازسازیِ تمیز است.
PF_CHUNK=15          # سقف multiport در iptables

pf_norm() {          # "80, 443, 7777-7784" -> "80,443,7777:7784"  (یا خطا)
  local raw="${1// /}" out="" t a b
  [[ -n "$raw" ]] || return 1
  for t in ${raw//,/ }; do
    if [[ "$t" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
      a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
      (( a>=1 && a<=65535 && b>=1 && b<=65535 && a<=b )) || return 1
      out+="$a:$b,"
    elif [[ "$t" =~ ^[0-9]{1,5}$ ]]; then
      (( t>=1 && t<=65535 )) || return 1
      out+="$t,"
    else return 1; fi
  done
  echo "${out%,}"
}

pf_count() {         # تعداد ورودی‌ها (بازه = ۲ تا)
  local t n=0
  for t in ${1//,/ }; do [[ "$t" == *:* ]] && n=$((n+2)) || n=$((n+1)); done
  echo "$n"
}

pf_chunks() {        # لیست بلند را به تکه‌های مجاز multiport می‌شکند
  local t c cost=0 cur=""
  for t in ${1//,/ }; do
    [[ "$t" == *:* ]] && c=2 || c=1
    if (( cost + c > PF_CHUNK )); then echo "${cur%,}"; cur=""; cost=0; fi
    cur+="$t,"; cost=$((cost+c))
  done
  [[ -n "$cur" ]] && echo "${cur%,}"
}

pf_reserved() {      # پورت‌هایی که نباید فوروارد بشن، وگرنه خود سرور می‌خوابه
  local f sshp
  sshp="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)"
  echo -n "${sshp:-22} $CLIENT_WG_PORT"
  for f in "$EXITS"/*.conf; do
    [[ -f "$f" ]] && echo -n " $(sed -n 's/^RAW_PORT=//p' "$f")"
  done
  echo
}

pf_conflicts() {     # کدام پورت‌های لیست با پورت‌های حیاتی تداخل دارند
  local list="$1" t p a b conf=""
  local res; res="$(pf_reserved)"
  for t in ${list//,/ }; do
    if [[ "$t" == *:* ]]; then
      a="${t%%:*}"; b="${t##*:}"
      for p in $res; do [[ -n "$p" ]] && (( p>=a && p<=b )) && conf+="$p "; done
    else
      for p in $res; do [[ "$t" == "$p" ]] && conf+="$p "; done
    fi
  done
  echo "$conf"
}

pf_chains_init() {
  iptables -t nat -N HYDRA_PRE  2>/dev/null
  iptables -t nat -N HYDRA_POST 2>/dev/null
  iptables        -N HYDRA_FWD  2>/dev/null
  iptables -t nat -C PREROUTING  -j HYDRA_PRE  2>/dev/null || iptables -t nat -I PREROUTING  1 -j HYDRA_PRE
  iptables -t nat -C POSTROUTING -j HYDRA_POST 2>/dev/null || iptables -t nat -I POSTROUTING 1 -j HYDRA_POST
  iptables        -C FORWARD     -j HYDRA_FWD  2>/dev/null || iptables        -I FORWARD     1 -j HYDRA_FWD
}

pf_apply_all() {     # همه‌چیز را از روی فایل‌ها بازسازی می‌کند (idempotent)
  pf_chains_init
  iptables -t nat -F HYDRA_PRE  2>/dev/null
  iptables -t nat -F HYDRA_POST 2>/dev/null
  iptables        -F HYDRA_FWD  2>/dev/null
  iptables -A HYDRA_FWD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null

  local f name proto list pr chunk rules=0
  for f in "$EXITS"/*.ports; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f" .ports)"
    [[ -f "$EXITS/$name.conf" ]] || continue
    local EXIT_IN; EXIT_IN="$(sed -n 's/^EXIT_IN=//p' "$EXITS/$name.conf")"
    [[ -n "$EXIT_IN" ]] || continue
    iptables -t nat -A HYDRA_POST -o "wg-$name" -j MASQUERADE 2>/dev/null
    while read -r proto list; do
      [[ -z "${proto:-}" || -z "${list:-}" ]] && continue
      for pr in $( [[ "$proto" == both ]] && echo "tcp udp" || echo "$proto" ); do
        while read -r chunk; do
          [[ -z "$chunk" ]] && continue
          iptables -t nat -A HYDRA_PRE -i "$PUBLIC_IF" -p "$pr" -m multiport --dports "$chunk" \
                   -j DNAT --to-destination "$EXIT_IN" 2>/dev/null && rules=$((rules+1))
          iptables -A HYDRA_FWD -d "$EXIT_IN" -p "$pr" -m multiport --dports "$chunk" -j ACCEPT 2>/dev/null
        done < <(pf_chunks "$list")
      done
    done <"$f"
  done
  echo "$rules"
}

pf_table() {         # جدول فورواردهای فعلی
  printf "  ${W}%-4s %-10s %-6s %s${N}\n" "#" "EXIT" "PROTO" "PORTS"
  hr
  local f name proto list i=0
  for f in "$EXITS"/*.ports; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f" .ports)"
    while read -r proto list; do
      [[ -z "${proto:-}" ]] && continue
      i=$((i+1))
      printf "  %-4s %-10s %-6s %s\n" "$i" "$name" "$proto" "${list//:/-}"
    done <"$f"
  done
  [[ $i == 0 ]] && echo -e "  ${D}هیچ پورتی فوروارد نشده.${N}"
  return 0
}

pf_nth() {           # خط شماره n را به صورت "name<TAB>proto list" برمی‌گرداند
  local want="$1" f name proto list i=0
  for f in "$EXITS"/*.ports; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f" .ports)"
    while read -r proto list; do
      [[ -z "${proto:-}" ]] && continue
      i=$((i+1))
      [[ "$i" == "$want" ]] && { printf '%s\t%s %s\n' "$name" "$proto" "$list"; return 0; }
    done <"$f"
  done
  return 1
}

pf_add() {
  clear; banner; echo; hr; echo -e "  ${W}${BLD}افزودن پورت فوروارد${N}"; hr; echo
  local names n; names="$(for f in "$EXITS"/*.conf; do [[ -f "$f" ]] && basename "$f" .conf; done | tr '\n' ' ')"
  [[ -n "${names// /}" ]] || { err "اول یک تونل بساز."; pause; return; }
  echo -e "  ${D}خروجی‌های موجود: ${W}$names${N}"; echo
  n="$(ask "پورت‌ها به کدام خروجی برن؟")"
  [[ -f "$EXITS/$n.conf" ]] || { err "خروجی «$n» پیدا نشد."; pause; return; }

  echo
  echo -e "  ${D}چند پورت را با کاما جدا کن، بازه را با خط‌تیره:${N}"
  echo -e "  ${D}مثال: ${W}50820,51820,2097,2096,443,80${N}   ${D}یا${N}  ${W}27015,7777-7784${N}"
  echo
  local raw list; raw="$(ask "پورت‌ها")"
  list="$(pf_norm "$raw")" || { err "لیست نامعتبره. فقط عدد ۱ تا ۶۵۵۳۵، کاما و خط‌تیره."; pause; return; }

  local conf; conf="$(pf_conflicts "$list")"
  if [[ -n "${conf// /}" ]]; then
    echo
    warn "این پورت‌ها روی خود این سرور استفاده می‌شن: ${W}${conf}${N}"
    echo -e "  ${D}فورواردشون یعنی SSH یا وایرگارد یا خود تونل از دسترس خارج می‌شه.${N}"
    echo -e "  ${D}اگه از راه دور وصلی، ممکنه همین‌جا ارتباطت قطع بشه.${N}"; echo
    askyn "با این حال ادامه بدم؟" n || { msg "لغو شد."; pause; return; }
  fi

  echo
  echo -e "   ${G}1${N}) هر دو (TCP + UDP)   ${G}2${N}) فقط TCP   ${G}3${N}) فقط UDP"; echo
  local proto
  case "$(ask "پروتکل" "1")" in 2) proto=tcp ;; 3) proto=udp ;; *) proto=both ;; esac

  echo "$proto $list" >>"$EXITS/$n.ports"
  local applied; applied="$(pf_apply_all)"
  logit "port-forward add $n [$proto] $list"
  echo
  ok "$(pf_count "$list") پورت به «$n» فوروارد شد ($proto)."
  echo -e "  ${D}در $applied رول multiport خلاصه شد، نه یک رول به‌ازای هر پورت.${N}"
  pause
}

pf_del() {
  clear; banner; echo; hr; echo -e "  ${W}${BLD}حذف پورت فوروارد${N}"; hr; echo
  pf_table; echo; hr
  local sel row name rest
  sel="$(ask "شماره‌ی خطی که حذف بشه (خالی = انصراف)")"
  [[ -n "$sel" ]] || return
  row="$(pf_nth "$sel")" || { err "شماره نامعتبره."; pause; return; }
  name="${row%%$'\t'*}"; rest="${row#*$'\t'}"
  grep -vxF "$rest" "$EXITS/$name.ports" >"$EXITS/$name.ports.tmp" 2>/dev/null
  mv -f "$EXITS/$name.ports.tmp" "$EXITS/$name.ports"
  [[ -s "$EXITS/$name.ports" ]] || rm -f "$EXITS/$name.ports"
  pf_apply_all >/dev/null
  logit "port-forward del $name [$rest]"
  ok "حذف شد."; pause
}

port_menu() {
  while :; do
    clear; banner; echo; hr
    echo -e "  ${W}${BLD}فوروارد پورت${N}   ${D}پورت‌های عمومی این سرور → سرور خارج${N}"
    hr; echo
    pf_table
    echo; hr
    echo -e "   ${G}1${N}) افزودن پورت      ${G}2${N}) حذف یک ردیف"
    echo -e "   ${G}3${N}) پاک کردن همه‌ی پورت‌های یک خروجی"
    echo -e "   ${G}4${N}) اعمال دوباره‌ی رول‌ها"
    echo -e "   ${G}5${N}) نمایش رول‌های iptables"
    echo -e "   ${G}0${N}) بازگشت"; echo
    case "$(ask "انتخاب")" in
      1) pf_add ;;
      2) pf_del ;;
      3) local n; n="$(ask "نام خروجی")"
         if [[ -f "$EXITS/$n.ports" ]]; then rm -f "$EXITS/$n.ports"; pf_apply_all >/dev/null
           logit "port-forward clear $n"; ok "همه‌ی پورت‌های «$n» پاک شد."
         else err "برای «$n» چیزی ثبت نشده."; fi; pause ;;
      4) local r; r="$(pf_apply_all)"; ok "$r رول اعمال شد."; pause ;;
      5) clear; echo -e "${W}nat / HYDRA_PRE${N}"; hr
         iptables -t nat -S HYDRA_PRE 2>/dev/null | sed 's/^/  /' || echo -e "  ${D}خالی${N}"
         echo; echo -e "${W}filter / HYDRA_FWD${N}"; hr
         iptables -S HYDRA_FWD 2>/dev/null | sed 's/^/  /' || echo -e "  ${D}خالی${N}"
         pause ;;
      0|"") return ;;
    esac
  done
}

logs_menu() {
  clear; echo -e "${W}۵۰ خط آخر رویدادها${N}"; hr
  tail -n 50 "$LOG" 2>/dev/null || echo -e "${D}چیزی ثبت نشده.${N}"
  hr; echo -e "${D}برای لاگ زنده‌ی یک سرویس: journalctl -u hydra-raw@NAME -f${N}"
  pause
}

uninstall_all() {
  clear; banner; echo; hr
  warn "این کار همه‌ی تونل‌ها، کاربران و کانفیگ‌ها رو پاک می‌کنه."
  askyn "مطمئنی؟" n || return
  local f
  for f in "$EXITS"/*.conf; do [[ -f "$f" ]] && systemctl disable --now "hydra-link@$(basename "$f" .conf)" >/dev/null 2>&1; done
  for f in "$LINKS"/*.conf; do [[ -f "$f" ]] && systemctl disable --now "hydra-exit-link@$(basename "$f" .conf)" >/dev/null 2>&1; done
  systemctl disable --now hydra-watch hydra-rule hydra-ports wg-quick@wg0 >/dev/null 2>&1
  iptables -t nat -D PREROUTING  -j HYDRA_PRE  2>/dev/null
  iptables -t nat -D POSTROUTING -j HYDRA_POST 2>/dev/null
  iptables        -D FORWARD     -j HYDRA_FWD  2>/dev/null
  iptables -t nat -F HYDRA_PRE 2>/dev/null; iptables -t nat -X HYDRA_PRE 2>/dev/null
  iptables -t nat -F HYDRA_POST 2>/dev/null; iptables -t nat -X HYDRA_POST 2>/dev/null
  iptables -F HYDRA_FWD 2>/dev/null; iptables -X HYDRA_FWD 2>/dev/null
  rm -f /etc/systemd/system/hydra-*.service
  rm -f /etc/wireguard/wg-*.conf /etc/wireguard/wg0.conf
  rm -f /etc/sysctl.d/99-hydra.conf /etc/modules-load.d/hydra-bbr.conf
  rm -rf "$DIR" "$STATE"
  systemctl daemon-reload; sysctl --system >/dev/null 2>&1
  ok "حذف شد. باینری‌های udp2raw و speederv2 دست‌نخورده موندن."
  exit 0
}

# ================================================================== منوها ===
menu_hub() {
  while :; do
    clear; banner; echo
    echo -e "  ${D}نقش این سرور:${N} ${W}سرور ایران (هاب)${N}   ${D}$(pub_ip)${N}"
    hr; show_status_hub; hr; echo
    echo -e "   ${G}1${N}) ${W}ساخت تونل جدید${N}       ${D}اضافه کردن یک سرور خارج${N}"
    echo -e "   ${G}2${N}) مدیریت تونل‌ها        ${D}حذف، پین، ری‌استارت، توکن${N}"
    echo -e "   ${G}3${N}) مدیریت کاربران        ${D}ساخت کانفیگ وایرگارد + QR${N}"
    echo -e "   ${G}4${N}) تنظیم FEC             ${D}فعلی: $FEC${N}"
    echo -e "   ${G}5${N}) فوروارد پورت           ${D}چند پورت هم‌زمان، با کاما${N}"
    echo -e "   ${G}6${N}) اعمال دوباره‌ی BBR و تیونینگ"
    echo -e "   ${G}7${N}) رویدادها و لاگ"
    echo -e "   ${G}8${N}) ${R}حذف کامل${N}"
    echo -e "   ${G}0${N}) خروج"; echo
    case "$(ask "انتخاب")" in
      1) create_tunnel ;; 2) tunnel_menu ;; 3) client_menu ;; 4) fec_menu ;;
      5) port_menu ;; 6) apply_tune; pause ;; 7) logs_menu ;; 8) uninstall_all ;;
      0|q|"") clear; exit 0 ;;
    esac
  done
}

menu_exit() {
  while :; do
    clear; banner; echo
    echo -e "  ${D}نقش این سرور:${N} ${W}سرور خارج (خروجی)${N}   ${D}$(pub_ip)${N}"
    hr; show_status_exit; hr; echo
    echo -e "   ${G}1${N}) ${W}اتصال به سرور ایران${N}   ${D}پیست کردن توکن${N}"
    echo -e "   ${G}2${N}) حذف یک لینک"
    echo -e "   ${G}3${N}) ری‌استارت همه‌ی لینک‌ها"
    echo -e "   ${G}4${N}) تنظیم FEC             ${D}فعلی: $FEC${N}"
    echo -e "   ${G}5${N}) اعمال دوباره‌ی BBR و تیونینگ"
    echo -e "   ${G}6${N}) رویدادها و لاگ"
    echo -e "   ${G}7${N}) ${R}حذف کامل${N}"
    echo -e "   ${G}0${N}) خروج"; echo
    case "$(ask "انتخاب")" in
      1) connect_hub ;;
      2) local n; n="$(ask "نام لینک")"
         if [[ -f "$LINKS/$n.conf" ]]; then
           systemctl disable --now "hydra-exit-link@$n" >/dev/null 2>&1
           rm -f "$LINKS/$n.conf" "/etc/wireguard/wg-$n.conf"; ok "حذف شد."
         else err "پیدا نشد."; fi; pause ;;
      3) local f; for f in "$LINKS"/*.conf; do [[ -f "$f" ]] && systemctl restart "hydra-exit-link@$(basename "$f" .conf)"; done
         ok "ری‌استارت شد."; pause ;;
      4) fec_menu ;; 5) apply_tune; pause ;; 6) logs_menu ;; 7) uninstall_all ;;
      0|q|"") clear; exit 0 ;;
    esac
  done
}

menu_setup() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}این سرور چیه؟${N}"; hr; echo
  echo -e "   ${G}1${N}) ${W}سرور ایران${N}  ${D}— هاب. کاربرها بهش وصل می‌شن، به چند سرور خارج تونل می‌زنه.${N}"
  echo -e "   ${G}2${N}) ${W}سرور خارج${N}   ${D}— خروجی. با توکنی که هاب می‌ده به هاب وصل می‌شه.${N}"
  echo -e "   ${G}0${N}) خروج"; echo
  case "$(ask "انتخاب")" in
    1) setup_hub; menu_hub ;;
    2) setup_exit; menu_exit ;;
    *) clear; exit 0 ;;
  esac
}

[[ -f /etc/hydra/install-url ]] && . /etc/hydra/install-url 2>/dev/null
INSTALL_URL="${HYDRA_INSTALL_URL:-https://raw.githubusercontent.com/YOUR_USER/hydra/main/install.sh}"

# =================================================================== ورودی ==
case "${1:-}" in
  _link-up)    _link_up "$2" ;;
  _link-down)  _link_down "$2" ;;
  _elink-up)   _elink_up "$2" ;;
  _elink-down) _elink_down "$2" ;;
  _watch)      _watch ;;
  _ports-apply) pf_apply_all >/dev/null; exit 0 ;;
  apply)       shift; apply_token "$1"; exit $? ;;
  status)      [[ "$(role)" == hub ]] && show_status_hub || show_status_exit; exit 0 ;;
  "")
    case "$(role)" in
      hub)  menu_hub ;;
      exit) menu_exit ;;
      *)    menu_setup ;;
    esac ;;
  *) echo "hydra v$VERSION — بدون آرگومان اجرا کن تا منو باز بشه."; exit 1 ;;
esac
