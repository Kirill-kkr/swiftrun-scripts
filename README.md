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

## `setup-node.sh` — установка + оптимизация + защита Remnawave-Node

Полный комбайн для свежей VPS — 7 шагов одним скриптом:

1. **Docker** + compose plugin
2. **BBR + TCP tuning + Anti-DDoS sysctl** — прирост throughput 10-30%, защита от SYN flood / port scan / spoofing
3. **UFW firewall** — `:443` публично, `:NODE_PORT` только для IP панели, SSH rate-limited, остальное deny
4. **Fail2ban** — защита SSH от brute-force (3 попытки/10 мин → бан на 24ч)
5. **SSH hardening** (опционально) — создание non-root admin-юзера + отключение root SSH + password auth
6. **`/opt/remnanode/`** + docker-compose.yml (с embedded SECRET_KEY от Remnawave admin)
7. **`docker compose up -d`** — запуск ноды

Полностью идемпотентен — повторный запуск пропускает уже сделанное.

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

Скрипт покажет banner и пошагово:
1. Поставит Docker (если нет)
2. Применит BBR + TCP tuning
3. Спросит IP панели и настроит UFW
4. Поставит fail2ban
5. Попросит вставить docker-compose.yml (Ctrl+D в конце)
6. Запустит ноду

**Сразу с IP панели** (избегает интерактивного вопроса):

```bash
sudo bash /tmp/setup-node.sh --panel-ip 1.2.3.4
```

**SSH hardening** — отдельно (опционально, скрипт спросит интерактивно):

```bash
sudo bash /tmp/setup-node.sh \
  --harden-ssh \
  --admin-user kirill \
  --admin-ssh-key "$(cat ~/.ssh/id_ed25519.pub)"
```

Или передай путь к файлу:
```bash
sudo bash /tmp/setup-node.sh --harden-ssh --admin-user kirill --admin-ssh-key /tmp/key.pub
```

Скрипт:
1. Создаст non-root юзера `kirill` с переданным SSH-ключом
2. Добавит его в группу sudo (sudo без пароля, т.к. password auth отключится)
3. Спросит подтверждение что ты проверил вход новым юзером
4. **После твоего "y"** — отключит root SSH login и password auth

⚠️ **Перед подтверждением — ОБЯЗАТЕЛЬНО проверь в другом терминале:**
```bash
ssh kirill@<VPS_IP>
sudo whoami    # должно вывести: root
```

Если SSH ключ был передан с опечаткой и `ssh kirill@...` не пускает — НЕ подтверждай отключение root. Иначе остаёшься без доступа.

**Пропустить отдельные этапы:**

| Флаг | Что пропустит |
|---|---|
| `--skip-tuning` | sysctl/BBR/anti-DDoS настройки |
| `--skip-firewall` | UFW |
| `--skip-fail2ban` | fail2ban |
| `--compose-file <path>` | Не спрашивать compose интерактивно |
| `--harden-ssh` | Принудительно делать SSH hardening (по умолчанию спрашивает) |

Например, обновить только firewall с новым IP панели:

```bash
sudo bash /tmp/setup-node.sh --panel-ip <NEW_IP> --skip-tuning --skip-fail2ban
```

**Альтернатива одной командой через pipe:**

```bash
curl -fsSL https://raw.githubusercontent.com/Kirill-kkr/swiftrun-scripts/main/setup-node.sh | sudo bash
```

⚠️ Pipe-способ **может тормозить или висеть** на некоторых системах из-за
особенностей буферизации `sudo` + bash. Двухшаговый способ выше — надёжнее.

⚠️ **НЕ ИСПОЛЬЗУЙ** `sudo bash <(curl ...)` — sudo не наследует `/dev/fd`
из подпроцесса, получишь ошибку `/dev/fd/63: No such file or directory`.

### Что даёт BBR + TCP tuning

- **BBR** (Bottleneck Bandwidth and RTT) — современный congestion control от Google.
  Заменяет старый CUBIC. Прирост throughput на международных маршрутах:
  - С Hetzner Германия → RU: +20-30%
  - С Aeza Москва → RU: +5-10%
- **Cake qdisc** (или fq fallback) — умный qdisc с anti-bufferbloat + AQM + fair queueing.
  Снижает latency под нагрузкой. Если sch_cake модуль не доступен (старое
  ядро) — скрипт автоматически откатится на fq. На современных VPS (Hetzner,
  Aeza, etc) cake доступен из коробки.
- **TCP Fast Open** — экономит 1 RTT на каждом новом соединении
- **Conntrack table** = 524k — поддержка до 100k одновременных VPN-сессий
- **TCP buffers 64 MiB** — для high-bandwidth gigabit links

Проверить что BBR работает после запуска:

```bash
ss -tin | grep bbr | head -5
sysctl net.ipv4.tcp_congestion_control
```

### Anti-DDoS / kernel hardening

Скрипт применяет защитные sysctl-параметры:

| Параметр | Защита от |
|---|---|
| `tcp_syncookies = 1` | SYN flood — резервная защита когда SYN-queue переполнен |
| `tcp_max_syn_backlog = 8192` | SYN queue — больше pending connections |
| `tcp_rfc1337 = 1` | TIME_WAIT assassination attacks |
| `rp_filter = 1` | Spoofed packets (поддельный src IP) |
| `accept_source_route = 0` | Source routing attacks |
| `accept_redirects = 0` | ICMP redirects (man-in-the-middle) |
| `icmp_echo_ignore_broadcasts = 1` | Smurf attacks |
| `icmp_ratelimit = 100` | Ping flood |
| `log_martians = 1` | Логируем подозрительные пакеты |

SSH-порт 22 открыт через простой `ufw allow` (без `limit`). От brute-force
защищает fail2ban (3 fail попытки/10 мин → бан на 24ч). `ufw limit` отключён
намеренно — он может блокировать легитимные сценарии типа tmux-reconnect
или ansible параллельных подключений.

### Что даёт Fail2ban

Защищает только **SSH** (порт 22). VPN-трафик на :443 не трогается —
там тысячи юзеров с разных IP, бан был бы вреден.

После 3 неудачных попыток SSH с одного IP за 10 минут — бан на 24 часа:

```bash
fail2ban-client status sshd       # сколько IP забанено
fail2ban-client unban <IP>        # разбанить вручную если случайно
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
