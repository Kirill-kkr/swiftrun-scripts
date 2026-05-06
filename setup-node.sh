#!/bin/bash
set -e

usage() {
  echo "Usage: $0 --name NAME --panel-url URL --panel-user USER --panel-pass PASS --panel-ip IP --ssh-key 'ssh-ed25519 ...'"
  echo ""
  echo "  --name        Node name in panel, e.g. nl-2"
  echo "  --panel-url   Panel HTTPS URL, e.g. https://panel.swiftrun.work:8000"
  echo "  --panel-user  Panel admin username"
  echo "  --panel-pass  Panel admin password"
  echo "  --panel-ip    Panel server IP for UFW, e.g. 150.251.145.57"
  echo "  --ssh-key     Public SSH key to add for admin user"
  exit 1
}

NAME="" PANEL_URL="" PANEL_USER="" PANEL_PASS="" PANEL_IP="" SSH_KEY=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --name)       NAME="$2";       shift 2 ;;
    --panel-url)  PANEL_URL="$2";  shift 2 ;;
    --panel-user) PANEL_USER="$2"; shift 2 ;;
    --panel-pass) PANEL_PASS="$2"; shift 2 ;;
    --panel-ip)   PANEL_IP="$2";   shift 2 ;;
    --ssh-key)    SSH_KEY="$2";    shift 2 ;;
    *) echo "Unknown argument: $1"; usage ;;
  esac
done

[[ -z "$NAME" || -z "$PANEL_URL" || -z "$PANEL_USER" || -z "$PANEL_PASS" || -z "$PANEL_IP" || -z "$SSH_KEY" ]] && usage

[[ "$EUID" -ne 0 ]] && { echo "Run as root"; exit 1; }

echo "[1/7] User setup"
if ! id admin &>/dev/null; then
  if getent group admin &>/dev/null; then
    adduser --disabled-password --gecos "" --ingroup admin admin
  else
    adduser --disabled-password --gecos "" admin
  fi
fi
usermod -aG sudo admin

mkdir -p /home/admin/.ssh
echo "$SSH_KEY" > /home/admin/.ssh/authorized_keys
chown -R admin:admin /home/admin/.ssh
chmod 700 /home/admin/.ssh
chmod 600 /home/admin/.ssh/authorized_keys

echo "admin ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/admin-nopasswd
chmod 440 /etc/sudoers.d/admin-nopasswd

sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/'       /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
grep -q 'PubkeyAuthentication yes' /etc/ssh/sshd_config || \
  echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config
systemctl restart ssh

echo "[2/7] UFW"
apt-get install -y -q ufw
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp   comment 'SSH'
ufw allow 80/tcp   comment 'HTTP'
ufw allow 443/tcp  comment 'VLESS+Reality'
ufw allow 443/udp  comment 'reserved'
ufw allow from "$PANEL_IP" to any port 62050 proto tcp comment 'marzban-node REST'
ufw allow from "$PANEL_IP" to any port 62051 proto tcp comment 'Xray API'
ufw --force enable

echo "[3/7] System update + packages"
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q
apt-get install -y -q curl wget jq nano htop net-tools fail2ban
systemctl enable --now fail2ban

timedatectl set-ntp true
systemctl restart systemd-timesyncd
sleep 3

echo "[4/7] BBR + sysctl"
grep -q 'tcp_congestion_control=bbr' /etc/sysctl.conf || cat >> /etc/sysctl.conf << 'SYSCTL'

# SwiftrunVPN tuning
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.netfilter.nf_conntrack_max=524288
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_max_syn_backlog=4096
net.core.somaxconn=65535
net.core.netdev_max_backlog=16384
fs.file-max=1000000
SYSCTL
sysctl -p -q

grep -q 'nofile 1000000' /etc/security/limits.conf || cat >> /etc/security/limits.conf << 'LIMITS'
* soft nofile 1000000
* hard nofile 1000000
LIMITS

echo "[5/7] Docker"
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
  sleep 5
fi

echo "[6/7] Get panel cert + start marzban-node"
AUTH_RESP=$(curl -s -X POST "$PANEL_URL/api/admin/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=$PANEL_USER&password=$PANEL_PASS")
TOKEN=$(echo "$AUTH_RESP" | jq -r '.access_token // empty')

if [[ -z "$TOKEN" ]]; then
  echo "ERROR: Panel auth failed"
  echo "Response: $AUTH_RESP"
  exit 1
fi

mkdir -p /var/lib/marzban-node /opt/marzban-node

curl -s -H "Authorization: Bearer $TOKEN" \
  "$PANEL_URL/api/node/settings" | jq -r '.certificate' > /var/lib/marzban-node/cert.pem

cat > /opt/marzban-node/docker-compose.yml << 'EOF'
services:
  marzban-node:
    container_name: marzban-node
    image: gozargah/marzban-node:latest
    restart: always
    network_mode: host
    environment:
      SSL_CLIENT_CERT_FILE: "/var/lib/marzban-node/cert.pem"
      SERVICE_PORT: "62050"
      XRAY_API_PORT: "62051"
      SERVICE_PROTOCOL: "rest"
    volumes:
      - /var/lib/marzban-node:/var/lib/marzban
      - /var/lib/marzban-node:/var/lib/marzban-node
EOF

cd /opt/marzban-node
docker compose up -d
sleep 5

echo "[7/7] Register node in panel"
NODE_IP=$(curl -s https://ipinfo.io/ip 2>/dev/null || hostname -I | awk '{print $1}')
RESULT=$(curl -s -X POST "$PANEL_URL/api/node" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"$NAME\",\"address\":\"$NODE_IP\",\"port\":62050,\"api_port\":62051,\"usage_coefficient\":1}")
NODE_ID=$(echo "$RESULT" | jq -r '.id // "unknown"')

echo ""
echo "════════════════════════════════════════════"
echo "  НОДА ГОТОВА: $NAME"
echo "════════════════════════════════════════════"
echo "  IP:      $NODE_IP"
echo "  Node ID: $NODE_ID"
echo ""
echo "  Нода зарегистрирована в панели автоматически."
echo "  Проверь статус в $PANEL_URL/dashboard/"
echo "════════════════════════════════════════════"
echo ""
echo "Logs:"
docker compose logs --tail=8
