#!/usr/bin/env bash
# ============================================================================
#  hydra installer
#
#  نصب و باز کردن منو:
#     bash <(curl -fsSL https://raw.githubusercontent.com/devprogrmer/hydra/main/install.sh)
#
#  نصب مستقیم روی سرور خارج با توکن:
#     bash <(curl -fsSL .../install.sh) apply <TOKEN>
# ============================================================================
set -euo pipefail

# ── این یک خط رو با یوزرنیم گیت‌هاب خودت عوض کن ─────────────────────────────
REPO="${HYDRA_REPO:-devprogrmer/hydra}"
BRANCH="${HYDRA_BRANCH:-main}"
# ───────────────────────────────────────────────────────────────────────────

BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"
G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; W=$'\e[97m'; D=$'\e[90m'; N=$'\e[0m'

[[ $EUID -eq 0 ]] || { echo -e "${R}✘${N} با root اجرا کن:  sudo bash <(curl -fsSL $BASE/install.sh)"; exit 1; }

echo -e "${W}نصب hydra…${N}"

command -v curl >/dev/null || {
  if   command -v apt-get >/dev/null; then apt-get update -qq && apt-get install -y -qq curl
  elif command -v dnf     >/dev/null; then dnf install -y -q curl
  else echo -e "${R}✘${N} curl نصب نیست."; exit 1; fi
}

tmp="$(mktemp)"
if ! curl -fsSL "$BASE/hydra.sh" -o "$tmp"; then
  echo -e "${R}✘${N} دانلود از $BASE/hydra.sh ناموفق بود."
  echo -e "${D}اگه ریپو private ـه یا آدرس اشتباهه، متغیر HYDRA_REPO رو ست کن:${N}"
  echo -e "${D}  HYDRA_REPO=user/repo bash <(curl -fsSL .../install.sh)${N}"
  exit 1
fi

head -1 "$tmp" | grep -q '^#!' || { echo -e "${R}✘${N} فایل دانلودشده معتبر نیست."; exit 1; }

install -m755 "$tmp" /usr/local/bin/hydra
rm -f "$tmp"

# آدرس نصب رو داخل اسکریپت ثبت کن تا توکن‌هایی که تولید می‌کنه هم درست باشن
mkdir -p /etc/hydra
echo "HYDRA_INSTALL_URL=$BASE/install.sh" >/etc/hydra/install-url
cat >/etc/profile.d/hydra.sh <<EOF
export HYDRA_INSTALL_URL="$BASE/install.sh"
EOF

echo -e "${G}✔${N} نصب شد. دستور: ${W}hydra${N}"
echo

export HYDRA_INSTALL_URL="$BASE/install.sh"

if [[ "${1:-}" == "apply" && -n "${2:-}" ]]; then
  exec /usr/local/bin/hydra apply "$2"
else
  exec /usr/local/bin/hydra
fi
