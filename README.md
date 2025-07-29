# Ollama to InfluxDB Log Translator

Транслятор журналов из Ollama в InfluxDB для мониторинга и анализа работы языковой модели.

## Возможности

- �  Чтение логов Ollama из systemd journal
- � Зевркалирование логов в InfluxDB в реальном времени
- �  Мониторинг каждые 10 секунд
- � Дедутпликация записей через хеширование
- ⚡ Автоматический запуск как системная служба

## Установка

1. Клонируйте репозиторий:
```bash
git clone <repository-url>
cd Ollama_InfluxDB
```

2. Настройте переменные окружения в `config.env`:
```bash
INFLUXDB_URL="http://your-influxdb-server:8086"
INFLUXDB_TOKEN="your-influxdb-token"
INFLUXDB_ORG="your-organization"
INFLUXDB_BUCKET="ollama-logs"
```

3. Для тестирования:
```bash
./start.sh
```

4. Для установки как службы:
```bash
sudo ./install.sh
```
**Примечание:** Установщик автоматически использует те же права пользователя, что и служба Ollama

## Как это работает: Права доступа

Для чтения системных логов службы `ollama` транслятор должен иметь соответствующие права. Однако запускать его от имени `root` небезопасно.

Скрипт `install.sh` решает эту проблему следующим образом:
1.  Определяет пользователя, от имени которого запущена служба `ollama` (обычно это пользователь `ollama`).
2.  Создает специальный файл `/etc/sudoers.d/ollama_translator_sudo`, который дает этому пользователю право выполнять команду `journalctl` **только** для службы `ollama` без запроса пароля.

Это обеспечивает безопасный и ограниченный доступ к необходимым логам, не предоставляя лишних привилегий.

## Использование

### Ручной запуск для тестирования
```bash
./start.sh
```

### Установка как системная служба
```bash
sudo ./install.sh
```
**Требования:** Должна быть установлена служба `ollama.service`

### Управление службой
```bash
sudo systemctl start Ollama_InfluxDB     # Запуск
sudo systemctl stop Ollama_InfluxDB      # Остановка
sudo systemctl status Ollama_InfluxDB    # Статус
journalctl -u Ollama_InfluxDB -f         # Логи в реальном времени
```

## Структура данных в InfluxDB

Данные сохраняются в measurement `ollama_logs`:

### Tags
- `source`: "systemd" 
- `host`: имя хоста
- `msg_hash`: уникальный хеш для дедупликации

### Fields
- `message`: полный текст лога из systemd journal

## Логирование

Транслятор ведет собственные логи в файле `translator.log` и выводит информацию в консоль.

## Требования

- Python 3.7+
- InfluxDB 2.0+
- Ollama (установленный и запущенный)

## Лицензия

MIT License
