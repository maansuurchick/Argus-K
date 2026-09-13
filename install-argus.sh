#!/bin/sh
# install-argus.sh — интерактивная настройка /opt/etc/argus-k.sh
FILE=/opt/etc/argus-k.sh

if [ ! -f "$FILE" ]; then
    echo "ОШИБКА: $FILE не найден."
    exit 1
fi

is_filled() { [ -n "$1" ] && ! echo "$1" | grep -q "ВСТАВЬТЕ_"; }
is_url() { echo "$1" | grep -qE '^https?://[^ ]+$'; }
is_tg_token() { echo "$1" | grep -qE '^[0-9]{8,12}:[A-Za-z0-9_-]{30,}$'; }
is_tg_chat_ids() { echo "$1" | grep -qE '^-?[0-9]+( +-?[0-9]+)*$'; }

sed_escape_repl() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/&/\\&/g' -e 's/|/\\|/g'
}

HAPP_VERSION_FIXED="4.3.0"

is_lan_iface() {
    case "$1" in
        br0|br1|br-lan|br-guest|lo|ezcfg0|bond0) return 0 ;;
        *) return 1 ;;
    esac
}

detect_wan_if() {
    local rt
    rt=$(ip route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
    if [ -n "$rt" ] && ! is_lan_iface "$rt"; then
        echo "$rt"
        return 0
    fi
    local iface
    for iface in lte_br0 lte0 lte1 usb0 usb1 usb2 wwan0 wwan1 ppp0 eth3 eth2.2 nwg0 nwg1; do
        if ! is_lan_iface "$iface" && ip -4 addr show dev "$iface" 2>/dev/null | grep -q "inet "; then
            echo "$iface"
            return 0
        fi
    done
    return 1
}

list_wan_candidates() {
    ip -4 -o addr show 2>/dev/null \
        | awk '$2 != "lo" && $2 != "br0" && $2 != "br1" && $2 != "br-lan" && $2 != "ezcfg0" {print $2}' \
        | sort -u
}

detect_wan_ip() {
    local iface="$1"
    [ -z "$iface" ] && return 1
    ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1
}

detect_wan_gateway() {
    local iface="$1"
    [ -z "$iface" ] && return 1
    ip route show dev "$iface" 2>/dev/null | awk '/default/ {print $3; exit}'
}

detect_lan_settings() {
    local bridge
    for bridge in br0 br1 br-lan; do
        local cidr
        cidr=$(ip -4 addr show dev "$bridge" 2>/dev/null | awk '/inet / {print $2; exit}')
        if [ -n "$cidr" ]; then
            local ip="${cidr%/*}"
            local prefix="${cidr#*/}"
            local net
            if [ "$prefix" = "24" ]; then
                net="$(echo "$ip" | cut -d. -f1-3).0/24"
            else
                net="$cidr"
            fi
            echo "$net|$ip"
            return 0
        fi
    done
    return 1
}

detect_existing_tg_tunnel() {
    local found=""
    if command -v ipset >/dev/null 2>&1; then
        local sets
        sets=$(ipset list -n 2>/dev/null | grep -iE 'telegram|^tg|_tg_')
        [ -n "$sets" ] && found="$found
    ipset: $(echo "$sets" | tr '\n' ' ')"
    fi
    if command -v iptables >/dev/null 2>&1; then
        local hit
        hit=$(iptables -t nat -S 2>/dev/null | grep -iE 'telegram|TG_|_TG|XRAY_TG' | grep -viE 'XRAY_TG')
        [ -n "$hit" ] && found="$found
    iptables: $(echo "$hit" | head -1 | cut -c1-90)"
    fi
    local pat proc
    for pat in 'z2k' 'z4r' 'sing-box' 'tg-tunnel' 'telegram-proxy' 'mtg' 'mtproto'; do
        proc=$(ps 2>/dev/null | grep -v grep | grep -iE "$pat" | head -1)
        if [ -n "$proc" ]; then
            found="$found
    процесс: $(echo "$proc" | awk '{for(i=5;i<=NF;i++) printf "%s ", $i; print ""}' | cut -c1-70)"
            break
        fi
    done
    [ -n "$found" ] && { echo "$found"; return 0; }
    return 1
}

clear 2>/dev/null || true
echo "============================================================"
echo "  ШАГ 0. УСТАНОВКА ЗАВИСИМОСТЕЙ"
echo "============================================================"
echo ""

if ! mount 2>/dev/null | grep -q " /opt "; then
    echo "Каталог /opt не смонтирован."
    exit 1
fi

for pkg_cmd in "jq:jq" "curl:curl" "ipset:ipset"; do
    pkg="${pkg_cmd%%:*}"
    cmd="${pkg_cmd##*:}"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        opkg update >/dev/null 2>&1 || true
        opkg install "$pkg" >/dev/null 2>&1 || true
    fi
    command -v "$cmd" >/dev/null 2>&1 && echo "OK $cmd" || echo "MISS $cmd"
done

if ! command -v xray >/dev/null 2>&1 && [ ! -x /opt/sbin/xray ]; then
    opkg install xray >/dev/null 2>&1 || true
fi
command -v xray >/dev/null 2>&1 || [ -x /opt/sbin/xray ] && echo "OK Xray"

mkdir -p /opt/etc/xray/configs /opt/var/log/xray
echo ""
printf "Нажмите Enter для продолжения..."
read DUMMY

clear 2>/dev/null || true
cat << 'HELP'
============================================================
   ШАГ 0.5. ОПРЕДЕЛЕНИЕ СЕТЕВЫХ ПАРАМЕТРОВ
============================================================
Скрипт определит:
  - WAN-интерфейс (через который роутер смотрит в интернет);
  - адрес локальной сети (LAN);
  - IP роутера в локальной сети.

Если определится неверно — можно переопределить вручную.
============================================================
HELP
echo ""

DETECTED_WAN=$(detect_wan_if || true)
WAN_CANDIDATES=$(list_wan_candidates)

echo "Найдены интерфейсы с IPv4:"
i=0
for iface in $WAN_CANDIDATES; do
    i=$((i+1))
    addr=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}')
    marker=""
    [ "$iface" = "$DETECTED_WAN" ] && marker=" <- предлагаю"
    printf "  %2d) %-14s %s%s\n" "$i" "$iface" "$addr" "$marker"
done
echo ""
printf "WAN-интерфейс [%s] (имя или номер из списка): " "${DETECTED_WAN:-не определён}"
read INPUT_WAN

if [ -z "$INPUT_WAN" ]; then
    if [ -n "$DETECTED_WAN" ]; then
        WAN_IF="$DETECTED_WAN"
    else
        echo "WAN-интерфейс не определён и не указан."
        exit 1
    fi
elif echo "$INPUT_WAN" | grep -qE '^[0-9]+$'; then
    PICKED=$(echo "$WAN_CANDIDATES" | sed -n "${INPUT_WAN}p")
    if [ -z "$PICKED" ]; then
        echo "Номера $INPUT_WAN нет в списке."
        exit 1
    fi
    WAN_IF="$PICKED"
    echo "  по номеру $INPUT_WAN -> $WAN_IF"
else
    WAN_IF="$INPUT_WAN"
fi

WAN_IF_IP=$(detect_wan_ip "$WAN_IF" || true)
WAN_IF_GW=$(detect_wan_gateway "$WAN_IF" || true)

if [ -n "$WAN_IF_IP" ]; then
    echo "WAN_IF = $WAN_IF ($WAN_IF_IP)"
    [ -n "$WAN_IF_GW" ] && echo "  шлюз оператора: $WAN_IF_GW"
else
    echo "WAN_IF = $WAN_IF (IPv4 сейчас не виден — норма для некоторых LTE-режимов)"
fi
echo ""

DETECTED_LAN=$(detect_lan_settings || true)
DETECTED_LAN_NET="${DETECTED_LAN%%|*}"
DETECTED_LAN_IP="${DETECTED_LAN##*|}"

if [ -n "$DETECTED_LAN_NET" ] && [ "$DETECTED_LAN" != "$DETECTED_LAN_NET" ]; then
    echo "Локальная сеть: $DETECTED_LAN_NET"
    echo "IP роутера в LAN: $DETECTED_LAN_IP"
    printf "Использовать эти значения? (Y/n): "
    read OK_LAN
    case "$OK_LAN" in
        n|N|no|NO)
            printf "Локальная сеть [%s]: " "$DETECTED_LAN_NET"
            read INPUT_LAN
            LOCAL_NET="${INPUT_LAN:-$DETECTED_LAN_NET}"
            printf "IP роутера [%s]: " "$DETECTED_LAN_IP"
            read INPUT_IP
            ROUTER_IP="${INPUT_IP:-$DETECTED_LAN_IP}"
            ;;
        *)
            LOCAL_NET="$DETECTED_LAN_NET"
            ROUTER_IP="$DETECTED_LAN_IP"
            ;;
    esac
else
    echo "Не удалось определить LAN автоматически (br0/br1 не найден)."
    printf "Локальная сеть (напр. 192.168.1.0/24): "
    read LOCAL_NET
    printf "IP роутера в LAN (напр. 192.168.1.1): "
    read ROUTER_IP
fi
echo "LOCAL_NET = $LOCAL_NET"
echo "ROUTER_IP = $ROUTER_IP"
echo ""
printf "Нажмите Enter для продолжения..."
read DUMMY

clear 2>/dev/null || true
cat << 'HELP'
============================================================
   ШАГ 1. ССЫЛКА НА ПОДПИСКУ
============================================================
Если вы знаете ссылку на свою подписку — вставьте её сейчас.

Если не знаете — откройте приложение Happ:
  1. Найдите свою подписку на главном экране.
  2. Нажмите «три точки» рядом с подпиской.
  3. Выберите «Редактировать» (или «Edit»).
  4. Скопируйте URL из поля — это и есть ссылка.
============================================================
HELP

while true; do
    printf "Ссылка на подписку: "
    read SUB_URL
    if ! is_filled "$SUB_URL"; then
        echo "Пусто. Попробуйте снова."
        continue
    fi
    if ! is_url "$SUB_URL"; then
        echo "Это не похоже на URL (должно начинаться с http:// или https://)."
        printf "Всё равно использовать? (y/N): "
        read OK
        case "$OK" in
            y|Y|yes|YES) break ;;
            *) continue ;;
        esac
    fi
    break
done
echo ""

clear 2>/dev/null || true
cat << 'HELP'
============================================================
   ШАГ 2. ДАННЫЕ УСТРОЙСТВА
============================================================
Чтобы роутер не занял НОВЫЙ слот в подписке, а имитировал
уже подключённый смартфон, нужно указать те же данные,
что отправляет Happ с вашего телефона.

Если подписка без лимита устройств — можно пропустить
эти поля, значения сгенерируются автоматически.
============================================================
HELP
printf "Нажмите Enter, чтобы продолжить..."
read DUMMY
echo ""

cat << 'HELP'
------------------------------------------------------------
2.1 HWID (идентификатор устройства)
------------------------------------------------------------
Строка из 16 символов (hex).
Где посмотреть:
  1. Личный кабинет VPN-провайдера -> «Устройства»
     (ищите «HWID» или «Device ID»).
  2. Приложение Happ -> Настройки -> Информация.
  3. Поддержка провайдера.
Если не нашли — нажмите Enter, значение сгенерируется.
ВНИМАНИЕ: случайный HWID может занять новый слот в подписке!
------------------------------------------------------------
HELP
printf "HWID (Enter — сгенерировать): "
read HWID
if [ -z "$HWID" ]; then
    HWID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-')
    echo "  сгенерирован: $HWID"
    echo "  ВНИМАНИЕ: может занять новый слот в подписке"
fi
echo ""

cat << 'HELP'
------------------------------------------------------------
2.2 UA DEVICE ID
------------------------------------------------------------
Числовой ID устройства в строке User-Agent приложения Happ.
Полная строка выглядит так:
  Happ/4.3.0/Android/17877369741321921609
                       ^^^^^^^^^^^^^^^^^^ — это UA Device ID

Можно вставить всю строку целиком — Argus-K сам выделит
число после последнего слеша.

Где посмотреть:
  1. Личный кабинет провайдера -> «Устройства».
  2. Через mitmproxy — перехватить запрос Happ к подписке.
  3. Поддержка провайдера.
Если не нашли — нажмите Enter, значение сгенерируется.
ВНИМАНИЕ: случайный ID может занять новый слот в подписке!
------------------------------------------------------------
HELP
printf "UA Device ID или полная строка User-Agent: "
read UA_ID
if [ -z "$UA_ID" ]; then
    UA_ID=$(od -An -tu8 -N8 /dev/urandom 2>/dev/null | tr -d ' ')
    echo "  сгенерирован: $UA_ID"
    echo "  ВНИМАНИЕ: может занять новый слот в подписке"
elif echo "$UA_ID" | grep -q '/'; then
    PARSED=$(printf '%s' "$UA_ID" | sed 's|.*/||')
    if echo "$PARSED" | grep -qE '^[0-9]+$'; then
        echo "  распознан UA Device ID: $PARSED"
        UA_ID="$PARSED"
    else
        echo "  не удалось выделить число после слеша."
        echo "  использую строку как есть (может не сработать)."
    fi
fi
echo ""

cat << 'HELP'
------------------------------------------------------------
2.3 МОДЕЛЬ УСТРОЙСТВА
------------------------------------------------------------
Модель вашего смартфона — провайдер может её проверять.
Где посмотреть:
  1. Телефон -> Настройки -> О телефоне -> Модель.
  2. Личный кабинет провайдера -> «Устройства».
Если не знаете — нажмите Enter, будет «Android Device».
------------------------------------------------------------
HELP
printf "Модель устройства (Enter — Android Device): "
read DEVICE_MODEL
[ -z "$DEVICE_MODEL" ] && DEVICE_MODEL="Android Device"
echo ""

echo "============================================================"
echo "  ПРОВЕРКА ПОДПИСКИ"
echo "============================================================"
UA="Happ/$HAPP_VERSION_FIXED/Android/$UA_ID"
TMP_SUB="/tmp/argus_test_sub.$$"

HTTP_CODE=$(curl -s -L --compressed -o "$TMP_SUB" -w "%{http_code}" \
    -A "$UA" -H "X-HWID: $HWID" -H "X-Device-OS: Android" \
    -H "X-Device-Model: $DEVICE_MODEL" -H "X-Device-Locale: ru-RU" \
    --connect-timeout 15 --max-time 60 "$SUB_URL" 2>/dev/null)
CURL_RC=$?

echo "HTTP: $HTTP_CODE (curl rc=$CURL_RC)"
SUB_OK=0
SUB_MSG=""

if [ "$CURL_RC" -ne 0 ]; then
    SUB_MSG="Не удалось подключиться (curl rc=$CURL_RC)."
elif [ "$HTTP_CODE" != "200" ]; then
    SUB_MSG="Сервер вернул HTTP $HTTP_CODE."
elif [ ! -s "$TMP_SUB" ]; then
    SUB_MSG="Пустой ответ."
else
    SIZE=$(wc -c < "$TMP_SUB")
    FIRST=$(head -c 1 "$TMP_SUB" | tr -d '[:space:]')
    echo "Размер: $SIZE байт, первый символ: '$FIRST'"
    echo ""
    if [ "$FIRST" = "[" ] || [ "$FIRST" = "{" ]; then
        CNT=$(jq 'length' "$TMP_SUB" 2>/dev/null)
        if [ -n "$CNT" ] && [ "$CNT" -gt 0 ] 2>/dev/null; then
            echo "Найдено конфигов: $CNT"
            echo "Первые 5:"
            jq -r '.[0:5][] | "    - " + (.remarks // "(без названия)")' "$TMP_SUB" 2>/dev/null
            echo ""
            FIRST_UUID=$(jq -r '.[0].outbounds[]? | select(.protocol=="vless" or .protocol=="vmess") | .settings.vnext[0].users[0].id // empty' "$TMP_SUB" 2>/dev/null)
            if [ "$FIRST_UUID" = "00000000-0000-0000-0000-000000000000" ] || [ -z "$FIRST_UUID" ]; then
                SUB_MSG="Похоже на ЗАГЛУШКУ. Проверьте HWID и UA Device ID."
            else
                SUB_OK=1
                SUB_MSG="Подписка рабочая: $CNT конфигов."
            fi
        else
            SUB_MSG="JSON есть, но конфигов в нём нет."
        fi
    else
        SUB_MSG="Ответ не похож на JSON."
    fi
fi
rm -f "$TMP_SUB"
echo "$SUB_MSG"
echo ""

if [ "$SUB_OK" -eq 0 ]; then
    printf "Продолжить с этими данными? (y/N): "
    read GO
    case "$GO" in
        y|Y|yes|YES) ;;
        *) exit 1 ;;
    esac
fi

echo ""
clear 2>/dev/null || true
cat << 'HELP'
============================================================
   ШАГ 2.5. ТУННЕЛЬ ДЛЯ TELEGRAM
============================================================
Telegram блокируется оператором независимо от режима сети.

Argus-K умеет пускать трафик к Telegram через Xray всегда —
даже когда остальной интернет работает напрямую. Работает
это так: через VPN идут только IP-адреса Telegram, весь
остальной трафик не трогается.

ВАЖНО: два туннеля для Telegram одновременно работать
не будут — они конфликтуют между собой. Если у вас уже
настроен отдельный туннель (z2k, z4r, sing-box, mtg или
вручную) — оставьте его, Argus-K трогать не будет.
============================================================
HELP
echo ""

echo "Проверяю систему на существующий TG-туннель..."
DETECTED_TG=$(detect_existing_tg_tunnel || true)
DETECT_FOUND=0
if [ -n "$DETECTED_TG" ]; then
    DETECT_FOUND=1
    echo "Найдены признаки:"
    echo "$DETECTED_TG"
else
    echo "Признаков не найдено."
fi
echo ""

HAS_TG_TUNNEL=""
while true; do
    printf "У вас уже есть туннель для Telegram? (y/n): "
    read HAS_TG_TUNNEL
    case "$HAS_TG_TUNNEL" in
        y|Y|yes|YES|n|N|no|NO) break ;;
        *) echo "Ответьте y или n." ;;
    esac
done

case "$HAS_TG_TUNNEL" in
    y|Y|yes|YES)
        TG_TUNNEL_ENABLED="no"
        echo "Argus-K не будет трогать Telegram."
        ;;
    n|N|no|NO)
        if [ "$DETECT_FOUND" -eq 1 ]; then
            printf "Настроить туннель через Xray всё равно? (y/N): "
            read CONFLICT_OK
            case "$CONFLICT_OK" in
                y|Y|yes|YES) TG_TUNNEL_ENABLED="yes" ;;
                *) TG_TUNNEL_ENABLED="no" ;;
            esac
        else
            printf "Настроить туннель через Xray? (Y/n): "
            read WANT_TG_TUNNEL
            case "$WANT_TG_TUNNEL" in
                n|N|no|NO) TG_TUNNEL_ENABLED="no" ;;
                *) TG_TUNNEL_ENABLED="yes" ;;
            esac
        fi
        ;;
esac
echo ""

clear 2>/dev/null || true
cat << 'HELP'
============================================================
   ШАГ 2.6. SPLIT ROUTING ДЛЯ RU-ДОМЕНОВ
============================================================
Argus-K может добавить в скачанные из подписки конфиги
одно правило: домены из списка
/opt/etc/argus-k-split-domains.txt идут напрямую, а не
через VPN.

Зачем:
  - российские сервисы (Яндекс, VK, Ozon, госуслуги,
    банки) не любят, когда заходят с VPN-IP;
  - экономит трафик;
  - снижает нагрузку на туннель.

Если у вашей подписки УЖЕ есть свои domain-based
direct-правила — Argus-K их не тронет.
============================================================
HELP
printf "Добавлять RU-домены напрямую? (Y/n): "
read WANT_SPLIT
case "$WANT_SPLIT" in
    n|N|no|NO)
        SPLIT_ROUTING_ENABLED="no"
        echo "Split routing не будет добавляться."
        ;;
    *)
        SPLIT_ROUTING_ENABLED="yes"
        echo "Split routing будет добавлен в конфиги без своих direct-правил."
        echo "Список: /opt/etc/argus-k-split-domains.txt"
        echo "Дополнять можно вручную, изменения подхватятся при рестарте."
        ;;
esac
echo ""

clear 2>/dev/null || true
cat << 'HELP'
============================================================
   ШАГ 3. TELEGRAM-БОТ (ОПЦИОНАЛЬНО)
============================================================
Telegram-бот позволяет:
  - получать уведомления о смене режима;
  - переключать режимы командой (/on, /off, /auto);
  - смотреть статус (/status) и диагностику (/diag);
  - управлять конфигами (/next, /use, /configs).

Без бота скрипт тоже работает: тихо в фоне, сам определяет
white list и включает/выключает редирект.
============================================================
HELP
printf "Настроить Telegram-бота? (y/N): "
read WANT_TG

TG_TOKEN=""
TG_CHAT_IDS=""

case "$WANT_TG" in
    y|Y|yes|YES)
        echo ""
        cat << 'HELP'
------------------------------------------------------------
3.1 ТОКЕН БОТА
------------------------------------------------------------
Как получить:
  1. Откройте Telegram (через VPN, если заблокирован).
  2. Найдите @BotFather.
  3. Отправьте /newbot и следуйте инструкциям бота.
  4. Придумайте имя и username (должен оканчиваться на "bot").
  5. BotFather пришлёт токен вида:
       1234567890:ABCdefGHIjklMNOpqrSTUvwxYZ-1234567
------------------------------------------------------------
HELP
        while true; do
            printf "Токен: "
            read TG_TOKEN
            if ! is_filled "$TG_TOKEN"; then
                echo "Пусто."
                continue
            fi
            if is_tg_token "$TG_TOKEN"; then
                break
            fi
            printf "Формат не похож. Всё равно? (y/N): "
            read OK
            case "$OK" in y|Y|yes|YES) break ;; *) continue ;; esac
        done
        echo ""
        cat << 'HELP'
------------------------------------------------------------
3.2 CHAT ID
------------------------------------------------------------
Числовой ID пользователя (НЕ логин @username).
Как узнать:
  1. Найдите @userinfobot в Telegram.
  2. Отправьте ему любое сообщение.
  3. Он ответит вашим ID (например: 123456789).

Можно несколько ID через пробел.

ВАЖНО: каждый пользователь сначала должен написать
вашему боту /start, иначе Telegram не даст боту
отправить ему первое сообщение.
------------------------------------------------------------
HELP
        while true; do
            printf "Chat ID: "
            read TG_CHAT_IDS
            if ! is_filled "$TG_CHAT_IDS"; then
                echo "Пусто."
                continue
            fi
            if is_tg_chat_ids "$TG_CHAT_IDS"; then
                break
            fi
            printf "Не число. Всё равно? (y/N): "
            read OK
            case "$OK" in y|Y|yes|YES) break ;; *) continue ;; esac
        done
        ;;
    *)
        echo "Telegram не настраивается."
        ;;
esac

echo ""
clear 2>/dev/null || true
cat << 'MENU'
============================================================
   ШАГ 4. ОБХОДЧИК DPI (опционально)
============================================================
Если обходчик не установлен — выберите «нет».
Argus-K умеет синхронизировать состояние обходчика с
режимом прокси.

  1) Нет / не использую
  2) nfqws-keenetic               /opt/etc/init.d/S51nfqws
  3) nfqws2-keenetic              /opt/etc/init.d/S51nfqws2
  4) zapret (оригинальный bol-van) /opt/zapret/init.d/sysv/zapret
  5) z2k (модульный zapret2)      /opt/etc/init.d/S99zapret2
  6) b4 (DPI bypass)              /opt/etc/init.d/S99b4
  7) z4r (zapret4rocket)          /opt/etc/init.d/S90-zapret
  8) Другой — укажу путь вручную
============================================================
MENU

printf "Ваш выбор [1-8]: "
read Z2K_CHOICE

Z2K_TYPE="none"
Z2K_INIT=""

case "$Z2K_CHOICE" in
    1) Z2K_TYPE="none"; Z2K_INIT="" ;;
    2) Z2K_TYPE="nfqws";  Z2K_INIT="/opt/etc/init.d/S51nfqws" ;;
    3) Z2K_TYPE="nfqws2"; Z2K_INIT="/opt/etc/init.d/S51nfqws2" ;;
    4) Z2K_TYPE="zapret"; Z2K_INIT="/opt/zapret/init.d/sysv/zapret" ;;
    5) Z2K_TYPE="z2k";    Z2K_INIT="/opt/etc/init.d/S99zapret2" ;;
    6) Z2K_TYPE="b4";     Z2K_INIT="/opt/etc/init.d/S99b4" ;;
    7) Z2K_TYPE="z4r";    Z2K_INIT="/opt/etc/init.d/S90-zapret" ;;
    8)
        Z2K_TYPE="custom"
        printf "Укажите полный путь к init-скрипту обходчика: "
        read Z2K_INIT
        ;;
    *)
        echo "Неизвестный выбор, обходчик не будет управляться."
        Z2K_TYPE="none"; Z2K_INIT=""
        ;;
esac

if [ "$Z2K_TYPE" != "none" ] && [ -n "$Z2K_INIT" ]; then
    if [ ! -x "$Z2K_INIT" ]; then
        echo "Файл $Z2K_INIT не найден или не исполняемый."
        printf "Продолжить? (y/N): "
        read OK
        case "$OK" in
            y|Y|yes|YES) ;;
            *) Z2K_TYPE="none"; Z2K_INIT="" ;;
        esac
    else
        echo "Обходчик найден: $Z2K_INIT"
    fi
fi
echo ""

echo "============================================================"
echo "  ИТОГОВЫЕ ДАННЫЕ"
echo "============================================================"
echo "  WAN_IF            = $WAN_IF"
echo "  WAN_IF_IP         = ${WAN_IF_IP:-(нет IPv4)}"
echo "  LOCAL_NET         = $LOCAL_NET"
echo "  ROUTER_IP         = $ROUTER_IP"
echo "  SUB_URL           = $SUB_URL"
echo "  HAPP_HWID         = $HWID"
echo "  UA_DEVICE_ID      = $UA_ID"
echo "  DEVICE_MODEL      = $DEVICE_MODEL"
echo "  TG_TUNNEL         = $TG_TUNNEL_ENABLED"
echo "  SPLIT_ROUTING     = $SPLIT_ROUTING_ENABLED"
echo "  TG_TOKEN          = ${TG_TOKEN:-(не настроен)}"
echo "  TG_CHAT_IDS       = ${TG_CHAT_IDS:-(не настроены)}"
echo "  Z2K_TYPE          = $Z2K_TYPE"
echo "  Z2K_INIT          = ${Z2K_INIT:-(не используется)}"
echo ""
printf "Записать в конфиг? (y/N): "
read CONFIRM
case "$CONFIRM" in
    y|Y|yes|YES) ;;
    *) echo "Отменено."; exit 0 ;;
esac

ESC_TG_TOKEN=$(sed_escape_repl "$TG_TOKEN")
ESC_TG_CHAT_IDS=$(sed_escape_repl "$TG_CHAT_IDS")
ESC_SUB_URL=$(sed_escape_repl "$SUB_URL")
ESC_HWID=$(sed_escape_repl "$HWID")
ESC_HAPP_VERSION=$(sed_escape_repl "$HAPP_VERSION_FIXED")
ESC_UA_ID=$(sed_escape_repl "$UA_ID")
ESC_DEVICE_MODEL=$(sed_escape_repl "$DEVICE_MODEL")
ESC_Z2K_TYPE=$(sed_escape_repl "$Z2K_TYPE")
ESC_Z2K_INIT=$(sed_escape_repl "$Z2K_INIT")
ESC_TG_TUNNEL_ENABLED=$(sed_escape_repl "$TG_TUNNEL_ENABLED")
ESC_SPLIT_ROUTING_ENABLED=$(sed_escape_repl "$SPLIT_ROUTING_ENABLED")
ESC_WAN_IF=$(sed_escape_repl "$WAN_IF")
ESC_LOCAL_NET=$(sed_escape_repl "$LOCAL_NET")
ESC_ROUTER_IP=$(sed_escape_repl "$ROUTER_IP")

sed -i \
  -e "s|^TG_TOKEN=.*|TG_TOKEN=\"$ESC_TG_TOKEN\"|" \
  -e "s|^TG_CHAT_IDS=.*|TG_CHAT_IDS=\"$ESC_TG_CHAT_IDS\"|" \
  -e "s|^SUBSCRIPTION_URL=.*|SUBSCRIPTION_URL=\"$ESC_SUB_URL\"|" \
  -e "s|^HAPP_HWID=.*|HAPP_HWID=\"$ESC_HWID\"|" \
  -e "s|^HAPP_VERSION=.*|HAPP_VERSION=\"$ESC_HAPP_VERSION\"|" \
  -e "s|^HAPP_UA_DEVICE_ID=.*|HAPP_UA_DEVICE_ID=\"$ESC_UA_ID\"|" \
  -e "s|^HAPP_DEVICE_MODEL=.*|HAPP_DEVICE_MODEL=\"$ESC_DEVICE_MODEL\"|" \
  -e "s|^Z2K_TYPE=.*|Z2K_TYPE=\"$ESC_Z2K_TYPE\"|" \
  -e "s|^Z2K_INIT=.*|Z2K_INIT=\"$ESC_Z2K_INIT\"|" \
  -e "s|^TG_TUNNEL_ENABLED=.*|TG_TUNNEL_ENABLED=\"$ESC_TG_TUNNEL_ENABLED\"|" \
  -e "s|^SPLIT_ROUTING_ENABLED=.*|SPLIT_ROUTING_ENABLED=\"$ESC_SPLIT_ROUTING_ENABLED\"|" \
  -e "s|^WAN_IF=.*|WAN_IF=\"$ESC_WAN_IF\"|" \
  -e "s|^LOCAL_NET=.*|LOCAL_NET=\"$ESC_LOCAL_NET\"|" \
  -e "s|^ROUTER_IP=.*|ROUTER_IP=\"$ESC_ROUTER_IP\"|" \
  "$FILE"
chmod +x "$FILE"

if sh -n "$FILE" 2>/dev/null; then
    echo "Синтаксис OK"
    echo ""
    printf "Запустить Argus-K сейчас? (y/N): "
    read RESTART
    case "$RESTART" in
        y|Y|yes|YES)
            if [ -x /opt/etc/init.d/S99argus ]; then
                /opt/etc/init.d/S99argus restart
            else
                /opt/argus-k.sh >/dev/null 2>&1 &
            fi
            sleep 5
            echo "Прогресс: tail -f /tmp/argus-k.log"
            ;;
        *)
            echo "Запустите вручную: /opt/etc/init.d/S99argus start"
            ;;
    esac
else
    echo "Синтаксическая ошибка после подстановки."
    exit 1
fi

echo ""
echo "============================================================"
echo "  Установка завершена."
echo "============================================================"
echo ""
echo "Полезные команды Telegram-бота."
echo "Чтобы добавить их в меню бота — напишите @BotFather,"
echo "отправьте /setcommands, выберите своего бота и вставьте"
echo "список ниже:"
echo ""
echo "status - текущее состояние"
echo "on - включить прокси вручную"
echo "off - выключить прокси вручную"
echo "auto - автоматический режим"
echo "next - переключить на следующий живой конфиг"
echo "use - выбрать конфиг по маске (укажите часть имени)"
echo "configs - список конфигов"
echo "restart - перезапустить Xray"
echo "update - обновить конфиги из подписки"
echo "diag - диагностический отчёт"
echo "log - последние строки лога"
echo "help - список команд"
echo ""
echo "Управление из консоли роутера:"
echo "  /opt/etc/init.d/S99argus status"
echo "  /opt/etc/init.d/S99argus start"
echo "  /opt/etc/init.d/S99argus stop"
echo "  /opt/etc/init.d/S99argus restart"
echo ""
echo "Диагностика:"
echo "  sh /opt/etc/argus-k-debug.sh"
echo "  sh /opt/etc/argus-k-debug.sh --tg  (отправить в Telegram)"
echo ""
