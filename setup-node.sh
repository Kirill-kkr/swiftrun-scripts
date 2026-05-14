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
if [ ! -t 0 ] && [ -r /dev/tty ]; then
	exec < /dev/tty
fi

NODE_DIR="/opt/remnanode"
COMPOSE_FILE_FLAG=""

log()    { printf '\033[36m[node]\033[0m %s\n' "$*"; }
ok()     { printf '\033[32m[ ok ]\033[0m %s\n' "$*"; }
warn()   { printf '\033[33m[warn]\033[0m %s\n' "$*"; }
fail()   { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

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

if [ "$(id -u)" -ne 0 ]; then
	fail "запускай через sudo"
fi
if ! command -v curl >/dev/null 2>&1; then
	fail "нужен curl"
fi

# --- 1. Docker ---

if ! command -v docker >/dev/null 2>&1; then
	log "ставлю Docker (через get.docker.com)…"
	curl -fsSL https://get.docker.com | sh
	ok "Docker установлен"
else
	ok "Docker уже установлен"
fi

# --- 2. Каталог ---

mkdir -p "$NODE_DIR"
cd "$NODE_DIR"

# --- 3. compose.yml ---

if [ -f docker-compose.yml ]; then
	ok "docker-compose.yml уже существует — переподнимаю существующий стек"
else
	if [ -n "$COMPOSE_FILE_FLAG" ]; then
		# Скопировать из указанного path.
		[ -f "$COMPOSE_FILE_FLAG" ] || fail "файл не найден: $COMPOSE_FILE_FLAG"
		cp "$COMPOSE_FILE_FLAG" docker-compose.yml
		ok "compose-файл скопирован из $COMPOSE_FILE_FLAG"
	else
		# Интерактивный режим — попросить оператора вставить.
		cat <<'EOF'

Вставь docker-compose.yml для этой ноды (скопирован из Remnawave admin UI).
Завершить ввод: Ctrl+D на пустой строке.

EOF
		cat > docker-compose.yml
		[ -s docker-compose.yml ] || fail "пустой ввод; ничего не записано"
		ok "compose-файл получен"
	fi
fi
chmod 600 docker-compose.yml

# Sanity-checks: убедимся, что файл выглядит как Remnawave-Node compose.
if ! grep -qE 'image:\s*remnawave/node' docker-compose.yml; then
	warn "в compose-файле нет 'image: remnawave/node' — проверь источник"
fi
if ! grep -qE 'SECRET_KEY' docker-compose.yml; then
	warn "в compose-файле не вижу SECRET_KEY — нода без секрета не подключится"
fi

# --- 4. firewall hint ---
NODE_PORT=$(grep -oE 'APP_PORT=[0-9]+' docker-compose.yml | head -1 | cut -d= -f2 || true)
if [ -z "$NODE_PORT" ]; then
	# Параметр иногда задан через environment, иногда через ports — попробуем достать из ports:
	NODE_PORT=$(grep -oE '[0-9]+:[0-9]+' docker-compose.yml | head -1 | cut -d: -f1 || true)
fi
NODE_PORT="${NODE_PORT:-2222}"

log "ожидаемый node port: $NODE_PORT (откой только для IP панели в ufw)"

# --- 5. up ---

log "docker compose pull…"
docker compose pull
log "docker compose up -d…"
docker compose up -d

sleep 3
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
