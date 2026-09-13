#!/bin/sh
# install-bootstrap.sh — установщик Argus-K
#
# Argus-K — автоматическое управление Xray на роутерах Keenetic
# с LTE-модемом (KeeneticOS + Entware). Рассчитан на ситуацию,
# когда мобильный оператор включает режим белых списков.
#
# Использование:
#   curl -fsSL https://raw.githubusercontent.com/USER/argus-k/main/install-bootstrap.sh | sh
#
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
    echo "Скачиваю $src → $dst"
    mkdir -p "$(dirname "$dst")"
    if curl -fsSL -o "$dst" "${BASE_URL}/${src}"; then
        case "$src" in
            templates/split-domains.txt) : ;;
            *) chmod +x "$dst" ;;
        esac
        echo "  OK"
    else
        echo "  ❌ Не удалось скачать $src"
        case "$src" in
            argus-k.sh|install-argus.sh) exit 1 ;;
        esac
    fi
done

[ -s "$ARGUS_DST" ] || { echo "❌ argus-k.sh пустой"; exit 1; }
head -1 "$ARGUS_DST" | grep -q "^#!/bin/sh" || {
    echo "❌ argus-k.sh не похож на shell-скрипт"
    exit 1
}

echo ""
echo "=== Запуск инсталлера ==="
echo ""
exec "$INSTALLER_DST"