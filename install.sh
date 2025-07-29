#!/bin/bash

# Установщик службы Ollama_InfluxDB

set -e

SERVICE_NAME="Ollama_InfluxDB"
INSTALL_DIR="/opt/Ollama_InfluxDB"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Проверка sudo
if [ "$EUID" -ne 0 ]; then
    echo "❌ Запустите с sudo: sudo ./install.sh"
    exit 1
fi

echo "🚀 Установка службы $SERVICE_NAME..."

# Проверяем наличие службы ollama
if ! systemctl list-unit-files | grep -q "ollama.service"; then
    echo "❌ Служба ollama не найдена! Установите Ollama сначала."
    exit 1
fi

echo "✅ Служба ollama найдена"

# Получаем параметры службы ollama
OLLAMA_USER=$(systemctl show ollama.service -p User --value)
OLLAMA_GROUP=$(systemctl show ollama.service -p Group --value)

if [ -z "$OLLAMA_USER" ]; then
    OLLAMA_USER="ollama"
fi

if [ -z "$OLLAMA_GROUP" ]; then
    OLLAMA_GROUP="ollama"
fi

echo "📋 Используем пользователя: $OLLAMA_USER:$OLLAMA_GROUP"

# Копируем файлы
echo "📁 Копирую файлы в $INSTALL_DIR..."
mkdir -p $INSTALL_DIR
cp -r . $INSTALL_DIR/
chown -R $OLLAMA_USER:$OLLAMA_GROUP $INSTALL_DIR

# Настраиваем Python
echo "🐍 Настраиваю Python окружение..."
cd $INSTALL_DIR
python3 -m venv venv
chown -R $OLLAMA_USER:$OLLAMA_GROUP venv
sudo -u $OLLAMA_USER $INSTALL_DIR/venv/bin/pip install -r requirements.txt

# Создаем службу
echo "⚙️ Создаю systemd службу..."
cat > $SERVICE_FILE << EOF
[Unit]
Description=Ollama to InfluxDB Log Translator
After=network.target ollama.service
Wants=ollama.service

[Service]
Type=simple
User=$OLLAMA_USER
Group=$OLLAMA_GROUP
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/ollama_translator.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Настраиваем sudoers для безопасного доступа к логам
echo "INFO: Настройка sudoers для пользователя $OLLAMA_USER..."
SUDOERS_FILE="/etc/sudoers.d/ollama_translator_sudo"
COMMAND_PATH=$(which journalctl)

# Создаем правило, разрешающее выполнение только одной конкретной команды
cat > $SUDOERS_FILE << EOF
# Это правило разрешает пользователю $OLLAMA_USER читать логи службы ollama
# без пароля. Это необходимо для работы Ollama_InfluxDB.
$OLLAMA_USER ALL=(ALL) NOPASSWD: $COMMAND_PATH --unit=ollama --output=json --no-pager
$OLLAMA_USER ALL=(ALL) NOPASSWD: $COMMAND_PATH --unit=ollama -n 200 --no-pager
EOF

# Устанавливаем правильные права на файл sudoers
chmod 0440 $SUDOERS_FILE

echo "✅ Правило sudoers создано в $SUDOERS_FILE"

# Перезагружаем systemd
systemctl daemon-reload
systemctl enable $SERVICE_NAME

echo ""
echo "🎉 Служба $SERVICE_NAME установлена!"
echo ""
echo "Управление:"
echo "  sudo systemctl start $SERVICE_NAME"
echo "  sudo systemctl status $SERVICE_NAME"
echo "  journalctl -u $SERVICE_NAME -f"
echo ""
echo "Файлы: $INSTALL_DIR"