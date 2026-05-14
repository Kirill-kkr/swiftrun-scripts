# swiftrun-scripts

Утилиты развёртки нод [SwiftrunVPN](https://github.com/Kirill-kkr) на чистой Ubuntu/Debian VPS.

## `check-clean-ip.py` — комплексная проверка IP на пригодность к RU VPN

Прогоняет IP через **2 теста**:

1. **Whitelist** — попадает ли IP в community-список CIDR-блоков, которые
   остаются доступны на российских мобильных операторах в режиме restriction
   (когда оператор режет всё кроме разрешённых ресурсов — бывает регулярно).
   Источник: [hxehex/russia-mobile-internet-whitelist](https://github.com/hxehex/russia-mobile-internet-whitelist)
   (~30k CIDR + индивидуальные IP).

2. **TCP-reachability с RU** — через [check-host.net](https://check-host.net) API
   делает TCP-connect на `:443` (или другой порт) с 4-х нод в РФ (Москва/СПб/Екб).
   Показывает реальный пинг и достижимость с разных регионов.

### Использование

```bash
# Скачать и запустить одной командой
curl -fsSL https://raw.githubusercontent.com/Kirill-kkr/swiftrun-scripts/main/check-clean-ip.py | python3 - <IP>

# Или установить локально
curl -fsSL https://raw.githubusercontent.com/Kirill-kkr/swiftrun-scripts/main/check-clean-ip.py -o /usr/local/bin/check-clean-ip
chmod +x /usr/local/bin/check-clean-ip
check-clean-ip 87.240.190.78
```

Опции:

```bash
check-clean-ip <IP>                # все проверки
check-clean-ip --no-reach <IP>     # только whitelist (без пингов, мгновенно)
check-clean-ip --port 2087 <IP>    # другой порт для reachability check
check-clean-ip --update            # принудительное обновление кеша whitelist
```

### Пример вывода

```
Checking 87.240.190.78

1. RU mobile whitelist (hxehex)
   ✓ in whitelist  CIDR: 87.240.176.0/20

2. RU operator reachability (TCP :443 via check-host.net)
   ✓ ru1  Moscow           13ms
   ✓ ru2  Moscow           9ms
   ✓ ru3  Saint Petersburg 2ms
   ✓ ru4  Ekaterinburg     53ms

VERDICT: ✓ ALL CLEAN (5/5) — safe to use
```

### Verdicts

- **✓ ALL CLEAN** — IP в whitelist + достижим из РФ → можно ставить ноду
- **⚠ PARTIAL** — достижим, но не в whitelist → будет работать пока оператор не введёт restriction mode
- **✗ DIRTY** — ничего не работает → менять IP

### Exit codes

- `0` — all checks pass
- `1` — partial / fail
- `2` — invalid IP

### Workflow покупки чистого IP

1. Заказываешь VPS у RU-хостера (Timeweb, FirstByte, Aeza, ihor.ru, Hostkey, VK Cloud, и т.п.)
2. Получаешь public IP
3. `check-clean-ip <IP>` — если `ALL CLEAN` → берёшь
4. Если `PARTIAL` или `DIRTY` → пишешь в тикет "поменять IP" (50-100₽), пробуешь снова
5. После подтверждения чистоты IP — запускаешь `setup-node.sh` для установки Remnawave-Node

### Внимание

- Whitelist собирается community, не официальный — точность зависит от свежести
  репорта по конкретному оператору/региону
- Идеальная проверка — `nc -zw3 IP 443` с **симки целевого оператора в нужном
  регионе**. check-host.net проверяет с datacenter-нод, а не с мобильных
  операторов — DPI блок мобильных может не отлавливаться
- Whitelist меняется — IP может быть в списке сегодня, выпасть завтра.
  Держи 2-3 VPS у разных хостеров для резерва

---

## `rotate-yc-ip.sh` — ротация IP в Yandex Cloud до чистого

Крутит stop/start виртуалки в **твоём** Yandex Cloud через **локальный `yc` CLI**,
пока IP не попадёт в RU mobile whitelist.

Никаких сторонних ботов и третьих лиц. Скрипт обращается к YC API только через
`yc` CLI, который ты сам авторизовал командой `yc init`. Все credentials остаются
на твоей машине.

### Требования

- [Yandex Cloud CLI](https://yandex.cloud/docs/cli/quickstart) — `yc`
- `python3`, `jq`, `curl`
- Авторизация: `yc init` (один раз)

```bash
# Install yc CLI (macOS / Linux)
curl -sSL https://storage.yandexcloud.net/yandexcloud-yc/install.sh | bash
yc init
```

### Использование

```bash
# Скачать и запустить одной командой
curl -fsSL https://raw.githubusercontent.com/Kirill-kkr/swiftrun-scripts/main/rotate-yc-ip.sh \
  | bash -s -- <vm-name>

# Или установить локально
curl -fsSL https://raw.githubusercontent.com/Kirill-kkr/swiftrun-scripts/main/rotate-yc-ip.sh \
  -o /usr/local/bin/rotate-yc-ip
chmod +x /usr/local/bin/rotate-yc-ip

rotate-yc-ip swiftrun-node-1           # до 20 попыток
rotate-yc-ip swiftrun-node-1 50        # до 50 попыток
```

### Что делает

1. Останавливает VM
2. Запускает её снова (получает новый динамический public IP)
3. Достаёт IP через `yc compute instance get ... --format json`
4. Проверяет через `check-clean-ip.py --no-reach` (whitelist match)
5. Если в whitelist → ✓ готово, печатает IP и следующие шаги
6. Если нет → возвращается к п.1

### Воркфлоу

```bash
# 1. Создай минимальную VM в Yandex Cloud (через console.yandex.cloud)
#    параметры: 2 vCPU / 2 GB / 30 GB / ubuntu-2204-lts / zone ru-central1-a

# 2. Возьми её имя (например swiftrun-node-1) и запусти ротатор:
rotate-yc-ip swiftrun-node-1 30

# 3. Когда ✓ FOUND CLEAN IP — проверь полным чеком:
check-clean-ip <IP>

# 4. Если ALL CLEAN — поставь ноду:
ssh ubuntu@<IP>
sudo bash <(curl -fsSL https://raw.githubusercontent.com/Kirill-kkr/swiftrun-scripts/main/setup-node.sh)
```

### Альтернатива — `@hunter_yasha_bot`

В Telegram есть бот **`@hunter_yasha_bot`** — делает ровно то же, но **за тебя** на их инфраструктуре.

- **Плюс**: не надо самому крутить, готовый IP за минуты
- **Плюс**: 500₽ за каждый найденный (первый — бесплатно бонусом)
- **Минус**: требует загрузить JSON-ключ сервисного аккаунта твоего YC — полный доступ к твоему облаку

Если параноишь насчёт credentials третьим лицам — используй этот скрипт.
Если время дороже денег — `@hunter_yasha_bot`.

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
curl -fsSL https://raw.githubusercontent.com/Kirill-kkr/swiftrun-scripts/main/setup-node.sh -o /tmp/setup-node.sh
sudo bash /tmp/setup-node.sh
```

Скрипт покажет banner и попросит вставить docker-compose.yml из Шага 1.
Завершить ввод — `Ctrl+D` на пустой строке.

**Альтернатива одной командой через pipe:**

```bash
curl -fsSL https://raw.githubusercontent.com/Kirill-kkr/swiftrun-scripts/main/setup-node.sh | sudo bash
```

⚠️ Pipe-способ **может тормозить или висеть** на некоторых системах из-за
особенностей буферизации `sudo` + bash. Двухшаговый способ выше — надёжнее.

**Если у тебя уже сохранён compose-файл** (Ansible / CI / переустановка):

```bash
sudo bash /tmp/setup-node.sh --compose-file /path/to/compose.yml
```

⚠️ **НЕ ИСПОЛЬЗУЙ** `sudo bash <(curl ...)` — sudo не наследует `/dev/fd`
из подпроцесса, получишь ошибку `/dev/fd/63: No such file or directory`.

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
