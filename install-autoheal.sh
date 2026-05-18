#!/usr/bin/env bash
#
# install-autoheal.sh — добавить autoheal + daily-restart на уже
# работающую Remnawave-ноду (БЕЗ полного re-run setup-node.sh).
#
# Идемпотентен: запускай сколько хочешь, если уже стоит — обновит.
#
# Использование:
#   curl -fsSL https://raw.githubusercontent.com/Kirill-kkr/swiftrun-scripts/main/install-autoheal.sh -o /tmp/install-autoheal.sh
#   sudo bash /tmp/install-autoheal.sh
#
# Опции:
#   --node-dir DIR             где docker-compose.yml ноды (default /opt/remnanode)
#   --node-port PORT           порт ноды для healthcheck (default авто-детект)
#   --interval SECONDS         интервал autoheal-проверок (default 30)
#   --daily-restart-hour 0-23  час ежедневного рестарта (default 4)
#   --no-cron                  не ставить cron daily-restart
#   --no-autoheal              не ставить autoheal-контейнер (только healthcheck/override)

set -euo pipefail

NODE_DIR="/opt/remnanode"
NODE_PORT=""
INTERVAL=30
DAILY_HOUR=4
INSTALL_CRON=1
INSTALL_AUTOHEAL=1

while [ $# -gt 0 ]; do
	case "$1" in
		--node-dir) NODE_DIR="$2"; shift 2 ;;
		--node-port) NODE_PORT="$2"; shift 2 ;;
		--interval) INTERVAL="$2"; shift 2 ;;
		--daily-restart-hour) DAILY_HOUR="$2"; shift 2 ;;
		--no-cron) INSTALL_CRON=0; shift ;;
		--no-autoheal) INSTALL_AUTOHEAL=0; shift ;;
		-h|--help) head -n 25 "$0"; exit 0 ;;
		*) echo "неизвестный аргумент: $1" >&2; exit 1 ;;
	esac
done

log()  { printf '\033[36m▶\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m⚠\033[0m %s\n' "$*"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "запускай через sudo"
[ -d "$NODE_DIR" ] || fail "$NODE_DIR не существует — указано неверно? Используй --node-dir"
[ -f "$NODE_DIR/docker-compose.yml" ] || fail "$NODE_DIR/docker-compose.yml не найден"

cd "$NODE_DIR"

# Авто-детект сервиса (имя контейнера ноды в compose)
NODE_SVC=$(grep -E '^[[:space:]]*[a-z_-]+:[[:space:]]*$' docker-compose.yml \
	| grep -iE 'node|remna' \
	| head -1 \
	| sed -E 's/^[[:space:]]*([a-z_-]+):.*$/\1/' \
	|| echo "remnanode")
[ -z "$NODE_SVC" ] && NODE_SVC="remnanode"
log "сервис в compose: $NODE_SVC"

# Авто-детект порта если не указан.
# grep может вернуть exit=1 если в compose нет port-mapping (network_mode: host)
# — это нормально, не считаем ошибкой. || true спасает от set -e + pipefail.
if [ -z "$NODE_PORT" ]; then
	NODE_PORT=$(grep -oE '[0-9]+:[0-9]+' docker-compose.yml 2>/dev/null | head -1 | cut -d: -f1 || true)
	if [ -z "$NODE_PORT" ]; then
		# Попробуем найти через APP_PORT / env / etc внутри compose
		NODE_PORT=$(grep -oE 'APP_PORT[=:]\s*"?[0-9]+' docker-compose.yml 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)
	fi
	[ -z "$NODE_PORT" ] && NODE_PORT=2222
fi
log "порт ноды: $NODE_PORT (если у тебя другой — передай --node-port N)"

# --- 1. override.yml: label + healthcheck ---

OVERRIDE_FILE="$NODE_DIR/docker-compose.override.yml"
log "пишу $OVERRIDE_FILE"
cat > "$OVERRIDE_FILE" <<OVERRIDE
# Добавлено swiftrun install-autoheal.sh — управляет autoheal + healthcheck
services:
  $NODE_SVC:
    labels:
      autoheal: "true"
    healthcheck:
      test: ["CMD-SHELL", "nc -z 127.0.0.1 $NODE_PORT || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s
OVERRIDE
ok "override.yml создан"

# --- 2. autoheal контейнер ---

if [ $INSTALL_AUTOHEAL -eq 1 ]; then
	if docker ps -a --format '{{.Names}}' | grep -qE '^autoheal$'; then
		log "autoheal уже есть — пересоздаю"
		docker rm -f autoheal >/dev/null 2>&1 || true
	fi
	log "запускаю autoheal-watchdog"
	docker run -d \
		--name autoheal \
		--restart=always \
		-e AUTOHEAL_CONTAINER_LABEL=autoheal \
		-e AUTOHEAL_INTERVAL="$INTERVAL" \
		-e AUTOHEAL_DEFAULT_STOP_TIMEOUT=10 \
		-v /var/run/docker.sock:/var/run/docker.sock \
		willfarrell/autoheal:latest >/dev/null
	ok "autoheal запущен (interval=${INTERVAL}s)"
else
	warn "autoheal-контейнер пропущен (--no-autoheal)"
fi

# --- 3. recreate ноды с healthcheck ---

log "recreate $NODE_SVC (применяю healthcheck)"
docker compose up -d "$NODE_SVC"

# --- 4. cron daily restart ---

if [ $INSTALL_CRON -eq 1 ]; then
	CRON_FILE="/etc/cron.d/swiftrun-remnanode-daily-restart"
	log "пишу $CRON_FILE (рестарт в $(printf '%02d' "$DAILY_HOUR"):00)"
	cat > "$CRON_FILE" <<CRON
# Swiftrun-VPN — daily restart node (anti-leak)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$DAILY_HOUR 0 * * * root cd $NODE_DIR && docker compose restart $NODE_SVC >/var/log/swiftrun-restart.log 2>&1
CRON
	chmod 644 "$CRON_FILE"
	systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || true
	ok "cron установлен (${DAILY_HOUR}:00 ежедневно)"
else
	warn "cron пропущен (--no-cron)"
fi

# --- 5. проверка ---

sleep 3
echo ""
echo "─── Статус ───"
docker compose ps "$NODE_SVC"
echo ""

if [ $INSTALL_AUTOHEAL -eq 1 ]; then
	AUTOHEAL_STATE=$(docker inspect autoheal --format '{{.State.Status}}' 2>/dev/null || echo "?")
	echo "autoheal:    $AUTOHEAL_STATE"
fi

NODE_CONTAINER_ID=$(docker compose ps -q "$NODE_SVC" 2>/dev/null)
if [ -n "$NODE_CONTAINER_ID" ]; then
	NODE_HEALTH=$(docker inspect "$NODE_CONTAINER_ID" --format '{{.State.Health.Status}}' 2>/dev/null || echo "no-healthcheck")
	echo "node health: $NODE_HEALTH"
	echo "(в течение 60 сек должно стать 'healthy' если порт $NODE_PORT слушается)"
fi

echo ""
ok "Готово. Нода будет автоматически рестартиться при зависании + ежедневно в $(printf '%02d' "$DAILY_HOUR"):00"
echo ""
echo "Проверь через минуту:"
echo "  docker compose ps                    # status: Up X seconds (healthy)"
echo "  docker logs autoheal | tail -5       # autoheal активен"
echo "  cat /etc/cron.d/swiftrun-remnanode-daily-restart"
