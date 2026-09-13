\# Решение проблем



\## Бот не отвечает



\### Идёт первое сканирование конфигов



При первом запуске скрипт проверяет все конфиги — это

занимает 3–7 минут. Прогресс:



```sh

tail -f /tmp/argus-k.log

```



Дождитесь строки `Telegram poller запущен`.



\### Xray не запущен



```sh

ps | grep "xray run" | grep -v grep

netstat -tlnp 2>/dev/null | grep 10808

```



Если процессов нет — смотрите `/opt/var/log/xray/error.log`.



\### Проверка SOCKS



```sh

curl -x socks5h://127.0.0.1:10808 -s -o /dev/null -w "HTTP: %{http\_code}\\n" \\

&#x20;    --max-time 10 https://api.telegram.org

```



\- `200` — работает

\- `000` — не работает



\## Интернет у устройств не работает при whitelist



Проверьте, что редирект включён:



```sh

iptables -t nat -L XRAY\_PREROUTING -n -v

```



\## Не тот WAN-интерфейс



Симптомы:

\- в логе постоянно `-> LINK\_DOWN`;

\- ping канареек всегда падает;

\- редирект включается, но интернета нет.



Проверьте:



```sh

\# Что сейчас в конфиге

grep "^WAN\_IF=" /opt/etc/argus-k.sh



\# Какие интерфейсы есть в системе

ip -4 -o addr show | grep -v "lo\\|br0"



\# Куда смотрит default route

ip route show default

```



Если интерфейс не тот — либо перезапустите инсталлер

(он определит заново), либо впишите вручную:



```sh

sed -i 's|^WAN\_IF=.\*|WAN\_IF="usb0"|' /opt/etc/argus-k.sh

/opt/etc/init.d/S99argus restart

```



\## ROUTER\_IP не совпадает с реальным



Проверка:



```sh

grep "^ROUTER\_IP=" /opt/etc/argus-k.sh

ip -4 addr show br0

```



Если IP роутера изменился (например, сменили подсеть LAN),

поправьте:



```sh

sed -i 's|^ROUTER\_IP=.\*|ROUTER\_IP="10.0.0.1"|' /opt/etc/argus-k.sh

sed -i 's|^LOCAL\_NET=.\*|LOCAL\_NET="10.0.0.0/24"|' /opt/etc/argus-k.sh

/opt/etc/init.d/S99argus restart

```



\## Xray падает при старте после split routing



Если в логе:



```

failed to load geosite

```



или ошибки парсинга JSON — значит конфиг получил битое

правило. Отключите split routing:



```sh

sed -i 's|^SPLIT\_ROUTING\_ENABLED=.\*|SPLIT\_ROUTING\_ENABLED="no"|' /opt/etc/argus-k.sh

/opt/etc/init.d/S99argus restart

```



Если ошибка осталась — перекачайте конфиги из подписки

(команда `/update` в боте) — они придут заново без

наших правил.



\## Telegram-туннель конфликтует со сторонним



Проверьте, что видит Argus-K:



```sh

sh /opt/etc/argus-k-debug.sh

```



Раздел «Конфликты TG-туннеля» покажет, что нашлось в

ipset / iptables / процессах.



Если у вас уже есть сторонний туннель (z2k, z4r, sing-box),

выключите встроенный:



```sh

sed -i 's|^TG\_TUNNEL\_ENABLED=.\*|TG\_TUNNEL\_ENABLED="no"|' /opt/etc/argus-k.sh

/opt/etc/init.d/S99argus restart

```



\## Автозагрузка



```sh

ls -la /opt/etc/init.d/S99argus

/opt/etc/init.d/S99argus status

```



\## Дубли процессов



```sh

PID=$(cat /tmp/argus-k/argus-k.pid)

for p in $(ps | grep argus-k.sh | grep -v grep | awk '{print $1}'); do

&#x20;   \[ "$p" != "$PID" ] \&\& kill -9 "$p"

done

```



\## Логи



| Файл | Что содержит |

|---|---|

| `/tmp/argus-k.log` | Основной лог |

| `/opt/var/log/xray/error.log` | Лог Xray |

| `/tmp/argus-k/` | Файлы состояния |



\## Диагностика одной командой



```sh

sh /opt/etc/argus-k-debug.sh

```

