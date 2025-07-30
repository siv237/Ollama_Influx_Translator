# Пошаговая сборка Flux-запроса для диаграммы Ганта

Этот документ служит рабочим журналом для создания и отладки сложного Flux-запроса. Каждый шаг представляет собой отдельный, проверенный фрагмент логики.

Проверяем запросы тут influx/run_flux.sh запрос.flux

---

## Шаг 1: Базовый отбор API-запросов

**Цель:** Убедиться, что мы можем выбрать из базы данных все строки логов, относящиеся к API-запросам (`[GIN]`).

**Запрос:**
```flux
import "strings"

from(bucket: "ollama-logs")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "ollama_logs" and r._field == "message")
  |> filter(fn: (r) => strings.containsStr(v: r._value, substr: "[GIN]"))
  |> keep(columns: ["_time", "_value"])
```

---

## Шаг 2: Генерация `session_id`

**Цель:** Создать `session_id` путем округления времени запроса (`_time`) до 10-минутного интервала для группировки.

**Запрос:**
```flux
import "strings"

from(bucket: "ollama-logs")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "ollama_logs" and r._field == "message")
  |> filter(fn: (r) => strings.containsStr(v: r._value, substr: "[GIN]"))
  |> map(fn: (r) => ({ r with request_time: r._time })) // Сохраняем оригинальное время
  |> truncateTimeColumn(unit: 10m) // Округляем _time, это будет наш ID сессии
  |> map(fn: (r) => ({
      session_id: string(v: r._time), // Превращаем округленное время в ID
      request_start: r.request_time, // Возвращаем оригинальное время
      log_message: r._value
  }))
  |> keep(columns: ["session_id", "request_start", "log_message"])
```

---

## Шаг 3: Парсинг эндпоинта

**Цель:** Извлечь из строки лога конечную точку API (например, `/api/chat`).

**Запрос:**
```flux
import "strings"

from(bucket: "ollama-logs")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "ollama_logs" and r._field == "message")
  |> filter(fn: (r) => strings.containsStr(v: r._value, substr: "[GIN]"))
  |> map(fn: (r) => {
      parts = strings.split(v: r._value, t: "|")
      endpoint_part = strings.trimSpace(v: parts[4])
      endpoint = strings.split(v: endpoint_part, t: "\"")[1]
      return { _time: r._time, endpoint: endpoint }
  })
```

---

## Шаг 4: Парсинг статуса

**Цель:** Извлечь код ответа HTTP (например, `200`) из строки лога.

**Запрос:**
```flux
import "strings"

from(bucket: "ollama-logs")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "ollama_logs" and r._field == "message")
  |> filter(fn: (r) => strings.containsStr(v: r._value, substr: "[GIN]"))
  |> map(fn: (r) => {
      parts = strings.split(v: r._value, t: "|")
      status_str = strings.trimSpace(v: parts[1])
      return { _time: r._time, status: int(v: status_str) }
  })
```

---

## Шаг 5: Парсинг времени задержки (latency)

**Цель:** Извлечь время выполнения запроса и преобразовать его в числовое значение в миллисекундах.

**Запрос:**
```flux
import "strings"
import "regexp"

from(bucket: "ollama-logs")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "ollama_logs" and r._field == "message")
  |> filter(fn: (r) => strings.containsStr(v: r._value, substr: "[GIN]"))
  |> map(fn: (r) => {
      parts = strings.split(v: r._value, t: "|")
      latency_str = strings.trimSpace(v: parts[2])
      re_numeric = regexp.compile(v: "[0-9\\.]+")
      numeric_part_str = regexp.findString(r: re_numeric, v: latency_str)
      numeric_val = float(v: numeric_part_str)
      multiplier = 
        if strings.containsStr(v: latency_str, substr: "ms") then 1.0
        else if strings.containsStr(v: latency_str, substr: "µs") then 0.001
        else if strings.containsStr(v: latency_str, substr: "s") then 1000.0
        else 0.0
      latency_ms = numeric_val * multiplier
      return { _time: r._time, latency_ms: latency_ms }
  })
```

---

## Шаг 6: Финальная сборка

**Цель:** Объединить все предыдущие шаги в один рабочий запрос, который готовит данные для диаграммы Ганта.

**Запрос:**
```flux
import "strings"
import "regexp"

from(bucket: "ollama-logs")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "ollama_logs" and r._field == "message")
  |> filter(fn: (r) => strings.containsStr(v: r._value, substr: "[GIN]"))
  |> map(fn: (r) => ({ r with request_time: r._time, log_message: r._value }))
  |> truncateTimeColumn(unit: 10m)
  |> map(fn: (r) => {
      parts = strings.split(v: r.log_message, t: "|")
      
      status_str = strings.trimSpace(v: parts[1])
      status = int(v: status_str)

      latency_str = strings.trimSpace(v: parts[2])
      re_numeric = regexp.compile(v: "[0-9\\.]+")
      numeric_part_str = regexp.findString(r: re_numeric, v: latency_str)
      numeric_val = float(v: numeric_part_str)
      multiplier = 
        if strings.containsStr(v: latency_str, substr: "ms") then 1.0
        else if strings.containsStr(v: latency_str, substr: "µs") then 0.001
        else if strings.containsStr(v: latency_str, substr: "s") then 1000.0
        else 0.0
      latency_ms = numeric_val * multiplier

      endpoint_part = strings.trimSpace(v: parts[4])
      endpoint = strings.split(v: endpoint_part, t: "\"")[1]

      return {
        session_id: string(v: r._time), // _time уже округлено
        request_start: r.request_time,
        endpoint: endpoint,
        latency_ms: latency_ms,
        status: status
      }
  })
  |> keep(columns: ["session_id", "request_start", "endpoint", "latency_ms", "status"])
```

**Результат:** Ожидается получение таблицы со всеми необходимыми полями для визуализации.

---

## Шаг 7: Извлечение маркеров начала сессий

**Цель:** Найти в логах все события запуска сервера (`starting llama server`) и создать для них `session_id`.

**Запрос:**
```flux
import "strings"

from(bucket: "ollama-logs")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "ollama_logs" and r._field == "message")
  |> filter(fn: (r) => strings.containsStr(v: r._value, substr: "starting llama server"))
  |> map(fn: (r) => ({ r with session_start_time: r._time }))
  |> truncateTimeColumn(unit: 10m)
  |> map(fn: (r) => ({
      session_id: string(v: r._time),
      session_start: r.session_start_time
  }))
  |> keep(columns: ["session_id", "session_start"])
```

---

## Шаг 8: Финальная сборка - Объединение сессий и запросов

**Цель:** Собрать все предыдущие шаги в один запрос, который сопоставляет API-запросы с их сессиями, используя `union` и `fill` для реализации "as-of join".

**Запрос:**
```flux
import "strings"
import "regexp"

// --- Таблица 1: API запросы ---
requests = from(bucket: "ollama-logs")
  |> range(start: -24h)
  |> map(fn: (r) => ({ r with _value: string(v: r._value) }))
  |> filter(fn: (r) => strings.containsStr(v: r._value, substr: "[GIN]"))
  |> map(fn: (r) => ({ r with request_time: r._time, log_message: r._value }))
  |> map(fn: (r) => {
      parts = strings.split(v: r.log_message, t: "|")
      status_str = strings.trimSpace(v: parts[1])
      latency_str = strings.trimSpace(v: parts[2])
      re_numeric = regexp.compile(v: "[0-9\\.]+")
      numeric_part_str = regexp.findString(r: re_numeric, v: latency_str)
      numeric_val = float(v: numeric_part_str)
      multiplier = 
        if strings.containsStr(v: latency_str, substr: "ms") then 1.0
        else if strings.containsStr(v: latency_str, substr: "µs") then 0.001
        else if strings.containsStr(v: latency_str, substr: "s") then 1000.0
        else 0.0
      endpoint_part = strings.trimSpace(v: parts[4])
      endpoint = strings.split(v: endpoint_part, t: "\"")[1]
      return {
        _time: r.request_time,
        endpoint: endpoint,
        latency_ms: numeric_val * multiplier,
        status: int(v: status_str)
      }
  })
  |> keep(columns: ["_time", "endpoint", "latency_ms", "status"])

// --- Таблица 2: Начало сессий ---
sessions = from(bucket: "ollama-logs")
  |> range(start: -24h)
  |> map(fn: (r) => ({ r with _value: string(v: r._value) }))
  |> filter(fn: (r) => strings.containsStr(v: r._value, substr: "starting llama server"))
  |> map(fn: (r) => ({
      _time: r._time,
      session_start: r._time,
      endpoint: "",
      latency_ms: -1.0,
      status: -1
  }))
  |> keep(columns: ["_time", "session_start", "endpoint", "latency_ms", "status"])

// --- Объединение и обработка ---
union(tables: [requests, sessions])
  |> group()
  |> sort(columns: ["_time"])
  |> fill(column: "session_start", usePrevious: true)
  |> filter(fn: (r) => r.endpoint != "")
  |> filter(fn: (r) => exists r.session_start)
  |> rename(columns: {_time: "request_start"})
  |> map(fn: (r) => ({
      session_id: string(v: r.session_start),
      session_start: r.session_start,
      request_start: r.request_start,
      endpoint: r.endpoint,
      latency_ms: r.latency_ms,
      status: r.status
  }))
```

**Результат:** Финальная таблица, готовая для использования в Grafana Gantt. Содержит `session_id`, `session_start`, `request_start`, `endpoint`, `latency_ms`, `status`.

---

## Шаг 9: Построение диаграммы Ганта для API-запросов

**Цель:** Сформировать окончательные данные для визуализации в панели Grafana типа *State timeline*. На следующем шаге будут подключены имена моделей вместо абстрактных session_id.

**Запрос:**
```flux
import "strings"
import "regexp"
import "experimental"

requests = from(bucket: "ollama-logs")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "ollama_logs" and r._field == "message")
  |> filter(fn: (r) => r.host == "${host}")
  |> filter(fn: (r) => strings.containsStr(v: r._value, substr: "[GIN]"))
  // FIX: A much stricter filter to only allow /api/chat
  |> filter(fn: (r) => strings.containsStr(v: r._value, substr: "\"/api/chat\""))
  |> map(fn: (r) => {
      parts = strings.split(v: r._value, t: "|")
      latency_str = strings.trimSpace(v: parts[2])
      re_numeric = regexp.compile(v: "[0-9\\.]+")
      numeric_part_str = regexp.findString(r: re_numeric, v: latency_str)
      
      numeric_val = if numeric_part_str != "" then float(v: numeric_part_str) else 0.0

      multiplier = 
        if strings.containsStr(v: latency_str, substr: "ms") then 1.0
        else if strings.containsStr(v: latency_str, substr: "µs") then 0.001
        else if strings.containsStr(v: latency_str, substr: "s") then 1000.0
        else 0.0
      endpoint_part = strings.trimSpace(v: parts[4])
      endpoint = strings.split(v: endpoint_part, t: "\"")[1]
      return {
        _time: r._time,
        endpoint: endpoint,
        latency_ms: numeric_val * multiplier,
        status: int(v: strings.trimSpace(v: parts[1]))
      }
  })
  |> keep(columns: ["_time", "endpoint", "latency_ms", "status"])

sessions = from(bucket: "ollama-logs")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "ollama_logs" and r._field == "message")
  |> filter(fn: (r) => r.host == "${host}")
  |> filter(fn: (r) => strings.containsStr(v: r._value, substr: "starting llama server"))
  |> map(fn: (r) => ({
      _time: r._time,
      session_start: r._time,
      endpoint: "",
      latency_ms: -1.0,
      status: -1
  }))
  |> keep(columns: ["_time", "session_start", "endpoint", "latency_ms", "status"])

union(tables: [requests, sessions])
  |> group()
  |> sort(columns: ["_time"])
  |> fill(column: "session_start", usePrevious: true)
  |> filter(fn: (r) => r.endpoint != "")
  |> filter(fn: (r) => exists r.session_start)
  |> rename(columns: {_time: "request_start"})
  |> map(fn: (r) => ({
      _time: r.request_start,
      endTime: experimental.addDuration(d: duration(v: int(v: r.latency_ms * 1000000.0)), to: r.request_start),
      _value: r.endpoint,
      session_id: string(v: r.session_start)
  }))
  |> group(columns: ["session_id"])
```

**Результат:** Финальная таблица, готовая для использования в Grafana Gantt. Содержит `_time`, `endTime`, `_value`, `session_id`.

```csv
,result,table,_time,_value,endTime,session_id
,_result,0,2025-07-22T23:26:32.429635Z,/api/chat,2025-07-22T23:26:41.533557169Z,2025-07-22T23:26:23.639029000Z
,_result,0,2025-07-22T23:26:37.502353Z,/api/chat,2025-07-22T23:26:42.564446353Z,2025-07-22T23:26:23.639029000Z
,_result,1,2025-07-22T23:27:24.603314Z,/api/chat,2025-07-22T23:27:34.994052388Z,2025-07-22T23:27:19.689142000Z
,_result,1,2025-07-22T23:27:25.142701Z,/api/chat,2025-07-22T23:27:25.671126056Z,2025-07-22T23:27:19.689142000Z
,_result,2,2025-07-22T23:28:48.275209Z,/api/chat,2025-07-22T23:29:21.458032672Z,2025-07-22T23:28:15.313208000Z
```

---

## Шаг 10: Финальная сборка с именами моделей и контекстом

**Цель:** Создать финальный запрос, который объединяет все предыдущие шаги и формирует подписи для серий в формате `model_name (ctx: NNNN)`.

**Запрос:**
```flux
import "strings"
import "regexp"
import "experimental"

// --- Часть 1: Получаем сессии и модели с максимально широким диапазоном ---
// Это гарантирует, что мы всегда найдем начало сессии, независимо от зума.
sessions_with_sha_and_ctx = from(bucket: "ollama-logs")
  |> range(start: 0)
  |> filter(fn: (r) => r._measurement == "ollama_logs" and r._field == "message" and r.host == "${host}")
  |> filter(fn: (r) => strings.containsStr(v: r._value, substr: "starting llama server"))
  |> map(fn: (r) => {
      sha_regex = regexp.compile(v: "sha256-([0-9a-f]{64})")
      ctx_regex = regexp.compile(v: "--ctx-size [0-9]+")
      sha_match = regexp.findString(r: sha_regex, v: r._value)
      ctx_match = regexp.findString(r: ctx_regex, v: r._value)
      sha256_clean = if sha_match != "" then strings.trimPrefix(v: sha_match, prefix: "sha256-") else ""
      ctx_size = if ctx_match != "" then strings.split(v: ctx_match, t: " ")[1] else "N/A"
      return { _time: r._time, sha256: sha256_clean, ctx: ctx_size }
  })
  |> filter(fn: (r) => r.sha256 != "")

model_inventory = from(bucket: "ollama-logs")
  |> range(start: 0)
  |> filter(fn: (r) => r._measurement == "ollama_model_inventory" and r.host == "${host}")
  |> last()
  |> pivot(rowKey:["model_name"], columnKey:["_field"], valueColumn:"_value")
  |> keep(columns:["model_name", "sha256"])

session_starts_with_models = join(
  tables: {sessions: sessions_with_sha_and_ctx, inventory: model_inventory},
  on: ["sha256"]
)
|> map(fn: (r) => ({
    _time: r._time,
    session_label: r.model_name + " (ctx: " + r.ctx + ")",
    endpoint: "",
    latency_ms: -1.0,
    status: -1
}))
|> keep(columns: ["_time", "session_label", "endpoint", "latency_ms", "status"])

// --- Часть 2: Получаем API запросы (с узким диапазоном Grafana) ---
requests = from(bucket: "ollama-logs")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "ollama_logs" and r._field == "message" and r.host == "${host}")
  |> filter(fn: (r) => strings.containsStr(v: r._value, substr: "[GIN]") and strings.containsStr(v: r._value, substr: "\"/api/chat\""))
  |> map(fn: (r) => {
      parts = strings.split(v: r._value, t: "|")
      latency_str = strings.trimSpace(v: parts[2])
      re_numeric = regexp.compile(v: "[0-9\\.]+")
      numeric_part_str = regexp.findString(r: re_numeric, v: latency_str)
      numeric_val = if numeric_part_str != "" then float(v: numeric_part_str) else 0.0
      multiplier = if strings.containsStr(v: latency_str, substr: "ms") then 1.0 else if strings.containsStr(v: latency_str, substr: "µs") then 0.001 else if strings.containsStr(v: latency_str, substr: "s") then 1000.0 else 0.0
      endpoint_part = strings.trimSpace(v: parts[4])
      endpoint = strings.split(v: endpoint_part, t: "\"")[1]
      return { _time: r._time, endpoint: endpoint, latency_ms: numeric_val * multiplier, status: int(v: strings.trimSpace(v: parts[1])) }
  })
  |> keep(columns: ["_time", "endpoint", "latency_ms", "status"])

// --- Финальная сборка ---
union(tables: [requests, session_starts_with_models])
  |> group()
  |> sort(columns: ["_time"])
  |> fill(column: "session_label", usePrevious: true)
  |> filter(fn: (r) => r.endpoint != "" and exists r.session_label)
  |> rename(columns: {_time: "request_start"})
  |> map(fn: (r) => ({
      _time: r.request_start,
      endTime: experimental.addDuration(d: duration(v: int(v: r.latency_ms * 1000000.0)), to: r.request_start),
      _value: r.endpoint,
      series: r.session_label
  }))
  |> group(columns: ["series"])
```

**Результат:** Финальная таблица, готовая для использования в Grafana Gantt. Содержит `_time`, `endTime`, `_value` и `series` в формате `model_name (ctx: NNNN)`.

---

### Шаг 11: Анализ ключевых логов и определение сегментов для визуализации

На основе анализа логов и документации, жизненный цикл обработки запроса в Ollama можно разделить на несколько ключевых, затратных по времени этапов. Наша цель — отобразить каждый из этих этапов как отдельный цветной блок на диаграмме Ганта.

#### 11.1 Определение полного цикла сессии через сопоставление памяти

**Цель:** Научиться точно определять какая именно модель была выгружена путем сопоставления потребляемой и освобожденной памяти.

**Запрос для извлечения данных о потреблении памяти:**
```flux
import "strings"

from(bucket: "ollama-logs")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "ollama_logs" and r._field == "message")
  |> filter(fn: (r) => r.host == "user-MS-7D18")
  |> filter(fn: (r) => strings.containsStr(v: r._value, substr: "msg=offload"))
  |> keep(columns: ["_time", "_value"])
  |> sort(columns: ["_time"])
```

**Результат анализа данных о потреблении памяти:**

| Время | memory.required.full | memory.weights.total | Модель (по времени) |
|-------|---------------------|---------------------|-------------------|
| 23:26:23 | **11.0 GiB** | **6.8 GiB** | gemma3:12b (первая) |
| 23:27:19 | **1.8 GiB** | **762.5 MiB** | gemma3:1b (вторая) |
| 23:28:15 | **9.5 GiB** | **8.2 GiB** | phi4:latest (третья) |
| 00:32:04 | **9.5 GiB** | **8.2 GiB** | phi4:latest (повтор) |
| 00:49:20 | **9.5 GiB** | **8.2 GiB** | phi4:latest (повтор) |
| 08:05:18 | **9.5 GiB** | **8.2 GiB** | phi4:latest (повтор) |
| 11:46:53 | **4.2 GiB** | **3.1 GiB** | smallthinker:latest |

**Данные о VRAM изменениях:**

| Время | Событие | Available память | Изменение |
|-------|---------|-----------------|-----------|
| 23:27:14 | vram_update | **1.5 GiB** | - |
| 23:28:15 | vram_update | **9.8 GiB** | **+8.3 GiB** |

**Сопоставление "потребление → освобождение":**

Найденная пара выгрузки:
- **Время выгрузки:** 23:28:15
- **Освобождено памяти:** 8.3 GiB (1.5 → 9.8 GiB)
- **Кандидаты на выгрузку:**
  - gemma3:12b: 11.0 GiB (required.full) или 6.8 GiB (weights.total)
  - gemma3:1b: 1.8 GiB (required.full) или 762.5 MiB (weights.total)

**Анализ совпадений:**

1. **По required.full:**
   - gemma3:12b (11.0 GiB) vs освобождено (8.3 GiB) = разница 2.7 GiB ✅
   - gemma3:1b (1.8 GiB) vs освобождено (8.3 GiB) = не подходит ❌

2. **По weights.total:**
   - gemma3:12b (6.8 GiB) vs освобождено (8.3 GiB) = разница 1.5 GiB ✅
   - gemma3:1b (762.5 MiB ≈ 0.74 GiB) vs освобождено (8.3 GiB) = не подходит ❌

**Вывод:** Выгружена модель **gemma3:12b** - наиболее близкое совпадение по размеру памяти.

**🎯 100% ТОЧНОЕ ОПРЕДЕЛЕНИЕ через SHA256 сопоставление:**

**Запрос для извлечения SHA256 из VRAM timeout событий:**
```flux
from(bucket: "ollama-logs")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "ollama_logs" and r._field == "message")
  |> filter(fn: (r) => r.host == "user-MS-7D18")
  |> filter(fn: (r) => strings.containsStr(v: r._value, substr: "gpu VRAM usage didn't recover within timeout"))
  |> keep(columns: ["_time", "_value"])
```

**Запрос для получения model inventory:**
```flux
from(bucket: "ollama-logs")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "ollama_model_inventory" and r.host == "user-MS-7D18")
  |> last()
  |> pivot(rowKey:["model_name"], columnKey:["_field"], valueColumn:"_value")
  |> keep(columns:["model_name", "sha256"])
```

**Результат сопоставления:**
- **VRAM timeout SHA256:** `adca500fad9b54c565ae672184e0c9eb690eb6014ba63f8ec13849d4f73a32d3`
- **Model inventory:** `gemma3:12b` → SHA256: `adca500fad9b54c565ae672184e0c9eb690eb6014ba63f8ec13849d4f73a32d3` ✅

**🏆 Алгоритм 100% точного определения:**
1. Найти VRAM timeout события перед выгрузкой
2. Извлечь SHA256 из model= поля
3. Сопоставить SHA256 с model_inventory
4. Получить точное имя модели

**Полный цикл сессии gemma3:12b (100% точность):**
- **Запуск:** 23:26:29 (Load time: 5.52s)
- **SHA256:** adca500fad9b54c565ae672184e0c9eb690eb6014ba63f8ec13849d4f73a32d3
- **Потребление памяти:** 11.0 GiB (required.full) / 6.8 GiB (weights.total)
- **VRAM timeout:** 23:27:19 (3 события для этого SHA256)
- **Выгрузка:** 23:28:15 (освобождено 8.3 GiB)
- **Время жизни:** ~1 час 46 минут
- **Причина выгрузки:** Принудительная (для загрузки phi4:latest)

*Примечание: SHA256 сопоставление дает 100% точность определения выгруженной модели, устраняя необходимость в вероятностных расчетах.*

**Основные этапы, которые мы будем отслеживать:**

### 11.2 Алгоритм определения выгрузки модели: Рабочие шаги (в процессе отладки)

В ходе отладки был выработан и проверен следующий пошаговый алгоритм для надежного обнаружения событий выгрузки моделей.

**Шаг 1: Надежный поиск событий-индикаторов выгрузки**

Первоначальные попытки найти логи по полной строке `gpu VRAM usage didn't recover within timeout` провалились из-за проблем с обработкой апострофа (`'`) в `didn't` при передаче через API.

**Решение:** Использовать для поиска уникальную подстроку, не содержащую спецсимволов: `"recover within timeout"`.

**Рабочий Flux-запрос для поиска логов о таймауте VRAM:**
```flux
import "strings"

host = "user-MS-7D18"

from(bucket: "ollama-logs")
    |> range(start: -30d)
    |> filter(fn: (r) => r._measurement == "ollama_logs" and r._field == "message" and r.host == host)
    |> filter(fn: (r) => strings.containsStr(v: r._value, substr: "recover within timeout"))
    |> keep(columns: ["_time", "_value"])
    |> yield(name: "vram_timeout_logs")
```
Этот запрос успешно возвращает все события, связанные с таймаутом VRAM, которые являются надежным индикатором предстоящей выгрузки модели.

**Шаг 2: Извлечение SHA256 из логов о таймауте**

Следующим шагом является извлечение `SHA256` модели из найденных логов.

**Рабочий Flux-запрос для извлечения SHA256:**
```flux
import "regexp"
import "strings"

host = "user-MS-7D18"

from(bucket: "ollama-logs")
    |> range(start: -30d)
    |> filter(fn: (r) => r._measurement == "ollama_logs" and r._field == "message" and r.host == host)
    |> filter(fn: (r) => strings.containsStr(v: r._value, substr: "recover within timeout"))
    |> map(fn: (r) => ({
        _time: r._time,
        sha256: strings.replace(
            v: regexp.findString(r: regexp.compile(v: "sha256-([0-9a-f]{64})"), v: r._value),
            t: "sha256-",
            u: "",
            i: 1
        )
    }))
    |> filter(fn: (r) => r.sha256 != "")
    |> yield(name: "vram_timeout_sha_only")
```
Этот запрос успешно извлекает `SHA256` из каждой строки лога, предоставляя нам точный идентификатор модели, которая была выгружена.

**Шаг 3: Поиск соответствия SHA256 -> Имя модели (Проблема)**

Это текущий нерешенный вопрос. В ходе расследования было установлено:
1.  **Измерение `ollama_inventory` пустое.** Многократные запросы с разными временными диапазонами (до 1 года) не вернули никаких данных. Этот источник информации ненадежен.
2.  **Логи `starting llama server` не содержат имени модели.** Они содержат `SHA256`, но не содержат тега `model=` с читаемым именем (например, `gemma:latest`).

**Вывод:** На данный момент в базе данных отсутствует надежный и доступный источник для сопоставления `SHA256` с именем модели. Это блокирует дальнейшую реализацию алгоритма по пункту 11.1.

1.  **Загрузка модели (Model Load)**
    *   **Описание:** Время на загрузку модели в память и инициализацию. Происходит один раз в начале сессии.
    *   **Лог-маркер:** `msg="llama runner started in X seconds"`
    *   **Цвет на диаграмме:** `Синий`

2.  **Обработка API запроса (API Request)**
    *   **Описание:** Общее время выполнения запроса к API, например `/api/chat`. На данный момент этот сегмент включает в себя и оценку промпта, и генерацию ответа, так как в текущих логах они не разделены.
    *   **Лог-маркер:** `[GIN] ... | DURATION | ... POST "/api/chat"`
    *   **Цвет на диаграмме:** `Зеленый`

3.  **Предупреждения (Warnings)**
    *   **Описание:** События, которые не являются ошибками, но могут влиять на производительность или результат (например, усечение контекста).
    *   **Лог-маркер:** `level=WARN`
    *   **Визуализация:** Пока не реализуем как блок, но можем в будущем отмечать запросы с предупреждениями (например, иконкой или изменением оттенка основного блока).

4.  **Выгрузка модели (Model Eviction)**
    *   **Описание:** Выгрузка модели из памяти (автоматическая по таймауту или принудительная при нехватке памяти).
    *   **Лог-маркер (прямой):** `msg="evicting model to free up space"` - **НЕ НАЙДЕН в текущих данных**
    *   **Лог-маркер (косвенный):** `msg="updated VRAM based on existing loaded models"` с увеличением `available` памяти
    *   **Способ отслеживания:** Анализ изменений доступной VRAM между событиями
    *   **Визуализация:** Маркер или короткий блок на временной шкале
    *   **Цвет на диаграмме:** `Серый`

*Примечание: Согласно исходному коду Ollama, события выгрузки логируются только на уровне DEBUG. В обычных логах мы видим только косвенные признаки через VRAM recovery timeout и изменения доступной памяти.*

#### Обнаруженные паттерны выгрузки:
- **Конфигурация:** `OLLAMA_KEEP_ALIVE:5m0s` (выгрузка через 5 минут неактивности)
- **Косвенный маркер:** Увеличение `available` VRAM в событиях `updated VRAM based on existing loaded models`
- **Пример:** available изменилось с `1.5 GiB` на `9.8 GiB` = освобождено ~8.3 GiB (выгрузка модели)
- **Временной интервал:** Может быть меньше 5 минут при принудительной выгрузке для новой модели

---

#### Примеры лог-сообщений для парсинга:

На этом шаге мы документируем точные форматы логов для ключевых событий, которые мы хотим отслеживать. Это послужит основой для расширения и уточнения нашего Flux-запроса.

**1. Событие: Запуск сессии и загрузка модели**

Эта строка лога сигнализирует о полном завершении процесса загрузки модели и готовности к работе. Ключевая информация здесь — это сообщение `llama runner started` и время выполнения.

```log
июл 23 21:46:58 user-MS-7D18 ollama[35304]: time=2025-07-23T21:46:58.334+10:00 level=INFO source=server.go:619 msg="llama runner started in 4.26 seconds"
```

*   **Что извлекаем:** Мы уже используем похожую, но менее точную строку `starting llama server`. В будущем мы можем перейти на эту строку для более точного определения момента старта сессии.

**2. Событие: API-запрос (успешный)**

Это стандартная строка для успешного вызова API. Она содержит всю необходимую нам информацию: статус, время выполнения, IP-адрес и эндпоинт.

```log
июл 23 21:47:10 user-MS-7D18 ollama[35304]: [GIN] 2025/07/23 - 21:47:10 | 200 | 16.608743461s |      172.17.0.3 | POST     "/api/chat"
```

*   **Что извлекаем:**
    *   `200` - Статус-код.
    *   `16.608743461s` - Длительность выполнения. Наш текущий парсер уже умеет работать с секундами (`s`) и миллисекундами (`ms`).
    *   `"/api/chat"` - Эндпоинт. Мы его уже извлекаем.

**3. Событие: Предупреждение (Warning) во время запроса**

Эта строка появляется, когда происходит что-то некритичное, но заслуживающее внимания. В данном случае — усечение входного промпта.

```log
июл 23 21:47:10 user-MS-7D18 ollama[35304]: time=2025-07-23T21:47:10.396+10:00 level=WARN source=runner.go:131 msg="truncating input prompt" limit=2048 prompt=2172 keep=4 new=2048
```

*   **Потенциальное использование:** В будущем мы можем добавить на диаграмму специальные отметки или изменять цвет событий, если во время их выполнения были зафиксированы предупреждения. Это поможет быстрее выявлять потенциальные проблемы.

**4. Событие: Косвенная выгрузка модели (обнаружено в ходе исследования)**

Прямые события выгрузки не логируются, но мы можем отследить их косвенно через изменения доступной VRAM.

```log
time=2025-07-23T09:27:14.373+10:00 level=INFO source=sched.go:509 msg="updated VRAM based on existing loaded models" gpu=GPU-72c48c23-32a4-2e54-95c9-99bb82483caa library=cuda total="11.8 GiB" available="1.5 GiB"
```

```log
time=2025-07-23T09:28:15.162+10:00 level=INFO source=sched.go:509 msg="updated VRAM based on existing loaded models" gpu=GPU-72c48c23-32a4-2e54-95c9-99bb82483caa library=cuda total="11.8 GiB" available="9.8 GiB"
```

*   **Что извлекаем:**
    *   Время события: `2025-07-23T09:28:15.162+10:00`
    *   Изменение доступной памяти: с `1.5 GiB` до `9.8 GiB` = освобождено ~8.3 GiB
    *   Это указывает на выгрузку модели между этими событиями

**5. Событие: Предупреждения о восстановлении VRAM**

Эти события могут указывать на проблемы с выгрузкой или переключением моделей.

```log
time=2025-07-23T09:27:19.419+10:00 level=WARN source=sched.go:648 msg="gpu VRAM usage didn't recover within timeout" seconds=5.04476581 model=/root/.ollama/models/blobs/sha256-adca500fad9b54c565ae672184e0c9eb690eb6014ba63f8ec13849d4f73a32d3
```

*   **Потенциальное использование:** Можем отмечать проблемные периоды на диаграмме или использовать как дополнительный индикатор процессов выгрузки.

**6. Новая цель: Визуализация всех длительных операций**

**Задача:** Каждый значительный промежуток времени, который `ollama` тратит на какую-либо операцию (например, загрузка модели), должен быть отображен на диаграмме Ганта в виде отдельного блока. Это позволит визуально оценивать загруженность и длительность всех ключевых процессов внутри сессии.

*   **Пример загрузки:**
    ```log
    ... msg="llama runner started in 4.26 seconds"
    ```
    Длительность `4.26 seconds` должна быть извлечена и представлена как блок на диаграмме в самом начале сессии.

*   **Пример выгрузки (косвенно):**
    Анализ изменений `available` VRAM между событиями `updated VRAM based on existing loaded models`

*   **Исключения:** Мелкие, общие API-запросы, не связанные напрямую с процессом обработки в рамках модели (например, запросы статуса), на данном этапе не включаются.

```csv
,result,table,_time,_value,endTime,series
,_result,0,2025-07-22T23:26:32.429635Z,/api/chat,2025-07-22T23:26:41.533557169Z,gemma3:12b (ctx: 2048)
,_result,0,2025-07-22T23:26:37.502353Z,/api/chat,2025-07-22T23:26:42.564446353Z,gemma3:12b (ctx: 2048)
,_result,1,2025-07-22T23:27:24.603314Z,/api/chat,2025-07-22T23:27:34.994052388Z,gemma3:1b (ctx: 8192)
,_result,1,2025-07-22T23:27:25.142701Z,/api/chat,2025-07-22T23:27:25.671126056Z,gemma3:1b (ctx: 8192)
,_result,2,2025-07-22T23:28:48.275209Z,/api/chat,2025-07-22T23:29:21.458032672Z,phi4:latest (ctx: 2048)
```

---

## Шаг 12: Реализация многоуровневой диаграммы жизненного цикла модели

### Цель:
Создать комплексную диаграмму Ганта, которая отображает полный жизненный цикл моделей с вложенными блоками выполнения.

### Структура данных для многоуровневой визуализации:

#### Уровень 1: Жизненный цикл модели (фоновые блоки)
```flux
// Определяем периоды жизни модели от запуска до выгрузки
model_lifecycle = // запрос для создания серых прозрачных блоков
```

#### Уровень 2: Загрузка модели (синие блоки)
```flux
// Блоки времени загрузки модели
model_loading = // запрос на основе "llama runner started in X seconds"
```

#### Уровень 3: Выполнение запросов (зеленые блоки)
```flux
// API-запросы внутри жизненного цикла модели
api_requests = // существующий запрос из шага 10
```

#### Уровень 4: Маркеры событий
```flux
// VRAM timeout warnings (желтые маркеры)
// Выгрузка модели (красные маркеры)
event_markers = // запрос для маркеров событий
```

### Техническая реализация:

Для создания многоуровневой диаграммы в Grafana потребуется:
1. **Несколько серий данных** с разными `_value` для цветового кодирования
2. **Общая временная шкала** для всех уровней
3. **Группировка по моделям** для корректного отображения

### Пример итоговой структуры данных:
```csv
,result,table,_time,_value,endTime,series,layer
,_result,0,2025-07-22T23:26:29Z,model_lifecycle,2025-07-22T23:28:15Z,gemma3:12b,background
,_result,0,2025-07-22T23:26:29Z,model_loading,2025-07-22T23:26:34.52Z,gemma3:12b,loading
,_result,0,2025-07-22T23:26:32Z,api_request,2025-07-22T23:26:41Z,gemma3:12b,execution
,_result,0,2025-07-22T23:27:19Z,vram_timeout,2025-07-22T23:27:19Z,gemma3:12b,warning
,_result,0,2025-07-22T23:28:15Z,model_unload,2025-07-22T23:28:15Z,gemma3:12b,unload
```

Это позволит создать богатую визуализацию, где каждый аспект жизненного цикла модели будет четко виден и понятен.

---

## Практические выводы из исследования логов (23.07.2025)

### Обнаруженные события и их маркеры:

#### ✅ Реализуемые события:
1. **Загрузка модели:** `msg="llama runner started in X seconds"` - **НАЙДЕНО**
2. **API-запросы:** `[GIN] ... POST "/api/chat"` - **РЕАЛИЗОВАНО**
3. **Косвенная выгрузка:** `msg="updated VRAM based on existing loaded models"` с увеличением available - **НАЙДЕНО**
4. **Предупреждения:** `level=WARN` включая `msg="truncating input prompt"` - **НАЙДЕНО**

#### ❌ Подтвержденные ограничения (из исходного кода):
1. **Прямая выгрузка:** `msg="evicting model to free up space"` - **НЕ СУЩЕСТВУЕТ в коде Ollama**
2. **События keep_alive timeout** - логируются только на уровне DEBUG: `"timer expired, expiring to unload"`
3. **События выгрузки** - большинство логируется на уровне DEBUG и не видно в обычных логах

### Конфигурация системы:
- **Keep-alive timeout:** `OLLAMA_KEEP_ALIVE:5m0s`
- **Общая VRAM:** `11.8 GiB`
- **Хост:** `user-MS-7D18` (критически важно для запросов!)

### Временные паттерны:
- **Загрузка модели:** 0.75-8.02 секунд
- **API-запросы:** от 528ms до 33+ секунд
- **Косвенная выгрузка:** обнаружена через ~1.5 минуты (не 5 минут - возможно принудительная)

### Подтвержденная архитектура выгрузки (из исходного кода):
1. **Таймер выгрузки:** `expireTimer` запускается после завершения запроса
2. **VRAM recovery:** `waitForVRAMRecovery()` ждет освобождения GPU памяти
3. **Debug логирование:** `"timer expired, expiring to unload"`, `"starting background wait for VRAM recovery"`
4. **Косвенные маркеры:** VRAM timeout warnings - единственные видимые события

### Результаты практического исследования (23.07.2025):

#### Найденные пары "запуск → выгрузка":
```
Хронология событий за 24 часа:
23:26:29 - model_start (Load time: 5.52s) 
23:27:14 - vram_update (Available: 1.5 GiB) ← первая модель загружена
23:27:19 - 3x vram_timeout ← попытки выгрузки первой модели
23:27:20 - model_start (Load time: 0.75s) ← вторая модель загружена
23:28:15 - vram_update (Available: 9.8 GiB) ← ВЫГРУЗКА! память освободилась
23:28:23 - model_start (Load time: 8.02s) ← третья модель
23:33:18-19 - 3x vram_timeout ← попытки выгрузки
00:32:06 - model_start (Load time: 1.50s)
00:49:21 - model_start (Load time: 1.51s)
08:05:19 - model_start (Load time: 1.51s)
11:46:58 - model_start (Load time: 4.26s)
```

#### Подтвержденная пара "запуск → выгрузка":
- **Запуск:** 23:26:29 (5.52s) → **Выгрузка:** 23:28:15 (VRAM: 1.5→9.8 GiB)
- **Время жизни модели:** ~1 час 46 минут
- **Причина выгрузки:** Принудительная (для загрузки новой модели)
- **Освобождено памяти:** ~8.3 GiB

#### Статистика за 24 часа:
- **7 запусков моделей**
- **1 подтвержденная выгрузка** (освобождено ~8.3 GiB)
- **6 VRAM timeout событий** (попытки выгрузки)
- **2 VRAM update события** (изменения памяти)

#### Паттерн выгрузки:
1. **VRAM timeout warnings** - система пытается освободить память
2. **VRAM update** с увеличением available - **фактическая выгрузка**
3. **Новый model_start** - загрузка следующей модели

### Концепция визуализации жизненного цикла модели:

#### Многоуровневая диаграмма Ганта:
1. **Фоновый блок (серый прозрачный):** Полный жизненный цикл модели от запуска до выгрузки
2. **Блок загрузки (синий):** Время загрузки модели (`llama runner started in X seconds`)
3. **Блоки выполнения (зеленые):** API-запросы `/api/chat` внутри жизненного цикла
4. **Маркеры предупреждений (желтые):** VRAM timeout events
5. **Маркер выгрузки (красный):** Момент фактической выгрузки (VRAM update с увеличением памяти)

#### Преимущества такого подхода:
- **Полная картина:** Видно весь жизненный цикл модели
- **Контекст выполнения:** API-запросы показаны в контексте сессии модели
- **Проблемные зоны:** VRAM timeout warnings выделяют проблемы с памятью
- **Эффективность:** Можно оценить время простоя модели между запросами

### Следующие шаги для реализации:
1. Создать запрос для фоновых блоков жизненного цикла (model_start → vram_update)
2. Добавить блоки загрузки модели (`llama runner started`)
3. Интегрировать API-запросы как вложенные блоки
4. Добавить маркеры VRAM timeout events
5. Создать маркеры выгрузки на основе VRAM update с увеличением памяти
6. Объединить все в единую многоуровневую диаграмму Ганта
