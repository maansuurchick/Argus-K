# Argus-K

Argus-K  — скрипт
автоматического управления Xray на роутерах Keenetic с
LTE-модемом (KeeneticOS + Entware).

Скрипт рассчитан на ситуацию, когда мобильный оператор
включает **режим белых списков** — пропускает только
одобренные ресурсы, а всё остальное режет. Argus-K
определяет это и **временно направляет трафик устройств
в сети через Xray-туннель**. Как только white list
выключается, трафик снова идёт напрямую.

При этом Telegram можно пустить через VPN всегда — это
полезно, если мессенджер должен работать стабильно, даже
когда остальной интернет доступен напрямую.

> Для проводного интернета (Ethernet, GPON, PPPoE) скрипт
> тоже работает, но детект белого списка там обычно не
> срабатывает — у проводных провайдеров такого режима нет.

## Чем это отличается от Xkeen и bypass_keenetic

Это разные инструменты, решающие разные задачи — их можно
использовать вместе.

- **Xkeen** — это слой запуска Xray на KeeneticOS: установка,
  CLI-обёртки, ротация, управление конфигами через opkg.
  Инфраструктура. Argus-K такой слой не заменяет.
- **bypass_keenetic** — набор скриптов для маршрутизации
  и обхода DPI через Xray. Фокус — что и как проксировать.
- **Argus-K** — автоматика поверх всего этого, заточенная
  под **конкретный сценарий**: LTE-оператор с white list.
  Он сам определяет, включился ли white list, и включает
  редирект трафика в VPN только на это время. Плюс
  Telegram-бот, автосмена конфигов по живости, прозрачный
  туннель для Telegram, split routing для RU-доменов.

Коротко: Xkeen/bypass_keenetic отвечают на вопрос «как
поднять Xray и что через него пускать», Argus-K — на вопрос
«когда его включать и как не вмешиваться вручную». Если
вы уже используете Xkeen — Argus-K можно поставить рядом,
он не претендует на его роль.

## Как это работает

Argus-K не заворачивает весь интернет в VPN постоянно. Он
**включает редирект трафика через Xray-туннель только
тогда**, когда это действительно нужно — при white list
мобильного оператора. В обычном режиме устройства в сети
выходят в интернет напрямую, как обычно.

Служба Xray при этом всегда запущена в фоне — она ничего
не перенаправляет, пока Argus-K не даст команду. Это нужно
для двух вещей:
- Telegram-бот может управлять роутером и отправлять
  уведомления в любой момент.
- Прозрачный туннель для Telegram (если включён) работает
  всегда — Telegram идёт через VPN, а остальной интернет
  напрямую.

## Возможности

- **Детект white list** оператора через канарейки.
- **Редирект трафика устройств в сети через Xray только
  при white list** — в обычном режиме трафик идёт напрямую.
- **Прозрачный туннель для Telegram** — при желании можно
  пустить только Telegram через VPN, остальное напрямую.
  Инсталлер сам проверяет, не установлен ли уже сторонний
  туннель (z2k, z4r, sing-box, mtg) и не конфликтует с ним.
- **Split routing для RU-доменов**: если в скачанном
  конфиге нет своих domain-based direct-правил, Argus-K
  добавит одно правило со списком из
  `/opt/etc/argus-k-split-domains.txt`. Российские сервисы
  пойдут напрямую, остальное — через VPN.
- **Автообновление конфигов** из подписки Happ.
- **Автопереключение между живыми конфигами** при падении
  туннеля.
- **Управление через Telegram** (`/status`, `/on`, `/off`,
  `/auto`, `/next`, `/configs`, `/update`, `/diag`, `/log`).
- **Поддержка обходчиков DPI**: nfqws, nfqws2, zapret, z2k,
  b4, z4r.
- **Работа тихо в фоне**, если Telegram не настроен.
- **Поддержка нескольких Telegram-пользователей**.
- **Автоопределение сетевых параметров**: WAN-интерфейс
  (LTE/USB/PPPoE), IP роутера и локальная подсеть —
  инсталлер находит их сам.

## Требования

- Keenetic с KeeneticOS и установленным Entware.
- LTE-модем (USB или встроенный) в режиме основного
  интернет-подключения.
- USB-флешка или внутренняя память, примонтированная в `/opt`.
- Подписка Xray в формате Happ (JSON).
- От 5 до 50 МБ свободного места.

## Быстрая установка

Скопируйте **одну команду** в SSH-консоль роутера:

```sh
opkg update && opkg install curl && \
  curl -fsSL https://raw.githubusercontent.com/maansuurchick/argus-k/main/install-bootstrap.sh -o /tmp/argus-bootstrap.sh && \
  sh /tmp/argus-bootstrap.sh
```

Первая часть ставит curl, вторая — скачивает bootstrap
в файл и запускает его. Bootstrap скачает все файлы,
подготовит конфиг и сразу запустит интерактивную
настройку.

> **Почему не через pipe?** Классический способ
> `curl ... | sh` занимает stdin скриптом, и инсталлер
> не может задавать вопросы через `read`. Поэтому
> bootstrap скачивается в файл и запускается отдельно.

## Документация

- [Настройка DNS в Keenetic](docs/DNS-SETUP.md)
- [Получение данных устройства через mitmproxy](docs/MITMPROXY.md)
- [Решение проблем](docs/TROUBLESHOOTING.md)
- [FAQ](docs/FAQ.md)

## Обновление

Повторно запустите ту же команду bootstrap. Свежие файлы
скачаются автоматически.

## Удаление

### Автоматически (рекомендуется)

```sh
sh /opt/etc/uninstall-argus.sh
```

Скрипт спросит подтверждение, затем удалит:
- службу Argus-K и её Xray-процесс;
- iptables-цепочки `XRAY_PREROUTING`, `XRAY_OUTPUT`, `XRAY_TG_PREROUTING`;
- ipset `argus_k_tg_ips`;
- hook-файл `/opt/etc/ndm/netfilter.d/099-argus-k.sh`;
- все файлы скрипта из `/opt/etc/`;
- каталог состояния `/tmp/argus-k` и логи.

Спросит отдельно, удалять ли скачанные конфиги
(`/opt/etc/xray/configs/sub_*.json`). Можно сохранить их
флагом:

```sh
sh /opt/etc/uninstall-argus.sh --keep-configs
```

Без интерактивных вопросов (например, для скрипта):

```sh
sh /opt/etc/uninstall-argus.sh --yes
```

### Что НЕ удаляется

Скрипт **не трогает**:
- Xray (`/opt/sbin/xray`) — установлен через Entware;
- пакеты Entware (`jq`, `curl`, `ipset`);
- твои собственные конфиги Xray, не начинающиеся с `sub_`.

Если хочешь удалить и Xray:

```sh
opkg remove xray
```

### Вручную

Если автоматический удалятор недоступен:

````sh
/opt/etc/init.d/S99argus stop
killall -9 xray 2>/dev/null
iptables -t nat -D PREROUTING -j XRAY_TG_PREROUTING 2>/dev/null
iptables -t nat -D PREROUTING -j XRAY_PREROUTING 2>/dev/null
iptables -t nat -D OUTPUT -j XRAY_OUTPUT 2>/dev/null
iptables -t nat -F XRAY_PREROUTING 2>/dev/null; iptables -t nat -X XRAY_PREROUTING 2>/dev/null
iptables -t nat -F XRAY_OUTPUT 2>/dev/null; iptables -t nat -X XRAY_OUTPUT 2>/dev/null
iptables -t nat -F XRAY_TG_PREROUTING 2>/dev/null; iptables -t nat -X XRAY_TG_PREROUTING 2>/dev/null
ipset destroy argus_k_tg_ips 2>/dev/null
rm -f /opt/etc/ndm/netfilter.d/099-argus-k.sh
rm -f /opt/etc/init.d/S99argus /opt/etc/argus-k.sh
rm -f /opt/etc/install-argus.sh /opt/etc/argus-k-debug.sh
rm -f /opt/etc/argus-k-split-domains.txt /opt/etc/uninstall-argus.sh
rm -rf /tmp/argus-k
rm -f /tmp/argus-k.log /tmp/argus-k-live_configs.txt /tmp/argus-k-telegram_ips.txt
````

## Лицензия

MIT — см. LICENSE.
