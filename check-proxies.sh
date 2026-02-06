#!/bin/bash
# ============================================================
#  Проверка всех прокси из proxy-list.txt одной командой
#
#  Запуск:  bash check-proxies.sh
# ============================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROXY_FILE="${SCRIPT_DIR}/proxy-list.txt"

if [ ! -f "$PROXY_FILE" ]; then
  echo -e "${RED}[!!]${NC} Файл proxy-list.txt не найден. Сначала запусти deploy-multi-proxy.sh"
  exit 1
fi

echo ""
echo "══════════════════════════════════════════════════════════"
echo "  Проверка прокси из proxy-list.txt"
echo "══════════════════════════════════════════════════════════"
echo ""

TOTAL=0
OK=0
FAIL=0

printf "  %-4s  %-22s  %-18s  %-8s  %s\n" "#" "Прокси" "Подсеть" "Время" "Статус"
echo "  ────  ──────────────────────  ──────────────────  ────────  ──────"

while IFS= read -r line; do
  [ -z "$line" ] && continue
  TOTAL=$((TOTAL + 1))

  # Парсим строку IP:PORT:USER:PASS
  PROXY_IP=$(echo "$line" | cut -d: -f1)
  PROXY_PORT=$(echo "$line" | cut -d: -f2)
  PROXY_USER=$(echo "$line" | cut -d: -f3)
  PROXY_PASS=$(echo "$line" | cut -d: -f4)

  SUBNET=$(echo "$PROXY_IP" | cut -d. -f1-3).x

  # Замеряем время и проверяем
  START_MS=$(date +%s%N)
  RESULT=$(curl -s --max-time 10 -x "http://${PROXY_USER}:${PROXY_PASS}@${PROXY_IP}:${PROXY_PORT}" http://ifconfig.me 2>/dev/null)
  END_MS=$(date +%s%N)
  ELAPSED=$(( (END_MS - START_MS) / 1000000 ))

  if [ -n "$RESULT" ] && echo "$RESULT" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    OK=$((OK + 1))
    if [ "$RESULT" = "$PROXY_IP" ]; then
      STATUS="${GREEN}OK${NC} (IP совпал)"
    else
      STATUS="${YELLOW}OK${NC} (ответ: ${RESULT})"
    fi
  else
    FAIL=$((FAIL + 1))
    STATUS="${RED}ОШИБКА${NC}"
    ELAPSED="-"
  fi

  if [ "$ELAPSED" != "-" ]; then
    TIME_STR="${ELAPSED}ms"
  else
    TIME_STR="-"
  fi

  printf "  %-4s  %-22s  %-18s  %-8s  " "$TOTAL" "${PROXY_IP}:${PROXY_PORT}" "$SUBNET" "$TIME_STR"
  echo -e "$STATUS"

done < "$PROXY_FILE"

echo ""
echo "  ──────────────────────────────────────────────────────"
echo -e "  Всего: ${TOTAL}   ${GREEN}Работает: ${OK}${NC}   ${RED}Ошибок: ${FAIL}${NC}"
echo "══════════════════════════════════════════════════════════"
echo ""
