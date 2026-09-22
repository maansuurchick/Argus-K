#!/bin/sh
# ============================================================================
# argus-k.sh  (v5.8.17)
# BusyBox ash / KeeneticOS + Entware.
#
# Argus-K — автоматическое управление Xray на роутерах Keenetic
# с LTE-модемом (KeeneticOS + Entware).
#
# Назначение: работать в условиях, когда мобильный оператор
# включает "белый список" — пропускает только одобренные
# ресурсы, а всё остальное режет. Argus-K определяет это
# и направляет трафик устройств в сети через Xray-туннель
# ТОЛЬКО на время действия white list. В обычном режиме
# трафик идёт напрямую, как обычно.
#
# Служба Xray при этом всегда запущена в фоне, но она ничего
# не перенаправляет, пока Argus-K не даст команду. Это нужно
# для работы Telegram-бота и (опционально) прозрачного
# туннеля для Telegram.
#
# Работает также на проводных подключениях, но там детект
# white list обычно не срабатывает (у проводных провайдеров
# такого режима нет) — скрипт просто держит Xray и проксирует
# Telegram, если это включено.
# ============================================================================

# ============================================================================
# --- Загрузка пользовательских настроек из /opt/etc/argus-k.conf ---
# Файл создаётся/обновляется install-argus.sh. Обновления кода
# через bootstrap его не трогают, поэтому настройки сохраняются.
CONF_FILE="${CONF_FILE:-/opt/etc/argus-k.conf}"
if [ -f "$CONF_FILE" ]; then
    . "$CONF_FILE"
fi

# ============================================================================
# Дефолты для переменных, которые обычно приходят из argus-k.conf.
# Если conf отсутствует или в нём нет переменной — используются эти значения.
# Защита от ситуации, когда conf потерян или неполный.
# ============================================================================

# --- ПОДПИСКА HAPP ---
SUBSCRIPTION_URL="${SUBSCRIPTION_URL:-}"
HAPP_HWID="${HAPP_HWID:-}"
HAPP_VERSION="${HAPP_VERSION:-4.3.0}"
HAPP_UA_DEVICE_ID="${HAPP_UA_DEVICE_ID:-}"
HAPP_DEVICE_MODEL="${HAPP_DEVICE_MODEL:-Android Device}"
HAPP_DEVICE_NAME="${HAPP_DEVICE_NAME:-Android Device}"
HAPP_VER_OS="${HAPP_VER_OS:-15}"
HAPP_LOCALE="${HAPP_LOCALE:-ru-RU}"

# --- TELEGRAM ---
TG_TOKEN="${TG_TOKEN:-}"
TG_CHAT_IDS="${TG_CHAT_IDS:-}"

# --- СЕТЬ ---
WAN_IF="${WAN_IF:-}"
LOCAL_NET="${LOCAL_NET:-}"
ROUTER_IP="${ROUTER_IP:-}"
EXCLUDED_IPS="${EXCLUDED_IPS:-}"
WHITELIST_CANARIES="${WHITELIST_CANARIES:-1.1.1.1 8.8.8.8 9.9.9.9 208.67.222.222}"

# --- ФИЧИ ---
SPLIT_ROUTING_ENABLED="${SPLIT_ROUTING_ENABLED:-yes}"
TG_TUNNEL_ENABLED="${TG_TUNNEL_ENABLED:-no}"

# --- ОБХОДЧИК DPI ---
Z2K_TYPE="${Z2K_TYPE:-none}"
Z2K_INIT="${Z2K_INIT:-}"


# ======================== НАСТРОЙКИ ПОЛЬЗОВАТЕЛЯ ============================
# ============================================================================

# --- ПОРТЫ XRAY ---
PROXY_PORT="1181"
SOCKS_PORT="10808"
TEST_SOCKS_PORT="10888"
TEST_HTTP_PORT="11888"

# --- ПУТИ ---
CONFIG_DIR="/opt/etc/xray/configs"
XRAY_BIN=$(command -v xray || echo "/opt/sbin/xray")
IPT_BIN="/opt/sbin/iptables"
[ -x "$IPT_BIN" ] || IPT_BIN=$(command -v iptables || echo "/opt/sbin/iptables")
IPSET_BIN="/opt/sbin/ipset"
[ -x "$IPSET_BIN" ] || IPSET_BIN=$(command -v ipset || echo "")
HAVE_IPSET=0
[ -n "$IPSET_BIN" ] && HAVE_IPSET=1
TG_IPSET_NAME="argus_k_tg_ips"

LOG_FILE="/tmp/argus-k.log"
MAX_LOG_SIZE=150000
ERROR_LOG="/opt/var/log/xray/error.log"
HOOK_FILE="/opt/etc/ndm/netfilter.d/099-argus-k.sh"
SPLIT_DOMAINS_FILE="/opt/etc/argus-k-split-domains.txt"

# --- ПАРАМЕТРЫ ---
MAIN_LOOP_SLEEP="${MAIN_LOOP_SLEEP:-3}"
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-4}"
HEALTH_FAIL_THRESHOLD="${HEALTH_FAIL_THRESHOLD:-2}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-6}"
TEST_MAX_TIME="${TEST_MAX_TIME:-15}"
MIN_STABLE_SECONDS="${MIN_STABLE_SECONDS:-60}"
TG_POLL_TIMEOUT=5
BG_MONITOR_INTERVAL="${BG_MONITOR_INTERVAL:-900}"
WHITELIST_CACHE_TTL="${WHITELIST_CACHE_TTL:-10}"
WHITELIST_CACHE_TTL_ON="${WHITELIST_CACHE_TTL_ON:-10}"
WHITELIST_CONFIRM_SECONDS="${WHITELIST_CONFIRM_SECONDS:-20}"
TELEGRAM_IPS_TTL="${TELEGRAM_IPS_TTL:-43200}"
CONFIG_UPDATE_INTERVAL="${CONFIG_UPDATE_INTERVAL:-86400}"
CONFIG_RETRY_BACKOFF="${CONFIG_RETRY_BACKOFF:-300}"
MAX_CONFIGS_PER_SCAN="${MAX_CONFIGS_PER_SCAN:-15}"

# ============================================================================
# ===================== КОНЕЦ НАСТРОЕК ПОЛЬЗОВАТЕЛЯ ==========================
# ============================================================================

STATE_DIR="/tmp/argus-k"
mkdir -p "$STATE_DIR"

CURRENT_CONFIG_FILE="$STATE_DIR/current_config.txt"
MANUAL_FILE="$STATE_DIR/manual_mode.txt"
MANUAL_PROXY_FILE="$STATE_DIR/manual_proxy.txt"
PROXY_STATE_FILE="$STATE_DIR/proxy_state.txt"
WHITELIST_CACHE_FILE="$STATE_DIR/whitelist_cache.txt"
TG_OFFSET_FILE="$STATE_DIR/tg_offset.txt"
RUN_CONFIG_FILE="$STATE_DIR/run_current.json"
TEST_CONFIG_FILE="$STATE_DIR/test_config.json"
TEST_ERROR_LOG="$STATE_DIR/test_error.log"
TELEGRAM_IPS_TS_FILE="$STATE_DIR/telegram_ips_ts.txt"
ERROR_LOG_CHECKPOINT_FILE="$STATE_DIR/error_log_checkpoint.txt"
LAST_UPDATE_FILE="$STATE_DIR/last_config_update.txt"
LAST_ATTEMPT_FILE="$STATE_DIR/last_config_attempt.txt"

LIVE_CONFIGS_FILE="/tmp/argus-k-live_configs.txt"
TELEGRAM_IPS_FILE="/tmp/argus-k-telegram_ips.txt"

PIDFILE="$STATE_DIR/argus-k.pid"
MAIN_XRAY_PIDFILE="$STATE_DIR/xray_main.pid"
BGMON_PIDFILE="$STATE_DIR/bg_monitor.pid"
POLLER_PIDFILE="$STATE_DIR/tg_poller.pid"

CURRENT_CONFIG=""
LAST_SWITCH_TS=0

TEST_INBOUNDS='[{"listen":"127.0.0.1","port":'"$TEST_SOCKS_PORT"',"protocol":"socks","settings":{"auth":"noauth","udp":true}},{"listen":"127.0.0.1","port":'"$TEST_HTTP_PORT"',"protocol":"http","settings":{}}]'

MAIN_INBOUNDS='[{"listen":"127.0.0.1","port":'"$SOCKS_PORT"',"protocol":"socks","settings":{"auth":"noauth","udp":true,"userLevel":8},"sniffing":{"destOverride":["http","tls"],"enabled":true},"tag":"socks"},{"listen":"0.0.0.0","port":'"$PROXY_PORT"',"protocol":"dokodemo-door","settings":{"network":"tcp,udp","followRedirect":true,"userLevel":8},"sniffing":{"destOverride":["http","tls"],"enabled":true},"tag":"transparent"}]'

# ============================== ЛОГИРОВАНИЕ =================================
log() {
    if [ -f "$LOG_FILE" ]; then
        local size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$size" -gt "$MAX_LOG_SIZE" ]; then
            tail -n 400 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
        fi
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# ==================== АУТЕНТИФИКАЦИЯ TELEGRAM ===============================
is_allowed_chat() {
    local chat="$1" cid
    [ -z "$chat" ] && return 1
    for cid in $TG_CHAT_IDS; do
        [ "$chat" = "$cid" ] && return 0
    done
    return 1
}

# ============================== СОСТОЯНИЕ ===================================
load_manual_mode() {
    MANUAL_MODE=$(cat "$MANUAL_FILE" 2>/dev/null || echo 0)
    MANUAL_PROXY=$(cat "$MANUAL_PROXY_FILE" 2>/dev/null || echo "off")
}
save_manual_mode()  { echo "$MANUAL_MODE" > "$MANUAL_FILE"; }
save_manual_proxy() { echo "$MANUAL_PROXY" > "$MANUAL_PROXY_FILE"; }
load_proxy_state() { PROXY_STATE=$(cat "$PROXY_STATE_FILE" 2>/dev/null || echo "off"); }
save_proxy_state()  { echo "$PROXY_STATE" > "$PROXY_STATE_FILE"; }

save_current_config() {
    [ -n "$CURRENT_CONFIG" ] && [ -f "$CURRENT_CONFIG" ] && echo "$CURRENT_CONFIG" > "$CURRENT_CONFIG_FILE"
}
load_current_config() {
    [ -f "$CURRENT_CONFIG_FILE" ] && {
        local saved=$(cat "$CURRENT_CONFIG_FILE")
        [ -n "$saved" ] && [ -f "$saved" ] && CURRENT_CONFIG="$saved"
    }
}

# ==================== АВТООПРЕДЕЛЕНИЕ WAN (FALLBACK) ========================

is_lan_iface() {
    case "$1" in
        br0|br1|br-lan|br-guest|lo|ezcfg0|bond0) return 0 ;;
        *) return 1 ;;
    esac
}

autodetect_wan_if() {
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

# Извлекает IP-адреса VPN-серверов из всех конфигов подписки.
# Смотрит только outbounds с протоколами vless/vmess/trojan/shadowsocks,
# чтобы IP из dns.servers или других мест не попали в исключения.
extract_server_ips() {
    [ -z "$CONFIG_DIR" ] && return 0
    command -v jq >/dev/null 2>&1 || {
        grep -hoE '"address": *"[^"]+"' "$CONFIG_DIR"/*.json 2>/dev/null \
            | cut -d'"' -f4 \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
            | sort -u
        return 0
    }
    jq -r '
        .outbounds[]?
        | select(.protocol == "vless" or .protocol == "vmess" or .protocol == "trojan" or .protocol == "shadowsocks")
        | (.settings.vnext[]?.address // .settings.servers[]?.address // empty)
    ' "$CONFIG_DIR"/*.json 2>/dev/null \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -u
}

# ============================ УТИЛИТЫ =======================================
sanitize_filename() {
    printf '%s' "$1" | sed \
        -e 's/[[:cntrl:]]//g' \
        -e 's#[/\\:*?"<>|]#_#g' \
        -e 's/[[:space:]][[:space:]]*/_/g' \
        -e 's/^_*//' \
        -e 's/_*$//'
}

json_replace_key() {
    local infile="$1" outfile="$2" key="$3" repl="$4"

    awk -v key="\"$key\"" -v repl="$repl" '
    BEGIN { found = 0; skipping = 0 }
    {
        if (!found) {
            idx = index($0, key)
            if (idx > 0) {
                rest = substr($0, idx + length(key))
                cidx = index(rest, ":")
                if (cidx > 0) {
                    after = substr(rest, cidx + 1)
                    tmp = after
                    gsub(/^[ \t]+/, "", tmp)
                    bracket = substr(tmp, 1, 1)
                    if (bracket == "[" || bracket == "{") {
                        found = 1
                        openc = bracket
                        closec = (bracket == "[") ? "]" : "}"
                        printf "%s%s: %s\n", substr($0, 1, idx - 1), key, repl
                        depth = 0; instr = 0; esc = 0; donetail = 0
                        n = length(tmp); i = 1
                        while (i <= n) {
                            c = substr(tmp, i, 1)
                            if (instr) {
                                if (esc) { esc = 0 }
                                else if (c == "\\") { esc = 1 }
                                else if (c == "\"") { instr = 0 }
                            } else {
                                if (c == "\"") instr = 1
                                else if (c == openc) depth++
                                else if (c == closec) {
                                    depth--
                                    if (depth == 0) { tail = substr(tmp, i + 1); donetail = 1; break }
                                }
                            }
                            i++
                        }
                        if (donetail) { if (length(tail) > 0) print tail }
                        else { skipping = 1 }
                        next
                    }
                }
            }
            print $0
            next
        } else if (skipping) {
            n = length($0); i = 1; donetail = 0
            while (i <= n) {
                c = substr($0, i, 1)
                if (instr) {
                    if (esc) { esc = 0 }
                    else if (c == "\\") { esc = 1 }
                    else if (c == "\"") { instr = 0 }
                } else {
                    if (c == "\"") instr = 1
                    else if (c == openc) depth++
                    else if (c == closec) {
                        depth--
                        if (depth == 0) { tail = substr($0, i + 1); donetail = 1; break }
                    }
                }
                i++
            }
            if (donetail) { skipping = 0; if (length(tail) > 0) print tail }
            next
        } else {
            print $0
        }
    }
    ' "$infile" > "$outfile"

    # Валидация результата
    if [ -s "$outfile" ] && command -v jq >/dev/null 2>&1 && jq empty "$outfile" 2>/dev/null; then
        return 0
    fi

    # Fallback: медленный, но надёжный jq
    if command -v jq >/dev/null 2>&1; then
        if jq --argjson v "$repl" ".$key = \$v" "$infile" > "$outfile.fb" 2>/dev/null && jq empty "$outfile.fb" 2>/dev/null; then
            mv "$outfile.fb" "$outfile"
            return 0
        fi
        rm -f "$outfile.fb"
    fi

    return 1
}

prepare_run_config() {
    cp "$1" "$RUN_CONFIG_FILE"
}

# ============================ ОБНОВЛЕНИЕ КОНФИГОВ ============================
fix_config_ports() {
    local file="$1"
    [ -f "$file" ] || return 1
    if ! command -v jq >/dev/null 2>&1; then
        log "WARNING: jq не установлен, inbounds в $(basename "$file") не приведены к стандарту"
        return 0
    fi
    if jq --argjson inb "$MAIN_INBOUNDS" '
        .inbounds = $inb
        | .outbounds |= (map(
            if (.protocol == "vless" or .protocol == "vmess" or .protocol == "trojan" or .protocol == "shadowsocks")
            then (.streamSettings.sockopt.domainStrategy = "UseIPv4")
            else .
            end
          ))
        | (if ([.outbounds[]? | select(.tag == "dns-out")] | length) == 0
           then .outbounds += [{"protocol":"dns","tag":"dns-out"}]
           else . end)
        | (.routing.rules //= [])
        | (if ([.routing.rules[]? | select(.outboundTag == "dns-out")] | length) == 0
           then .routing.rules = [{"type":"field","inboundTag":["transparent"],"port":53,"outboundTag":"dns-out"}] + .routing.rules
           else . end)
        ' "$file" > "$file.tmp" 2>/dev/null; then
        mv "$file.tmp" "$file"
        inject_split_routing "$file"
        return 0
    fi
    rm -f "$file.tmp"
    log "WARNING: jq не смог обработать $(basename "$file")"
    return 1
}

ensure_dns_hijack() {
    local file="$1"
    [ -f "$file" ] || return 1
    command -v jq >/dev/null 2>&1 || return 0
    if jq '
        (if ([.outbounds[]? | select(.tag == "dns-out")] | length) == 0
         then .outbounds += [{"protocol":"dns","tag":"dns-out"}]
         else . end)
        | (.routing.rules //= [])
        | (if ([.routing.rules[]? | select(.outboundTag == "dns-out")] | length) == 0
           then .routing.rules = [{"type":"field","inboundTag":["transparent"],"port":53,"outboundTag":"dns-out"}] + .routing.rules
           else . end)
        ' "$file" > "$file.tmp" 2>/dev/null && [ -s "$file.tmp" ]; then
        mv "$file.tmp" "$file"
        return 0
    fi
    rm -f "$file.tmp"
    log "WARNING: не удалось добавить dns-out в $(basename "$file")"
    return 1
}

# Добавляет в конфиг одно domain-based direct-правило со списком
# из $SPLIT_DOMAINS_FILE, если такого правила ещё нет.
#
# Признак «уже есть» — любое правило с outboundTag:direct и
# непустым .domain[]. Так мы не трогаем ни готовые конфиги из
# подписки, ни уже пропатченные нами ранее (идемпотентно).
inject_split_routing() {
    local file="$1"
    [ -f "$file" ] || return 1
    [ "$SPLIT_ROUTING_ENABLED" = "yes" ] || return 0
    [ -f "$SPLIT_DOMAINS_FILE" ] || {
        log "split: $SPLIT_DOMAINS_FILE не найден, пропускаю"
        return 0
    }
    command -v jq >/dev/null 2>&1 || return 0

    # Уже есть domain-based direct правило?
    if jq -e '
        [.routing.rules[]?
         | select(.outboundTag == "direct")
         | select((.domain // []) | length > 0)]
        | length > 0
    ' "$file" >/dev/null 2>&1; then
        log "split: в $(basename "$file") уже есть domain-based direct — пропускаю"
        return 0
    fi

    # Формируем JSON-массив ["domain:x", "domain:y", ...]
    local domains_json
    domains_json=$(grep -v '^[[:space:]]*#' "$SPLIT_DOMAINS_FILE" 2>/dev/null \
        | grep -v '^[[:space:]]*$' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | sed 's|^|domain:|' \
        | jq -R . | jq -s .)

    [ -z "$domains_json" ] && { log "split: список доменов пуст"; return 1; }
    local dom_cnt=$(echo "$domains_json" | jq 'length' 2>/dev/null)
    [ -z "$dom_cnt" ] || [ "$dom_cnt" -eq 0 ] && { log "split: не удалось разобрать список"; return 1; }

    # Убеждаемся, что outbound "direct" существует
    if ! jq -e '[.outbounds[]? | select(.tag == "direct")] | length > 0' "$file" >/dev/null 2>&1; then
        if jq '.outbounds += [{"protocol":"freedom","settings":{"domainStrategy":"AsIs"},"tag":"direct"}]' \
             "$file" > "$file.tmp" 2>/dev/null; then
            mv "$file.tmp" "$file"
        else
            rm -f "$file.tmp"
            log "split: не удалось добавить direct outbound в $(basename "$file")"
            return 1
        fi
    fi

    # Препендим правило. Оно окажется выше dns-out и выше
    # пользовательских правил, но это безопасно: ведёт в direct,
    # куда и так шли бы эти домены.
    if jq --argjson doms "$domains_json" '
        .routing.rules = [
            {"type":"field","domain":$doms,"outboundTag":"direct"}
        ] + (.routing.rules // [])
    ' "$file" > "$file.tmp" 2>/dev/null; then
        mv "$file.tmp" "$file"
        log "split: добавлено $dom_cnt доменов в $(basename "$file")"
        return 0
    fi
    rm -f "$file.tmp"
    log "split: jq не смог добавить правило в $(basename "$file")"
    return 1
}

update_configs_from_subscription() {
    log "Обновление конфигов из подписки..."
    date +%s > "$LAST_ATTEMPT_FILE"
    local tmp_raw="$STATE_DIR/sub_raw.bin"

    if ! command -v jq >/dev/null 2>&1; then
        log "ERROR: jq не установлен"
        return 1
    fi

    local UA="Happ/$HAPP_VERSION/Android/$HAPP_UA_DEVICE_ID"
    log "HWID: $HAPP_HWID, UA: $UA"

    local PROXY_OPT=""
    if [ -n "$(pgrep -f "$XRAY_BIN run" 2>/dev/null)" ]; then
        PROXY_OPT="-x socks5h://127.0.0.1:$SOCKS_PORT"
        log "Скачиваю подписку через SOCKS туннеля"
    else
        log "Xray не запущен — скачиваю подписку напрямую (bootstrap)"
    fi

    if ! curl -s -L --compressed \
         $PROXY_OPT \
         -A "$UA" \
         -H "X-HWID: $HAPP_HWID" \
         -H "X-Device-OS: Android" \
         -H "X-Device-Model: $HAPP_DEVICE_MODEL" \
         -H "X-Device-Name: $HAPP_DEVICE_NAME" \
         -H "X-Ver-OS: $HAPP_VER_OS" \
         -H "X-Device-Locale: $HAPP_LOCALE" \
         --connect-timeout 15 --max-time 120 \
         "$SUBSCRIPTION_URL" -o "$tmp_raw" 2>>"$LOG_FILE"; then
        log "WARNING: не удалось скачать подписку"
        rm -f "$tmp_raw"; return 1
    fi
    [ -s "$tmp_raw" ] || { log "WARNING: подписка пуста"; rm -f "$tmp_raw"; return 1; }
    log "Размер ответа: $(wc -c < "$tmp_raw") байт"

    local magic=$(head -c 2 "$tmp_raw" | od -An -tx1 2>/dev/null | tr -d ' \n')
    if [ "$magic" = "1f8b" ] && command -v gunzip >/dev/null 2>&1; then
        gunzip -c "$tmp_raw" > "$tmp_raw.dec" 2>/dev/null && mv "$tmp_raw.dec" "$tmp_raw"
    fi

    local first=$(head -c 1 "$tmp_raw" | tr -d '[:space:]')
    log "Первый символ ответа: '$first'"

    case "$first" in
        '['|'{') : ;;
        *)
            if head -c 300 "$tmp_raw" | tr -d '\r\n' | grep -qE '^[A-Za-z0-9+/=]+$'; then
                base64 -d "$tmp_raw" > "$tmp_raw.dec" 2>/dev/null && mv "$tmp_raw.dec" "$tmp_raw"
                first=$(head -c 1 "$tmp_raw" | tr -d '[:space:]')
                log "После base64 первый символ: '$first'"
            fi
            ;;
    esac

    local backup_dir="$STATE_DIR/configs_backup"
    rm -rf "$backup_dir"; mkdir -p "$backup_dir"
    cp "$CONFIG_DIR"/sub_*.json "$backup_dir/" 2>/dev/null

    local saved=0
    case "$first" in
        '[')
            if jq -e 'type == "array"' "$tmp_raw" >/dev/null 2>&1; then
                rm -f "$CONFIG_DIR"/sub_*.json
                local cnt=$(jq 'length' "$tmp_raw" 2>/dev/null)
                log "Получено $cnt конфигов в JSON-массиве"
                local i=1
                while [ "$i" -le "$cnt" ]; do
                    local remark=$(jq -r ".[$((i-1))].remarks // empty" "$tmp_raw" 2>/dev/null)
                    local base_name=""
                    if [ -n "$remark" ]; then
                        base_name=$(sanitize_filename "$remark")
                    fi
                    [ -z "$base_name" ] && base_name="config_${i}"

                    local out_file="$CONFIG_DIR/sub_${base_name}.json"
                    local suffix=1
                    while [ -e "$out_file" ]; do
                        out_file="$CONFIG_DIR/sub_${base_name}_${suffix}.json"
                        suffix=$((suffix + 1))
                    done

                    if jq -c ".[$((i-1))]" "$tmp_raw" > "$out_file" 2>/dev/null && [ -s "$out_file" ]; then
                        fix_config_ports "$out_file"
                        i=$((i+1))
                    else
                        rm -f "$out_file"; break
                    fi
                done
                saved=$((i-1))
            fi
            ;;
        '{')
            if jq -e 'type == "object"' "$tmp_raw" >/dev/null 2>&1; then
                rm -f "$CONFIG_DIR"/sub_*.json
                local remark=$(jq -r '.remarks // empty' "$tmp_raw" 2>/dev/null)
                local base_name=""
                [ -n "$remark" ] && base_name=$(sanitize_filename "$remark")
                [ -z "$base_name" ] && base_name="config_1"
                local out_file="$CONFIG_DIR/sub_${base_name}.json"
                local suffix=1
                while [ -e "$out_file" ]; do
                    out_file="$CONFIG_DIR/sub_${base_name}_${suffix}.json"
                    suffix=$((suffix + 1))
                done
                cp "$tmp_raw" "$out_file"
                fix_config_ports "$out_file"
                saved=1
            fi
            ;;
    esac

    if [ "${saved:-0}" -eq 0 ]; then
        log "ERROR: не удалось разобрать подписку"
        log "Первые 200 байт: $(head -c 200 "$tmp_raw" | tr -d '\r\n')"
        rm -f "$CONFIG_DIR"/sub_*.json
        cp "$backup_dir"/*.json "$CONFIG_DIR/" 2>/dev/null
        rm -f "$tmp_raw"; return 1
    fi

    rm -f "$tmp_raw"
    date +%s > "$LAST_UPDATE_FILE"
    log "Конфиги обновлены: $saved шт."
    send_tg "🔄 Argus-K: конфиги обновлены из подписки ($saved шт.)"
    return 0
}

configs_need_update() {
    local now=$(date +%s)
    if [ -f "$LAST_ATTEMPT_FILE" ]; then
        local last_attempt=$(cat "$LAST_ATTEMPT_FILE" 2>/dev/null || echo 0)
        [ $((now - last_attempt)) -lt "$CONFIG_RETRY_BACKOFF" ] && return 1
    fi
    [ ! -f "$LAST_UPDATE_FILE" ] && return 0
    local last=$(cat "$LAST_UPDATE_FILE" 2>/dev/null || echo 0)
    [ $((now - last)) -ge "$CONFIG_UPDATE_INTERVAL" ]
}

# ============================ КОНФИГИ XRAY ===================================
get_config_list() {
    local files=""
    for f in "$CONFIG_DIR"/*.json; do
        [ -e "$f" ] && files="$files
$f"
    done
    echo "$files" | sed '/^$/d'
}

test_config_liveness() {
    local src="$1"
    json_replace_key "$src" "$TEST_CONFIG_FILE" "inbounds" "$TEST_INBOUNDS"
    [ ! -s "$TEST_CONFIG_FILE" ] && { log "test: $(basename "$src") -> ошибка подготовки"; return 1; }
    > "$TEST_ERROR_LOG"
    $XRAY_BIN run -c "$TEST_CONFIG_FILE" 2>"$TEST_ERROR_LOG" >/dev/null &
    local test_pid=$!
    sleep 2
    kill -0 "$test_pid" 2>/dev/null || { log "test: $(basename "$src") -> xray не запустился"; return 1; }
    curl -x socks5h://127.0.0.1:$TEST_SOCKS_PORT -s -o /dev/null \
         --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TEST_MAX_TIME" \
         http://cp.cloudflare.com/generate_204
    local ok=$?
    kill "$test_pid" 2>/dev/null; sleep 1
    kill -0 "$test_pid" 2>/dev/null && sleep 1
    kill -0 "$test_pid" 2>/dev/null && kill -9 "$test_pid" 2>/dev/null
    wait "$test_pid" 2>/dev/null
    if [ "$ok" -eq 0 ]; then
        log "test: $(basename "$src") -> LIVE"; return 0
    fi
    local errtail=$(tail -n 2 "$TEST_ERROR_LOG" 2>/dev/null | tr '\n' ' ')
    log "test: $(basename "$src") -> dead (curl rc=$ok) xray: ${errtail:-<пусто>}"
    return 1
}

scan_configs_liveness() {
    local list=$(get_config_list)
    local tmp_live="$STATE_DIR/live_configs.tmp"
    > "$tmp_live"
    OLD_IFS="$IFS"; IFS='
'
    for f in $list; do
        [ "$f" = "$CURRENT_CONFIG" ] && continue
        test_config_liveness "$f" && echo "$f" >> "$tmp_live"
    done
    IFS="$OLD_IFS"
    mv "$tmp_live" "$LIVE_CONFIGS_FILE"
    log "Фоновая проверка завершена: $(wc -l < "$LIVE_CONFIGS_FILE" 2>/dev/null) живых конфигов"
}

initial_quick_scan() {
    log "Стартовое сканирование всех конфигов..."
    local list=$(get_config_list)
    [ -z "$list" ] && { log "FATAL: конфиги не найдены"; return 1; }
    local tmp_live="$STATE_DIR/live_configs.tmp"
    > "$tmp_live"
    OLD_IFS="$IFS"; IFS='
'
    for f in $list; do
        test_config_liveness "$f" && echo "$f" >> "$tmp_live"
    done
    IFS="$OLD_IFS"
    mv "$tmp_live" "$LIVE_CONFIGS_FILE"
    local first_live=$(head -1 "$LIVE_CONFIGS_FILE" 2>/dev/null)
    if [ -n "$first_live" ]; then
        CURRENT_CONFIG="$first_live"
        log "Стартовый выбор: живой конфиг $CURRENT_CONFIG"
    else
        CURRENT_CONFIG=$(echo "$list" | head -1)
        log "WARNING: нет живых, беру первый: $CURRENT_CONFIG"
    fi
    save_current_config
    return 0
}

get_live_config_list() {
    [ -f "$LIVE_CONFIGS_FILE" ] || return 0
    while IFS= read -r f; do
        [ -n "$f" ] && [ -f "$f" ] && echo "$f"
    done < "$LIVE_CONFIGS_FILE"
}

pick_next_config() {
    local live=$(get_live_config_list)
    local found=0 chosen="" first=""
    if [ -n "$live" ]; then
        OLD_IFS="$IFS"; IFS='
'
        for f in $live; do
            [ -z "$first" ] && first="$f"
            [ "$found" -eq 1 ] && { chosen="$f"; break; }
            [ "$f" = "$CURRENT_CONFIG" ] && found=1
        done
        IFS="$OLD_IFS"
        [ -z "$chosen" ] && chosen="$first"
        echo "$chosen"; return 0
    fi
    log "WARNING: кэш живых пуст, аварийный переход по полному списку"
    local list=$(get_config_list)
    [ -z "$list" ] && return 1
    found=0; chosen=""; first=""
    OLD_IFS="$IFS"; IFS='
'
    for f in $list; do
        [ -z "$first" ] && first="$f"
        if [ "$f" = "$CURRENT_CONFIG" ]; then found=1; continue; fi
        [ "$found" -eq 1 ] && { chosen="$f"; break; }
    done
    IFS="$OLD_IFS"
    [ -z "$chosen" ] && chosen="$first"
    echo "$chosen"
}

is_main_xray_running() {
    [ -f "$MAIN_XRAY_PIDFILE" ] && kill -0 "$(cat "$MAIN_XRAY_PIDFILE" 2>/dev/null)" 2>/dev/null
}
kill_main_xray() {
    [ -f "$MAIN_XRAY_PIDFILE" ] || return 0
    local pid=$(cat "$MAIN_XRAY_PIDFILE")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null; sleep 1
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    fi
    rm -f "$MAIN_XRAY_PIDFILE"
}
start_main_xray() {
    local cfg="$1"
    prepare_run_config "$cfg"
    > "$ERROR_LOG" 2>/dev/null
    echo 0 > "$ERROR_LOG_CHECKPOINT_FILE"
    $XRAY_BIN run -c "$RUN_CONFIG_FILE" 2>>"$ERROR_LOG" >/dev/null &
    local pid=$!
    echo "$pid" > "$MAIN_XRAY_PIDFILE"
    sleep 3
    if kill -0 "$pid" 2>/dev/null; then
        CURRENT_CONFIG="$cfg"
        save_current_config
        LAST_SWITCH_TS=$(date +%s)
        log "Основной Xray запущен (pid $pid), конфиг: $cfg"
        return 0
    fi
    log "ERROR: основной Xray не запустился с $cfg"
    rm -f "$MAIN_XRAY_PIDFILE"
    return 1
}
switch_config() {
    local next=$(pick_next_config)
    [ -z "$next" ] && { log "switch_config: нет кандидатов"; return 1; }
    log "Переключение на $next"
    kill_main_xray
    if start_main_xray "$next"; then
        set_xray_rules
        load_proxy_state
        [ "$PROXY_STATE" = "on" ] && enable_redirect
        send_tg "🔄 Argus-K: конфиг VPN переключен на $(basename "$next")"
        return 0
    fi
    send_tg "❌ Argus-K: не удалось запустить Xray с $(basename "$next")"
    return 1
}
use_config_by_name() {
    local pattern="$1"
    local match=$(get_config_list | grep -i "$pattern" | head -1)
    [ -z "$match" ] && { send_tg "❌ Argus-K: конфиг по маске '$pattern' не найден"; return 1; }
    kill_main_xray
    if start_main_xray "$match"; then
        set_xray_rules
        load_proxy_state
        [ "$PROXY_STATE" = "on" ] && enable_redirect
        send_tg "✅ Argus-K: переключено на $(basename "$match")"
    else
        send_tg "❌ Argus-K: не удалось запустить Xray с $(basename "$match")"
    fi
}
background_monitor() {
    # Проверяем не более MAX_CONFIGS_PER_SCAN конфигов за прогон.
    # На слабых роутерах с десятками конфигов это снижает пиковую
    # нагрузку. Следующий прогон продолжит с того же места.
    #
    # Важно: из старого списка живых вычитаем ВСЁ, что проверялось
    # в этом проходе (и живых, и мёртвых). Только после этого
    # добавляем результаты новых тестов. Иначе мёртвые, проверенные
    # и не прошедшие тест, остаются в кэше навсегда.
    local scan_cursor_file="$STATE_DIR/scan_cursor.txt"
    while true; do
        sleep "$BG_MONITOR_INTERVAL"
        local cursor=0
        [ -f "$scan_cursor_file" ] && cursor=$(cat "$scan_cursor_file" 2>/dev/null || echo 0)
        local total=$(get_config_list | wc -l)
        if [ "$total" -eq 0 ]; then
            continue
        fi
        log "Фоновое сканирование: с позиции $cursor из $total (бюджет $MAX_CONFIGS_PER_SCAN)"
        local checked=0
        local idx=0
        local tmp_live="$STATE_DIR/live_configs.tmp"
        local checked_file="$STATE_DIR/checked_this_pass.tmp"
        : > "$tmp_live"
        : > "$checked_file"
        OLD_IFS="$IFS"; IFS='
'
        for f in $(get_config_list); do
            idx=$((idx + 1))
            [ "$idx" -lt "$cursor" ] && continue
            [ "$checked" -ge "$MAX_CONFIGS_PER_SCAN" ] && break
            [ "$f" = "$CURRENT_CONFIG" ] && continue
            echo "$f" >> "$checked_file"
            test_config_liveness "$f" && echo "$f" >> "$tmp_live"
            checked=$((checked + 1))
        done
        IFS="$OLD_IFS"
        local new_cursor=$((cursor + checked))
        [ "$new_cursor" -ge "$total" ] && new_cursor=0
        echo "$new_cursor" > "$scan_cursor_file"
        # Вычитаем из старого списка всё проверенное в этом проходе
        if [ -f "$LIVE_CONFIGS_FILE" ]; then
            grep -vFxf "$checked_file" "$LIVE_CONFIGS_FILE" >> "$tmp_live" 2>/dev/null
        fi
        sort -u "$tmp_live" | sed '/^$/d' > "$LIVE_CONFIGS_FILE.tmp"
        mv "$LIVE_CONFIGS_FILE.tmp" "$LIVE_CONFIGS_FILE"
        log "Фоновое сканирование: проверено $checked, курсор $new_cursor/$total, живых $(wc -l < "$LIVE_CONFIGS_FILE" 2>/dev/null)"
    done
}
start_background_monitor() {
    [ -f "$BGMON_PIDFILE" ] && kill -0 "$(cat "$BGMON_PIDFILE" 2>/dev/null)" 2>/dev/null && return 0
    background_monitor &
    echo $! > "$BGMON_PIDFILE"
    log "Фоновый монитор запущен (pid $!)"
}

# ============================ TELEGRAM =======================================
tg_send_curl() {
    curl -x socks5h://127.0.0.1:$SOCKS_PORT -s --connect-timeout 10 --max-time 30 "$@" "https://api.telegram.org/bot$TG_TOKEN/sendMessage" 2>>"$LOG_FILE"
}
send_tg() {
    [ -z "$TG_TOKEN" ] && return 0
    local body=$(printf '%s' "$1" | head -c 3800)
    # Отправляем в фоне, чтобы не блокировать главный цикл.
    # И с retry: если текущий туннель умирает ровно в момент
    # отправки — main loop успеет переключить конфиг, а мы
    # повторим попытку через живой туннель.
    (
        local cid rc attempt
        for attempt in 1 2 3; do
            [ "$attempt" -gt 1 ] && sleep $((attempt * 5))
            rc=0
            for cid in $TG_CHAT_IDS; do
                [ -z "$cid" ] && continue
                tg_send_curl --data-urlencode "chat_id=$cid" --data-urlencode "text=$body" >/dev/null 2>&1 || rc=$?
            done
            [ "$rc" -eq 0 ] && exit 0
        done
        log "send_tg FAILED после 3 попыток (rc=$rc)"
    ) &
}

send_tg_with_markup() {
    [ -z "$TG_TOKEN" ] && return 0
    local body="$1"
    local markup="$2"
    local cid
    for cid in $TG_CHAT_IDS; do
        [ -z "$cid" ] && continue
        tg_send_curl --data-urlencode "chat_id=$cid" \
                     --data-urlencode "text=$body" \
                     --data-urlencode "reply_markup=$markup" >/dev/null 2>&1
    done
}

answer_callback() {
    local cbid="$1"
    [ -z "$TG_TOKEN" ] && return 0
    [ -z "$cbid" ] && return 0
    curl -x socks5h://127.0.0.1:$SOCKS_PORT -s -o /dev/null \
         --connect-timeout 5 --max-time 10 \
         --data-urlencode "callback_query_id=$cbid" \
         "https://api.telegram.org/bot$TG_TOKEN/answerCallbackQuery" 2>>"$LOG_FILE"
}

show_configs_keyboard() {
    local chat="$1"
    local listfile="$STATE_DIR/config_list.${chat}.txt"
    get_config_list > "$listfile"
    local cnt=$(wc -l < "$listfile" 2>/dev/null)
    if [ "$cnt" -eq 0 ]; then
        send_tg "Конфигов нет. Обновите командой /update."
        return
    fi

    # Собираем inline_keyboard вручную, без jq
    local kb='{"inline_keyboard":['
    local i=0
    local first=1
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        i=$((i+1))
        local name=$(basename "$path")
        name=$(printf '%s' "$name" | sed 's/^sub_//; s/\.json$//')
        local esc=$(printf '%s' "$name" | sed 's/\\/\\\\/g; s/"/\\"/g')
        [ "$first" -eq 1 ] || kb="$kb,"
        first=0
        kb="${kb}[{\"text\":\"${i}. ${esc}\",\"callback_data\":\"use_${i}\"}]"
    done < "$listfile"
    kb="$kb]}"

    send_tg_with_markup "Выберите конфиг ($cnt шт.):" "$kb"
}

use_config_by_path() {
    local path="$1"
    if [ -z "$path" ] || [ ! -f "$path" ]; then
        send_tg "Конфиг не найден."
        return 1
    fi
    kill_main_xray
    if start_main_xray "$path"; then
        set_xray_rules
        load_proxy_state
        [ "$PROXY_STATE" = "on" ] && enable_redirect
        send_tg "Переключено на $(basename "$path")"
    else
        send_tg "Не удалось запустить Xray с $(basename "$path")"
    fi
}

tg_poll_curl() {
    local offset="$1"
    curl -x socks5h://127.0.0.1:$SOCKS_PORT -s --connect-timeout 8 --max-time $((TG_POLL_TIMEOUT + 10)) \
         --data-urlencode "timeout=$TG_POLL_TIMEOUT" --data-urlencode "offset=$offset" \
         "https://api.telegram.org/bot$TG_TOKEN/getUpdates" 2>>"$LOG_FILE"
}
TG_QUEUE_DIR="$STATE_DIR/tg_queue"
mkdir -p "$TG_QUEUE_DIR"

tg_parse_updates() {
    jq -r '
        (.result // [])[] |
        if .callback_query then
            "\(.callback_query.message.chat.id)\t__CB:\(.callback_query.id):\(.callback_query.data)"
        elif .message.text then
            "\(.message.chat.id)\t\(.message.text)"
        else
            empty
        end
    ' 2>/dev/null
}

tg_poller() {
    local offset=$(cat "$TG_OFFSET_FILE" 2>/dev/null || echo 0)
    local batch_seq=0
    log "Telegram poller: стартовый offset=$offset"
    while true; do
        local resp=$(tg_poll_curl "$offset")
        if [ -z "$resp" ]; then sleep 3; continue; fi
        echo "$resp" | grep -q '"ok":true' || { sleep 3; continue; }
        local max_id=$(echo "$resp" | grep -o '"update_id":[0-9]*' | grep -o '[0-9]*' | sort -n | tail -1)
        if [ -n "$max_id" ]; then
            offset=$((max_id + 1)); echo "$offset" > "$TG_OFFSET_FILE"
        fi
        # batch_seq в имени файла — на случай, если два пакета
        # сообщений прилетят в одну и ту же секунду (иначе второй
        # файл перезапишет первый и команды потеряются).
        batch_seq=$((batch_seq + 1))
        local batch_tmp="$STATE_DIR/tg_batch.$$.$(date +%s).${batch_seq}.tmp"
        echo "$resp" | tg_parse_updates > "$batch_tmp"
        if [ -s "$batch_tmp" ]; then
            mv "$batch_tmp" "$TG_QUEUE_DIR/msg.$(date +%s).$$.${batch_seq}"
        else
            rm -f "$batch_tmp"
        fi
    done
}
start_tg_poller() {
    [ -z "$TG_TOKEN" ] && { log "Telegram не настроен"; return 0; }
    [ -f "$POLLER_PIDFILE" ] && kill -0 "$(cat "$POLLER_PIDFILE" 2>/dev/null)" 2>/dev/null && return 0
    tg_poller &
    echo $! > "$POLLER_PIDFILE"
    log "Telegram poller запущен (pid $!)"
}

update_telegram_ips() {
    local tmp="$STATE_DIR/telegram_ips.tmp"
    if curl -x socks5h://127.0.0.1:$SOCKS_PORT -s --connect-timeout 8 --max-time 15 \
         "https://core.telegram.org/resources/cidr.txt" -o "$tmp" 2>>"$LOG_FILE" && [ -s "$tmp" ]; then
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' "$tmp" > "$TELEGRAM_IPS_FILE"
        rm -f "$tmp"
        date +%s > "$TELEGRAM_IPS_TS_FILE"
        log "Список IP Telegram обновлён ($(wc -l < "$TELEGRAM_IPS_FILE" 2>/dev/null) диапазонов)"
        return 0
    fi
    rm -f "$tmp"
    if [ ! -s "$TELEGRAM_IPS_FILE" ]; then
        cat > "$TELEGRAM_IPS_FILE" << 'EOF'
149.154.167.0/24
149.154.175.0/24
91.108.56.0/24
91.108.4.0/24
95.161.64.0/24
EOF
        date +%s > "$TELEGRAM_IPS_TS_FILE"
        log "WARNING: не удалось скачать CIDR Telegram, использую статический список"
        return 1
    fi
    log "WARNING: не удалось обновить список IP Telegram"
    return 1
}
telegram_ips_stale() {
    [ ! -f "$TELEGRAM_IPS_FILE" ] && return 0
    local ts=$(cat "$TELEGRAM_IPS_TS_FILE" 2>/dev/null || echo 0)
    [ $(( $(date +%s) - ts )) -ge "$TELEGRAM_IPS_TTL" ]
}

# ============================ IPTABLES =======================================
generate_hook_file() {
    mkdir -p "$(dirname "$HOOK_FILE")"
    local servers="$1"
    {
        echo '#!/bin/sh'
        echo '[ "$type" = "ip6tables" ] && exit 0'
        echo "IPT=\"$IPT_BIN\""
        echo "ROUTER_IP=\"$ROUTER_IP\""
        echo "PROXY_PORT=\"$PROXY_PORT\""
        echo "LOCAL_NET=\"$LOCAL_NET\""
        [ "$HAVE_IPSET" -eq 1 ] && echo "IPSET=\"$IPSET_BIN\""
        echo ''
        echo 'while $IPT -t nat -D PREROUTING -j XRAY_TG_PREROUTING 2>/dev/null; do :; done'
        echo 'while $IPT -t nat -D PREROUTING -j XRAY_PREROUTING 2>/dev/null; do :; done'
        echo 'while $IPT -t nat -D OUTPUT -j XRAY_OUTPUT 2>/dev/null; do :; done'
        echo '$IPT -t nat -F XRAY_TG_PREROUTING 2>/dev/null; $IPT -t nat -X XRAY_TG_PREROUTING 2>/dev/null'
        echo '$IPT -t nat -F XRAY_PREROUTING 2>/dev/null; $IPT -t nat -X XRAY_PREROUTING 2>/dev/null'
        echo '$IPT -t nat -F XRAY_OUTPUT 2>/dev/null; $IPT -t nat -X XRAY_OUTPUT 2>/dev/null'
        echo '$IPT -t nat -N XRAY_PREROUTING'
        echo '$IPT -t nat -N XRAY_OUTPUT'
        echo ''
        echo '$IPT -t nat -A XRAY_PREROUTING -d "$ROUTER_IP" -j RETURN'
        for SERVER in $servers; do
            echo "\$IPT -t nat -A XRAY_PREROUTING -d \"$SERVER\" -j RETURN 2>/dev/null"
        done
        for IP in $EXCLUDED_IPS; do
            echo "\$IPT -t nat -A XRAY_PREROUTING -s \"$IP\" -j RETURN"
        done
        echo '$IPT -t nat -A XRAY_PREROUTING -s "$LOCAL_NET" -p tcp -j REDIRECT --to-ports "$PROXY_PORT"'
        echo '$IPT -t nat -A XRAY_PREROUTING -s "$LOCAL_NET" -p udp -j REDIRECT --to-ports "$PROXY_PORT"'
        echo ''
        echo '$IPT -t nat -A XRAY_OUTPUT -d "$ROUTER_IP" -j RETURN'
        echo '$IPT -t nat -A XRAY_OUTPUT -p tcp --dport 22 -j RETURN'
        echo '$IPT -t nat -A XRAY_OUTPUT -d 127.0.0.1 -j RETURN'
        if [ "$HAVE_IPSET" -eq 1 ]; then
            echo "\$IPSET create $TG_IPSET_NAME hash:net -exist"
            echo "\$IPSET flush $TG_IPSET_NAME"
            if [ -f "$TELEGRAM_IPS_FILE" ]; then
                while IFS= read -r cidr; do
                    [ -n "$cidr" ] && echo "\$IPSET add $TG_IPSET_NAME $cidr -exist"
                done < "$TELEGRAM_IPS_FILE"
            fi
            echo "\$IPT -t nat -A XRAY_OUTPUT -m set --match-set $TG_IPSET_NAME dst -j REDIRECT --to-ports \"\$PROXY_PORT\""
        elif [ -f "$TELEGRAM_IPS_FILE" ]; then
            while IFS= read -r cidr; do
                [ -n "$cidr" ] && echo "\$IPT -t nat -A XRAY_OUTPUT -d \"$cidr\" -j REDIRECT --to-ports \"\$PROXY_PORT\""
            done < "$TELEGRAM_IPS_FILE"
        fi
        echo '$IPT -t nat -A XRAY_OUTPUT -m owner --uid-owner 0 -j RETURN'
        for SERVER in $servers; do
            echo "\$IPT -t nat -A XRAY_OUTPUT -d \"$SERVER\" -j RETURN 2>/dev/null"
        done
        for IP in $EXCLUDED_IPS; do
            echo "\$IPT -t nat -A XRAY_OUTPUT -s \"$IP\" -j RETURN"
            echo "\$IPT -t nat -A XRAY_OUTPUT -d \"$IP\" -j RETURN"
        done
        echo ''
        echo '$IPT -t nat -I OUTPUT 1 -j XRAY_OUTPUT'
        echo ''
        if [ "$TG_TUNNEL_ENABLED" = "yes" ]; then
            echo "\$IPT -t nat -N XRAY_TG_PREROUTING"
            for SERVER in $servers; do
                echo "\$IPT -t nat -A XRAY_TG_PREROUTING -d \"$SERVER\" -j RETURN 2>/dev/null"
            done
            for IP in $EXCLUDED_IPS; do
                echo "\$IPT -t nat -A XRAY_TG_PREROUTING -s \"$IP\" -j RETURN"
            done
            if [ -f "$TELEGRAM_IPS_FILE" ]; then
                while IFS= read -r cidr; do
                    [ -n "$cidr" ] && echo "\$IPT -t nat -A XRAY_TG_PREROUTING -s \"\$LOCAL_NET\" -d \"$cidr\" -p tcp -j REDIRECT --to-ports \"\$PROXY_PORT\""
                done < "$TELEGRAM_IPS_FILE"
            fi
            echo "\$IPT -t nat -A XRAY_TG_PREROUTING -j RETURN"
            echo ''
            echo '$IPT -t nat -I PREROUTING 1 -j XRAY_TG_PREROUTING'
        fi
        echo ''
        echo "PROXY_STATE=\$(cat $PROXY_STATE_FILE 2>/dev/null)"
        if [ "$TG_TUNNEL_ENABLED" = "yes" ]; then
            echo 'if [ "$PROXY_STATE" = "on" ]; then'
            echo '    $IPT -t nat -I PREROUTING 2 -j XRAY_PREROUTING'
            echo 'fi'
        else
            echo 'if [ "$PROXY_STATE" = "on" ]; then'
            echo '    $IPT -t nat -I PREROUTING 1 -j XRAY_PREROUTING'
            echo 'fi'
        fi
    } > "$HOOK_FILE"
    chmod +x "$HOOK_FILE"
}

setup_telegram_ipset() {
    [ "$HAVE_IPSET" -eq 1 ] || return 1
    "$IPSET_BIN" create "$TG_IPSET_NAME" hash:net -exist >/dev/null 2>&1
    "$IPSET_BIN" flush "$TG_IPSET_NAME" >/dev/null 2>&1
    if [ -f "$TELEGRAM_IPS_FILE" ]; then
        while IFS= read -r cidr; do
            [ -n "$cidr" ] && "$IPSET_BIN" add "$TG_IPSET_NAME" "$cidr" -exist >/dev/null 2>&1
        done < "$TELEGRAM_IPS_FILE"
    fi
    return 0
}

setup_tg_prerouting_chain() {
    [ "$TG_TUNNEL_ENABLED" = "yes" ] || return 0
    local SERVERS_LOCAL=$(extract_server_ips)

    $IPT_BIN -t nat -F XRAY_TG_PREROUTING 2>/dev/null
    $IPT_BIN -t nat -X XRAY_TG_PREROUTING 2>/dev/null
    $IPT_BIN -t nat -N XRAY_TG_PREROUTING 2>/dev/null

    for SERVER in $SERVERS_LOCAL; do
        $IPT_BIN -t nat -A XRAY_TG_PREROUTING -d "$SERVER" -j RETURN 2>/dev/null
    done
    for IP in $EXCLUDED_IPS; do
        $IPT_BIN -t nat -A XRAY_TG_PREROUTING -s "$IP" -j RETURN
    done
    if [ -f "$TELEGRAM_IPS_FILE" ]; then
        while IFS= read -r cidr; do
            [ -n "$cidr" ] && $IPT_BIN -t nat -A XRAY_TG_PREROUTING \
                -s "$LOCAL_NET" -d "$cidr" -p tcp \
                -j REDIRECT --to-ports "$PROXY_PORT"
        done < "$TELEGRAM_IPS_FILE"
    fi
    $IPT_BIN -t nat -A XRAY_TG_PREROUTING -j RETURN
}

set_xray_rules() {
    $IPT_BIN -t nat -F XRAY_PREROUTING 2>/dev/null; $IPT_BIN -t nat -X XRAY_PREROUTING 2>/dev/null
    $IPT_BIN -t nat -F XRAY_OUTPUT 2>/dev/null; $IPT_BIN -t nat -X XRAY_OUTPUT 2>/dev/null
    $IPT_BIN -t nat -N XRAY_PREROUTING
    $IPT_BIN -t nat -N XRAY_OUTPUT

    $IPT_BIN -t nat -A XRAY_PREROUTING -d "$ROUTER_IP" -j RETURN

    SERVERS=$(extract_server_ips)
    for SERVER in $SERVERS; do
        $IPT_BIN -t nat -A XRAY_PREROUTING -d "$SERVER" -j RETURN 2>/dev/null
    done
    for IP in $EXCLUDED_IPS; do
        $IPT_BIN -t nat -A XRAY_PREROUTING -s "$IP" -j RETURN
    done
    $IPT_BIN -t nat -A XRAY_PREROUTING -s "$LOCAL_NET" -p tcp -j REDIRECT --to-ports "$PROXY_PORT"
    $IPT_BIN -t nat -A XRAY_PREROUTING -s "$LOCAL_NET" -p udp -j REDIRECT --to-ports "$PROXY_PORT"

    $IPT_BIN -t nat -A XRAY_OUTPUT -d "$ROUTER_IP" -j RETURN
    $IPT_BIN -t nat -A XRAY_OUTPUT -p tcp --dport 22 -j RETURN
    $IPT_BIN -t nat -A XRAY_OUTPUT -d 127.0.0.1 -j RETURN
    if [ "$HAVE_IPSET" -eq 1 ]; then
        setup_telegram_ipset
        $IPT_BIN -t nat -A XRAY_OUTPUT -m set --match-set "$TG_IPSET_NAME" dst -j REDIRECT --to-ports "$PROXY_PORT"
    else
        if [ -f "$TELEGRAM_IPS_FILE" ]; then
            while IFS= read -r cidr; do
                [ -n "$cidr" ] && $IPT_BIN -t nat -A XRAY_OUTPUT -d "$cidr" -j REDIRECT --to-ports "$PROXY_PORT"
            done < "$TELEGRAM_IPS_FILE"
        fi
    fi
    $IPT_BIN -t nat -A XRAY_OUTPUT -m owner --uid-owner 0 -j RETURN
    for SERVER in $SERVERS; do
        $IPT_BIN -t nat -A XRAY_OUTPUT -d "$SERVER" -j RETURN 2>/dev/null
    done
    for IP in $EXCLUDED_IPS; do
        $IPT_BIN -t nat -A XRAY_OUTPUT -s "$IP" -j RETURN
        $IPT_BIN -t nat -A XRAY_OUTPUT -d "$IP" -j RETURN
    done

    while $IPT_BIN -t nat -D OUTPUT -j XRAY_OUTPUT 2>/dev/null; do :; done
    $IPT_BIN -t nat -I OUTPUT 1 -j XRAY_OUTPUT

    setup_tg_prerouting_chain

    while $IPT_BIN -t nat -D PREROUTING -j XRAY_TG_PREROUTING 2>/dev/null; do :; done
    while $IPT_BIN -t nat -D PREROUTING -j XRAY_PREROUTING 2>/dev/null; do :; done

    if [ "$TG_TUNNEL_ENABLED" = "yes" ]; then
        $IPT_BIN -t nat -I PREROUTING 1 -j XRAY_TG_PREROUTING
    fi

    load_proxy_state
    if [ "$PROXY_STATE" = "on" ]; then
        if [ "$TG_TUNNEL_ENABLED" = "yes" ]; then
            $IPT_BIN -t nat -I PREROUTING 2 -j XRAY_PREROUTING
        else
            $IPT_BIN -t nat -I PREROUTING 1 -j XRAY_PREROUTING
        fi
    fi

    generate_hook_file "$SERVERS"
    log "iptables-правила применены (PREROUTING=$PROXY_STATE, TG-туннель=$TG_TUNNEL_ENABLED, WAN_IF=$WAN_IF, split=$SPLIT_ROUTING_ENABLED)"
}

enable_redirect() {
    while $IPT_BIN -t nat -D PREROUTING -j XRAY_PREROUTING 2>/dev/null; do :; done
    if [ "$TG_TUNNEL_ENABLED" = "yes" ]; then
        $IPT_BIN -t nat -I PREROUTING 2 -j XRAY_PREROUTING
    else
        $IPT_BIN -t nat -I PREROUTING 1 -j XRAY_PREROUTING
    fi
    PROXY_STATE="on"; save_proxy_state
    log "Редирект устройств в сети ВКЛЮЧЁН"
}
disable_redirect() {
    local removed=0
    while $IPT_BIN -t nat -D PREROUTING -j XRAY_PREROUTING 2>/dev/null; do removed=1; done
    PROXY_STATE="off"; save_proxy_state
    [ "$removed" -eq 1 ] && log "Редирект устройств в сети ВЫКЛЮЧЕН" || log "Редирект уже выключен"
}
clear_xray_rules() {
    rm -f "$HOOK_FILE"
    while $IPT_BIN -t nat -D PREROUTING -j XRAY_TG_PREROUTING 2>/dev/null; do :; done
    while $IPT_BIN -t nat -D PREROUTING -j XRAY_PREROUTING 2>/dev/null; do :; done
    while $IPT_BIN -t nat -D OUTPUT -j XRAY_OUTPUT 2>/dev/null; do :; done
    $IPT_BIN -t nat -F XRAY_TG_PREROUTING 2>/dev/null; $IPT_BIN -t nat -X XRAY_TG_PREROUTING 2>/dev/null
    $IPT_BIN -t nat -F XRAY_PREROUTING 2>/dev/null; $IPT_BIN -t nat -X XRAY_PREROUTING 2>/dev/null
    $IPT_BIN -t nat -F XRAY_OUTPUT 2>/dev/null; $IPT_BIN -t nat -X XRAY_OUTPUT 2>/dev/null
    log "Все iptables-правила сняты"
}

# ============================ ПРОВЕРКИ СЕТИ ==================================
is_link_up() {
    local gateway=$(ip route show dev "$WAN_IF" 2>/dev/null | awk '/default/ {print $3; exit}')
    [ -z "$gateway" ] && gateway=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
    if [ -n "$gateway" ]; then
        ping -I "$WAN_IF" -c 2 -W 3 "$gateway" >/dev/null 2>&1 && return 0
    fi
    ip -4 addr show dev "$WAN_IF" 2>/dev/null | grep -q "inet " && return 0
    return 1
}

is_ru_site_reachable() {
    ping -I "$WAN_IF" -c 1 -W 1 77.88.8.8 >/dev/null 2>&1 && return 0
    curl -s -k -o /dev/null --connect-timeout 2 --max-time 3 \
         --interface "$WAN_IF" "https://77.88.8.8/" 2>/dev/null
    local rc=$?
    [ $rc -ne 7 ] && [ $rc -ne 28 ]
}

is_public_internet_reachable() {
    # Параллельная проверка канареек. Запускаем все одновременно,
    # ждём конкретные PID (не голый wait — он поймает bg_monitor
    # и повесит главный цикл).
    local tmpdir="$STATE_DIR/canary.$$"
    rm -rf "$tmpdir"
    mkdir -p "$tmpdir"
    local ip pids=""
    for ip in $WHITELIST_CANARIES; do
        (
            curl -s -k -o /dev/null --connect-timeout 2 --max-time 3 \
                 --interface "$WAN_IF" "https://$ip/" 2>/dev/null
            echo "$?" > "$tmpdir/$ip"
        ) &
        pids="$pids $!"
    done
    local p
    for p in $pids; do
        wait "$p"
    done
    local rc alive=0
    for f in "$tmpdir"/*; do
        [ -f "$f" ] || continue
        rc=$(cat "$f" 2>/dev/null)
        [ -z "$rc" ] && continue
        if [ "$rc" != "7" ] && [ "$rc" != "28" ]; then
            alive=1
            break
        fi
    done
    rm -rf "$tmpdir"
    [ "$alive" -eq 1 ]
}

WL_STATE="unknown"
is_whitelist_active() {
    local now=$(date +%s)
    if [ -f "$WHITELIST_CACHE_FILE" ]; then
        local cached=$(cat "$WHITELIST_CACHE_FILE")
        local cstate="${cached%%:*}" cts="${cached##*:}"
        local ttl="$WHITELIST_CACHE_TTL"
        [ "$cstate" = "on" ] && ttl="$WHITELIST_CACHE_TTL_ON"
        if echo "$cts" | grep -q '^[0-9][0-9]*$' && [ $((now - cts)) -lt "$ttl" ]; then
            WL_STATE="$cstate"; return 0
        fi
    fi
    if is_public_internet_reachable; then
        WL_STATE="off"
    elif is_ru_site_reachable; then
        WL_STATE="on"
    else
        WL_STATE="unknown"
    fi
    echo "$WL_STATE:$now" > "$WHITELIST_CACHE_FILE"
    return 0
}

check_log_for_errors() {
    [ ! -f "$ERROR_LOG" ] && return 0
    local total=$(wc -l < "$ERROR_LOG" 2>/dev/null || echo 0)
    local last=$(cat "$ERROR_LOG_CHECKPOINT_FILE" 2>/dev/null || echo 0)
    [ "$total" -lt "$last" ] 2>/dev/null && last=0
    local new_lines=$((total - last))
    local result=0
    if [ "$new_lines" -gt 0 ]; then
        tail -n "$new_lines" "$ERROR_LOG" | grep -qE "failed to dial|connection refused|i/o timeout|no such host" && result=1
    fi
    echo "$total" > "$ERROR_LOG_CHECKPOINT_FILE"
    return $result
}
check_vpn_health() {
    local url
    if [ $(( $(date +%s) % 2 )) -eq 0 ]; then url="http://cp.cloudflare.com/generate_204"
    else url="http://connectivitycheck.gstatic.com/generate_204"; fi
    curl -x socks5h://127.0.0.1:$SOCKS_PORT -s -o /dev/null --connect-timeout 3 --max-time 5 "$url"
}

# ============================ Z2K ============================================
z2k_start() {
    case "$Z2K_TYPE" in
        none) return 0 ;;
        *)
            [ -x "$Z2K_INIT" ] || return 0
            # Паттерн процессов для этого типа
            local pattern=""
            case "$Z2K_TYPE" in
                nfqws|nfqws2) pattern="nfqws" ;;
                zapret)       pattern="nfqws|tpws" ;;
                z2k|z4r)      pattern="nfqws|tpws" ;;
                b4)           pattern="b4" ;;
                custom)       pattern="${Z2K_STATUS_PATTERN:-}" ;;
            esac
            # Если процесс уже жив (orphan от прошлого запуска) —
            # не пытаемся запустить второй. Очередь NFQUEUE занята,
            # второй экземпляр упадёт с "Operation not permitted".
            if [ -n "$pattern" ] && ps 2>/dev/null | grep -v grep | grep -qE "$pattern"; then
                log "z2k_start: процесс уже запущен, второй экземпляр не стартую"
                return 0
            fi
            "$Z2K_INIT" start > /dev/null 2>&1
            sleep 2
            if [ -n "$pattern" ] && ! ps 2>/dev/null | grep -v grep | grep -qE "$pattern"; then
                log "z2k_start WARNING: обходчик $Z2K_TYPE не запустился"
                send_tg "⚠️ Argus-K: обходчик DPI ($Z2K_TYPE) не запустился"
                return 1
            fi
            return 0
            ;;
    esac
}
z2k_stop() {
    case "$Z2K_TYPE" in
        none) return 0 ;;
        *)
            [ -x "$Z2K_INIT" ] || return 0
            "$Z2K_INIT" stop > /dev/null 2>&1
            sleep 2
            local pattern=""
            case "$Z2K_TYPE" in
                nfqws|nfqws2) pattern="nfqws" ;;
                zapret)       pattern="nfqws|tpws" ;;
                z2k|z4r)      pattern="nfqws|tpws" ;;
                b4)           pattern="b4" ;;
                custom)       pattern="${Z2K_STATUS_PATTERN:-}" ;;
            esac
            [ -z "$pattern" ] && return 0
            # Если init не справился (stale PID-файл) — добиваем сами
            local left
            left=$(ps 2>/dev/null | grep -v grep | grep -cE "$pattern")
            if [ "$left" -gt 0 ]; then
                log "z2k_stop WARNING: $left процесс(ов) осталось, добиваю kill -9"
                for p in $(ps 2>/dev/null | grep -v grep | grep -E "$pattern" | awk '{print $1}'); do
                    kill -9 "$p" 2>/dev/null
                done
                # Чистим stale PID-файл, чтобы init не путался
                rm -f /opt/var/run/nfqws2.pid 2>/dev/null
                sleep 1
                left=$(ps 2>/dev/null | grep -v grep | grep -cE "$pattern")
                [ "$left" -gt 0 ] && log "z2k_stop: не удалось добить всё, осталось $left"
            fi
            return 0
            ;;
    esac
}
z2k_status() {
    case "$Z2K_TYPE" in
        none) echo "⚪ не используется" ;;
        *)
            local label="$Z2K_TYPE"
            if [ ! -x "$Z2K_INIT" ]; then
                echo "🔴 не найден ($label)"
                return
            fi
            local pattern=""
            case "$Z2K_TYPE" in
                nfqws|nfqws2) pattern="nfqws" ;;
                zapret)       pattern="nfqws|tpws" ;;
                z2k|z4r)      pattern="nfqws|tpws" ;;
                b4)           pattern="b4" ;;
                custom)       pattern="${Z2K_STATUS_PATTERN:-}" ;;
            esac

            # Источник истины — реальные процессы, а не init-скрипт.
            # Init смотрит stale PID-файл и врёт "not running",
            # когда процесс на самом деле живёт (nfqws2 после reboot или
            # неприятного stop).
            local proc_found=0
            if [ -n "$pattern" ] && ps 2>/dev/null | grep -v grep | grep -qE "$pattern"; then
                proc_found=1
            fi

            local out init_says="unknown"
            out=$("$Z2K_INIT" status 2>/dev/null)
            if echo "$out" | grep -qiE "not running|not started|stopped|inactive|остановлен|не запущен"; then
                init_says="stopped"
            elif echo "$out" | grep -qiE "running|started|active|запущен"; then
                init_says="running"
            fi

            if [ "$proc_found" -eq 1 ]; then
                if [ "$init_says" = "running" ]; then
                    echo "🟢 запущен ($label)"
                else
                    echo "🟡 запущен, init не видит ($label)"
                fi
            else
                echo "⚪ остановлен ($label)"
            fi
            ;;
    esac
}

emergency_cleanup() {
    log "Emergency cleanup"
    kill_main_xray
    clear_xray_rules
    z2k_start
    [ -f "$BGMON_PIDFILE" ]  && kill "$(cat "$BGMON_PIDFILE")"  2>/dev/null
    [ -f "$POLLER_PIDFILE" ] && kill "$(cat "$POLLER_PIDFILE")" 2>/dev/null
    rm -f "$BGMON_PIDFILE" "$POLLER_PIDFILE"
}

# ============================ ДИАГНОСТИКА ====================================
collect_diag() {
    local d=""
    d="🔧 Argus-K diagnostic report
$(date '+%Y-%m-%d %H:%M:%S')

📦 Система
$(uname -m)
Свободно в /opt: $(df -h /opt 2>/dev/null | tail -1 | awk '{print $4}')

🌐 Сеть
WAN_IF: $WAN_IF
WAN_IF_IP: $(ip -4 -o addr show dev "$WAN_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
LAN: $LOCAL_NET, Router: $ROUTER_IP

🔧 Зависимости"
    for c in jq curl ipset xray; do
        if command -v "$c" >/dev/null 2>&1; then
            d="$d
  ✅ $c"
        else
            d="$d
  ❌ $c"
        fi
    done

    d="$d

⚙️  Состояние
Xray: $(is_main_xray_running && echo "🟢 запущен" || echo "🔴 остановлен")
Конфиг: $(basename "$CURRENT_CONFIG" 2>/dev/null)
Живых: $(get_live_config_list | wc -l)
Связь: $(is_link_up && echo "🟢 есть" || echo "🔴 нет")
Белый список: $( case "$WL_STATE" in on) echo "🟡 ВКЛ" ;; off) echo "🟢 выкл" ;; *) echo "⚪ ?" ;; esac )
Редирект: $( [ "$PROXY_STATE" = "on" ] && echo "🟢 вкл" || echo "⚪ выкл" )
Split routing: $( [ "$SPLIT_ROUTING_ENABLED" = "yes" ] && echo "🟢 вкл" || echo "⚪ выкл" )
Обходчик DPI: $(z2k_status)
TG-туннель: $( [ "$TG_TUNNEL_ENABLED" = "yes" ] && echo "🟢 вкл" || echo "⚪ выкл" )

🌐 Канарейки"
    for ip in $WHITELIST_CANARIES; do
        curl -s -k -o /dev/null --connect-timeout 3 --max-time 5 --interface "$WAN_IF" "https://$ip/" 2>/dev/null
        rc=$?
        if [ $rc -ne 7 ] && [ $rc -ne 28 ]; then
            d="$d
  ✅ $ip"
        else
            d="$d
  ❌ $ip"
        fi
    done

    d="$d

📋 iptables
XRAY_PREROUTING: $($IPT_BIN -t nat -L XRAY_PREROUTING -n >/dev/null 2>&1 && echo "🟢 есть" || echo "🔴 нет")
XRAY_TG_PREROUTING: $($IPT_BIN -t nat -L XRAY_TG_PREROUTING -n >/dev/null 2>&1 && echo "🟢 есть" || echo "🔴 нет")
PREROUTING→XRAY: $($IPT_BIN -t nat -C PREROUTING -j XRAY_PREROUTING 2>/dev/null && echo активен || echo нет)

📝 Последние 5 строк лога:
$(tail -n 5 "$LOG_FILE" 2>/dev/null)"

    echo "$d"
}

# ============================ TELEGRAM: КОМАНДЫ ==============================
do_upgrade() {
    local base="https://raw.githubusercontent.com/maansuurchick/Argus-K/main"
    local tmp="/tmp/argus-k-upgrade.$$"
    mkdir -p "$tmp"

    local files="argus-k.sh install-argus.sh argus-k-debug.sh"
    local updated=0 failed=0 old_ver="" mode=""

    old_ver=$(grep -m1 "^# argus-k.sh  (" "$ARGUS_FILE" 2>/dev/null | sed 's/.*(\(v[^)]*\)).*/\1/')
    [ -z "$old_ver" ] && old_ver="?"

    # Сначала пробуем напрямую. Если GitHub недоступен (БС) —
    # переключаемся на SOCKS Xray. Делаем это одной проверкой
    # на первый файл, чтобы не пытаться дважды для каждого.
    local probe="$tmp/.probe"
    if curl -fsSL --connect-timeout 5 --max-time 15 -o /dev/null \
         "$base/argus-k.sh" 2>/dev/null; then
        mode="direct"
        log "upgrade: GitHub доступен напрямую"
    else
        mode="socks"
        log "upgrade: прямой доступ не работает, иду через SOCKS"
    fi

    local curl_opt=""
    [ "$mode" = "socks" ] && curl_opt="-x socks5h://127.0.0.1:$SOCKS_PORT"

    for f in $files; do
        local url="${base}/${f}"
        local dst="/opt/etc/${f}"
        local new_file="$tmp/${f}"

        if ! curl $curl_opt -fsSL --connect-timeout 10 --max-time 60 \
                 "$url" -o "$new_file" 2>/dev/null; then
            log "upgrade: не удалось скачать $f ($mode)"
            failed=$((failed + 1))
            continue
        fi
        [ -s "$new_file" ] || { failed=$((failed + 1)); continue; }

        case "$f" in
            *.sh) sh -n "$new_file" 2>/dev/null || {
                log "upgrade: $f не прошёл sh -n, отменяю"
                failed=$((failed + 1))
                continue
            } ;;
        esac

        if cmp -s "$new_file" "$dst" 2>/dev/null; then
            log "upgrade: $f уже актуален"
            continue
        fi

        [ -f "$dst" ] && cp "$dst" "$dst.bak"
        cp "$new_file" "$dst"
        chmod +x "$dst"
        updated=$((updated + 1))
        log "upgrade: $f обновлён"
    done

    rm -rf "$tmp"

    if [ "$failed" -gt 0 ] && [ "$updated" -eq 0 ]; then
        send_tg "❌ Argus-K: не удалось обновить ($mode, ошибок: $failed)"
        return 1
    fi

    if [ "$updated" -eq 0 ]; then
        send_tg "✅ Argus-K: уже последняя версия ($old_ver, $mode)"
        return 0
    fi

    local new_ver
    new_ver=$(grep -m1 "^# argus-k.sh  (" "$ARGUS_FILE" 2>/dev/null | sed 's/.*(\(v[^)]*\)).*/\1/')
    send_tg "⬆️ Argus-K: обновлено с $old_ver до ${new_ver:-?} ($mode). Перезапускаю..."
    sleep 2
    /opt/etc/init.d/S99argus restart >/dev/null 2>&1 &
}

process_tg_commands() {
    local f proc
    for f in "$TG_QUEUE_DIR"/msg.*; do
        [ -e "$f" ] || continue
        proc="$f.processing"
        mv "$f" "$proc" 2>/dev/null || continue
        while IFS="$(printf '\t')" read -r chat text; do
        is_allowed_chat "$chat" || continue

        case "$text" in
            __CB:*)
                local cbid=$(echo "$text" | cut -d: -f2)
                local cbdata=$(echo "$text" | cut -d: -f3-)
                answer_callback "$cbid"
                case "$cbdata" in
                    use_*)
                        local idx="${cbdata#use_}"
                        local listfile="$STATE_DIR/config_list.${chat}.txt"
                        if [ -f "$listfile" ]; then
                            local path=$(sed -n "${idx}p" "$listfile")
                            if [ -n "$path" ] && [ -f "$path" ]; then
                                use_config_by_path "$path"
                            else
                                send_tg "Конфиг больше не существует. Откройте /configs заново."
                            fi
                        else
                            send_tg "Список устарел. Отправьте /configs заново."
                        fi
                        continue
                        ;;
                esac
                continue
                ;;
        esac
        local cmd=$(echo "$text" | awk '{print tolower($1)}')
        local arg=$(echo "$text" | cut -s -d' ' -f2-)

        case "$cmd" in
            /start|/help)
                send_tg "Argus-K команды:
/status — текущее состояние
/on — включить прокси вручную
/off — выключить прокси вручную
/auto — автоматический режим
/next — переключить VPN-конфиг
/use <имя> — выбрать конфиг по маске
/configs — список конфигов
/restart — перезапустить Xray
/update — обновить конфиги из подписки
/diag — диагностический отчёт
/log — последние строки лога
/upgrade — обновить сам Argus-K с GitHub"
                ;;
            /status)
                load_manual_mode; load_proxy_state
                local xr="🔴 не запущен"; is_main_xray_running && xr="🟢 запущен"
                local link="🔴 нет"; is_link_up && link="🟢 есть"
                is_whitelist_active
                local wl="⚪ ?"
                [ "$WL_STATE" = "on" ]  && wl="🟡 ВКЛ"
                [ "$WL_STATE" = "off" ] && wl="🟢 выкл"
                local mode="авто"; [ "$MANUAL_MODE" -eq 1 ] && mode="ручной ($( [ "$MANUAL_PROXY" = "on" ] && echo "🔒 вкл" || echo "🔓 выкл" ))"
                local live_count=$(get_live_config_list | wc -l)
                local wan_ip=$(ip -4 -o addr show dev "$WAN_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
                send_tg "📊 Argus-K Статус:
Xray: $xr, конфиг: $(basename "$CURRENT_CONFIG" 2>/dev/null)
Живых: $live_count
WAN: $WAN_IF ($wan_ip)
Связь: $link
Белый список: $wl
Редирект: $( [ "$PROXY_STATE" = "on" ] && echo "🟢 вкл" || echo "⚪ выкл" )
Split routing: $( [ "$SPLIT_ROUTING_ENABLED" = "yes" ] && echo "🟢 вкл" || echo "⚪ выкл" )
TG-туннель: $( [ "$TG_TUNNEL_ENABLED" = "yes" ] && echo "🟢 вкл" || echo "⚪ выкл" )
Управление: $mode
Обходчик DPI: $(z2k_status)"
                ;;
            /on)
                MANUAL_MODE=1; MANUAL_PROXY="on"; save_manual_mode; save_manual_proxy
                enable_redirect; z2k_stop
                send_tg "🔒 Argus-K: ручной режим, прокси включен."
                ;;
            /off)
                MANUAL_MODE=1; MANUAL_PROXY="off"; save_manual_mode; save_manual_proxy
                disable_redirect; z2k_start
                send_tg "🔓 Argus-K: ручной режим, прокси выключен."
                ;;
            /auto)
                MANUAL_MODE=0; save_manual_mode
                rm -f "$WHITELIST_CACHE_FILE"
                STATE="__RECHECK__"
                send_tg "🤖 Argus-K: автоматический режим."
                ;;
            /next)
                switch_config
                ;;
            /use)
                if [ -n "$arg" ]; then
                    use_config_by_name "$arg"
                else
                    show_configs_keyboard "$chat"
                fi
                ;;
            /configs)
                show_configs_keyboard "$chat"
                ;;
            /restart)
                kill_main_xray
                start_main_xray "$CURRENT_CONFIG"
                set_xray_rules
                load_proxy_state
                [ "$PROXY_STATE" = "on" ] && enable_redirect
                send_tg "♻️ Argus-K: Xray перезапущен."
                ;;
            /update)
                if update_configs_from_subscription; then
                    scan_configs_liveness
                    send_tg "✅ Argus-K: обновление завершено."
                else
                    send_tg "❌ Argus-K: не удалось обновить."
                fi
                ;;
            /diag)
                send_tg "$(collect_diag)"
                ;;
            /log)
                local log_text=$(tail -n 20 "$LOG_FILE" 2>/dev/null | head -c 3500)
                send_tg "📜 Argus-K лог:
$log_text"
                ;;
            /upgrade)
                send_tg "⏳ Argus-K: проверяю обновления..."
                do_upgrade
                ;;
            *)
                send_tg "Argus-K: неизвестная команда: $text"
                ;;
        esac
        done < "$proc"
        rm -f "$proc"
    done
}

# ============================================================================
# ЗАЩИТА ОТ ДУБЛЕЙ И СТАРТ
# ============================================================================
sleep 1
SELF=$$
if [ -f "$PIDFILE" ]; then
    OLD_PID=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && [ "$OLD_PID" != "$SELF" ]; then
        kill -9 "$OLD_PID" 2>/dev/null
    fi
fi
for p in $(ps | grep -E "argus-k\.sh" | grep -v grep | awk '{print $1}'); do
    [ "$p" = "$SELF" ] && continue
    kill -9 "$p" 2>/dev/null
done
for p in $(ps | grep -E "xray run" | grep -v grep | awk '{print $1}'); do
    kill -9 "$p" 2>/dev/null
done
sleep 2
rm -f "$PIDFILE" "$MAIN_XRAY_PIDFILE" "$BGMON_PIDFILE" "$POLLER_PIDFILE"

echo $$ > "$PIDFILE"
trap 'emergency_cleanup; exit 0' INT TERM
trap 'rm -f "$PIDFILE"' EXIT

load_current_config
load_manual_mode
load_proxy_state

# --- Автодетект WAN_IF (fallback, если установка была ручной) ---
if [ -z "$WAN_IF" ] || echo "$WAN_IF" | grep -q "ВСТАВЬТЕ_"; then
    DETECTED_WAN=$(autodetect_wan_if || true)
    if [ -n "$DETECTED_WAN" ]; then
        WAN_IF="$DETECTED_WAN"
        log "WAN_IF автоопределён: $WAN_IF"
    else
        log "FATAL: WAN_IF не задан и не определён автоматически"
        log "Укажите WAN_IF в /opt/etc/argus-k.sh вручную."
        exit 1
    fi
fi

if [ -z "$LOCAL_NET" ] || echo "$LOCAL_NET" | grep -q "ВСТАВЬТЕ_"; then
    log "FATAL: LOCAL_NET не задан. Запустите install-argus.sh или укажите вручную."
    exit 1
fi

if [ -z "$ROUTER_IP" ] || echo "$ROUTER_IP" | grep -q "ВСТАВЬТЕ_"; then
    log "FATAL: ROUTER_IP не задан. Запустите install-argus.sh или укажите вручную."
    exit 1
fi

if [ -z "$(get_config_list)" ]; then
    log "Конфигов нет — первичное скачивание подписки (bootstrap)"
    update_configs_from_subscription
fi

DNS_HIJACK_MIGRATED_FILE="$STATE_DIR/dns_hijack_migrated.txt"
if [ ! -f "$DNS_HIJACK_MIGRATED_FILE" ]; then
    log "Миграция: добавляю dns-out в конфиги..."
    for f in $(get_config_list); do
        ensure_dns_hijack "$f"
    done
    date +%s > "$DNS_HIJACK_MIGRATED_FILE"
fi

# Прогоняем split routing по всем конфигам. Функция идемпотентна:
# конфиги, где правило уже есть, пропускаются.
if [ "$SPLIT_ROUTING_ENABLED" = "yes" ]; then
    for f in $(get_config_list); do
        inject_split_routing "$f"
    done
fi

if [ -z "$CURRENT_CONFIG" ] || [ ! -f "$CURRENT_CONFIG" ]; then
    if ! initial_quick_scan; then
        log "FATAL: не удалось выбрать стартовый конфиг"
        exit 1
    fi
fi

if ! start_main_xray "$CURRENT_CONFIG"; then
    log "Первая попытка не удалась, полное сканирование..."
    initial_quick_scan && start_main_xray "$CURRENT_CONFIG"
fi
if ! is_main_xray_running; then
    log "FATAL: не удалось запустить Xray"
    exit 1
fi

if configs_need_update; then
    if update_configs_from_subscription; then
        scan_configs_liveness
    fi
fi

set_xray_rules
update_telegram_ips
set_xray_rules
send_tg "🟢 Argus-K запущен (конфиг: $(basename "$CURRENT_CONFIG"), WAN: $WAN_IF)"

start_background_monitor
start_tg_poller

log "=== Argus-K запущен (v5.8.17) ==="
sleep 10

STATE="UNKNOWN"
PENDING_STATE=""
PENDING_SINCE=0
HEALTH_COUNTER=0
HEALTH_FAIL=0

while true; do
    load_manual_mode
    load_proxy_state
    process_tg_commands

    if configs_need_update; then
        if update_configs_from_subscription; then
            scan_configs_liveness
        fi
    fi

    if telegram_ips_stale; then
        if update_telegram_ips; then
            set_xray_rules
        fi
    fi

    if ! is_main_xray_running; then
        log "Основной Xray не запущен — перезапуск"
        start_main_xray "$CURRENT_CONFIG" || switch_config
        set_xray_rules
        load_proxy_state
        [ "$PROXY_STATE" = "on" ] && enable_redirect
    fi

    if [ "$MANUAL_MODE" -eq 1 ]; then
        if [ "$STATE" != "MANUAL" ]; then
            log "Ручной режим ($MANUAL_PROXY)"
            STATE="MANUAL"
        fi
    else
        if ! is_link_up; then
            NEW_STATE="LINK_DOWN"
        else
            is_whitelist_active
            case "$WL_STATE" in
                on)  NEW_STATE="WHITELIST" ;;
                off) NEW_STATE="OPEN" ;;
                *)   NEW_STATE="$STATE" ;;
            esac
        fi

        if [ "$NEW_STATE" != "$STATE" ] && [ -n "$NEW_STATE" ]; then
            # Anti-flapping: ждём, пока новый статус продержится
            # WHITELIST_CONFIRM_SECONDS подряд. Одиночный морг LTE
            # (канарейки упали → ожили за 10 сек) не переключит STATE.
            now_ts=$(date +%s)
            if [ "$NEW_STATE" != "$PENDING_STATE" ]; then
                PENDING_STATE="$NEW_STATE"
                PENDING_SINCE=$now_ts
                log "Кандидат на смену состояния: $NEW_STATE (подтверждаю $WHITELIST_CONFIRM_SECONDS сек)"
            else
                pending_duration=$((now_ts - PENDING_SINCE))
                if [ "$pending_duration" -ge "$WHITELIST_CONFIRM_SECONDS" ]; then
                    case "$NEW_STATE" in
                        OPEN)
                            log "-> OPEN (подтверждено $pending_duration сек)"
                            disable_redirect
                            z2k_start
                            send_tg "🌐 Argus-K: белый список выключен, прямой доступ."
                            ;;
                        WHITELIST)
                            log "-> WHITELIST (подтверждено $pending_duration сек)"
                            enable_redirect
                            z2k_stop
                            send_tg "🚧 Argus-K: белый список включён, трафик сети через VPN."
                            ;;
                        LINK_DOWN)
                            log "-> LINK_DOWN (подтверждено $pending_duration сек)"
                            disable_redirect
                            z2k_stop
                            ;;
                    esac
                    STATE="$NEW_STATE"
                    PENDING_STATE=""
                    PENDING_SINCE=0
                    HEALTH_COUNTER=0
                    HEALTH_FAIL=0
                fi
            fi
        else
            # Состояние совпадает с текущим — сбрасываем накопление
            PENDING_STATE=""
            PENDING_SINCE=0
        fi
    fi

    load_proxy_state
    if is_main_xray_running && [ "$PROXY_STATE" = "on" ]; then
        log_error_found=0
        check_log_for_errors || { log_error_found=1; log "В логе Xray есть ошибки"; }

        HEALTH_COUNTER=$((HEALTH_COUNTER + 1))
        health_failed=0
        if [ $((HEALTH_COUNTER % HEALTH_CHECK_INTERVAL)) -eq 0 ]; then
            if check_vpn_health >/dev/null 2>&1; then
                HEALTH_FAIL=0
            else
                health_failed=1
                HEALTH_FAIL=$((HEALTH_FAIL + 1))
                log "Health-check не прошёл ($HEALTH_FAIL/$HEALTH_FAIL_THRESHOLD)"
            fi
        fi

        now_ts=$(date +%s)
        since_switch=$((now_ts - LAST_SWITCH_TS))
        need_switch=0
        if [ "$since_switch" -ge "$MIN_STABLE_SECONDS" ]; then
            [ $log_error_found -eq 1 ] && need_switch=1
            [ $health_failed -eq 1 ] && [ $HEALTH_FAIL -ge $HEALTH_FAIL_THRESHOLD ] && need_switch=1
        fi

        if [ $need_switch -eq 1 ]; then
            switch_config && HEALTH_FAIL=0
        fi
    fi

    sleep "$MAIN_LOOP_SLEEP"
done
