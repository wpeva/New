#!/bin/bash
# ============================================================
#  ГЛАВНЫЙ СКРИПТ: раскатка прокси на все VPS одной кнопкой
#
#  Что делает:
#    1. Читает список серверов из servers.txt
#    2. Заходит на каждый по SSH
#    3. Ставит и запускает 3proxy
#    4. Проверяет, что подсети реально разные
#    5. Выводит готовый список прокси + сохраняет в файл
#
#  Запуск:
#    bash deploy-multi-proxy.sh
#
#  Требования (на ТВОЁМ компьютере, откуда запускаешь):
#    - Linux / macOS / WSL (Windows Subsystem for Linux)
#    - Установлен sshpass:
#        Ubuntu/Debian:  sudo apt install -y sshpass
#        macOS:          brew install hudochenkov/sshpass/sshpass
# ============================================================

set -euo pipefail

# --------------------- НАСТРОЙКИ ----------------------------
# >>>  ПОМЕНЯЙ ЭТИ ЗНАЧЕНИЯ ПЕРЕД ЗАПУСКОМ  <<<

PROXY_USER="proxyuser"         # единый логин для всех прокси
PROXY_PASS="SuperSecret123"    # единый пароль (ПОМЕНЯЙ!)
PROXY_PORT=3128                # порт прокси на каждом сервере
SERVERS_FILE="servers.txt"     # файл со списком серверов
INSTALLER="install-on-node.sh" # скрипт-установщик для удалённого VPS

# --------------------- ЦВЕТА --------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
info()  { echo -e "${YELLOW}[..]${NC} $1"; }
fail()  { echo -e "${RED}[!!]${NC} $1"; }
header(){ echo -e "\n${CYAN}${BOLD}$1${NC}\n"; }

# --------------------- ПРОВЕРКИ -----------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVERS_PATH="${SCRIPT_DIR}/${SERVERS_FILE}"
INSTALLER_PATH="${SCRIPT_DIR}/${INSTALLER}"

if [ ! -f "$SERVERS_PATH" ]; then
  fail "Файл ${SERVERS_FILE} не найден рядом со скриптом."
  fail "Создай его по примеру и впиши свои серверы."
  exit 1
fi

if [ ! -f "$INSTALLER_PATH" ]; then
  fail "Файл ${INSTALLER} не найден рядом со скриптом."
  exit 1
fi

if ! command -v sshpass &> /dev/null; then
  fail "Не найден sshpass. Установи его:"
  echo "    Ubuntu/Debian:  sudo apt install -y sshpass"
  echo "    macOS:          brew install hudochenkov/sshpass/sshpass"
  exit 1
fi

# --------------------- ЧТЕНИЕ СЕРВЕРОВ ----------------------

SERVERS=()
while IFS= read -r line; do
  # Пропускаем пустые строки и комментарии
  line="$(echo "$line" | sed 's/#.*//' | xargs)"
  [ -z "$line" ] && continue
  SERVERS+=("$line")
done < "$SERVERS_PATH"

TOTAL=${#SERVERS[@]}

if [ "$TOTAL" -eq 0 ]; then
  fail "В ${SERVERS_FILE} нет серверов. Впиши хотя бы один."
  fail "Формат строки:  IP  ПАРОЛЬ_ROOT  SSH_ПОРТ"
  exit 1
fi

header "Найдено серверов: ${TOTAL}"
echo "  Логин прокси:  ${PROXY_USER}"
echo "  Пароль прокси: ${PROXY_PASS}"
echo "  Порт прокси:   ${PROXY_PORT}"
echo ""

# --------------------- ДЕПЛОЙ -------------------------------

SUCCESS_LIST=()
SUCCESS_IPS=()
FAIL_LIST=()

for i in "${!SERVERS[@]}"; do
  entry="${SERVERS[$i]}"
  NUM=$((i + 1))

  # Парсим строку: IP ПАРОЛЬ ПОРТ_SSH
  SERVER_IP=$(echo "$entry" | awk '{print $1}')
  SERVER_PASS=$(echo "$entry" | awk '{print $2}')
  SSH_PORT=$(echo "$entry" | awk '{print $3}')
  SSH_PORT="${SSH_PORT:-22}"

  echo "─────────────────────────────────────────"
  info "[${NUM}/${TOTAL}] Сервер: ${SERVER_IP} (SSH-порт ${SSH_PORT})"

  # 1. Копируем скрипт-установщик на сервер
  info "  Копирование установщика..."
  if ! sshpass -p "${SERVER_PASS}" \
       scp -o StrictHostKeyChecking=no \
           -o ConnectTimeout=15 \
           -o UserKnownHostsFile=/dev/null \
           -o LogLevel=ERROR \
           -P "${SSH_PORT}" \
           "${INSTALLER_PATH}" \
           "root@${SERVER_IP}:/tmp/install-on-node.sh" 2>/dev/null; then
    fail "  Не удалось подключиться к ${SERVER_IP}. Пропускаю."
    FAIL_LIST+=("${SERVER_IP}  —  ошибка подключения (SCP)")
    continue
  fi

  # 2. Запускаем установщик на сервере
  info "  Установка 3proxy (1–3 минуты)..."
  REMOTE_OUTPUT=$(sshpass -p "${SERVER_PASS}" \
       ssh -o StrictHostKeyChecking=no \
           -o ConnectTimeout=15 \
           -o ServerAliveInterval=30 \
           -o UserKnownHostsFile=/dev/null \
           -o LogLevel=ERROR \
           -p "${SSH_PORT}" \
           "root@${SERVER_IP}" \
           "bash /tmp/install-on-node.sh '${PROXY_USER}' '${PROXY_PASS}' '${PROXY_PORT}'" 2>&1) || true

  # 3. Проверяем результат
  if echo "$REMOTE_OUTPUT" | grep -q "\[OK\] ГОТОВО"; then
    REAL_IP=$(echo "$REMOTE_OUTPUT" | grep "\[OK\] ГОТОВО" | sed 's/.*ГОТОВО: //' | cut -d: -f1)
    ok "  Прокси работает: ${REAL_IP}:${PROXY_PORT}"
    SUCCESS_LIST+=("${REAL_IP}:${PROXY_PORT}")
    SUCCESS_IPS+=("${REAL_IP}")
  else
    fail "  Установка не удалась на ${SERVER_IP}"
    # Показываем последние строки для диагностики
    LAST_LINES=$(echo "$REMOTE_OUTPUT" | tail -3)
    [ -n "$LAST_LINES" ] && echo "  Лог: ${LAST_LINES}"
    FAIL_LIST+=("${SERVER_IP}  —  ошибка установки")
  fi
done

# --------------------- ПРОВЕРКА ПОДСЕТЕЙ --------------------

check_subnets() {
  local ips=("$@")
  local subnets=()
  local duplicates=()

  for ip in "${ips[@]}"; do
    # Берём первые 3 октета = подсеть /24
    subnet=$(echo "$ip" | cut -d. -f1-3)
    if [[ " ${subnets[*]:-} " == *" ${subnet} "* ]]; then
      duplicates+=("${ip} (подсеть ${subnet}.x)")
    fi
    subnets+=("$subnet")
  done

  # Уникальные подсети
  local unique
  unique=$(printf '%s\n' "${subnets[@]}" | sort -u | wc -l)

  echo ""
  header "ПРОВЕРКА ПОДСЕТЕЙ (/24)"
  echo ""
  printf "  %-20s  %-18s\n" "IP-адрес" "Подсеть"
  echo "  ──────────────────  ──────────────────"
  for ip in "${ips[@]}"; do
    subnet=$(echo "$ip" | cut -d. -f1-3)
    printf "  %-20s  %s.x\n" "$ip" "$subnet"
  done
  echo ""

  if [ ${#duplicates[@]} -gt 0 ]; then
    fail "ВНИМАНИЕ: найдены IP из одинаковых подсетей!"
    for d in "${duplicates[@]}"; do
      echo -e "    ${RED}⚠${NC}  ${d}"
    done
    echo ""
    fail "Совет: замени дублирующиеся VPS на серверы из другого хостинга/ДЦ."
  else
    ok "Все ${unique} IP из разных подсетей — отлично!"
  fi
}

# --------------------- ИТОГОВЫЙ ОТЧЁТ ----------------------

echo ""
echo "══════════════════════════════════════════════════════════"

if [ ${#SUCCESS_LIST[@]} -gt 0 ]; then

  # Проверяем подсети
  check_subnets "${SUCCESS_IPS[@]}"

  header "ГОТОВЫЕ ПРОКСИ (${#SUCCESS_LIST[@]} шт):"
  echo ""

  # Формат 1: IP:PORT:USER:PASS (для импорта в софт)
  echo "  Формат  IP:PORT:USER:PASS"
  echo "  ─────────────────────────────────────────────"
  for proxy_addr in "${SUCCESS_LIST[@]}"; do
    echo "  ${proxy_addr}:${PROXY_USER}:${PROXY_PASS}"
  done

  echo ""

  # Формат 2: URL (для curl / requests / браузера)
  echo "  Формат  http://USER:PASS@IP:PORT"
  echo "  ─────────────────────────────────────────────"
  for proxy_addr in "${SUCCESS_LIST[@]}"; do
    echo "  http://${PROXY_USER}:${PROXY_PASS}@${proxy_addr}"
  done

  # Сохраняем оба формата в файлы
  PROXY_FILE="${SCRIPT_DIR}/proxy-list.txt"
  PROXY_URL_FILE="${SCRIPT_DIR}/proxy-list-urls.txt"

  > "$PROXY_FILE"
  > "$PROXY_URL_FILE"
  for proxy_addr in "${SUCCESS_LIST[@]}"; do
    echo "${proxy_addr}:${PROXY_USER}:${PROXY_PASS}" >> "$PROXY_FILE"
    echo "http://${PROXY_USER}:${PROXY_PASS}@${proxy_addr}" >> "$PROXY_URL_FILE"
  done
  echo ""
  ok "Сохранено: proxy-list.txt       (формат IP:PORT:USER:PASS)"
  ok "Сохранено: proxy-list-urls.txt  (формат http://...)"
fi

if [ ${#FAIL_LIST[@]} -gt 0 ]; then
  echo ""
  fail "Не удалось установить на ${#FAIL_LIST[@]} сервер(ов):"
  for f in "${FAIL_LIST[@]}"; do
    echo "    ✗  ${f}"
  done
fi

echo ""
echo "  ─────────────────────────────────────────────"
if [ ${#SUCCESS_LIST[@]} -gt 0 ]; then
  FIRST="${SUCCESS_LIST[0]}"
  echo "  Быстрая проверка (запусти с домашнего ПК):"
  echo ""
  echo "    curl -x http://${PROXY_USER}:${PROXY_PASS}@${FIRST} http://ifconfig.me"
  echo ""
  echo "  Проверить ВСЕ прокси разом:"
  echo ""
  echo "    bash check-proxies.sh"
fi
echo ""
echo "══════════════════════════════════════════════════════════"
echo ""
