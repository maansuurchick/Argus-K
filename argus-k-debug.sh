#!/bin/sh
# argus-k-debug.sh — диагностика Argus-K
# Использование:
#   sh argus-k-debug.sh              # вывести отчёт в консоль
#   sh argus-k-debug.sh --tg         # отправить отчёт в Telegram
#   sh argus-k-debug.sh > /tmp/d.txt # сохранить в файл

XKEEN_FILE="${XKEEN_FILE:-/opt/etc/argus-k.sh}"
INIT_FILE="${INIT_FILE:-/opt/etc/init.d/S99argus}"
SPLIT_FILE="${SPLIT_FILE:-/opt/etc/argus-k-split-domains.txt}"
LOG_FILE="/tmp/argus-k.log"
XRAY_ERR_LOG="/opt/var/log/xray/error.log"
STATE_DIR="/tmp/argus-k"

if [ -t 1 ]; then
    C_OK="\033[32m"; C_ERR="\033[31m"; C_WARN="\033[33m"
    C_INFO="\033[36m"; C_RESET="\033[0m"; C_BOLD="\033[1m"
else
    C_OK=""; C_ERR=""; C_WARN=""; C_INFO=""; C_RESET=""; C_BOLD=""
fi

ok()   { printf "  ${C_OK}✅ %s${C_RESET}\n" "$1"; }
err()  { printf "  ${C_ERR}❌ %s${C_RESET}\n" "$1"; }
warn() { printf "  ${C_WARN}⚠️  %s${C_RESET}\n" "$1"; }
info() { printf "  ${C_INFO}ℹ️  %s${C_RESET}\n" "$1"; }
hdr()  { printf "\n${C_BOLD}=== %s ===${C_RESET}\n" "$1"; }

ERRORS=0; WARNINGS=0

hdr "1. Система"
if mount 2>/dev/null | grep -q " /opt "; then
    ok "Entware смонтирован"
else
    err "Entware НЕ смонтирован"
    ERRORS=$((ERRORS+1))
fi
echo "  Архитектура: $(uname -m)"
echo "  Свободно в /opt: $(df -h /opt 2>/dev/null | tail -1 | awk '{print $4}')"

hdr "2. Зависимости"
for cmd in jq curl ipset xray; do
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd"
    else
        err "$cmd не установлен"
        ERRORS=$((ERRORS+1))
    fi
done

hdr "3. Основной скрипт"
if [ -f "$XKEEN_FILE" ]; then
    if [ -x "$XKEEN_FILE" ]; then ok "исполняемый"; else err "не исполняемый"; ERRORS=$((ERRORS+1)); fi
    if sh -n "$XKEEN_FILE" 2>/dev/null; then ok "синтаксис OK"; else err "синтаксис ERROR"; ERRORS=$((ERRORS+1)); fi
    for v in SUBSCRIPTION_URL TG_CHAT_IDS TG_TOKEN HAPP_HWID HAPP_UA_DEVICE_ID WAN_IF LOCAL_NET ROUTER_IP; do
        val=$(grep "^${v}=" "$XKEEN_FILE" | head -1 | cut -d'=' -f2- | tr -d '"')
        if [ -z "$val" ] || echo "$val" | grep -q "ВСТАВЬТЕ_"; then
            err "$v не заполнено"; ERRORS=$((ERRORS+1))
        else
            ok "$v заполнено"
        fi
    done
else
    err "не найден: $XKEEN_FILE"; ERRORS=$((ERRORS+1))
fi

hdr "4. Конфиги Xray"
if [ -d /opt/etc/xray/configs ]; then
    cnt=$(ls -1 /opt/etc/xray/configs/*.json 2>/dev/null | wc -l)
    if [ "$cnt" -gt 0 ]; then ok "$cnt конфигов"; else warn "каталог пуст"; WARNINGS=$((WARNINGS+1)); fi
fi

hdr "5. Xray процесс"
if ps | grep "xray run" | grep -v grep >/dev/null; then
    ok "Xray запущен"
else
    err "Xray не запущен"; ERRORS=$((ERRORS+1))
fi
if netstat -tlnp 2>/dev/null | grep -q ":10808 "; then
    ok "SOCKS 10808 слушает"
else
    err "SOCKS 10808 не слушает"; ERRORS=$((ERRORS+1))
fi

hdr "6. Сеть: WAN, LAN, whitelist"
wan_if=$(grep "^WAN_IF=" "$XKEEN_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d '"')

if [ -z "$wan_if" ] || echo "$wan_if" | grep -q "ВСТАВЬТЕ_"; then
    err "WAN_IF не задан в $XKEEN_FILE"
    ERRORS=$((ERRORS+1))
elif ! ip link show dev "$wan_if" >/dev/null 2>&1; then
    err "WAN_IF='$wan_if' не существует в системе"
    ERRORS=$((ERRORS+1))
else
    ok "WAN_IF=$wan_if существует"
    wan_ip=$(ip -4 -o addr show dev "$wan_if" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    wan_gw=$(ip route show dev "$wan_if" 2>/dev/null | awk '/default/ {print $3; exit}')
    if [ -n "$wan_ip" ]; then
        ok "IPv4 на $wan_if: $wan_ip"
        [ -n "$wan_gw" ] && info "шлюз оператора: $wan_gw"
    else
        err "на $wan_if нет IPv4"
        ERRORS=$((ERRORS+1))
    fi
fi

router_ip_cfg=$(grep "^ROUTER_IP=" "$XKEEN_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d '"')
local_net_cfg=$(grep "^LOCAL_NET=" "$XKEEN_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d '"')
if [ -n "$router_ip_cfg" ] && ! echo "$router_ip_cfg" | grep -q "ВСТАВЬТЕ_"; then
    if ip -4 addr show 2>/dev/null | grep -q " $router_ip_cfg/"; then
        ok "ROUTER_IP=$router_ip_cfg присутствует на роутере"
    else
        err "ROUTER_IP=$router_ip_cfg не найден ни на одном интерфейсе"
        ERRORS=$((ERRORS+1))
    fi
else
    err "ROUTER_IP не задан"
    ERRORS=$((ERRORS+1))
fi
if [ -n "$local_net_cfg" ] && ! echo "$local_net_cfg" | grep -q "ВСТАВЬТЕ_"; then
    ok "LOCAL_NET=$local_net_cfg"
else
    err "LOCAL_NET не задан"
    ERRORS=$((ERRORS+1))
fi

if [ -n "$wan_if" ] && ip link show dev "$wan_if" >/dev/null 2>&1; then
    canaries=$(grep "^WHITELIST_CANARIES=" "$XKEEN_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"')
    [ -z "$canaries" ] && canaries="1.1.1.1 8.8.8.8 9.9.9.9 208.67.222.222"
    alive=0
    for ip in $canaries; do
        http=$(curl -s -k -o /dev/null -w "%{http_code}" \
            --connect-timeout 3 --max-time 5 --interface "$wan_if" "https://$ip/" 2>/dev/null)
        if [ "$http" != "000" ] && [ -n "$http" ]; then
            ok "$ip → HTTP $http"
            alive=$((alive+1))
        else
            echo "     $ip → недоступен"
        fi
    done
    [ "$alive" -gt 0 ] && info "Состояние: OPEN ($alive живых)" || info "Состояние: WHITELIST или нет связи"
fi

hdr "7. iptables"
iptables -t nat -L XRAY_PREROUTING -n >/dev/null 2>&1 && ok "XRAY_PREROUTING есть" || warn "XRAY_PREROUTING нет"
iptables -t nat -L XRAY_TG_PREROUTING -n >/dev/null 2>&1 && ok "XRAY_TG_PREROUTING есть" || info "XRAY_TG_PREROUTING отсутствует (TG-туннель выключен)"
iptables -t nat -C PREROUTING -j XRAY_PREROUTING 2>/dev/null && ok "PREROUTING→XRAY активен" || info "PREROUTING→XRAY не подключён"

hdr "8. Split routing"
split_flag=$(grep "^SPLIT_ROUTING_ENABLED=" "$XKEEN_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d '"')
if [ "$split_flag" = "yes" ]; then
    ok "SPLIT_ROUTING_ENABLED = yes"
    if [ -f "$SPLIT_FILE" ]; then
        dom_cnt=$(grep -v '^[[:space:]]*#' "$SPLIT_FILE" 2>/dev/null | grep -v '^[[:space:]]*$' | wc -l)
        ok "файл доменов: $dom_cnt записей"
    else
        warn "файл $SPLIT_FILE не найден"
        WARNINGS=$((WARNINGS+1))
    fi
    cfg_cnt=$(ls -1 /opt/etc/xray/configs/*.json 2>/dev/null | wc -l)
    injected=0
    for f in /opt/etc/xray/configs/*.json; do
        [ -f "$f" ] || continue
        if command -v jq >/dev/null 2>&1 && jq -e '
            [.routing.rules[]? | select(.outboundTag=="direct") | select((.domain // []) | length > 0)] | length > 0
        ' "$f" >/dev/null 2>&1; then
            injected=$((injected+1))
        fi
    done
    info "конфигов с domain+direct правилом: $injected из $cfg_cnt"
else
    info "SPLIT_ROUTING_ENABLED = no (или не задано)"
fi

hdr "9. Telegram"
tg_token=$(grep "^TG_TOKEN=" "$XKEEN_FILE" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"')
if [ -z "$tg_token" ]; then
    info "Telegram не настроен"
else
    ok "токен задан"
    if ps | grep "xray run" | grep -v grep >/dev/null; then
        http=$(curl -x socks5h://127.0.0.1:10808 -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 8 --max-time 15 "https://api.telegram.org/bot$tg_token/getMe" 2>/dev/null)
        [ "$http" = "200" ] && ok "Telegram API доступен" || err "Telegram API: HTTP $http"
    fi
fi

hdr "10. Конфликты TG-туннеля"
tg_flag=$(grep "^TG_TUNNEL_ENABLED=" "$XKEEN_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d '"')
foreign=""

if command -v ipset >/dev/null 2>&1; then
    sets=$(ipset list -n 2>/dev/null | grep -iE 'telegram|^tg|_tg_' | grep -v '^argus_k_tg_ips$')
    [ -n "$sets" ] && foreign="$foreign ipset:$(echo "$sets" | tr '\n' ',')"
fi

if command -v iptables >/dev/null 2>&1; then
    hit=$(iptables -t nat -S 2>/dev/null | grep -iE 'telegram|TG_|_TG' | grep -viE 'XRAY_TG_PREROUTING|XRAY_TG_')
    [ -n "$hit" ] && foreign="$foreign iptables"
fi

for pat in 'z2k' 'z4r' 'sing-box' 'tg-tunnel' 'telegram-proxy' 'mtg' 'mtproto'; do
    if ps 2>/dev/null | grep -v grep | grep -iE "$pat" >/dev/null; then
        foreign="$foreign proc:$pat"
    fi
done

if [ -n "$foreign" ]; then
    warn "обнаружены признаки сторонних TG-туннелей:$foreign"
    if [ "$tg_flag" = "yes" ]; then
        err "конфликт: TG_TUNNEL_ENABLED=yes, но есть чужой туннель"
        WARNINGS=$((WARNINGS+1))
    else
        ok "TG_TUNNEL_ENABLED=no, конфликта нет"
    fi
else
    info "сторонних TG-туннелей не найдено"
    [ "$tg_flag" = "yes" ] && ok "TG_TUNNEL_ENABLED=yes, наш туннель активен"
fi

hdr "11. Процессы"
total=$(ps | grep "argus-k.sh" | grep -v grep | wc -l)
if [ "$total" -ge 3 ] && [ "$total" -le 4 ]; then
    ok "процессов: $total"
else
    warn "процессов: $total"
fi

hdr "12. Автозагрузка"
if [ -f "$INIT_FILE" ]; then
    if [ -x "$INIT_FILE" ]; then ok "init-скрипт исполняемый"; else err "init не исполняемый"; fi
    echo "  Статус: $("$INIT_FILE" status 2>/dev/null)"
else
    err "init-скрипт не найден: $INIT_FILE"
fi

hdr "13. Последние 10 строк лога"
[ -f "$LOG_FILE" ] && tail -n 10 "$LOG_FILE" | sed 's/^/  /' || warn "лог отсутствует"

echo ""
echo "============================================================"
if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
    printf "${C_OK}${C_BOLD}  ✅ ВСЁ В ПОРЯДКЕ${C_RESET}\n"
elif [ "$ERRORS" -eq 0 ]; then
    printf "${C_WARN}${C_BOLD}  ⚠️  Предупреждений: %d${C_RESET}\n" "$WARNINGS"
else
    printf "${C_ERR}${C_BOLD}  ❌ Ошибок: %d${C_RESET}\n" "$ERRORS"
fi
echo "============================================================"
echo ""

if [ "$1" = "--tg" ]; then
    tg_token=$(grep "^TG_TOKEN=" "$XKEEN_FILE" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"')
    tg_chats=$(grep "^TG_CHAT_IDS=" "$XKEEN_FILE" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"')
    if [ -z "$tg_token" ] || [ -z "$tg_chats" ]; then
        echo "⚠️  Telegram не настроен, отправка пропущена."
        exit 0
    fi
    report=$(sh "$0" 2>&1 | head -250)
    for cid in $tg_chats; do
        curl -x socks5h://127.0.0.1:10808 -s -o /dev/null \
             --connect-timeout 10 --max-time 30 \
             --data-urlencode "chat_id=$cid" \
             --data-urlencode "text=🔧 Argus-K debug report:
\`\`\`
$report
\`\`\`" \
             "https://api.telegram.org/bot$tg_token/sendMessage" 2>/dev/null
    done
    echo "📨 Отчёт отправлен в Telegram ($tg_chats)"
fi