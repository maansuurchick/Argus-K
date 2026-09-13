#!/bin/sh
# install-bootstrap.sh — установщик Argus-K
set -e

BRANCH="${BRANCH:-main}"
REPO_OWNER="${REPO_OWNER:-maansuurchick}"
REPO_NAME="${REPO_NAME:-argus-k}"
BASE_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}"

INSTALLER_DST="/opt/etc/install-argus.sh"
ARGUS_DST="/opt/etc/argus-k.sh"
DEBUG_DST="/opt/etc/argus-k-debug.sh"
INIT_DST="/opt/etc/init.d/S99argus"
SPLIT_DST="/opt/etc/argus-k-split-domains.txt"

if [ "$(id -u)" != "0" ]; then
    echo "ОШИБКА: запустите от root"
    exit 1
fi

if ! mount 2>/dev/null | grep -q " /opt "; then
    echo "ОШИБКА: /opt не смонтирован — Entware не установлен."
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "ОШИБКА: curl не найден. Установите: opkg install curl"
    exit 1
fi

echo ""
echo "=== Argus-K установка ==="
echo ""

for pair in \
    "argus-k.sh:$ARGUS_DST" \
    "install-argus.sh:$INSTALLER_DST" \
    "argus-k-debug.sh:$DEBUG_DST" \
    "templates/S99argus:$INIT_DST" \
    "templates/split-domains.txt:$SPLIT_DST"
do
    src="${pair%%:*}"
    dst="${pair##*:}"
    echo "Скачиваю $src -> $dst"
    mkdir -p "$(dirname "$dst")"
    if curl -fsSL -o "$dst" "${BASE_URL}/${src}"; then
        case "$src" in
            templates/split-domains.txt) : ;;
            *) chmod +x "$dst" ;;
        esac
        echo "  OK"
    else
        echo "  ОШИБКА: не удалось скачать $src"
        case "$src" in
            argus-k.sh|install-argus.sh) exit 1 ;;
        esac
    fi
done

[ -s "$ARGUS_DST" ] || { echo "argus-k.sh пустой"; exit 1; }
head -1 "$ARGUS_DST" | grep -q "^#!/bin/sh" || {
    echo "argus-k.sh не похож на shell-скрипт"
    exit 1
}

echo ""
echo "=== Все файлы скачаны ==="
echo ""

# Инсталлеру нужен TTY для read. Если скрипт запущен через pipe
# (curl ... | sh), stdin занят и read не работает. Переключаемся
# на /dev/tty, если он доступен.
if [ -t 0 ]; then
    exec "$INSTALLER_DST"
elif [ -r /dev/tty ] && [ -c /dev/tty ]; then
    echo "Обнаружен запуск через pipe — переключаю ввод на /dev/tty"
    exec "$INSTALLER_DST" < /dev/tty
else
    echo "Интерактивный ввод недоступен (нет /dev/tty)."
    echo ""
    echo "Файлы скачаны, инсталлер не запущен."
    echo "Запустите вручную:"
    echo ""
    echo "  sh $INSTALLER_DST"
    echo ""
    exit 0
fi
