#!/bin/bash

# Простой стартовый скрипт для Ollama Translator

cd "$(dirname "$0")"

# Создаем venv если нет
if [ ! -d "venv" ]; then
    echo "Создаю venv..."
    python3 -m venv venv
fi

# Активируем venv
source venv/bin/activate

# Ставим зависимости если нужно
pip install -q -r requirements.txt

# Запускаем
echo "Запускаю транслятор..."
python3 ollama_translator.py