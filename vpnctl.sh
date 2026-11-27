#!/bin/bash
# vpnctl.sh - Xray VPN client with kill switch and subscription auto-update.
#
# Everything this server sends to the internet goes through the Xray tunnel (xtun).
# If the tunnel goes down or leaks, the nftables kill switch blocks all new outbound
# traffic from the host and from Docker containers.
# These still work while the tunnel is down:
#   - inbound connections and their replies (SSH, the web panel), via the WAN interface
#   - Xray itself, only to the VPN server IPs
#   - the subscription updater (user vpnsub), only TCP 443/2096 and DNS
#
# Usage:
#   vpnctl.sh install      install Xray, users, systemd units, firewall, then update
#   vpnctl.sh update       fetch subscription, pick a working server, apply it
#   vpnctl.sh check        health check (run by timer); restart or re-fetch on failure
#   vpnctl.sh firewall     (re)apply kill switch rules and policy routing
#   vpnctl.sh status       show state
#   vpnctl.sh rollback     remove kill switch and routing (open internet, no VPN)
#   vpnctl.sh uninstall    rollback, then remove units and files

set -u

# ---------------- settings ----------------
# Defaults. /etc/vpnctl/vpnctl.conf (written by setup.sh) overrides them.
# Set SUB_URL (subscription link, refreshed on a timer) or VPN_LINK (one vless/vmess/trojan link).
SUB_URL=""
VPN_LINK=""
XRAY_VERSION="latest"          # or a tag like v26.11.9
WAN_IF=""                      # empty = interface of the default route
TUN_IF="xtun"
TUN_ADDR="10.255.0.1/30"
TUN_MTU=1500
DNS_SERVERS="1.1.1.1 8.8.8.8"
UPDATE_EVERY="30min"          # subscription refresh interval
CHECK_EVERY="1min"            # health check interval
HEALTH_URL="https://www.gstatic.com/generate_204"
# -----------------------------------------
[ -f /etc/vpnctl/vpnctl.conf ] && . /etc/vpnctl/vpnctl.conf
[ -n "$WAN_IF" ] || WAN_IF=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
[ -n "$WAN_IF" ] || WAN_IF=$(cat /var/lib/vpnctl/wan_if 2>/dev/null)

BASE=/etc/vpnctl
STATE=/var/lib/vpnctl
XRAY_BIN=/usr/local/bin/xray
SELF=/usr/local/sbin/vpnctl.sh
RT_TABLE=100
MARK=0xff                      # traffic that must use eth0 (Xray, updater, inbound replies)
SOCKS_PORT=10808

log() { echo "[vpnctl $(date '+%F %T')] $*"; logger -t vpnctl -- "$*" 2>/dev/null || true; }
die() { log "ERROR: $*"; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"

# ---------- firewall + routing ----------
apply_firewall() {
    [ -n "$WAN_IF" ] || die "cannot find the WAN interface; set WAN_IF in /etc/vpnctl/vpnctl.conf"
    mkdir -p "$STATE"; echo "$WAN_IF" > "$STATE/wan_if"
    local vpn_ips sub_ips
    vpn_ips=$(cat "$STATE/vpn_ips" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    local elems=""; [ -n "$vpn_ips" ] && elems="elements = { $vpn_ips }"
    nft -f - <<EOF
table inet vpnks
delete table inet vpnks
table inet vpnks {
    set vpn_servers { type ipv4_addr; flags interval; $elems }

    # Mark new inbound connections from the internet so their replies leave via eth0.
    chain ks_pre {
        type filter hook prerouting priority mangle; policy accept;
        iifname "$WAN_IF" ct state new ct mark set $MARK
        ct mark $MARK meta mark set $MARK
    }

    # Route Xray and the updater via eth0; restore mark for inbound replies.
    chain ks_route {
        type route hook output priority mangle; policy accept;
        meta skuid "xray" meta mark set $MARK
        meta skuid "vpnsub" meta mark set $MARK
        ct mark $MARK meta mark set $MARK
    }

    # Kill switch for traffic created on this host.
    chain ks_out {
        type filter hook output priority filter; policy drop;
        oif lo accept
        ct state established,related accept
        oifname "$TUN_IF" accept
        oifname "docker0" accept
        oifname "br-*" accept
        oifname "$WAN_IF" meta skuid "xray" ip daddr @vpn_servers accept
        oifname "$WAN_IF" meta skuid "vpnsub" tcp dport { 53, 443, 2096 } accept
        oifname "$WAN_IF" meta skuid "vpnsub" udp dport 53 accept
        oifname "$WAN_IF" icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit } accept
        limit rate 5/minute log prefix "vpnks-drop-out "
        counter drop
    }

    # Kill switch for Docker containers: no new connection may leave via eth0.
    chain ks_fwd {
        type filter hook forward priority filter - 10; policy accept;
        oifname "$WAN_IF" ct state new limit rate 5/minute log prefix "vpnks-drop-fwd "
        oifname "$WAN_IF" ct state new counter drop
        oifname "$WAN_IF" ct direction reply accept
        oifname "$WAN_IF" counter drop
    }
}
EOF
    [ $? -eq 0 ] || die "nft rules failed"

    # Policy routing: everything uses table $RT_TABLE (default via tun) except marked traffic.
    # Routing decides before nft output hooks run, so eth0 traffic is selected here, not by nft marks:
    #   - replies from this host's own sockets carry source = WAN IP (pref 90)
    #   - accepted TCP sockets inherit the SYN mark (tcp_fwmark_accept)
    #   - Xray and the updater are routed by uid (pref 95/96)
    local wan_ip xu su
    wan_ip=$(ip -4 -o addr show "$WAN_IF" | awk '{print $4}' | cut -d/ -f1 | head -1)
    xu=$(id -u xray); su=$(id -u vpnsub)
    sysctl -qw net.ipv4.tcp_fwmark_accept=1
    for p in 90 95 96 100 150 200; do while ip rule del pref $p 2>/dev/null; do :; done; done
    [ -n "$wan_ip" ] && ip rule add pref 90 from "$wan_ip" lookup main
    ip rule add pref 95 uidrange "$xu-$xu" lookup main
    ip rule add pref 96 uidrange "$su-$su" lookup main
    ip rule add pref 100 fwmark $MARK lookup main
    ip rule add pref 150 lookup main suppress_prefixlength 0
    ip rule add pref 200 lookup $RT_TABLE
    # If xtun is gone, the blackhole route stops fallback to eth0 (second line of defence).
    ip route replace blackhole default metric 4000 table $RT_TABLE
    ip link show "$TUN_IF" >/dev/null 2>&1 && setup_tun_routes

    # No IPv6 out to the internet (common leak path). Inbound IPv6 is left alone.
    # src_valid_mark: reverse-path check must see the inbound mark, or DNAT traffic to Docker fails while the tunnel is down.
    sysctl -qw net.ipv4.conf.all.rp_filter=2 net.ipv4.conf.default.rp_filter=2 net.ipv4.conf.all.src_valid_mark=1
}

setup_tun_routes() {
    ip addr replace "$TUN_ADDR" dev "$TUN_IF"
    ip link set "$TUN_IF" up mtu "$TUN_MTU"
    ip route replace default dev "$TUN_IF" metric 10 table $RT_TABLE
}

remove_firewall() {
    nft delete table inet vpnks 2>/dev/null
    for p in 90 95 96 100 150 200; do while ip rule del pref $p 2>/dev/null; do :; done; done
    ip route flush table $RT_TABLE 2>/dev/null
}

# ---------- subscription -> xray config ----------
# Reads subscription text from file $1, writes one JSON outbound per line to stdout.
parse_sub() {
    python3 -I - "$@" <<'PY'
import sys, json, base64, urllib.parse as up
raw = open(sys.argv[1]).read().strip()
if "://" not in raw:
    try: raw = base64.b64decode(raw + "=" * (-len(raw) % 4)).decode()
    except Exception: sys.exit("subscription is neither plain links nor base64")
def stream(q, sec_default="none"):
    net = q.get("type", "tcp"); sec = q.get("security", sec_default)
    s = {"network": net, "security": sec}
    if sec == "tls":
        s["tlsSettings"] = {"serverName": q.get("sni", q.get("host", "")), "fingerprint": q.get("fp", "chrome"),
                            **({"alpn": q["alpn"].split(",")} if q.get("alpn") else {})}
    if sec == "reality":
        s["realitySettings"] = {"serverName": q.get("sni", ""), "fingerprint": q.get("fp", "chrome"),
                                "publicKey": q.get("pbk", ""), "shortId": q.get("sid", ""), "spiderX": q.get("spx", "")}
    if net == "ws":
        s["wsSettings"] = {"path": q.get("path", "/"), "host": q.get("host", "")}
    elif net == "grpc":
        s["grpcSettings"] = {"serviceName": q.get("serviceName", "")}
    elif net in ("xhttp", "splithttp"):
        x = {"path": q.get("path", "/"), "host": q.get("host", ""), "mode": q.get("mode", "auto")}
        if q.get("extra"):
            try: x["extra"] = json.loads(q["extra"])
            except Exception: pass
        s["network"] = "xhttp"; s["xhttpSettings"] = x
    elif net == "httpupgrade":
        s["httpupgradeSettings"] = {"path": q.get("path", "/"), "host": q.get("host", "")}
    elif net == "tcp" and q.get("headerType") == "http":
        s["tcpSettings"] = {"header": {"type": "http", "request": {"path": [q.get("path", "/")],
                            "headers": {"Host": [q.get("host", "")]}}}}
    return s
for line in raw.splitlines():
    line = line.strip()
    if not line: continue
    u = up.urlsplit(line); q = {k: v[0] for k, v in up.parse_qs(u.query).items()}
    name = up.unquote(u.fragment)
    if u.scheme == "vless":
        user = {"id": up.unquote(u.username), "encryption": q.get("encryption", "none")}
        if q.get("flow"): user["flow"] = q["flow"]
        ob = {"protocol": "vless", "settings": {"vnext": [{"address": u.hostname, "port": u.port,
              "users": [user]}]}, "streamSettings": stream(q)}
    elif u.scheme == "trojan":
        ob = {"protocol": "trojan", "settings": {"servers": [{"address": u.hostname, "port": u.port,
              "password": up.unquote(u.username)}]}, "streamSettings": stream(q, "tls")}
    elif u.scheme == "vmess":
        b = line[8:]; v = json.loads(base64.b64decode(b + "=" * (-len(b) % 4)))
        q = {"type": v.get("net", "tcp"), "security": v.get("tls") or "none", "sni": v.get("sni", ""),
             "host": v.get("host", ""), "path": v.get("path", "/"), "headerType": v.get("type", "")}
        ob = {"protocol": "vmess", "settings": {"vnext": [{"address": v["add"], "port": int(v["port"]),
              "users": [{"id": v["id"], "security": v.get("scy", "auto")}]}]}, "streamSettings": stream(q)}
        name = v.get("ps", "")
    else:
        continue
    ob["tag"] = "proxy"
    print(json.dumps({"name": name, "outbound": ob}))
PY
}

# Writes full xray config for one outbound JSON ($1) to file $2.
make_config() {
    python3 -I - "$1" "$2" "$TUN_IF" "$TUN_MTU" "$SOCKS_PORT" "$DNS_SERVERS" "${3:-}" <<'PY'
import sys, json
ob, out, tun, mtu, socks, dns, ip = sys.argv[1:8]
ob = json.loads(ob)
# Dial the server by IP: the host DNS goes through the tunnel and is not there before it is up.
if ip:
    s = ob["settings"]; srv = (s.get("vnext") or s.get("servers"))[0]
    host = srv["address"]; srv["address"] = ip
    st = ob.get("streamSettings", {})
    for k in ("tlsSettings", "realitySettings"):
        if k in st and not st[k].get("serverName"): st[k]["serverName"] = host
    for k in ("wsSettings", "xhttpSettings", "httpupgradeSettings"):
        if k in st and not st[k].get("host"): st[k]["host"] = host
cfg = {
  "log": {"loglevel": "warning"},
  "dns": {"servers": dns.split(), "queryStrategy": "UseIPv4"},
  "inbounds": [
    {"tag": "tun", "protocol": "tun", "settings": {"name": tun, "MTU": int(mtu)},
     "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"], "routeOnly": True}},
    {"tag": "socks", "listen": "127.0.0.1", "port": int(socks), "protocol": "socks", "settings": {"udp": True}}
  ],
  "outbounds": [ob, {"tag": "block", "protocol": "blackhole"}],
  "routing": {"domainStrategy": "AsIs", "rules": [
    {"type": "field", "ip": ["10.255.0.0/30"], "outboundTag": "block"},
    {"type": "field", "network": "tcp,udp", "outboundTag": "proxy"}]}
}
json.dump(cfg, open(out, "w"), indent=1)
PY
}

server_host() { python3 -I -c 'import sys,json;o=json.loads(sys.argv[1]);s=o["settings"];print((s.get("vnext") or s.get("servers"))[0]["address"])' "$1"; }

# Resolve as user vpnsub so it is allowed by the kill switch even when the tunnel is down.
resolve_ips() {
    local h=$1
    if [[ $h =~ ^[0-9.]+$ ]]; then echo "$h"; return; fi
    local ns
    for ns in $DNS_SERVERS; do
        runuser -u vpnsub -- dig +short +time=3 +tries=1 A "$h" @"$ns" 2>/dev/null | grep -E '^[0-9.]+$' && return
    done
}

test_config() {   # $1 config file; starts a test xray on a separate socks port and probes it
    local cfg=$1 tcfg=$BASE/test.json port=$((SOCKS_PORT + 1)) pid ok=1
    python3 -I - "$cfg" "$tcfg" "$port" <<'PY'
import sys, json
c = json.load(open(sys.argv[1]))
c["inbounds"] = [{"tag": "socks", "listen": "127.0.0.1", "port": int(sys.argv[3]), "protocol": "socks", "settings": {"udp": True}}]
json.dump(c, open(sys.argv[2], "w"))
PY
    chgrp xray "$tcfg"; chmod 640 "$tcfg"
    runuser -u xray -- "$XRAY_BIN" run -c "$tcfg" >/dev/null 2>&1 &
    pid=$!
    sleep 3
    curl -s -m 15 -o /dev/null -w '%{http_code}' --socks5-hostname 127.0.0.1:$port "$HEALTH_URL" | grep -q '^204$' && ok=0
    kill $pid 2>/dev/null; wait $pid 2>/dev/null
    rm -f "$tcfg"
    return $ok
}

do_update() {
    mkdir -p "$STATE"; chmod 700 "$STATE"
    local sub
    if [ -n "$VPN_LINK" ]; then
        sub="$VPN_LINK"
    else
    [ -n "$SUB_URL" ] || { log "set SUB_URL or VPN_LINK in $BASE/vpnctl.conf"; return 1; }
    # Resolve the subscription host directly, so the fetch works even when the tunnel is down.
    local sh sp sip
    sh=$(python3 -I -c 'import sys,urllib.parse as u;print(u.urlsplit(sys.argv[1]).hostname)' "$SUB_URL")
    sp=$(python3 -I -c 'import sys,urllib.parse as u;p=u.urlsplit(sys.argv[1]);print(p.port or (443 if p.scheme=="https" else 80))' "$SUB_URL")
    sip=$(resolve_ips "$sh" | head -1)
    sub=$(runuser -u vpnsub -- curl -fsS -m 30 ${sip:+--resolve "$sh:$sp:$sip"} "$SUB_URL") || { log "subscription fetch failed; keeping current config"; return 1; }
    fi
    printf '%s' "$sub" > "$STATE/sub.txt"
    local lines; lines=$(parse_sub "$STATE/sub.txt") || { log "subscription parse failed"; return 1; }
    [ -n "$lines" ] || { log "no usable links in subscription"; return 1; }

    # Allow every server IP in the subscription, so tests and failover work.
    : > "$STATE/vpn_ips.new"
    while IFS= read -r l; do
        resolve_ips "$(server_host "$(python3 -I -c 'import sys,json;print(json.dumps(json.loads(sys.argv[1])["outbound"]))' "$l")")" >> "$STATE/vpn_ips.new"
    done <<< "$lines"
    sort -u "$STATE/vpn_ips.new" -o "$STATE/vpn_ips.new"
    cat "$STATE/vpn_ips" "$STATE/vpn_ips.new" 2>/dev/null | sort -u > "$STATE/vpn_ips.all"
    mv "$STATE/vpn_ips.all" "$STATE/vpn_ips"
    apply_firewall

    local newhash; newhash=$(printf '%s' "$lines" | sha256sum | cut -c1-16)
    if [ "${1:-}" != force ] && [ "$newhash" = "$(cat "$STATE/sub.hash" 2>/dev/null)" ] && systemctl is-active -q vpnctl-xray; then
        mv "$STATE/vpn_ips.new" "$STATE/vpn_ips"; apply_firewall
        log "subscription unchanged"; return 0
    fi

    local l ob name cand=$STATE/candidate.json
    while IFS= read -r l; do
        ob=$(python3 -I -c 'import sys,json;print(json.dumps(json.loads(sys.argv[1])["outbound"]))' "$l")
        name=$(python3 -I -c 'import sys,json;print(json.loads(sys.argv[1])["name"])' "$l")
        make_config "$ob" "$cand" "$(resolve_ips "$(server_host "$ob")" | head -1)" || continue
        "$XRAY_BIN" run -test -c "$cand" >/dev/null 2>&1 || { log "invalid config: $name"; continue; }
        if test_config "$cand"; then
            install -m 640 -g xray "$cand" "$BASE/config.json"
            echo "$newhash" > "$STATE/sub.hash"
            echo "$name" > "$STATE/server.name"
            mv "$STATE/vpn_ips.new" "$STATE/vpn_ips"; apply_firewall
            systemctl restart vpnctl-xray
            log "applied server: $name"
            return 0
        fi
        log "server failed test: $name"
    done <<< "$lines"
    rm -f "$STATE/vpn_ips.new"
    log "no working server in subscription; keeping current config (kill switch stays on)"
    return 1
}

do_check() {
    local f=$STATE/fails n
    if ip link show "$TUN_IF" >/dev/null 2>&1 && \
       curl -s -m 10 -o /dev/null -w '%{http_code}' --interface "$TUN_IF" "$HEALTH_URL" | grep -q '^204$'; then
        echo 0 > "$f"; return 0
    fi
    n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 )); echo $n > "$f"
    log "health check failed ($n)"
    if [ $n -eq 2 ]; then systemctl restart vpnctl-xray
    elif [ $n -ge 4 ]; then do_update force; echo 0 > "$f"
    fi
}

do_install() {
    command -v dig >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dnsutils unzip python3 curl nftables >/dev/null
    command -v unzip >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unzip >/dev/null
    local ver=$XRAY_VERSION
    if [ "$ver" = latest ]; then
        ver=$(curl -fsSI -m 30 https://github.com/XTLS/Xray-core/releases/latest | tr -d '\r' | awk -F/ 'tolower($1) ~ /^location:/ {print $NF}')
        [ -n "$ver" ] || die "cannot find latest Xray version"
    fi
    if ! "$XRAY_BIN" version 2>/dev/null | grep -q "Xray ${ver#v} "; then
        local t; t=$(mktemp -d)
        curl -fsSL -m 180 -o "$t/x.zip" "https://github.com/XTLS/Xray-core/releases/download/$ver/Xray-linux-64.zip" || die "xray download failed"
        mkdir -p /usr/local/lib/xray && unzip -o -q "$t/x.zip" -d /usr/local/lib/xray && rm -rf "$t"
        ln -sf /usr/local/lib/xray/xray "$XRAY_BIN"
    fi
    id xray >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -d /nonexistent xray
    id vpnsub >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -d /nonexistent vpnsub
    mkdir -p "$BASE" "$STATE"; chmod 750 "$BASE"; chgrp xray "$BASE"; chmod 700 "$STATE"
    [ "$(readlink -f "$0")" = "$SELF" ] || install -m 700 "$0" "$SELF"

    cat > /etc/systemd/system/vpnctl-xray.service <<EOF
[Unit]
Description=Xray VPN client (vpnctl)
After=network-online.target vpnctl-firewall.service
Wants=network-online.target
Requires=vpnctl-firewall.service

[Service]
User=xray
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=$XRAY_BIN run -c $BASE/config.json
ExecStartPost=+/bin/bash -c 'for i in \$(seq 20); do ip link show $TUN_IF >/dev/null 2>&1 && break; sleep 0.5; done; $SELF firewall'
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    # Firewall starts before the network, so there is no leak window at boot.
    cat > /etc/systemd/system/vpnctl-firewall.service <<EOF
[Unit]
Description=vpnctl kill switch
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SELF firewall

[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/vpnctl-update.service <<EOF
[Unit]
Description=vpnctl subscription update
After=network-online.target
[Service]
Type=oneshot
ExecStart=$SELF update
EOF
    cat > /etc/systemd/system/vpnctl-update.timer <<EOF
[Unit]
Description=vpnctl subscription update timer
[Timer]
OnBootSec=1min
OnUnitActiveSec=$UPDATE_EVERY
[Install]
WantedBy=timers.target
EOF
    cat > /etc/systemd/system/vpnctl-check.service <<EOF
[Unit]
Description=vpnctl health check
[Service]
Type=oneshot
ExecStart=$SELF check
EOF
    cat > /etc/systemd/system/vpnctl-check.timer <<EOF
[Unit]
Description=vpnctl health check timer
[Timer]
OnBootSec=2min
OnUnitActiveSec=$CHECK_EVERY
[Install]
WantedBy=timers.target
EOF
    # systemd-networkd deletes routing rules and routes it did not create; keep ours.
    mkdir -p /etc/systemd/networkd.conf.d
    printf '[Network]\nManageForeignRoutingPolicyRules=no\nManageForeignRoutes=no\n' > /etc/systemd/networkd.conf.d/vpnctl.conf
    # Network up (WAN IP known): reapply rules.
    cat > /etc/systemd/system/vpnctl-firewall-late.service <<EOF
[Unit]
Description=vpnctl reapply routing after network is up
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=$SELF firewall
[Install]
WantedBy=multi-user.target
EOF
    # DNS for the host goes through the tunnel.
    mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNS=%s\nFallbackDNS=\nDNSStubListener=yes\n' "$DNS_SERVERS" > /etc/systemd/resolved.conf.d/vpnctl.conf
    systemctl restart systemd-resolved

    systemctl daemon-reload
    systemctl enable -q vpnctl-firewall vpnctl-firewall-late vpnctl-xray vpnctl-update.timer vpnctl-check.timer
    systemctl start vpnctl-firewall
    do_update force || log "first update failed; kill switch is on, internet is blocked"
    systemctl start vpnctl-update.timer vpnctl-check.timer
    log "install done"
}

do_status() {
    echo "server:  $(cat "$STATE/server.name" 2>/dev/null || echo none)"
    echo "xray:    $(systemctl is-active vpnctl-xray)"
    echo "tun:     $(ip -br addr show "$TUN_IF" 2>/dev/null || echo missing)"
    echo "vpn ips: $(tr '\n' ' ' < "$STATE/vpn_ips" 2>/dev/null)"
    echo -n "exit ip: "; curl -s -m 10 https://api.ipify.org || echo "(no internet)"; echo
    nft list table inet vpnks >/dev/null 2>&1 && echo "killswitch: on" || echo "killswitch: OFF"
}

case "${1:-}" in
    install)   do_install ;;
    update)    do_update "${2:-}" ;;
    check)     do_check ;;
    firewall)  apply_firewall ;;
    tunroutes) setup_tun_routes ;;
    status)    do_status ;;
    rollback)  remove_firewall; log "kill switch removed" ;;
    uninstall)
        systemctl disable --now vpnctl-xray vpnctl-firewall-late vpnctl-update.timer vpnctl-check.timer vpnctl-firewall 2>/dev/null
        remove_firewall
        rm -f /etc/systemd/system/vpnctl-* /etc/systemd/resolved.conf.d/vpnctl.conf /etc/systemd/networkd.conf.d/vpnctl.conf
        systemctl daemon-reload; systemctl restart systemd-resolved
        rm -rf "$STATE" "$BASE/config.json" "$BASE/test.json"; log "uninstalled (kept $BASE/vpnctl.conf)" ;;
    *) sed -n '2,20p' "$0"; exit 1 ;;
esac
