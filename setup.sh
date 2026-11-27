#!/bin/bash
# setup.sh - full install of sub2api on Ubuntu, with optional CDN origin lock and optional VPN kill switch.
#
# Run as root from this folder (vpnctl.sh must sit next to this file):
#   bash setup.sh
#
# Every question can be answered ahead of time with an environment variable, for a
# run with no prompts (all are optional; unset ones are asked):
#   DOMAINS="ai.example.com ai-ir.example.com"   nginx server_name list ("_" = any)
#   ADMIN_EMAIL=... ADMIN_PASSWORD=...           empty = sub2api generates them
#   ORIGIN_LOCK=yes|no                           allow port 80/443 only from Arvan CDN + ORIGIN_ALLOW
#   ORIGIN_ALLOW="203.0.113.10"                 extra IPs/CIDRs allowed to reach the origin
#   VPN=yes|no                                   route all outbound traffic through Xray with a kill switch
#   VPN_SOURCE="https://.../sub/xxx"             subscription URL, or one vless:// vmess:// trojan:// link
#   ASSUME_YES=1                                 accept defaults for anything not set
#
# Safe to run again: it upgrades packages and images and keeps existing secrets and data.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_DIR=/opt/sub2api-deploy
SETUP_CONF=/etc/sub2api-setup.conf
APP_PORT=8080
ARVAN_IPS_URL="https://www.arvancloud.ir/en/ips.txt"

c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_b=$'\e[1m'; c_0=$'\e[0m'
step() { echo; echo "${c_b}==> $*${c_0}"; }
ok()   { echo "${c_ok}  ok${c_0} $*"; }
warn() { echo "${c_warn}  !${c_0} $*"; }
die()  { echo "${c_err}ERROR:${c_0} $*" >&2; exit 1; }

# ask VAR "question" "default"  (skips when VAR is already set)
ask() {
    local var=$1 q=$2 def=${3:-} ans
    if [ -n "${!var+x}" ]; then return; fi
    if [ -n "${ASSUME_YES:-}" ] || [ ! -t 0 ]; then printf -v "$var" '%s' "$def"; return; fi
    read -r -p "$q${def:+ [$def]}: " ans
    printf -v "$var" '%s' "${ans:-$def}"
}
ask_secret() {
    local var=$1 q=$2 ans
    if [ -n "${!var+x}" ]; then return; fi
    if [ -n "${ASSUME_YES:-}" ] || [ ! -t 0 ]; then printf -v "$var" '%s' ""; return; fi
    read -r -s -p "$q: " ans; echo
    printf -v "$var" '%s' "$ans"
}
yes_no() { case "${1,,}" in y|yes|1|true) return 0 ;; *) return 1 ;; esac; }

# ---------------------------------------------------------------- checks
step "Checking system"
[ "$(id -u)" = 0 ] || die "run as root"
. /etc/os-release
[ "${ID:-}" = ubuntu ] || die "Ubuntu required (found ${ID:-unknown})"
case "$VERSION_ID" in 22.04|24.04|24.10|25.04|25.10|26.04) ok "Ubuntu $VERSION_ID" ;;
    *) warn "Ubuntu $VERSION_ID is not tested; continuing" ;; esac
[ -f "$HERE/vpnctl.sh" ] || die "vpnctl.sh not found next to setup.sh"
mem=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
disk=$(df -Pm / | awk 'NR==2 {print $4}')
[ "$mem" -ge 1000 ] || warn "RAM ${mem}MB; 2GB or more is recommended"
[ "$disk" -ge 5000 ] || die "only ${disk}MB free on /; need 5GB"
ok "RAM ${mem}MB, free disk ${disk}MB"
curl -fsS -m 20 -o /dev/null https://github.com 2>/dev/null || curl -fsS -m 20 -o /dev/null https://download.docker.com \
    || die "no internet access to github.com / download.docker.com"
ok "internet access"

# Load answers from a previous run as defaults.
if [ -f "$SETUP_CONF" ]; then
    # shellcheck disable=SC1090
    . "$SETUP_CONF"
    ok "loaded previous answers from $SETUP_CONF"
fi

# ---------------------------------------------------------------- questions
step "Settings"
ask DOMAINS      "Domains for the panel/API, space separated (_ = any)" "${P_DOMAINS:-_}"
ask ADMIN_EMAIL  "Admin email (empty = auto-generated)" ""
if [ -n "$ADMIN_EMAIL" ]; then ask_secret ADMIN_PASSWORD "Admin password (empty = auto-generated)"; else ADMIN_PASSWORD=${ADMIN_PASSWORD:-}; fi
ask ORIGIN_LOCK  "Allow web ports only from Arvan CDN? (yes/no)" "${P_ORIGIN_LOCK:-yes}"
if yes_no "$ORIGIN_LOCK"; then
    ask ORIGIN_ALLOW "Extra IPs allowed to reach the origin, e.g. an Iran relay (space separated)" "${P_ORIGIN_ALLOW:-}"
else ORIGIN_ALLOW=${ORIGIN_ALLOW:-}; fi
ask VPN          "Send all outbound traffic through a VPN with kill switch? (yes/no)" "${P_VPN:-no}"
if yes_no "$VPN"; then
    ask VPN_SOURCE "Subscription URL or a single vless/vmess/trojan link" "${P_VPN_SOURCE:-}"
    [ -n "$VPN_SOURCE" ] || die "VPN enabled but no subscription or link given"
    case "$VPN_SOURCE" in
        http://*|https://*) ok "VPN source: subscription" ;;
        vless://*|vmess://*|trojan://*) ok "VPN source: single link" ;;
        *) die "VPN source must start with https://, vless://, vmess:// or trojan://" ;;
    esac
else VPN_SOURCE=${VPN_SOURCE:-}; fi

umask 077
printf 'P_DOMAINS=%q\nP_ORIGIN_LOCK=%q\nP_ORIGIN_ALLOW=%q\nP_VPN=%q\nP_VPN_SOURCE=%q\n' \
    "$DOMAINS" "$ORIGIN_LOCK" "$ORIGIN_ALLOW" "$VPN" "$VPN_SOURCE" > "$SETUP_CONF"
umask 022

# ---------------------------------------------------------------- packages
step "Installing / upgrading packages"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
apt-get update -qq
PKGS="ca-certificates curl gnupg openssl nginx nftables python3 dnsutils unzip conntrack"
# shellcheck disable=SC2086
apt-get install -y -qq $PKGS >/dev/null
# shellcheck disable=SC2086
apt-get install -y -qq --only-upgrade $PKGS >/dev/null
ok "base packages"

if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh >/dev/null
    ok "Docker installed"
else
    apt-get install -y -qq --only-upgrade docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin >/dev/null 2>&1 || true
    ok "Docker upgraded/checked"
fi
systemctl enable -q --now docker
ok "$(docker --version), compose $(docker compose version --short)"

# ---------------------------------------------------------------- sub2api
step "Installing sub2api"
mkdir -p "$DEPLOY_DIR"; cd "$DEPLOY_DIR"
if [ ! -f .env ]; then
    curl -fsSL https://raw.githubusercontent.com/Wei-Shaw/sub2api/main/deploy/docker-deploy.sh | bash >/dev/null
    ok "deploy files and secrets created"
else
    cp .env ".env.bak-$(date +%F-%H%M%S)"
    ok "existing .env kept (backup made)"
fi
setenv() { # setenv KEY VALUE  -> set or add KEY=VALUE in .env
    if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >> .env; fi
}
setenv BIND_HOST 127.0.0.1           # nginx is the only public entry
setenv SERVER_PORT "$APP_PORT"
[ -n "$ADMIN_EMAIL" ]    && setenv ADMIN_EMAIL "$ADMIN_EMAIL"
[ -n "$ADMIN_PASSWORD" ] && setenv ADMIN_PASSWORD "$ADMIN_PASSWORD"
chmod 600 .env
docker compose pull -q
docker compose up -d --remove-orphans >/dev/null 2>&1
for i in $(seq 60); do
    curl -fsS -m 3 -o /dev/null "http://127.0.0.1:$APP_PORT/" && break; sleep 2
done
curl -fsS -m 3 -o /dev/null "http://127.0.0.1:$APP_PORT/" || die "sub2api did not start; see: docker compose -f $DEPLOY_DIR/docker-compose.yml logs sub2api"
ok "sub2api running on 127.0.0.1:$APP_PORT"

# ---------------------------------------------------------------- nginx
step "Configuring nginx origin"
rm -f /etc/nginx/sites-enabled/default
cat > /etc/nginx/sites-available/sub2api.conf <<EOF
# sub2api origin (written by setup.sh). Plain HTTP on 80; TLS ends at the CDN.
server {
    listen 80 default_server;
    server_name $DOMAINS;
    client_max_body_size 100m;

    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$http_x_real_ip;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$http_connection;
        # Streaming (SSE) API responses must not be buffered.
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        proxy_read_timeout 900s;
        proxy_send_timeout 900s;
    }
}
EOF
ln -sf /etc/nginx/sites-available/sub2api.conf /etc/nginx/sites-enabled/sub2api.conf
nginx -t -q || die "nginx config test failed"
systemctl enable -q nginx; systemctl reload nginx 2>/dev/null || systemctl restart nginx
ok "nginx :80 -> 127.0.0.1:$APP_PORT for: $DOMAINS"

# ---------------------------------------------------------------- origin lock
step "Origin lock"
cat > /usr/local/sbin/originlock.sh <<'LOCK'
#!/bin/bash
# originlock.sh - allow web ports only from Arvan CDN ranges and ORIGIN_ALLOW (written by setup.sh).
# Usage: originlock.sh apply | refresh | off
set -u
. /etc/sub2api-setup.conf
STATE=/var/lib/originlock; mkdir -p "$STATE"
URL="__ARVAN_IPS_URL__"
refresh() {
    local t; t=$(mktemp)
    for i in 1 2 3 4 5; do curl -fsS -m 20 "$URL" -o "$t" 2>/dev/null && break; sleep 3; done
    if [ "$(grep -cE '^[0-9.]+/[0-9]+$' "$t")" -ge 5 ]; then
        grep -E '^[0-9.]+/[0-9]+$' "$t" | sort -u > "$STATE/arvan_ips"
    else
        logger -t originlock "Arvan IP list fetch failed; keeping the old list"
    fi
    rm -f "$t"
}
apply() {
    # No list yet = no lock, so a failed first fetch does not take the site down.
    [ -s "$STATE/arvan_ips" ] || { logger -t originlock "no Arvan list yet; lock not applied"; return 1; }
    local allow; allow=$( (cat "$STATE/arvan_ips"; printf '%s\n' $P_ORIGIN_ALLOW) | grep -E '^[0-9./]+$' | sort -u | tr '\n' ',' | sed 's/,$//')
    nft -f - <<EOF
table inet originlock
delete table inet originlock
table inet originlock {
    set allow { type ipv4_addr; flags interval; auto-merge; elements = { $allow } }
    chain input {
        type filter hook input priority filter; policy accept;
        iif lo accept
        tcp dport { 80, 443 } ip saddr != @allow counter drop
        tcp dport { 80, 443 } meta nfproto ipv6 counter drop
    }
}
EOF
}
case "${1:-}" in
    apply)   apply ;;
    refresh) refresh; apply ;;
    off)     nft delete table inet originlock 2>/dev/null; true ;;
    *) echo "usage: $0 apply|refresh|off"; exit 1 ;;
esac
LOCK
sed -i "s|__ARVAN_IPS_URL__|$ARVAN_IPS_URL|" /usr/local/sbin/originlock.sh
chmod 700 /usr/local/sbin/originlock.sh
cat > /etc/systemd/system/originlock.service <<EOF
[Unit]
Description=Allow web ports only from CDN (originlock)
After=nftables.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/originlock.sh apply
ExecStop=/usr/local/sbin/originlock.sh off
[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/originlock-refresh.service <<EOF
[Unit]
Description=Refresh Arvan CDN IP list (originlock)
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/originlock.sh refresh
EOF
cat > /etc/systemd/system/originlock-refresh.timer <<EOF
[Unit]
Description=Refresh Arvan CDN IP list daily
[Timer]
OnBootSec=3min
OnUnitActiveSec=1d
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
# The older vpnctl kept its own origin lock; the new one does not, so nothing overlaps.
if yes_no "$ORIGIN_LOCK"; then
    /usr/local/sbin/originlock.sh refresh || die "could not fetch the Arvan IP list; run again or set ORIGIN_LOCK=no"
    systemctl enable -q --now originlock.service originlock-refresh.timer
    ok "ports 80/443 open only to Arvan CDN${ORIGIN_ALLOW:+ and $ORIGIN_ALLOW}"
else
    systemctl disable -q --now originlock.service originlock-refresh.timer 2>/dev/null || true
    /usr/local/sbin/originlock.sh off
    warn "origin lock off: port 80 is open to everyone"
fi

# ---------------------------------------------------------------- VPN
step "VPN"
if yes_no "$VPN"; then
    mkdir -p /etc/vpnctl
    {
        echo "# written by setup.sh"
        case "$VPN_SOURCE" in
            http*) printf 'SUB_URL=%q\nVPN_LINK=""\n' "$VPN_SOURCE" ;;
            *)     printf 'SUB_URL=""\nVPN_LINK=%q\n' "$VPN_SOURCE" ;;
        esac
    } > /etc/vpnctl/vpnctl.conf
    chmod 600 /etc/vpnctl/vpnctl.conf
    install -m 700 "$HERE/vpnctl.sh" /usr/local/sbin/vpnctl.sh
    # If something locks SSH out, this timer opens the firewall again after 10 minutes.
    systemctl stop vpnctl-safety.timer 2>/dev/null || true
    systemctl reset-failed vpnctl-safety.service vpnctl-safety.timer 2>/dev/null || true
    systemd-run -q --unit=vpnctl-safety --on-active=600 /usr/local/sbin/vpnctl.sh rollback
    /usr/local/sbin/vpnctl.sh install
    systemctl is-active -q vpnctl-xray || die "VPN did not start (kill switch is on, internet is blocked). Check: journalctl -t vpnctl; to undo: vpnctl.sh rollback"
    exit_ip=$(curl -fsS -m 15 https://api.ipify.org || echo "?")
    systemctl stop vpnctl-safety.timer 2>/dev/null || true
    ok "VPN up, exit IP $exit_ip; kill switch on"
else
    if [ -x /usr/local/sbin/vpnctl.sh ]; then
        /usr/local/sbin/vpnctl.sh uninstall >/dev/null 2>&1 || true
        warn "VPN removed (it was installed before)"
    else
        ok "VPN not used"
    fi
fi

# ---------------------------------------------------------------- summary
step "Done"
cd "$DEPLOY_DIR"
logs=$(docker compose logs sub2api 2>/dev/null || true)
a_email=${ADMIN_EMAIL:-$( (grep -oE 'Admin user created: [^ ]+' <<< "$logs" || true) | tail -1 | awk '{print $4}')}
a_pass=${ADMIN_PASSWORD:-$( (grep -oE 'Generated admin password \(one-time\): [^ ]+' <<< "$logs" || true) | tail -1 | awk '{print $NF}')}
# Keep first-start credentials, since the log line is gone once the container is recreated.
if [ -n "$a_pass" ]; then umask 077; printf 'ADMIN_EMAIL=%s\nADMIN_PASSWORD=%s\n' "$a_email" "$a_pass" > /root/sub2api-admin.txt; umask 022
elif [ -f /root/sub2api-admin.txt ]; then . /root/sub2api-admin.txt; a_email=${a_email:-$ADMIN_EMAIL}; a_pass=$ADMIN_PASSWORD; fi
echo "  Panel:         http://<domain>/  (domains: $DOMAINS)"
echo "  Admin email:   ${a_email:-unknown (admin existed before this run)}"
echo "  Admin password: ${a_pass:-unknown (only shown on first start)}"
echo "  Files:         $DEPLOY_DIR  (.env holds the secrets)"
echo "  Answers:       $SETUP_CONF  (used as defaults next run)"
yes_no "$VPN" && echo "  VPN:           vpnctl.sh status | update | rollback"
echo "  Point each domain (CDN on, origin HTTP port 80) to this server's IP or to your relay."
