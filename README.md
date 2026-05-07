# swiftrun-scripts

Утилиты развёртки нод [SwiftrunVPN](https://github.com/Kirill-kkr) на чистой Ubuntu/Debian VPS.

## `setup-node.sh` — Remnawave-Node

Поднимает [Remnawave-Node](https://github.com/remnawave/node) на свежей VPS:
устанавливает Docker, создаёт `/opt/remnanode/`, принимает docker-compose.yml
от оператора (он генерируется в Remnawave admin UI с embedded SECRET_KEY +
mTLS-сертификатом), запускает контейнер.

### Использование

**Шаг 1** — в Remnawave admin UI:
- Nodes → Management → **+ Add Node**
- Указать имя ноды (например `nl-1`, `fi-1`), public IP/hostname VPS, port
  (по умолчанию `2222`)
- Скопировать сгенерированный `docker-compose.yml` кнопкой **Copy**

**Шаг 2** — на VPS под `root` (или через `sudo`):

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/Kirill-kkr/swiftrun-scripts/main/setup-node.sh)
```

Скрипт попросит вставить docker-compose.yml из Шага 1. Завершить ввод — `Ctrl+D`
на пустой строке.

**Альтернатива** с предзаписанным файлом (если нужно автоматизировать через
Ansible / для CI):

```bash
# Сохранить docker-compose.yml на VPS любым способом (scp, через секрет-стор и т.п.)
curl -fsSL https://raw.githubusercontent.com/Kirill-kkr/swiftrun-scripts/main/setup-node.sh -o /tmp/setup-node.sh
sudo bash /tmp/setup-node.sh --compose-file /path/to/compose.yml
```

### Что скрипт делает

1. Проверяет что запущен под root.
2. Ставит Docker через `get.docker.com` (если ещё не установлен; повторный запуск skip-ает).
3. Создаёт `/opt/remnanode/` и сохраняет docker-compose.yml туда с `chmod 600`.
4. Sanity-checks: проверяет что в compose есть `image: remnawave/node` и `SECRET_KEY`.
5. `docker compose pull && up -d`, показывает статус.
6. Подсказывает ufw-команды для firewall (открыть NODE_PORT только для IP панели).

### Идемпотентность

Повторный запуск:
- Не переустанавливает Docker, если уже стоит.
- Если `/opt/remnanode/docker-compose.yml` уже существует — переподнимает существующий
  стек (для apply изменений в compose).
- Чтобы пересоздать ноду с нуля:
  ```bash
  cd /opt/remnanode && docker compose down -v
  sudo rm -rf /opt/remnanode
  # затем заново скрипт
  ```

### Безопасность

- `docker-compose.yml` содержит SECRET_KEY (mTLS-секрет ноды) — chmod 600 после
  записи.
- Скрипт **никогда** не принимает SECRET_KEY через CLI-аргумент. Только stdin или
  `--compose-file <path>`. Это закрывает class of leaks через `ps -ef` и shell
  history (проблема предыдущей Marzban-эпохи скрипта, где admin-пароль панели
  передавался через `--panel-pass`).
- Установка Docker через `curl | sh` — это официальный путь от docker.com;
  если хочешь более параноидальный — установи Docker заранее и скрипт пропустит
  этот шаг.

### Firewall

После старта ноды:

```bash
# Открыть :443 для входящего VLESS REALITY трафика (он публичный)
sudo ufw allow 443/tcp

# Открыть NODE_PORT (по умолчанию 2222) ТОЛЬКО для IP панели
sudo ufw allow from <PANEL_IP> to any port 2222 proto tcp
sudo ufw deny in 2222/tcp
```

### Дополнительные шаги

Скрипты развёртки **самой панели** (Remnawave panel + Caddy reverse proxy)
лежат в основном репо `swiftrun-bot/deploy/remnawave/` (приватный) — они нужны
только на одной центральной VPS, поэтому в публичный репо не вынесены.

Установка панели по официальной документации Remnawave:
https://docs.rw/docs/install/remnawave-panel
