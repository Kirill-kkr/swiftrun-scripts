#!/usr/bin/env bash
#
# setup-node.sh — развёртка Remnawave-Node на чистой Ubuntu/Debian VPS.
# https://github.com/Kirill-kkr/swiftrun-scripts
#
# По docs.rw/docs/install/remnawave-node:
#   1. Устанавливает Docker (если нужно).
#   2. Создаёт /opt/remnanode/.
#   3. Принимает docker-compose.yml для ноды от оператора (вставкой stdin
#      или через --compose-file <path>). Этот файл генерируется панелью
#      при создании ноды через UI (Nodes → Management → +) и содержит
#      embedded SECRET_KEY + сертификат — поэтому НЕТ headless-варианта
#      без участия админа панели.
#   4. docker compose up -d.
#
# Использование (любой из двух способов работает):
#
#   # Способ 1 — pipe в sudo bash (рекомендую):
#   curl -fsSL https://raw.githubusercontent.com/Kirill-kkr/swiftrun-scripts/main/setup-node.sh | sudo bash
#
#   # Способ 2 — скачать и запустить отдельно:
#   curl -fsSL https://raw.githubusercontent.com/Kirill-kkr/swiftrun-scripts/main/setup-node.sh -o /tmp/setup-node.sh
#   sudo bash /tmp/setup-node.sh
#   # или с предзаписанным compose-файлом:
#   sudo bash /tmp/setup-node.sh --compose-file /tmp/node-compose.yml
#
# Скрипт сам разрулит stdin: если запущен через pipe (Способ 1), переоткроет
# ввод из /dev/tty для интерактивной вставки compose-файла.
#
# ⚠️ `sudo bash <(curl ...)` НЕ работает — sudo не наследует /dev/fd из
# подпроцесса (ошибка "/dev/fd/63: No such file or directory"). Используй
# Способ 1 (`curl | sudo bash`) — он надёжный.
#
# Безопасность: docker-compose.yml содержит SECRET_KEY ноды (mTLS). Скрипт
# принимает его ТОЛЬКО через stdin или --compose-file path; НИКОГДА через
# CLI argv (чтобы не светиться в `ps`/history). Это сознательное
# ограничение — решает security-проблему предыдущей Marzban-эпохи скрипта,
# где admin-пароль панели передавался через --panel-pass.

set -euo pipefail

# Если stdin не TTY (curl | bash сценарий), переоткроем его из /dev/tty
# чтобы интерактивное чтение compose-файла работало нормально.
# Все ошибки попыток открыть /dev/tty (CI, контейнер без TTY) глушим в /dev/null.
if [ ! -t 0 ]; then
	{ exec < /dev/tty; } 2>/dev/null || true
fi

# Без буферизации — чтобы output моментально попадал в терминал
# даже при запуске через curl | sudo bash. Sentinel защищает от
# рекурсивного re-exec.
if [ -z "${SETUP_NODE_UNBUFFERED:-}" ] && command -v stdbuf >/dev/null 2>&1; then
	export SETUP_NODE_UNBUFFERED=1
	exec stdbuf -oL -eL "$0" "$@" 0<&0
fi

NODE_DIR="/opt/remnanode"
COMPOSE_FILE_FLAG=""

# Цветной structured logging — каждое сообщение видно в реальном времени.
log()    { printf '\033[36m▶\033[0m %s\n' "$*"; }
ok()     { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn()   { printf '\033[33m⚠\033[0m %s\n' "$*"; }
fail()   { printf '\033[31m✗ FAIL:\033[0m %s\n' "$*" >&2; exit 1; }
step()   { printf '\n\033[1;36m━━━ %s ━━━\033[0m\n' "$*"; }

# Hello banner — видно что скрипт реально стартанул.
cat <<'EOF'

╔══════════════════════════════════════════════════════════════════╗
║  Swiftrun setup-node.sh — Remnawave-Node install                 ║
║  https://github.com/Kirill-kkr/swiftrun-scripts                  ║
╚══════════════════════════════════════════════════════════════════╝

EOF

# --- args ---
while [ $# -gt 0 ]; do
	case "$1" in
		--compose-file)
			COMPOSE_FILE_FLAG="${2:?--compose-file требует path}"
			shift 2
			;;
		-h|--help)
			head -n 30 "$0"; exit 0
			;;
		*)
			fail "неизвестный аргумент: $1"
			;;
	esac
done

step "0/5 · Проверки окружения"

log "проверяю права root…"
if [ "$(id -u)" -ne 0 ]; then
	fail "запускай через sudo: 'curl ... | sudo bash'"
fi
ok "root ✓"

log "проверяю curl…"
if ! command -v curl >/dev/null 2>&1; then
	fail "curl не установлен. apt install curl"
fi
ok "curl ✓ ($(curl --version | head -1))"

log "проверяю системные пакеты…"
if command -v apt-get >/dev/null 2>&1; then
	ok "Debian/Ubuntu detected"
else
	warn "не Debian/Ubuntu — get.docker.com может работать иначе"
fi

# --- 1. Docker ---

step "1/5 · Docker"

if ! command -v docker >/dev/null 2>&1; then
	log "Docker не найден — ставлю через get.docker.com (это займёт 30-90 сек)…"
	echo
	# get.docker.com сам пишет в stdout прогресс установки —
	# не глушим, чтобы юзер видел что происходит.
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
	fail "docker compose plugin не работает. Возможно нужен апгрейд Docker"
fi
ok "docker compose ✓ ($(docker compose version --short))"

# --- 2. Каталог ---

step "2/5 · Создаю /opt/remnanode/"

log "mkdir -p $NODE_DIR"
mkdir -p "$NODE_DIR"
cd "$NODE_DIR"
ok "работаю в $(pwd)"

# --- 3. compose.yml ---

step "3/5 · docker-compose.yml"

if [ -f docker-compose.yml ]; then
	ok "docker-compose.yml уже существует — переподниму существующий стек"
else
	if [ -n "$COMPOSE_FILE_FLAG" ]; then
		# Скопировать из указанного path.
		log "беру compose из $COMPOSE_FILE_FLAG"
		[ -f "$COMPOSE_FILE_FLAG" ] || fail "файл не найден: $COMPOSE_FILE_FLAG"
		cp "$COMPOSE_FILE_FLAG" docker-compose.yml
		ok "compose скопирован"
	else
		# Интерактивный режим — попросить оператора вставить.
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

# Sanity-checks: убедимся, что файл выглядит как Remnawave-Node compose.
log "проверяю содержимое compose…"
if grep -qE 'image:\s*remnawave/node' docker-compose.yml; then
	ok "image remnawave/node найден"
else
	warn "image 'remnawave/node' не найден — проверь что скопировал правильный compose"
fi

if grep -qE 'SECRET_KEY' docker-compose.yml; then
	ok "SECRET_KEY найден"
else
	warn "SECRET_KEY не найден — нода без секрета не подключится к панели"
fi

# --- 4. firewall hint ---
step "4/5 · Firewall"

NODE_PORT=$(grep -oE 'APP_PORT=[0-9]+' docker-compose.yml | head -1 | cut -d= -f2 || true)
if [ -z "$NODE_PORT" ]; then
	NODE_PORT=$(grep -oE '[0-9]+:[0-9]+' docker-compose.yml | head -1 | cut -d: -f1 || true)
fi
NODE_PORT="${NODE_PORT:-2222}"

ok "node port: $NODE_PORT"
log "после старта открой :443 (VLESS REALITY) и :$NODE_PORT (только с IP панели)"

# --- 5. up ---

step "5/5 · Docker compose up"

log "docker compose pull (скачаю образ remnawave/node)…"
docker compose pull
echo

log "docker compose up -d…"
docker compose up -d
echo

log "жду 3 секунды чтобы контейнер инициализировался…"
sleep 3

log "статус контейнеров:"
docker compose ps

cat <<EOF


┌─────────────────────────────────────────────────────────────────┐
│  Remnawave-Node поднята.                                        │
│                                                                 │
│  Проверь в Remnawave admin UI: Nodes → видна нода со статусом   │
│  Connected (через 30-60 секунд).                                │
│                                                                 │
│  Firewall (если ufw):                                           │
│    sudo ufw allow from <PANEL_IP> to any port $NODE_PORT proto tcp
│    sudo ufw deny in $NODE_PORT/tcp     # запретить остальным    │
│                                                                 │
│  Дальше: открыть :443 для VLESS REALITY трафика (он публичный): │
│    sudo ufw allow 443/tcp                                       │
│                                                                 │
│  Логи: cd $NODE_DIR && docker compose logs -f                   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

EOF
