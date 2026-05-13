# swiftrun-scripts

Утилиты развёртки нод [SwiftrunVPN](https://github.com/Kirill-kkr) на чистой Ubuntu/Debian VPS.

## `check-clean-ip.py` — проверка IP на RU mobile whitelist

Проверяет попадает ли IP VPS в список CIDR-блоков, которые **остаются доступны**
на российских мобильных операторах в режиме whitelist (когда оператор режет
всё кроме разрешённых ресурсов — это бывает регулярно при ЧП).

Источник: [hxehex/russia-mobile-internet-whitelist](https://github.com/hxehex/russia-mobile-internet-whitelist)
— community-maintained список из ~30k CIDR-блоков и индивидуальных IP, попавших
в "белые" списки операторов.

### Использование

```bash
# Скачать и запустить одной командой
curl -fsSL https://raw.githubusercontent.com/Kirill-kkr/swiftrun-scripts/main/check-clean-ip.py | python3 - <IP>

# Или установить локально
curl -fsSL https://raw.githubusercontent.com/Kirill-kkr/swiftrun-scripts/main/check-clean-ip.py -o /usr/local/bin/check-clean-ip
chmod +x /usr/local/bin/check-clean-ip
check-clean-ip 87.240.190.78
```

### Поведение

- Скачивает свежий список и кеширует на 24 часа в `~/.cache/swiftrun-clean-ip/`
- Проверяет IP сначала по `ipwhitelist.txt` (точное совпадение), потом по `cidrwhitelist.txt`
- **Exit codes**:
  - `0` — IP в whitelist (✓ зелёный)
  - `1` — IP вне whitelist (✗ красный)
  - `2` — невалидный IP

### Workflow покупки чистой VPS

1. Заказываешь VPS у RU-хостера (Timeweb, FirstByte, Aeza, ihor.ru, Hostkey и т.п.)
2. Получаешь public IP
3. Прогоняешь `check-clean-ip <IP>` — если `✓ WHITELISTED` → берёшь
4. Если `✗` → просишь хостера сменить IP (большинство делает за 50-100₽) и проверяешь снова
5. После подтверждения чистоты IP — запускаешь `setup-node.sh` для установки Remnawave-Node

### Принудительное обновление кеша

```bash
check-clean-ip --update
```

### Внимание

- Список whitelist собирается community, не официальный — точность зависит от свежести
  репорта по конкретному оператору/региону
- В реальности после whitelist-check желательно ещё прогнать `nc -zw3 IP 443` с симки
  целевого оператора в нужном регионе чтобы убедиться что IP реально проходит
- Whitelist меняется операторами — IP может быть в списке сегодня, но завтра вылететь.
  Имей запас в виде 2-3 VPS у разных хостеров.

---

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
