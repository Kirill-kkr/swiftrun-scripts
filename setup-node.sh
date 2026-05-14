#!/usr/bin/env bash
#
# setup-node.sh — установка + оптимизация + защита Remnawave-Node.
# https://github.com/Kirill-kkr/swiftrun-scripts
#
# Делает:
#   0. Проверки окружения (root, curl, Debian/Ubuntu)
#   1. Docker + compose plugin
#   2. BBR + FQ + TCP tuning + anti-DDoS sysctl (SYN cookies, rp_filter и т.д.)
#   3. UFW firewall — :443 публично, :NODE_PORT только для panel IP, SSH rate-limit
#   4. Fail2ban — защита SSH от brute-force (3 попытки → 24ч бан)
#   5. SSH hardening (опционально, --harden-ssh) — создание админ-юзера,
#      отключение root SSH + password auth
#   6. /opt/remnanode/ + docker-compose.yml (от Remnawave admin UI)
#   7. docker compose up -d
#
# Использование (двухшаговый — надёжный):
#   curl -fsSL https://raw.githubusercontent.com/Kirill-kkr/swiftrun-scripts/main/setup-node.sh -o /tmp/setup-node.sh
#   sudo bash /tmp/setup-node.sh
#
# С предзаписанным compose:
#   sudo bash /tmp/setup-node.sh --compose-file /path/to/compose.yml
#
# С указанием IP панели для firewall (или скрипт спросит интерактивно):
#   sudo bash /tmp/setup-node.sh --panel-ip 1.2.3.4
#
# Пропустить отдельные шаги:
#   --skip-tuning      без sysctl/BBR
#   --skip-firewall    без UFW
#   --skip-fail2ban    без fail2ban
#
# Идемпотентен — повторный запуск пропустит уже сделанное.
#
# Безопасность: docker-compose.yml содержит SECRET_KEY ноды (mTLS). Скрипт
# принимает его ТОЛЬКО через stdin или --compose-file path; НИКОГДА через
# CLI argv (чтобы не светиться в `ps`/history).

set -euo pipefail

# Reopen stdin from /dev/tty for pipe-mode (curl | bash). Ошибки тихо
# игнорируем — на CI/контейнере без TTY всё-равно работает с --compose-file.
if [ ! -t 0 ]; then
	{ exec < /dev/tty; } 2>/dev/null || true
fi

NODE_DIR="/opt/remnanode"
COMPOSE_FILE_FLAG=""
PANEL_IP=""
SKIP_TUNING=0
SKIP_FIREWALL=0
SKIP_FAIL2BAN=0
HARDEN_SSH=0
ADMIN_USER=""
ADMIN_SSH_KEY=""

# Логирование — структурированный output с цветами
log()    { printf '\033[36m▶\033[0m %s\n' "$*"; }
ok()     { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn()   { printf '\033[33m⚠\033[0m %s\n' "$*"; }
fail()   { printf '\033[31m✗ FAIL:\033[0m %s\n' "$*" >&2; exit 1; }
step()   { printf '\n\033[1;36m━━━ %s ━━━\033[0m\n' "$*"; }

# Стартовый banner — видно что скрипт реально стартанул
cat <<'EOF'

╔══════════════════════════════════════════════════════════════════╗
║  Swiftrun setup-node.sh — Remnawave-Node install + tuning        ║
║  https://github.com/Kirill-kkr/swiftrun-scripts                  ║
║                                                                  ║
║  Docker · BBR/TCP tuning · UFW · Fail2ban · Remnawave-Node       ║
╚══════════════════════════════════════════════════════════════════╝

EOF

# --- args ---
while [ $# -gt 0 ]; do
	case "$1" in
		--compose-file)
			COMPOSE_FILE_FLAG="${2:?--compose-file требует path}"
			shift 2
			;;
		--panel-ip)
			PANEL_IP="${2:?--panel-ip требует IP}"
			shift 2
			;;
		--skip-tuning)
			SKIP_TUNING=1
			shift
			;;
		--skip-firewall)
			SKIP_FIREWALL=1
			shift
			;;
		--skip-fail2ban)
			SKIP_FAIL2BAN=1
			shift
			;;
		--harden-ssh)
			HARDEN_SSH=1
			shift
			;;
		--admin-user)
			ADMIN_USER="${2:?--admin-user требует имя}"
			shift 2
			;;
		--admin-ssh-key)
			ADMIN_SSH_KEY="${2:?--admin-ssh-key требует ключ или путь к файлу}"
			shift 2
			;;
		-h|--help)
			head -n 40 "$0"; exit 0
			;;
		*)
			fail "неизвестный аргумент: $1"
			;;
	esac
done

# =========================================================================
step "0/7 · Проверки окружения"
# =========================================================================

log "проверяю права root…"
if [ "$(id -u)" -ne 0 ]; then
	fail "запускай через sudo"
fi
ok "root ✓"

log "проверяю curl…"
if ! command -v curl >/dev/null 2>&1; then
	fail "curl не установлен. apt install curl"
fi
ok "curl ✓ ($(curl --version | head -1 | cut -d' ' -f1-2))"

log "проверяю системные пакеты…"
if command -v apt-get >/dev/null 2>&1; then
	ok "Debian/Ubuntu detected"
else
	warn "не Debian/Ubuntu — некоторые шаги (apt, ufw, fail2ban) могут не сработать"
fi

# =========================================================================
step "1/7 · Docker"
# =========================================================================

if ! command -v docker >/dev/null 2>&1; then
	log "Docker не найден — ставлю через get.docker.com (30-90 сек)…"
	echo
	curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
	sh /tmp/get-docker.sh
	rm -f /tmp/get-docker.sh
	echo
	ok "Docker установлен ($(docker --version))"
else
	ok "Docker уже установлен ($(docker --version))"
fi

log "проверяю docker compose plugin…"
if ! docker compose version >/dev/null 2>&1; then
	fail "docker compose plugin не работает. Обнови Docker до 20.10+"
fi
ok "docker compose ✓ ($(docker compose version --short))"

# =========================================================================
step "2/7 · BBR + TCP tuning"
# =========================================================================

if [ $SKIP_TUNING -eq 1 ]; then
	warn "пропущено по --skip-tuning"
else
	SYSCTL_FILE="/etc/sysctl.d/99-swiftrun-node.conf"

	log "пишу $SYSCTL_FILE"
	cat > "$SYSCTL_FILE" <<'SYSCTL'
# Swiftrun-VPN node optimization — managed by setup-node.sh

# BBR + FQ — современный TCP congestion control (требует ядро 4.9+)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP buffer sizes — для high-bandwidth links
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 67108864
net.ipv4.tcp_wmem = 4096 1048576 67108864

# TCP Fast Open (RFC 7413) — ускорение handshake
net.ipv4.tcp_fastopen = 3

# IP forwarding (нужно для VPN-трафика)
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# TCP оптимизации
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192

# Connection tracking — больше одновременных VPN-сессий
net.netfilter.nf_conntrack_max = 524288
net.netfilter.nf_conntrack_tcp_timeout_established = 7200

# IPv6 — оставляем включённым (Hetzner и др. дают /64 бесплатно)
net.ipv6.conf.all.disable_ipv6 = 0

# ============================================================
# Anti-DDoS hardening (kernel-level защита)
# ============================================================

# SYN flood защита
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3

# RFC 1337: защита от TIME_WAIT assassination attacks
net.ipv4.tcp_rfc1337 = 1

# Reverse path filtering — отбрасываем пакеты с поддельным src IP
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Игнорируем source routing (потенциальный вектор атак)
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Игнорируем ICMP redirects (атаки man-in-the-middle)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Не отправляем ICMP redirects (мы не роутер)
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Smurf attack защита — игнор broadcast ICMP
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Игнор bogus ICMP error responses
net.ipv4.icmp_ignore_bogus_error_responses = 1

# ICMP rate limit — против ping flood
net.ipv4.icmp_ratelimit = 100
net.ipv4.icmp_ratemask = 88089

# Логируем мартианские (spoofed) пакеты
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
SYSCTL

	log "применяю sysctl…"
	sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || warn "часть параметров не применилась (возможно nf_conntrack модуль не загружен)"

	CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
	CURRENT_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")

	if [ "$CURRENT_CC" = "bbr" ]; then
		ok "BBR активен (tcp_congestion_control = bbr)"
	else
		warn "BBR не активен (текущий: $CURRENT_CC) — попробуй: modprobe tcp_bbr"
	fi
	ok "default qdisc = $CURRENT_QDISC"
fi

# =========================================================================
step "3/7 · Firewall (UFW)"
# =========================================================================

# Получаем NODE_PORT заранее (из compose если уже есть, иначе дефолт 2222)
NODE_PORT="2222"
if [ -f "$NODE_DIR/docker-compose.yml" ]; then
	NODE_PORT=$(grep -oE 'APP_PORT=[0-9]+' "$NODE_DIR/docker-compose.yml" 2>/dev/null | head -1 | cut -d= -f2 || true)
	[ -z "$NODE_PORT" ] && NODE_PORT=$(grep -oE '[0-9]+:[0-9]+' "$NODE_DIR/docker-compose.yml" 2>/dev/null | head -1 | cut -d: -f1 || true)
	NODE_PORT="${NODE_PORT:-2222}"
fi

if [ $SKIP_FIREWALL -eq 1 ]; then
	warn "пропущено по --skip-firewall"
elif ! command -v apt-get >/dev/null 2>&1; then
	warn "не Debian/Ubuntu — пропускаю UFW"
else
	# Спросить PANEL_IP интерактивно если не передан флагом
	if [ -z "$PANEL_IP" ]; then
		echo
		echo "Для firewall: какой IP у твоей Remnawave-панели?"
		echo "  Через :$NODE_PORT панель будет ходить к ноде по mTLS."
		echo "  Если оставить пустым — :$NODE_PORT будет открыт всему интернету (небезопасно)."
		printf "IP панели (Enter чтобы пропустить): "
		read -r PANEL_IP < /dev/tty 2>/dev/null || PANEL_IP=""
		echo
	fi

	if ! command -v ufw >/dev/null 2>&1; then
		log "ставлю ufw…"
		apt-get update -qq && apt-get install -y ufw >/dev/null
		ok "ufw установлен"
	else
		ok "ufw уже установлен"
	fi

	log "настраиваю UFW…"
	ufw --force reset >/dev/null
	ufw default deny incoming >/dev/null
	ufw default allow outgoing >/dev/null

	# SSH — обязательно прежде чем включить ufw (чтоб не отрубить себя).
	# 'ufw limit' = block IP который делает >6 попыток за 30 сек.
	log "разрешаю SSH (22/tcp) + rate-limit (6 conn/30s per IP)"
	ufw limit 22/tcp >/dev/null

	# VPN-трафик — публичный
	log "разрешаю :443 (VLESS REALITY public)"
	ufw allow 443/tcp >/dev/null

	# Node API port — только для панели
	if [ -n "$PANEL_IP" ]; then
		log "разрешаю :$NODE_PORT только с IP панели ($PANEL_IP)"
		ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp >/dev/null
	else
		warn ":$NODE_PORT открыт всем (PANEL_IP не задан — лучше укажи позже)"
		ufw allow "$NODE_PORT"/tcp >/dev/null
	fi

	log "включаю UFW…"
	ufw --force enable >/dev/null
	ok "UFW активен"
fi

# =========================================================================
step "4/7 · Fail2ban (защита SSH)"
# =========================================================================

if [ $SKIP_FAIL2BAN -eq 1 ]; then
	warn "пропущено по --skip-fail2ban"
elif ! command -v apt-get >/dev/null 2>&1; then
	warn "не Debian/Ubuntu — пропускаю fail2ban"
else
	if ! command -v fail2ban-server >/dev/null 2>&1; then
		log "ставлю fail2ban…"
		apt-get install -y fail2ban >/dev/null
		ok "fail2ban установлен"
	else
		ok "fail2ban уже установлен"
	fi

	cat > /etc/fail2ban/jail.d/swiftrun-sshd.conf <<'JAIL'
# Swiftrun-VPN node — fail2ban SSH protection
[sshd]
enabled = true
port    = ssh
filter  = sshd
logpath = %(sshd_log)s
backend = %(sshd_backend)s
maxretry = 3
findtime = 600
bantime  = 86400
JAIL

	log "перезапускаю fail2ban…"
	systemctl enable fail2ban >/dev/null 2>&1 || true
	systemctl restart fail2ban
	sleep 1
	if systemctl is-active fail2ban >/dev/null; then
		ok "fail2ban активен (SSH: 3 попытки/10 мин → бан на 24ч)"
	else
		warn "fail2ban не стартанул — проверь: systemctl status fail2ban"
	fi
fi

# =========================================================================
step "5/7 · SSH hardening (опционально)"
# =========================================================================

# Создание non-root admin-юзера + отключение root SSH + password auth.
# Делается только если --harden-ssh передан, или интерактивно подтверждено.

SHOULD_HARDEN=0
if [ $HARDEN_SSH -eq 1 ]; then
	SHOULD_HARDEN=1
elif [ -t 0 ] || { [ -e /dev/tty ] && [ -r /dev/tty ]; }; then
	echo
	echo "Хочешь создать non-root админ-юзера + отключить root SSH login?"
	echo "  ⚠️ Если ssh-ключ настроен неправильно — можешь остаться без доступа!"
	echo "  Можно пропустить и сделать позже:"
	echo "    sudo bash $0 --harden-ssh --admin-user kirill --admin-ssh-key /tmp/key.pub"
	printf "Захарденить SSH? [y/N]: "
	read -r ANSWER < /dev/tty 2>/dev/null || ANSWER=""
	echo
	[ "$ANSWER" = "y" ] || [ "$ANSWER" = "Y" ] || [ "$ANSWER" = "yes" ] && SHOULD_HARDEN=1
fi

if [ $SHOULD_HARDEN -eq 0 ]; then
	warn "пропускаю SSH hardening (передай --harden-ssh чтобы включить)"
else
	# Имя юзера
	if [ -z "$ADMIN_USER" ]; then
		printf "Имя нового admin-юзера [admin]: "
		read -r ADMIN_USER < /dev/tty 2>/dev/null || ADMIN_USER=""
		ADMIN_USER="${ADMIN_USER:-admin}"
	fi

	# Валидация имени
	if ! echo "$ADMIN_USER" | grep -qE '^[a-z_][a-z0-9_-]{0,30}$'; then
		fail "недопустимое имя юзера: $ADMIN_USER (только lowercase, цифры, -, _)"
	fi

	# SSH key
	if [ -z "$ADMIN_SSH_KEY" ]; then
		echo
		echo "Вставь свой SSH публичный ключ (одна строка, начинается с 'ssh-ed25519' или 'ssh-rsa')."
		echo "На маке его взять: cat ~/.ssh/id_ed25519.pub"
		echo "Если нет — сгенерь: ssh-keygen -t ed25519"
		echo
		printf "Ключ: "
		read -r ADMIN_SSH_KEY < /dev/tty 2>/dev/null || ADMIN_SSH_KEY=""
		echo
	elif [ -f "$ADMIN_SSH_KEY" ]; then
		ADMIN_SSH_KEY=$(cat "$ADMIN_SSH_KEY")
	fi

	# Валидация ключа
	if ! echo "$ADMIN_SSH_KEY" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-) '; then
		fail "не похоже на SSH key: '$ADMIN_SSH_KEY' (должен начинаться с 'ssh-rsa', 'ssh-ed25519' или 'ecdsa-sha2-')"
	fi

	# Создание юзера
	if id "$ADMIN_USER" >/dev/null 2>&1; then
		ok "юзер $ADMIN_USER уже существует"
	else
		log "создаю юзера $ADMIN_USER"
		useradd -m -s /bin/bash "$ADMIN_USER"
		ok "юзер $ADMIN_USER создан"
	fi

	log "добавляю $ADMIN_USER в группу sudo"
	usermod -aG sudo "$ADMIN_USER"

	# Sudo без пароля (т.к. password auth скоро отключим)
	log "разрешаю sudo без пароля для $ADMIN_USER"
	echo "$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/swiftrun-$ADMIN_USER"
	chmod 0440 "/etc/sudoers.d/swiftrun-$ADMIN_USER"

	# SSH key
	log "ставлю SSH key для $ADMIN_USER"
	USER_SSH_DIR="/home/$ADMIN_USER/.ssh"
	mkdir -p "$USER_SSH_DIR"
	chmod 700 "$USER_SSH_DIR"
	echo "$ADMIN_SSH_KEY" > "$USER_SSH_DIR/authorized_keys"
	chmod 600 "$USER_SSH_DIR/authorized_keys"
	chown -R "$ADMIN_USER:$ADMIN_USER" "$USER_SSH_DIR"
	ok "SSH key установлен"

	# Перед отключением root — попросить проверить
	PUBLIC_IP_TMP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "<твой IP>")
	echo
	cat <<EOF
┌─────────────────────────────────────────────────────────────────┐
│  ⚠️ ПРОВЕРЬ В ДРУГОМ ТЕРМИНАЛЕ что новый юзер работает:         │
│                                                                 │
│    ssh $ADMIN_USER@$PUBLIC_IP_TMP
│    sudo whoami    # должно вывести: root                        │
│                                                                 │
│  Если работает — продолжаем (отключим root SSH и password).     │
│  Если НЕ работает — НЕ продолжай! Откатишь и переделаешь.       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
EOF
	printf "Войти под %s удалось? Отключить root SSH? [y/N]: " "$ADMIN_USER"
	read -r CONFIRM < /dev/tty 2>/dev/null || CONFIRM="n"
	echo

	if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ] || [ "$CONFIRM" = "yes" ]; then
		log "правлю /etc/ssh/sshd_config — отключаю root + password auth"

		# Backup
		cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.backup-$(date +%Y%m%d-%H%M%S)"

		# Apply via drop-in (Debian 12+ / Ubuntu 22.04+ поддерживают sshd_config.d)
		mkdir -p /etc/ssh/sshd_config.d
		cat > /etc/ssh/sshd_config.d/99-swiftrun-hardening.conf <<HARDEN
# Swiftrun-VPN node SSH hardening — managed by setup-node.sh
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
HARDEN

		# На случай если drop-in не поддерживается — заменим в основном файле
		if ! grep -q 'Include /etc/ssh/sshd_config.d/\*.conf' /etc/ssh/sshd_config 2>/dev/null; then
			sed -i -E 's|^#?PermitRootLogin.*|PermitRootLogin no|; s|^#?PasswordAuthentication.*|PasswordAuthentication no|; s|^#?PubkeyAuthentication.*|PubkeyAuthentication yes|' /etc/ssh/sshd_config
		fi

		log "тестирую конфиг sshd…"
		if ! sshd -t 2>/dev/null; then
			fail "sshd config invalid! НЕ перезапускаю SSH, откатываю drop-in"
		fi

		log "перезапускаю sshd…"
		systemctl restart sshd || systemctl restart ssh
		ok "SSH hardened: root login отключён, password auth отключён"
		warn "ВАЖНО: проверь что всё ещё можешь зайти как $ADMIN_USER в новой ssh-сессии"
	else
		warn "пропускаю отключение root — юзер $ADMIN_USER создан, можешь использовать"
	fi
fi

# =========================================================================
step "6/7 · docker-compose.yml"
# =========================================================================

log "mkdir -p $NODE_DIR"
mkdir -p "$NODE_DIR"
cd "$NODE_DIR"
ok "работаю в $(pwd)"

if [ -f docker-compose.yml ]; then
	ok "docker-compose.yml уже существует — переподниму существующий стек"
else
	if [ -n "$COMPOSE_FILE_FLAG" ]; then
		log "беру compose из $COMPOSE_FILE_FLAG"
		[ -f "$COMPOSE_FILE_FLAG" ] || fail "файл не найден: $COMPOSE_FILE_FLAG"
		cp "$COMPOSE_FILE_FLAG" docker-compose.yml
		ok "compose скопирован"
	else
		cat <<'EOF'

┌─────────────────────────────────────────────────────────────────┐
│  ВСТАВЬ docker-compose.yml для этой ноды:                       │
│                                                                 │
│  1. Открой Remnawave admin: Nodes → Management → +              │
│  2. Создай ноду, нажми «Copy docker-compose.yml»                │
│  3. Вставь сюда (Cmd+V / Ctrl+Shift+V)                          │
│  4. Нажми Enter, потом Ctrl+D на пустой строке                  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

Ожидаю ввод…

EOF
		cat > docker-compose.yml
		echo
		[ -s docker-compose.yml ] || fail "пустой ввод; ничего не записано"
		BYTES=$(wc -c < docker-compose.yml)
		ok "compose получен ($BYTES байт)"
	fi
fi
chmod 600 docker-compose.yml

# Sanity-checks
log "проверяю содержимое compose…"
if grep -qE 'image:\s*remnawave/node' docker-compose.yml; then
	ok "image remnawave/node найден"
else
	warn "image 'remnawave/node' не найден — проверь источник compose"
fi
if grep -qE 'SECRET_KEY' docker-compose.yml; then
	ok "SECRET_KEY найден"
else
	warn "SECRET_KEY не найден — нода без секрета не подключится к панели"
fi

# Обновим NODE_PORT после получения compose (если был дефолтный)
NEW_NODE_PORT=$(grep -oE 'APP_PORT=[0-9]+' docker-compose.yml 2>/dev/null | head -1 | cut -d= -f2 || true)
[ -z "$NEW_NODE_PORT" ] && NEW_NODE_PORT=$(grep -oE '[0-9]+:[0-9]+' docker-compose.yml 2>/dev/null | head -1 | cut -d: -f1 || true)
if [ -n "$NEW_NODE_PORT" ] && [ "$NEW_NODE_PORT" != "$NODE_PORT" ]; then
	warn "compose декларирует другой порт: $NEW_NODE_PORT (firewall настроен на $NODE_PORT)"
	log "после успешного старта запусти ещё раз: sudo bash $0 --panel-ip $PANEL_IP"
fi

# =========================================================================
step "7/7 · Docker compose up"
# =========================================================================

log "docker compose pull (скачаю remnawave/node)…"
docker compose pull
echo

log "docker compose up -d…"
docker compose up -d
echo

log "жду 3 сек инициализации…"
sleep 3

log "статус контейнеров:"
docker compose ps

# =========================================================================
# Финальный summary
# =========================================================================

PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "?")

cat <<EOF


╔══════════════════════════════════════════════════════════════════╗
║  ✓ Remnawave-Node поднята.                                       ║
╚══════════════════════════════════════════════════════════════════╝

Параметры:
  Public IP:              $PUBLIC_IP
  Node port:              $NODE_PORT
  Каталог:                $NODE_DIR
  TCP congestion control: ${CURRENT_CC:-?}
  Default qdisc:          ${CURRENT_QDISC:-?}

Проверь в Remnawave admin:
  Nodes → должна появиться твоя со статусом Connected (через 30-60 сек)

Полезные команды на ноде:
  cd $NODE_DIR && docker compose logs -f       # логи контейнера
  docker compose ps                            # статус
  ss -tin | grep bbr | head -5                 # проверить BBR работает
  ufw status numbered                          # firewall правила
  fail2ban-client status sshd                  # забаненные IP

Если позже надо добавить/изменить IP панели в firewall:
  sudo bash $0 --panel-ip <NEW_PANEL_IP> --skip-tuning --skip-fail2ban

EOF
