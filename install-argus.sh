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

HAPP_VERSION_FIXED="4.3.0"

# ============================================================
# АВТООПРЕДЕЛЕНИЕ СЕТЕВЫХ ПАРАМЕТРОВ
# ============================================================

detect_wan_if_keenetic() {
    command -v ndmc >/dev/null 2>&1 || return 1
    ndmc -c "show interface" 2>/dev/null \
        | awk '/^Interface,/{f=1;next} f && /Up/ && /inet/ {print $2}' \
        | head -1
}

detect_wan_if() {
    local k
    k=$(detect_wan_if_keenetic || true)
    if [ -n "$k" ]; then
        echo "$k"
        return 0
    fi
    local rt
    rt=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [ -n "$rt" ] && [ "$rt" != "lo" ] && [ "$rt" != "br0" ]; then
        echo "$rt"
        return 0
    fi
    local iface
    for iface in lte_br0 lte0 lte1 usb0 usb1 usb2 wwan0 wwan1 ppp0 eth3 eth2.2 nwg0 nwg1; do
        if ip -4 addr show dev "$iface" 2>/dev/null | grep -q "inet "; then
            echo "$iface"
            return 0
        fi
    done
    return 1
}

list_wan_candidates() {
    ip -4 -o addr show 2>/dev/null \
        | awk '$2 != "lo" && $2 != "br0" {print $2}' \
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
    for bridge in br0 br-lan; do
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

# ============================================================
# АВТООПРЕДЕЛЕНИЕ СУЩЕСТВУЮЩЕГО TG-ТУННЕЛЯ
# ============================================================

detect_existing_tg_tunnel() {
    local found=""

    if command -v ipset >/dev/null 2>&1; then
        local sets
        sets=$(ipset list -n 2>/dev/null | grep -iE 'telegram|^tg|_tg_')
        if [ -n "$sets" ]; then
            found="$found
    ipset: $(echo "$sets" | tr '\n' ' ')"
        fi
    fi

    if command -v iptables >/dev/null 2>&1; then
        local hit
        hit=$(iptables -t nat -S 2>/dev/null \
            | grep -iE 'telegram|TG_|_TG|XRAY_TG' \
            | grep -viE 'XRAY_TG_PREROUTING|XRAY_TG_')
        if [ -n "$hit" ]; then
            found="$found
    iptables: $(echo "$hit" | head -1 | cut -c1-90)"
        fi
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

# ============================================================
# ШАГ 0: ЗАВИСИМОСТИ
# ============================================================
clear 2>/dev/null || true
echo "============================================================"
echo "  ШАГ 0. УСТАНОВКА ЗАВИСИМОСТЕЙ"
echo "============================================================"
echo ""

if ! mount 2>/dev/null | grep -q " /opt "; then
    echo "❌ Каталог /opt не смонтирован — Entware не установлен."
    exit 1
fi

for pkg_cmd in "jq:jq" "curl:curl" "ipset:ipset"; do
    pkg="${pkg_cmd%%:*}"
    cmd="${pkg_cmd##*:}"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "⬇️  Устанавливаю $pkg..."
        opkg update >/dev/null 2>&1 || true
        opkg install "$pkg" || echo "⚠️ $pkg не установлен"
    fi
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "✅ $cmd"
    else
        echo "❌ $cmd"
    fi
done

if ! command -v xray >/dev/null 2>&1 && [ ! -x /opt/sbin/xray ]; then
    echo "⬇️  Устанавливаю Xray..."
    opkg install xray || {
        ARCH=$(uname -m)
        case "$ARCH" in
            aarch64)      XRAY_ARCH="arm64-v8a" ;;
            armv7l|armv7) XRAY_ARCH="arm32-v7a" ;;
            mips)         XRAY_ARCH="mips32" ;;
            mipsel)       XRAY_ARCH="mips32le" ;;
            *) echo "❌ Неизвестная архитектура"; exit 1 ;;
        esac
        TMPDIR=$(mktemp -d)
        URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip"
        curl -fsSL -o "$TMPDIR/xray.zip" "$URL" || exit 1
        command -v unzip >/dev/null 2>&1 || opkg install unzip >/dev/null 2>&1
        unzip -o "$TMPDIR/xray.zip" -d "$TMPDIR" >/dev/null
        mv "$TMPDIR/xray" /opt/sbin/xray
        chmod +x /opt/sbin/xray
        rm -rf "$TMPDIR"
    }
fi
echo "✅ Xray"

mkdir -p /opt/etc/xray/configs /opt/var/log/xray
echo ""
printf "Нажмите Enter для продолжения..."
read DUMMY

# ============================================================
# ШАГ 0.5: СЕТЕВЫЕ ПАРАМЕТРЫ (автоопределение)
# ============================================================
clear 2>/dev/null || true
cat << 'HELP'
============================================================
   ШАГ 0.5. ОПРЕДЕЛЕНИЕ СЕТЕВЫХ ПАРАМЕТРОВ
============================================================
Скрипту нужны три параметра сети:
  - WAN-интерфейс (через который роутер смотрит в интернет);
  - адрес локальной сети (LAN);
  - IP роутера в локальной сети.

Определяю автоматически. Если что-то определится неверно —
можно переопределить вручную.
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
    [ "$iface" = "$DETECTED_WAN" ] && marker=" ← предлагаю"
    printf "  %2d) %-14s %s%s\n" "$i" "$iface" "$addr" "$marker"
done
echo ""
printf "WAN-интерфейс [%s]: " "${DETECTED_WAN:-не определён}"
read INPUT_WAN
if [ -n "$INPUT_WAN" ]; then
    WAN_IF="$INPUT_WAN"
elif [ -n "$DETECTED_WAN" ]; then
    WAN_IF="$DETECTED_WAN"
else
    echo "❌ WAN-интерфейс не определён и не указан."
    echo "   Укажите вручную в /opt/etc/argus-k.sh (переменная WAN_IF)."
    exit 1
fi

if ! ip link show dev "$WAN_IF" >/dev/null 2>&1; then
    echo "⚠️  Интерфейс '$WAN_IF' не найден в системе."
    printf "   Продолжить? (y/N): "
    read OK
    case "$OK" in y|Y|yes|YES) ;; *) exit 1 ;; esac
fi
echo "✅ WAN_IF = $WAN_IF"
echo ""

WAN_IF_IP=$(detect_wan_ip "$WAN_IF" || true)
WAN_IF_GW=$(detect_wan_gateway "$WAN_IF" || true)

if [ -n "$WAN_IF_IP" ]; then
    echo "✅ WAN_IF имеет IPv4: $WAN_IF_IP"
    [ -n "$WAN_IF_GW" ] && echo "   Шлюз оператора: $WAN_IF_GW"
else
    echo "⚠️  На интерфейсе '$WAN_IF' нет IPv4."
    echo "   Возможные причины:"
    echo "     - модем не подключён / нет сессии LTE;"
    echo "     - выбран не тот интерфейс;"
    echo "     - IP появится позже (KeeneticOS поднимает ndm)."
    printf "   Продолжить всё равно? (y/N): "
    read OK_WAN_IP
    case "$OK_WAN_IP" in
        y|Y|yes|YES) ;;
        *)
            echo "Перезапустите установку, когда LTE-сессия активна."
            exit 1
            ;;
    esac
fi

if [ -n "$WAN_IF_IP" ]; then
    echo ""
    echo "Проверяю связь через $WAN_IF..."
    if ping -I "$WAN_IF" -c 2 -W 3 77.88.8.8 >/dev/null 2>&1; then
        echo "✅ ping 77.88.8.8 через $WAN_IF — OK"
    elif ping -I "$WAN_IF" -c 2 -W 3 1.1.1.1 >/dev/null 2>&1; then
        echo "✅ ping 1.1.1.1 через $WAN_IF — OK (Yandex DNS недоступен)"
    else
        echo "⚠️  ping через $WAN_IF не проходит. Возможно:"
        echo "     - оператор блокирует ICMP;"
        echo "     - неверный интерфейс;"
        echo "     - нет связи с модемом."
        printf "   Продолжить? (y/N): "
        read OK_PING
        case "$OK_PING" in y|Y|yes|YES) ;; *) exit 1 ;; esac
    fi
fi
echo ""

DETECTED_LAN=$(detect_lan_settings || true)
DETECTED_LAN_NET="${DETECTED_LAN%%|*}"
DETECTED_LAN_IP="${DETECTED_LAN##*|}"

if [ -n "$DETECTED_LAN_NET" ] && [ "$DETECTED_LAN" != "$DETECTED_LAN_NET" ]; then
    echo "Локальная сеть определена: $DETECTED_LAN_NET"
    echo "IP роутера в LAN: $DETECTED_LAN_IP"
    printf "Использовать эти значения? (Y/n): "
    read OK_LAN
    case "$OK_LAN" in
        n|N|no|NO)
            printf "  Локальная сеть [%s]: " "$DETECTED_LAN_NET"
            read INPUT_LAN
            LOCAL_NET="${INPUT_LAN:-$DETECTED_LAN_NET}"
            printf "  IP роутера [%s]: " "$DETECTED_LAN_IP"
            read INPUT_IP
            ROUTER_IP="${INPUT_IP:-$DETECTED_LAN_IP}"
            ;;
        *)
            LOCAL_NET="$DETECTED_LAN_NET"
            ROUTER_IP="$DETECTED_LAN_IP"
            ;;
    esac
else
    echo "⚠️  Не удалось определить LAN автоматически (br0 не найден)."
    printf "  Локальная сеть (напр. 192.168.1.0/24): "
    read LOCAL_NET
    printf "  IP роутера в LAN (напр. 192.168.1.1): "
    read ROUTER_IP
    if ! is_filled "$LOCAL_NET" || ! is_filled "$ROUTER_IP"; then
        echo "❌ Пустые значения недопустимы."
        exit 1
    fi
fi
echo "✅ LOCAL_NET = $LOCAL_NET"
echo "✅ ROUTER_IP = $ROUTER_IP"
echo ""
printf "Нажмите Enter для продолжения..."
read DUMMY

# ============================================================
# ШАГ 1: ПОДПИСКА
# ============================================================
clear 2>/dev/null || true
cat << 'HELP'
============================================================
   ШАГ 1. ССЫЛКА НА ПОДПИСКУ
============================================================
Если вы знаете ссылку на свою подписку — вставьте её сейчас.

Если не знаете — откройте приложение Happ:
  1. Найдите свою подписку на главном экране.
  2. Нажмите «три точки» (⋯) рядом с подпиской.
  3. Выберите «Редактировать» (или «Edit»).
  4. Скопируйте URL из поля — это и есть ссылка.
============================================================
HELP

while true; do
    printf "Ссылка на подписку: "
    read SUB_URL
    if ! is_filled "$SUB_URL"; then
        echo "❌ Пусто. Попробуйте снова."
        continue
    fi
    if ! is_url "$SUB_URL"; then
        echo "⚠️  Это не похоже на URL (должно начинаться с http:// или https://)."
        printf "   Всё равно использовать? (y/N): "
        read OK
        case "$OK" in
            y|Y|yes|YES) break ;;
            *) continue ;;
        esac
    fi
    break
done
echo ""

# ============================================================
# ШАГ 2: ДАННЫЕ УСТРОЙСТВА
# ============================================================
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
  1. Личный кабинет VPN-провайдера → «Устройства»
     (ищите «HWID» или «Device ID»).
  2. Приложение Happ → Настройки → Информация.
  3. Поддержка провайдера.
Если не нашли — нажмите Enter, значение сгенерируется.
⚠️  Может занять новый слот в подписке!
------------------------------------------------------------
HELP
printf "HWID (Enter — сгенерировать): "
read HWID
if [ -z "$HWID" ]; then
    HWID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-')
    echo "  → сгенерирован: $HWID"
    echo "  ⚠️  Может занять новый слот в подписке"
fi
echo ""

cat << 'HELP'
------------------------------------------------------------
2.2 UA DEVICE ID (число из User-Agent)
------------------------------------------------------------
Число, которое Happ передаёт в строке User-Agent:
  Happ/4.3.0/Android/17877369741321921609
                          ^^^^^^^^^^^^^^^^^^^^
Где посмотреть:
  1. Личный кабинет провайдера → «Устройства».
  2. Поддержка провайдера.
Если не нашли — Enter, значение сгенерируется.
⚠️  Может занять новый слот в подписке!
------------------------------------------------------------
HELP
printf "UA Device ID (Enter — сгенерировать): "
read UA_ID
if [ -z "$UA_ID" ]; then
    UA_ID=$(od -An -tu8 -N8 /dev/urandom 2>/dev/null | tr -d ' ')
    echo "  → сгенерирован: $UA_ID"
    echo "  ⚠️  Может занять новый слот в подписке"
fi
echo ""

cat << 'HELP'
------------------------------------------------------------
2.3 МОДЕЛЬ УСТРОЙСТВА
------------------------------------------------------------
Модель вашего смартфона — провайдер может её проверять.
Где посмотреть:
  1. Телефон → Настройки → О телефоне → Модель.
  2. Личный кабинет провайдера → «Устройства».
Если не знаете — Enter, будет «Android Device».
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

echo "  HTTP код: $HTTP_CODE (curl rc=$CURL_RC)"
SUB_OK=0
SUB_MSG=""

if [ "$CURL_RC" -ne 0 ]; then
    SUB_MSG="❌ Не удалось подключиться (curl rc=$CURL_RC)."
elif [ "$HTTP_CODE" != "200" ]; then
    SUB_MSG="❌ Сервер вернул HTTP $HTTP_CODE."
elif [ ! -s "$TMP_SUB" ]; then
    SUB_MSG="❌ Пустой ответ."
else
    SIZE=$(wc -c < "$TMP_SUB")
    FIRST=$(head -c 1 "$TMP_SUB" | tr -d '[:space:]')
    echo "  Размер: $SIZE байт, первый символ: '$FIRST'"
    echo ""
    if [ "$FIRST" = "[" ] || [ "$FIRST" = "{" ]; then
        CNT=$(jq 'length' "$TMP_SUB" 2>/dev/null)
        if [ -n "$CNT" ] && [ "$CNT" -gt 0 ] 2>/dev/null; then
            echo "  Найдено конфигов: $CNT"
            echo "  Первые 5 названий:"
            jq -r '.[0:5][] | "    - " + (.remarks // "(без названия)")' "$TMP_SUB" 2>/dev/null
            echo ""
            FIRST_UUID=$(jq -r '.[0].outbounds[]? | select(.protocol=="vless" or .protocol=="vmess") | .settings.vnext[0].users[0].id // empty' "$TMP_SUB" 2>/dev/null)
            if [ "$FIRST_UUID" = "00000000-0000-0000-0000-000000000000" ] || [ -z "$FIRST_UUID" ]; then
                SUB_MSG="⚠️  Похоже на ЗАГЛУШКУ.
   Проверьте HWID и UA Device ID (лучше через mitmproxy)."
            else
                SUB_OK=1
                SUB_MSG="✅ Подписка рабочая: $CNT конфигов."
            fi
        else
            SUB_MSG="⚠️  JSON есть, но конфигов в нём нет."
        fi
    else
        SUB_MSG="⚠️  Ответ не похож на JSON."
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

# ============================================================
# ШАГ 2.5: ТУННЕЛЬ ДЛЯ TELEGRAM
# ============================================================
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

echo "🔍 Проверяю систему на признаки существующего туннеля..."
DETECTED_TG=$(detect_existing_tg_tunnel || true)
DETECT_FOUND=0
if [ -n "$DETECTED_TG" ]; then
    DETECT_FOUND=1
    echo ""
    echo "⚠️  Найдены признаки существующего туннеля для Telegram:"
    echo "$DETECTED_TG"
    echo ""
else
    echo "   Признаков существующего туннеля не найдено."
    echo ""
fi

HAS_TG_TUNNEL=""
while true; do
    printf "У вас уже есть туннель для Telegram? (y/n): "
    read HAS_TG_TUNNEL
    case "$HAS_TG_TUNNEL" in
        y|Y|yes|YES|n|N|no|NO) break ;;
        *) echo "Ответьте 'y' или 'n'." ;;
    esac
done

case "$HAS_TG_TUNNEL" in
    y|Y|yes|YES)
        TG_TUNNEL_ENABLED="no"
        echo ""
        echo "→ Понятно. Argus-K не будет вмешиваться в Telegram."
        if [ "$DETECT_FOUND" -eq 0 ]; then
            echo ""
            echo "  ℹ️  Автопоиск ничего не нашёл, но вы сказали, что"
            echo "     туннель есть. Возможно:"
            echo "       - он реализован через домены, а не IP;"
            echo "       - он работает на уровне приложения (не на роутере);"
            echo "       - названия нестандартные."
            echo "     Если это ошибка — смените TG_TUNNEL_ENABLED на \"yes\""
            echo "     в /opt/etc/argus-k.sh и перезапустите S99argus."
        fi
        ;;
    n|N|no|NO)
        if [ "$DETECT_FOUND" -eq 1 ]; then
            echo ""
            echo "⚠️  Внимание: вы ответили, что своего туннеля нет,"
            echo "   но автопоиск нашёл признаки существующего (см. выше)."
            echo ""
            echo "   Если вы не уверены, что это — выберите «не настраивать»."
            echo "   Если это ложное срабатывание (например, старые правила"
            echo "   от удалённого туннеля) — можно продолжать, Argus-K"
            echo "   использует отдельные цепочки XRAY_TG_* и не тронет"
            echo "   чужие правила."
            echo ""
            printf "   Всё равно настроить туннель для Telegram через Xray? (y/N): "
            read CONFLICT_OK
            case "$CONFLICT_OK" in
                y|Y|yes|YES)
                    TG_TUNNEL_ENABLED="yes"
                    echo "→ Туннель для Telegram будет создан через Xray."
                    echo "  Если после установки Telegram не работает —"
                    echo "  смените TG_TUNNEL_ENABLED на \"no\" в /opt/etc/argus-k.sh."
                    ;;
                *)
                    TG_TUNNEL_ENABLED="no"
                    echo "→ Ок, туннель для Telegram настраивать не будем."
                    ;;
            esac
        else
            echo ""
            cat << 'HELP'
Тогда можно настроить прозрачный туннель через Xray.

Что это даёт:
  - работает автоматически, без отдельного демона;
  - переиспользует Xray, который Argus-K и так запускает;
  - переживает смену VPN-конфига из подписки;
  - не мешает white list детекту и остальному трафику.

Xray у Argus-K запущен в фоне постоянно (для бота), так
что туннель для Telegram не создаёт дополнительной нагрузки.
HELP
            printf "Настроить туннель для Telegram через Xray? (Y/n): "
            read WANT_TG_TUNNEL
            case "$WANT_TG_TUNNEL" in
                n|N|no|NO)
                    TG_TUNNEL_ENABLED="no"
                    echo "→ Ок, туннель для Telegram настраивать не будем."
                    ;;
                *)
                    TG_TUNNEL_ENABLED="yes"
                    echo "→ Туннель для Telegram будет создан."
                    ;;
            esac
        fi
        ;;
esac
echo ""

# ============================================================
# ШАГ 2.6: SPLIT ROUTING
# ============================================================
clear 2>/dev/null || true
cat << 'HELP'
============================================================
   ШАГ 2.6. SPLIT ROUTING ДЛЯ RU-ДОМЕНОВ
============================================================
Argus-K умеет добавлять в скачанные из подписки конфиги
одно правило: домены из списка
/opt/etc/argus-k-split-domains.txt идут напрямую, а не
через VPN.

Зачем это нужно:
  - российские сервисы (Яндекс, VK, Ozon, госуслуги,
    банки) не любят, когда заходят с VPN-IP;
  - экономит трафик;
  - снижает нагрузку на туннель.

Если у вашей подписки УЖЕ есть свои domain-based
direct-правила (у дорогих подписок бывает) — Argus-K
их не тронет.
============================================================
HELP
printf "Добавлять правило «RU-домены напрямую»? (Y/n): "
read WANT_SPLIT
case "$WANT_SPLIT" in
    n|N|no|NO)
        SPLIT_ROUTING_ENABLED="no"
        echo "→ Split routing не будет добавляться."
        ;;
    *)
        SPLIT_ROUTING_ENABLED="yes"
        echo "→ Split routing будет добавлен в конфиги без своих direct-правил."
        echo "  Список: /opt/etc/argus-k-split-domains.txt"
        echo "  Дополнять можно вручную, изменения подхватятся при рестарте."
        ;;
esac
echo ""

# ============================================================
# ШАГ 3: TELEGRAM-БОТ
# ============================================================
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
        while true; do
            cat << 'HELP'
------------------------------------------------------------
3.1 ТОКЕН БОТА
------------------------------------------------------------
Где взять:
  1. Откройте Telegram (через VPN, если заблокирован).
  2. Найдите @BotFather.
  3. Отправьте /newbot.
  4. Придумайте имя и username (оканчивается на "bot").
  5. BotFather пришлёт токен.
------------------------------------------------------------
HELP
            printf "Токен: "
            read TG_TOKEN
            is_filled "$TG_TOKEN" || { echo "❌ Пусто."; continue; }
            if is_tg_token "$TG_TOKEN"; then
                break
            fi
            printf "⚠️  Формат не похож. Всё равно? (y/N): "
            read OK
            case "$OK" in y|Y|yes|YES) break ;; *) continue ;; esac
        done
        echo ""
        while true; do
            cat << 'HELP'
------------------------------------------------------------
3.2 CHAT ID
------------------------------------------------------------
Числовой ID. НЕ логин (@username), а число.
Где взять:
  1. Найдите @userinfobot в Telegram.
  2. Отправьте ему любое сообщение.
  3. Он ответит вашим ID.

Можно несколько ID через пробел.
ВАЖНО: каждый пользователь сначала должен написать
вашему боту /start, иначе Telegram не даст боту
писать ему первым.
------------------------------------------------------------
HELP
            printf "Chat ID: "
            read TG_CHAT_IDS
            is_filled "$TG_CHAT_IDS" || { echo "❌ Пусто."; continue; }
            if is_tg_chat_ids "$TG_CHAT_IDS"; then
                break
            fi
            printf "⚠️  Не число. Всё равно? (y/N): "
            read OK
            case "$OK" in y|Y|yes|YES) break ;; *) continue ;; esac
        done
        ;;
    *)
        echo "→ Telegram не настраивается."
        ;;
esac

# ============================================================
# ШАГ 4: ОБХОДЧИК DPI
# ============================================================
echo ""
clear 2>/dev/null || true
cat << 'MENU'
============================================================
   ШАГ 4. ОБХОДЧИК DPI (опционально)
============================================================
Скрипт умеет синхронизировать состояние обходчика DPI
с режимом прокси. Если обходчик у вас НЕ установлен —
выберите «нет».

Какой обходчик DPI у вас установлен?
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
        echo "→ Неизвестный выбор, обходчик не будет управляться."
        Z2K_TYPE="none"; Z2K_INIT=""
        ;;
esac

if [ "$Z2K_TYPE" != "none" ] && [ -n "$Z2K_INIT" ]; then
    if [ ! -x "$Z2K_INIT" ]; then
        echo ""
        echo "⚠️  Файл '$Z2K_INIT' не найден или не исполняемый."
        printf "   Продолжить? (y/N): "
        read OK
        case "$OK" in
            y|Y|yes|YES) ;;
            *) Z2K_TYPE="none"; Z2K_INIT="" ;;
        esac
    else
        echo ""
        echo "✅ Обходчик найден: $Z2K_INIT"
    fi
fi
echo ""

# ============================================================
# ИТОГ
# ============================================================
echo ""
echo "============================================================"
echo "  ИТОГОВЫЕ ДАННЫЕ"
echo "============================================================"
echo "  WAN_IF            = $WAN_IF"
echo "  WAN_IF_IP         = ${WAN_IF_IP:-(нет IPv4)}"
echo "  WAN_IF_GW         = ${WAN_IF_GW:-(нет шлюза)}"
echo "  LOCAL_NET         = $LOCAL_NET"
echo "  ROUTER_IP         = $ROUTER_IP"
echo "  SUB_URL           = $SUB_URL"
echo "  HAPP_HWID         = $HWID"
echo "  HAPP_VERSION      = $HAPP_VERSION_FIXED"
echo "  UA_DEVICE_ID      = $UA_ID"
echo "  DEVICE_MODEL      = $DEVICE_MODEL"
echo "  TG_TUNNEL         = $TG_TUNNEL_ENABLED"
echo "  SPLIT_ROUTING     = $SPLIT_ROUTING_ENABLED"
if [ -n "$TG_TOKEN" ]; then
    echo "  TG_TOKEN          = $TG_TOKEN"
    echo "  TG_CHAT_IDS       = $TG_CHAT_IDS"
else
    echo "  TG_TOKEN          = (не настроен)"
    echo "  TG_CHAT_IDS       = (не настроены)"
fi
echo "  Z2K_TYPE          = $Z2K_TYPE"
echo "  Z2K_INIT          = ${Z2K_INIT:-'(не используется)'}"
echo ""
echo "  Примечание: WAN_IF_IP не сохраняется в конфиг —"
echo "  это динамический адрес LTE-сессии."
echo ""
printf "Записать в конфиг? (y/N): "
read CONFIRM
case "$CONFIRM" in
    y|Y|yes|YES) ;;
    *) echo "Отменено."; exit 0 ;;
esac

sed -i \
  -e "s|^TG_TOKEN=.*|TG_TOKEN=\"$TG_TOKEN\"|" \
  -e "s|^TG_CHAT_IDS=.*|TG_CHAT_IDS=\"$TG_CHAT_IDS\"|" \
  -e "s|^SUBSCRIPTION_URL=.*|SUBSCRIPTION_URL=\"$SUB_URL\"|" \
  -e "s|^HAPP_HWID=.*|HAPP_HWID=\"$HWID\"|" \
  -e "s|^HAPP_VERSION=.*|HAPP_VERSION=\"$HAPP_VERSION_FIXED\"|" \
  -e "s|^HAPP_UA_DEVICE_ID=.*|HAPP_UA_DEVICE_ID=\"$UA_ID\"|" \
  -e "s|^HAPP_DEVICE_MODEL=.*|HAPP_DEVICE_MODEL=\"$DEVICE_MODEL\"|" \
  -e "s|^Z2K_TYPE=.*|Z2K_TYPE=\"$Z2K_TYPE\"|" \
  -e "s|^Z2K_INIT=.*|Z2K_INIT=\"$Z2K_INIT\"|" \
  -e "s|^TG_TUNNEL_ENABLED=.*|TG_TUNNEL_ENABLED=\"$TG_TUNNEL_ENABLED\"|" \
  -e "s|^SPLIT_ROUTING_ENABLED=.*|SPLIT_ROUTING_ENABLED=\"$SPLIT_ROUTING_ENABLED\"|" \
  -e "s|^WAN_IF=.*|WAN_IF=\"$WAN_IF\"|" \
  -e "s|^LOCAL_NET=.*|LOCAL_NET=\"$LOCAL_NET\"|" \
  -e "s|^ROUTER_IP=.*|ROUTER_IP=\"$ROUTER_IP\"|" \
  "$FILE"
chmod +x "$FILE"

if sh -n "$FILE" 2>/dev/null; then
    echo "✅ Синтаксис OK"
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
    echo "❌ Синтаксическая ошибка после подстановки."
    exit 1
fi

# ============================================================
# ПРИЛОЖЕНИЕ: mitmproxy
# ============================================================
echo ""
echo "============================================================"
echo "  ПРИЛОЖЕНИЕ: получение данных устройства через mitmproxy"
echo "============================================================"
echo ""
cat << 'MITM'
Если вам нужно достать реальные HWID, UA Device ID и модель
устройства из приложения Happ — можно перехватить трафик.

Это способ для продвинутых пользователей, которые знают,
как работать с прокси.

Шаги:
  1. Установите mitmproxy на компьютер:
     https://mitmproxy.org/downloads/
  2. Запустите: mitmproxy -p 8080
  3. На телефоне в настройках Wi-Fi укажите прокси:
     Хост = IP компьютера, Порт = 8080
  4. Откройте http://mitm.it на телефоне и установите
     сертификат mitmproxy (для Android — в доверенные
     сертификаты пользователя).
  5. Откройте Happ и обновите подписку.
  6. В окне mitmproxy найдите запрос к серверу подписки
     (URL оканчивается на sub.php или похоже).
  7. Посмотрите заголовки запроса:
       X-HWID          → HWID
       User-Agent      → Happ/<версия>/Android/<ID>
                         <ID> — это UA Device ID
       X-Device-Model  → модель устройства
  8. Скопируйте значения и запустите инсталлер заново.

Не забудьте отключить прокси на телефоне после захвата.
MITM
echo ""
echo "============================================================"
echo "  Установка завершена."
echo "============================================================"