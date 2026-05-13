#!/usr/bin/env bash
#
# rotate-yc-ip.sh — крутит stop/start виртуалки в Yandex Cloud
# пока её динамический IP не попадёт в RU mobile whitelist
# (hxehex/russia-mobile-internet-whitelist).
#
# Требует: yc CLI (https://yandex.cloud/docs/cli/quickstart), python3, jq.
# Авторизация: yc init (один раз).
#
# Безопасность: всё крутится локально, никаких третьих лиц.
# Скрипт обращается к Yandex Cloud API только через твой `yc` CLI.
#
# Использование:
#   ./rotate-yc-ip.sh <vm-name> [max-attempts]
#
#   ./rotate-yc-ip.sh swiftrun-node-1            # до 20 попыток (default)
#   ./rotate-yc-ip.sh swiftrun-node-1 50         # до 50 попыток
#
# Exit:
#   0 — нашли чистый IP
#   1 — лимит исчерпан, чистого нет
#   2 — ошибка конфига (нет yc / нет VM / etc)

set -euo pipefail

VM_NAME="${1:?Usage: $0 <vm-name> [max-attempts]}"
MAX_ATTEMPTS="${2:-20}"

# === Цвета ===
GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; BLUE='\033[34m'; DIM='\033[2m'; RESET='\033[0m'

# === Sanity checks ===
command -v yc >/dev/null || { echo -e "${RED}✗ yc CLI не установлен${RESET}"; echo "  Install: curl -sSL https://storage.yandexcloud.net/yandexcloud-yc/install.sh | bash"; exit 2; }
command -v jq >/dev/null || { echo -e "${RED}✗ jq не установлен${RESET}"; echo "  brew install jq  (Mac)  /  apt install jq  (Linux)"; exit 2; }
command -v python3 >/dev/null || { echo -e "${RED}✗ python3 не установлен${RESET}"; exit 2; }

# Скачаем check-clean-ip если его нет
CHECKER="${HOME}/.cache/swiftrun-clean-ip/check-clean-ip.py"
if [ ! -x "$CHECKER" ]; then
    mkdir -p "$(dirname "$CHECKER")"
    echo -e "${DIM}fetching check-clean-ip.py…${RESET}"
    curl -fsSL https://raw.githubusercontent.com/Kirill-kkr/swiftrun-scripts/main/check-clean-ip.py -o "$CHECKER"
    chmod +x "$CHECKER"
fi

# Проверим что VM существует
if ! yc compute instance get "$VM_NAME" >/dev/null 2>&1; then
    echo -e "${RED}✗ VM '$VM_NAME' не найдена в текущем cloud/folder${RESET}"
    echo "  Список VM:  yc compute instance list"
    exit 2
fi

get_ip() {
    yc compute instance get "$VM_NAME" --format json \
        | jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address // empty'
}

get_status() {
    yc compute instance get "$VM_NAME" --format json | jq -r '.status'
}

echo -e "${BLUE}=== Yandex Cloud IP rotator ===${RESET}"
echo -e "VM:           $VM_NAME"
echo -e "Max attempts: $MAX_ATTEMPTS"
echo

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    echo -e "${BLUE}[$attempt/$MAX_ATTEMPTS]${RESET} stop → start → check"

    # Останавливаем (если уже остановлена — skip)
    STATUS=$(get_status)
    if [ "$STATUS" = "RUNNING" ]; then
        yc compute instance stop "$VM_NAME" >/dev/null
        echo -e "  ${DIM}stopped${RESET}"
    fi

    yc compute instance start "$VM_NAME" >/dev/null
    echo -e "  ${DIM}started${RESET}"

    # Подождём пока IP появится
    IP=""
    for _ in $(seq 1 15); do
        sleep 2
        IP=$(get_ip || true)
        [ -n "$IP" ] && break
    done

    if [ -z "$IP" ]; then
        echo -e "  ${YELLOW}⚠ IP не получен, retry${RESET}"
        continue
    fi

    echo -e "  IP: ${BLUE}$IP${RESET}"

    # Проверка через check-clean-ip (только whitelist, без reachability — быстрее)
    if "$CHECKER" --no-reach "$IP" >/dev/null 2>&1; then
        echo
        echo -e "${GREEN}✓ FOUND CLEAN IP: $IP${RESET}"
        echo
        echo -e "${DIM}Now run full check:${RESET}"
        echo -e "  $CHECKER $IP"
        echo
        echo -e "${DIM}If ALL CLEAN — provision the node:${RESET}"
        echo -e "  ssh ubuntu@$IP"
        echo -e "  sudo bash <(curl -fsSL https://raw.githubusercontent.com/Kirill-kkr/swiftrun-scripts/main/setup-node.sh)"
        exit 0
    fi

    echo -e "  ${RED}✗ not in whitelist${RESET}"
done

echo
echo -e "${RED}✗ исчерпали $MAX_ATTEMPTS попыток, чистого IP не нашли${RESET}"
echo
echo "Стратегии дальше:"
echo "  1. Запусти ещё раз — пул IP большой, может повезти"
echo "  2. Создай VM в другой зоне (ru-central1-b / -d) — другой пул IP"
echo "  3. Купи 1 IP через @hunter_yasha_bot за 500₽ если время дороже денег"
exit 1
