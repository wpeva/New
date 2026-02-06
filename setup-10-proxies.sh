#!/bin/bash
# ============================================================
#  Скрипт "одна кнопка": ставит и запускает 10 HTTP-прокси
#  на портах 3128–3137 с авторизацией логин/пароль.
#
#  Запуск:  sudo bash setup-10-proxies.sh
# ============================================================

set -e  # остановиться при первой же ошибке

# --------------------- НАСТРОЙКИ ----------------------------
# Меняй эти переменные под себя перед запуском.

PROXY_USER="proxyuser"          # логин для подключения к прокси
PROXY_PASS="SuperSecret123"     # пароль (поменяй на свой!)
PORT_START=3128                 # первый порт
PORT_COUNT=10                   # сколько прокси запустить
MAX_CONNECTIONS=200             # макс. одновременных соединений на все прокси

# --------------------- ЦВЕТА --------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # сброс цвета

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${YELLOW}[..]${NC} $1"; }
fail() { echo -e "${RED}[!!]${NC} $1"; exit 1; }

# --------------------- ПРОВЕРКИ -----------------------------
if [ "$EUID" -ne 0 ]; then
  fail "Запусти скрипт от root:  sudo bash $0"
fi

PORT_END=$((PORT_START + PORT_COUNT - 1))

echo ""
echo "=========================================="
echo "  Установка 10 прокси: порты ${PORT_START}–${PORT_END}"
echo "  Логин: ${PROXY_USER}"
echo "  Пароль: ${PROXY_PASS}"
echo "=========================================="
echo ""

# --------------------- 1. ОБНОВЛЕНИЕ СИСТЕМЫ ----------------
info "Обновление системы..."
apt update -qq && apt upgrade -y -qq
ok "Система обновлена"

# --------------------- 2. УСТАНОВКА ЗАВИСИМОСТЕЙ ------------
info "Установка build-essential и git..."
apt install -y -qq build-essential git ufw
ok "Зависимости установлены"

# --------------------- 3. СБОРКА 3PROXY ---------------------
if [ -f /usr/local/bin/3proxy ]; then
  ok "3proxy уже установлен, пропускаю сборку"
else
  info "Скачивание и сборка 3proxy..."
  cd /tmp
  rm -rf 3proxy
  git clone --quiet https://github.com/3proxy/3proxy.git
  cd 3proxy
  make -f Makefile.Linux -s
  cp bin/3proxy /usr/local/bin/3proxy
  chmod +x /usr/local/bin/3proxy
  cd /
  rm -rf /tmp/3proxy
  ok "3proxy собран и установлен"
fi

# --------------------- 4. СТРУКТУРА ПАПОК -------------------
mkdir -p /etc/3proxy
mkdir -p /var/log/3proxy
chown -R nobody:nogroup /var/log/3proxy
chmod -R 755 /var/log/3proxy

# --------------------- 5. ФАЙЛ ПАРОЛЕЙ ---------------------
info "Создание файла паролей..."
cat > /etc/3proxy/.proxyauth <<EOF
${PROXY_USER}:CL:${PROXY_PASS}
EOF
chmod 600 /etc/3proxy/.proxyauth
chown root:root /etc/3proxy/.proxyauth
ok "Файл паролей создан"

# --------------------- 6. ГЕНЕРАЦИЯ КОНФИГА ----------------
info "Генерация конфига на ${PORT_COUNT} портов..."

cat > /etc/3proxy/3proxy.cfg <<CFGEOF
# --- Автоматически сгенерировано setup-10-proxies.sh ---

# Запуск от непривилегированного пользователя (безопасность)
setgid 65534
setuid 65534

# DNS-кеш
nscache 65536

# Таймауты: подключение 1с, первый ответ 5с, данные 30с
timeouts 1 5 30

# Логи (новый файл каждый день)
log /var/log/3proxy/3proxy.log D
logformat "- +_L%t.%. %N.%p %E %U %C:%c %R:%r %O %I %h %T"

# Авторизация по логину/паролю
users \$/etc/3proxy/.proxyauth
auth strong

# Лимит одновременных соединений
maxconn ${MAX_CONNECTIONS}

# ---------- HTTP-прокси (${PORT_COUNT} штук) ----------
CFGEOF

for i in $(seq 0 $((PORT_COUNT - 1))); do
  port=$((PORT_START + i))
  echo "proxy -p${port}" >> /etc/3proxy/3proxy.cfg
done

ok "Конфиг создан: /etc/3proxy/3proxy.cfg"

# --------------------- 7. SYSTEMD-СЕРВИС ------------------
info "Создание systemd-сервиса..."

cat > /etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/3proxy /etc/3proxy/3proxy.cfg
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable 3proxy --quiet
ok "Сервис создан и включён в автозапуск"

# --------------------- 8. ФАЙРВОЛЛ (UFW) ------------------
info "Настройка файрволла..."
ufw allow 22/tcp       > /dev/null 2>&1
ufw allow ${PORT_START}:${PORT_END}/tcp > /dev/null 2>&1
ufw --force enable     > /dev/null 2>&1
ok "Файрволл настроен: SSH + порты ${PORT_START}–${PORT_END}"

# --------------------- 9. ЗАПУСК / ПЕРЕЗАПУСК --------------
info "Запуск 3proxy..."
systemctl restart 3proxy
sleep 2

if systemctl is-active --quiet 3proxy; then
  ok "3proxy запущен и работает!"
else
  fail "3proxy не запустился. Смотри: journalctl -u 3proxy -n 30"
fi

# --------------------- 10. ВЫВОД РЕЗУЛЬТАТА ----------------
SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || curl -s --max-time 5 api.ipify.org 2>/dev/null || echo "НЕ_ОПРЕДЕЛЁН")

echo ""
echo "=========================================="
echo -e "${GREEN}  ГОТОВО! 10 прокси запущены.${NC}"
echo "=========================================="
echo ""
echo "  Внешний IP сервера: ${SERVER_IP}"
echo "  Логин:              ${PROXY_USER}"
echo "  Пароль:             ${PROXY_PASS}"
echo ""
echo "  Твои прокси:"
echo "  ─────────────────────────────────────"

for i in $(seq 0 $((PORT_COUNT - 1))); do
  port=$((PORT_START + i))
  printf "  %2d)  http://%s:%s@%s:%d\n" $((i + 1)) "${PROXY_USER}" "${PROXY_PASS}" "${SERVER_IP}" "${port}"
done

echo "  ─────────────────────────────────────"
echo ""
echo "  Проверка (с домашнего компьютера):"
echo ""
echo "    curl -x http://${PROXY_USER}:${PROXY_PASS}@${SERVER_IP}:${PORT_START} http://ifconfig.me"
echo ""
echo "  Управление:"
echo "    sudo systemctl status 3proxy    — статус"
echo "    sudo systemctl restart 3proxy   — перезапуск"
echo "    sudo systemctl stop 3proxy      — остановка"
echo "    sudo tail -f /var/log/3proxy/3proxy.log  — логи"
echo ""
