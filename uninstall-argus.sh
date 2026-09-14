#!/bin/sh
# uninstall-argus.sh — полное удаление Argus-K
#
# Использование:
#   sh /opt/etc/uninstall-argus.sh           # интерактивно
#   sh /opt/etc/uninstall-argus.sh --keep-configs  # сохранить sub_*.json
#   sh /opt/etc/uninstall-argus.sh --yes     # без вопросов
#
# Что удаляется:
#   - процессы Argus-K и его Xray
#   - iptables-цепочки XRAY_PREROUTING, XRAY_OUTPUT, XRAY_TG_PREROUTING
#   - ipset argus_k_tg_ips
#   - /opt/etc/ndm/netfilter.d/099-argus-k.sh
#   - все файлы скрипта в /opt/etc/
#   - каталог состояния /tmp/argus-k и логи
#
# Что НЕ удаляется без спроса:
#   - конфиги Xray из подписки (/opt/etc/xray/configs/sub_*.json)
#   - сам Xray (/opt/sbin/xray)
#   - Entware и его пакеты

INIT_FILE="/opt/etc/init.d/S99argus"
ARGUS_FILE="/opt/etc/argus-k.sh"
INSTALLER_FILE="/opt/etc/install-argus.sh"
DEBUG_FILE="/opt/etc/argus-k-debug.sh"
SPLIT_FILE="/opt/etc/argus-k-split-domains.txt"
CONF_FILE="/opt/etc/argus-k.conf"
HOOK_FILE="/opt/etc/ndm/netfilter.d/099-argus-k.sh"
STATE_DIR="/tmp/argus-k"
LOG_FILE="/tmp/argus-k.log"
LIVE_FILE="/tmp/argus-k-live_configs.txt"
TG_IPS_FILE="/tmp/argus-k-telegram_ips.txt"
CONFIG_DIR="/opt/etc/xray/configs"
ARGUS_CONF="/opt/etc/argus-k.conf"

IPT_BIN="/opt/sbin/iptables"
[ -x "$IPT_BIN" ] || IPT_BIN=$(command -v iptables)
IPSET_BIN="/opt/sbin/ipset"
[ -x "$IPSET_BIN" ] || IPSET_BIN=$(command -v ipset)

FORCE_YES=0
KEEP_CONFIGS=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y) FORCE_YES=1 ;;
        --keep-configs) KEEP_CONFIGS=1 ;;
        --help|-h)
            echo "Использование:"
            echo "  sh $0                  # интерактивно"
            echo "  sh $0 --yes            # без подтверждений"
            echo "  sh $0 --keep-configs   # сохранить конфиги Xray из подписки"
            exit 0
            ;;
    esac
done

ask() {
    [ "$FORCE_YES" -eq 1 ] && return 0
    printf "%s (y/N): " "$1"
    read ANS
    case "$ANS" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

echo "============================================================"
echo "  Argus-K — полное удаление"
echo "============================================================"
echo ""
echo "Будут удалены:"
echo "  - служба Argus-K и её Xray-процесс"
echo "  - iptables-цепочки: XRAY_PREROUTING, XRAY_OUTPUT, XRAY_TG_PREROUTING"
echo "  - ipset argus_k_tg_ips"
echo "  - файлы:"
echo "      $ARGUS_FILE"
echo "      $INSTALLER_FILE"
echo "      $DEBUG_FILE"
echo "      $SPLIT_FILE"
echo "      $CONF_FILE (если есть)"
echo "      $INIT_FILE"
echo "      $HOOK_FILE"
echo "  - каталог состояния $STATE_DIR"
echo "  - логи $LOG_FILE и др."
echo ""
if [ "$KEEP_CONFIGS" -eq 0 ]; then
    echo "Также будут удалены:"
    echo "  - конфиги Xray из подписки: $CONFIG_DIR/sub_*.json"
    echo ""
    echo "Если хочешь сохранить конфиги — запусти так:"
    echo "  sh $0 --keep-configs"
    echo ""
fi

if ! ask "Продолжить удаление?"; then
    echo "Отменено."
    exit 0
fi

echo ""
echo "=== Шаг 1. Останавливаю службу ==="

if [ -x "$INIT_FILE" ]; then
    "$INIT_FILE" stop 2>/dev/null && echo "  служба остановлена" || echo "  служба не отвечает"
else
    echo "  init-скрипт не найден — пропускаю"
fi

echo ""
echo "=== Шаг 2. Убиваю процессы ==="

for p in $(ps 2>/dev/null | grep -E "argus-k\.sh" | grep -v grep | awk '{print $1}'); do
    kill -9 "$p" 2>/dev/null && echo "  killed argus-k.sh pid=$p"
done

for p in $(ps 2>/dev/null | grep -E "xray run -c .*argus-k" | grep -v grep | awk '{print $1}'); do
    kill -9 "$p" 2>/dev/null && echo "  killed xray pid=$p"
done

sleep 1

echo ""
echo "=== Шаг 3. Чищу iptables ==="

if [ -n "$IPT_BIN" ]; then
    for chain in XRAY_TG_PREROUTING XRAY_PREROUTING XRAY_OUTPUT; do
        while $IPT_BIN -t nat -D PREROUTING -j "$chain" 2>/dev/null; do :; done
        while $IPT_BIN -t nat -D OUTPUT -j "$chain" 2>/dev/null; do :; done
        $IPT_BIN -t nat -F "$chain" 2>/dev/null
        $IPT_BIN -t nat -X "$chain" 2>/dev/null && echo "  удалена цепочка $chain" || true
    done
else
    echo "  iptables не найден — пропускаю"
fi

echo ""
echo "=== Шаг 4. Чищу ipset ==="

if [ -n "$IPSET_BIN" ] && [ -x "$IPSET_BIN" ]; then
    if $IPSET_BIN list -n 2>/dev/null | grep -q "^argus_k_tg_ips$"; then
        $IPSET_BIN destroy argus_k_tg_ips 2>/dev/null && echo "  ipset argus_k_tg_ips удалён"
    else
        echo "  ipset не найден — пропускаю"
    fi
else
    echo "  ipset не найден — пропускаю"
fi

echo ""
echo "=== Шаг 5. Удаляю hook и файлы ==="

[ -f "$HOOK_FILE" ] && rm -f "$HOOK_FILE" && echo "  удалён $HOOK_FILE"
[ -f "$INIT_FILE" ] && rm -f "$INIT_FILE" && echo "  удалён $INIT_FILE"
[ -f "$ARGUS_FILE" ] && rm -f "$ARGUS_FILE" && echo "  удалён $ARGUS_FILE"
[ -f "$INSTALLER_FILE" ] && rm -f "$INSTALLER_FILE" && echo "  удалён $INSTALLER_FILE"
[ -f "$DEBUG_FILE" ] && rm -f "$DEBUG_FILE" && echo "  удалён $DEBUG_FILE"
[ -f "$SPLIT_FILE" ] && rm -f "$SPLIT_FILE" && echo "  удалён $SPLIT_FILE"
[ -f "$CONF_FILE" ] && rm -f "$CONF_FILE" && echo "  удалён $CONF_FILE"

rm -rf "$STATE_DIR" && echo "  удалён $STATE_DIR"
rm -f "$LOG_FILE" "$LIVE_FILE" "$TG_IPS_FILE"

echo ""
echo "=== Шаг 6. Конфиги Xray ==="

if [ "$KEEP_CONFIGS" -eq 1 ]; then
    echo "  сохранены по флагу --keep-configs"
else
    if ls "$CONFIG_DIR"/sub_*.json >/dev/null 2>&1; then
        CNT=$(ls "$CONFIG_DIR"/sub_*.json 2>/dev/null | wc -l)
        echo "  найдено $CNT конфигов из подписки"
        if ask "  Удалить их?"; then
            rm -f "$CONFIG_DIR"/sub_*.json
            echo "  удалено $CNT конфигов"
        else
            echo "  сохранены"
        fi
    else
        echo "  конфигов из подписки нет"
    fi
fi

echo ""
echo "=== Шаг 7. Проверка ==="

LEFT=0
for f in "$ARGUS_FILE" "$INSTALLER_FILE" "$DEBUG_FILE" "$SPLIT_FILE" "$INIT_FILE" "$HOOK_FILE"; do
    [ -e "$f" ] && { echo "  ОСТАЛСЯ: $f"; LEFT=$((LEFT+1)); }
done
[ -d "$STATE_DIR" ] && { echo "  ОСТАЛСЯ: $STATE_DIR"; LEFT=$((LEFT+1)); }

if [ -n "$IPT_BIN" ]; then
    for chain in XRAY_PREROUTING XRAY_OUTPUT XRAY_TG_PREROUTING; do
        if $IPT_BIN -t nat -L "$chain" -n >/dev/null 2>&1; then
            echo "  ОСТАЛАСЬ iptables-цепочка: $chain"
            LEFT=$((LEFT+1))
        fi
    done
fi

for p in $(ps 2>/dev/null | grep -E "argus-k|xray run -c .*argus-k" | grep -v grep | awk '{print $1}'); do
    echo "  ОСТАЛСЯ процесс: pid=$p"
    LEFT=$((LEFT+1))
done

echo ""
echo "============================================================"
if [ "$LEFT" -eq 0 ]; then
    echo "  Готово. Argus-K полностью удалён."
else
    echo "  Удаление завершено, но остались следы: $LEFT"
    echo "  Проверь вручную вывод выше."
fi
echo "============================================================"
echo ""
# Восстанавливаем обходчик DPI, если он был настроен
if [ -f "$ARGUS_CONF" ]; then
    Z2K_TYPE_SAVED=$(grep "^Z2K_TYPE=" "$ARGUS_CONF" 2>/dev/null | cut -d= -f2- | tr -d '"')
    Z2K_INIT_SAVED=$(grep "^Z2K_INIT=" "$ARGUS_CONF" 2>/dev/null | cut -d= -f2- | tr -d '"')
    if [ -n "$Z2K_INIT_SAVED" ] && [ "$Z2K_TYPE_SAVED" != "none" ] && [ -x "$Z2K_INIT_SAVED" ]; then
        echo ""
        echo "=== Шаг 8. Восстановление обходчика DPI ==="
        echo "  Обходчик: $Z2K_TYPE_SAVED ($Z2K_INIT_SAVED)"
        if ask "  Включить его обратно?"; then
            "$Z2K_INIT_SAVED" start 2>/dev/null && echo "  запущен" || echo "  не удалось запустить"
        else
            echo "  оставлен выключенным"
        fi
    fi
fi

echo "Xray (/opt/sbin/xray), Entware и его пакеты не тронуты."
echo "Если хочешь удалить и Xray:"
echo "  opkg remove xray"
