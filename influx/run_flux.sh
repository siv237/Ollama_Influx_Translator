#!/bin/bash

# Проверяем, был ли передан аргумент
if [ -z "$1" ]; then
  echo "Ошибка: Не указано имя файла с Flux-запросом."
  echo "Использование: ./run_flux.sh <имя_файла.flux>"
  exit 1
fi

# Путь к файлу с запросом
FLUX_FILE="$1"

# Проверяем, существует ли файл
if [ ! -f "$FLUX_FILE" ]; then
  echo "Ошибка: Файл '$FLUX_FILE' не найден."
  exit 1
fi

# Путь к файлу .env (в родительской директории)
ENV_FILE="$(dirname "$0")/../config.env"

# Проверяем, существует ли .env файл
if [ ! -f "$ENV_FILE" ]; then
  echo "Ошибка: Файл config.env не найден в корне проекта."
  exit 1
fi

# Загружаем переменные из .env
export $(grep -v '^#' "$ENV_FILE" | xargs)

# Проверяем, что переменные загружены
if [ -z "$INFLUXDB_URL" ] || [ -z "$INFLUXDB_TOKEN" ] || [ -z "$INFLUXDB_ORG" ]; then
  echo "Ошибка: Одна или несколько переменных (INFLUXDB_URL, INFLUXDB_TOKEN, INFLUXDB_ORG) не заданы в config.env файле."
  exit 1
fi

# Выполняем curl запрос
echo "Выполнение запроса из файла: $FLUX_FILE..."
curl -X POST "${INFLUXDB_URL}/api/v2/query?org=${INFLUXDB_ORG}" \
  -H "Authorization: Token ${INFLUXDB_TOKEN}" \
  -H "Accept: application/csv" \
  -H "Content-Type: application/vnd.flux" \
  --data-binary "@${FLUX_FILE}"
