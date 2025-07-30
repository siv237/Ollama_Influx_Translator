#!/bin/bash

# --- Configuration ---
TIME_RANGE_START="-24h"      # Default: last 24 hours
TIME_RANGE_STOP="now()"        # Default: now
HOST_NAME=$(hostname)          # Default: system hostname
FLUX_FILE_PATH=""

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    -h|--host)
      HOST_NAME="$2"
      shift 2 ;;
    -s|--start)
      TIME_RANGE_START="$2"
      shift 2 ;;
    -e|--stop)
      TIME_RANGE_STOP="$2"
      shift 2 ;;
    *)
      if [ -z "$FLUX_FILE_PATH" ]; then
        FLUX_FILE_PATH="$1"
      fi
      shift ;;
  esac
done

# --- Script Logic ---

# 1. Check for flux file
if [ -z "$FLUX_FILE_PATH" ]; then
  echo "Ошибка: Не указано имя файла с Flux-запросом."
  echo "Использование: ./run_flux.sh [--host <host>] [--start <start>] [--stop <stop>] <файл.flux>"
  exit 1
fi

if [ ! -f "$FLUX_FILE_PATH" ]; then
  echo "Ошибка: Файл '$FLUX_FILE_PATH' не найден."
  exit 1
fi

# 2. Find and load config.env
ENV_FILE="$(dirname "$0")/../config.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "Ошибка: Файл config.env не найден в корне проекта."
  exit 1
fi
export $(grep -v '^#' "$ENV_FILE" | xargs)

# 3. Check for required InfluxDB variables
if [ -z "$INFLUXDB_URL" ] || [ -z "$INFLUXDB_TOKEN" ] || [ -z "$INFLUXDB_ORG" ]; then
  echo "Ошибка: Одна или несколько переменных (INFLUXDB_URL, INFLUXDB_TOKEN, INFLUXDB_ORG) не заданы в config.env файле."
  exit 1
fi

# 4. Read and process the Flux query
echo "--- Подготовка запроса ---"
echo "Файл: $FLUX_FILE_PATH"
echo "Подстановка переменных Grafana:"
echo "  \${host}            -> ${HOST_NAME}"
echo "  v.timeRangeStart -> ${TIME_RANGE_START}"
echo "  v.timeRangeStop  -> ${TIME_RANGE_STOP}"
echo "--------------------------"

PROCESSED_QUERY=$(cat "$FLUX_FILE_PATH" | \
  sed "s/\${host}/${HOST_NAME}/g" | \
  sed "s/v.timeRangeStart/${TIME_RANGE_START}/g" | \
  sed "s/v.timeRangeStop/${TIME_RANGE_STOP}/g")

# 5. Execute the query using curl
echo "Выполнение запроса..."
curl --silent -X POST "${INFLUXDB_URL}/api/v2/query?org=${INFLUXDB_ORG}" \
  -H "Authorization: Token ${INFLUXDB_TOKEN}" \
  -H "Accept: application/csv" \
  -H "Content-Type: application/vnd.flux" \
  --data "$PROCESSED_QUERY"
