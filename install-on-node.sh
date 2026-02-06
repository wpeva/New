#!/bin/bash
# ============================================================
#  Этот скрипт выполняется НА УДАЛЁННОМ сервере.
#  Его не нужно запускать вручную — deploy-multi-proxy.sh
#  сам отправит его на каждый VPS и запустит.
# ============================================================

set -e

PROXY_USER="$1"
PROXY_PASS="$2"
PROXY_PORT="$3"

if [ -z "$PROXY_USER" ] || [ -z "$PROXY_PASS" ] || [ -z "$PROXY_PORT" ]; then
  echo "[!!] Использование: bash install-on-node.sh ЛОГИН ПАРОЛЬ ПОРТ"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "[..] Обновление системы..."
apt update -qq 2>/dev/null
apt upgrade -y -qq 2>/dev/null

echo "[..] Установка зависимостей..."
apt install -y -qq build-essential git ufw 2>/dev/null

# --- Сборка 3proxy (если ещё не стоит) ---
if [ ! -f /usr/local/bin/3proxy ]; then
  echo "[..] Сборка 3proxy..."
  cd /tmp
  rm -rf 3proxy
  git clone --quiet https://github.com/3proxy/3proxy.git
  cd 3proxy
  make -f Makefile.Linux -s
  cp bin/3proxy /usr/local/bin/3proxy
  chmod +x /usr/local/bin/3proxy
  cd /
  rm -rf /tmp/3proxy
fi

# --- Папки ---
mkdir -p /etc/3proxy /var/log/3proxy
chown -R nobody:nogroup /var/log/3proxy
chmod -R 755 /var/log/3proxy

# --- Файл паролей ---
cat > /etc/3proxy/.proxyauth <<EOF
${PROXY_USER}:CL:${PROXY_PASS}
EOF
chmod 600 /etc/3proxy/.proxyauth

# --- Конфиг ---
cat > /etc/3proxy/3proxy.cfg <<EOF
setgid 65534
setuid 65534
nscache 65536
timeouts 1 5 30

log /var/log/3proxy/3proxy.log D
logformat "- +_L%t.%. %N.%p %E %U %C:%c %R:%r %O %I %h %T"

users \$/etc/3proxy/.proxyauth
auth strong
maxconn 64

proxy -p${PROXY_PORT}
EOF

# --- Systemd-сервис ---
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
systemctl enable 3proxy --quiet 2>/dev/null
systemctl restart 3proxy
sleep 1

# --- Файрволл ---
ufw allow 22/tcp          > /dev/null 2>&1
ufw allow ${PROXY_PORT}/tcp > /dev/null 2>&1
ufw --force enable         > /dev/null 2>&1

# --- Проверка ---
if systemctl is-active --quiet 3proxy; then
  SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "?")
  echo "[OK] ГОТОВО: ${SERVER_IP}:${PROXY_PORT}"
else
  echo "[!!] ОШИБКА: 3proxy не запустился"
  exit 1
fi
