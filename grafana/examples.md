# Примеры Flux-запросов для мониторинга Ollama

## Задача: Извлечение одного значения из строки

**Цель:** Получить номер версии Ollama из строки лога.

**Исходная строка:**
```
msg="Listening on [::]:11434 (version 0.6.5)"
```

**Решение:** Используем `strings.split()` для "вырезания" нужной части строки между `(version ` и `)`.

```flux
import "strings"

from(bucket: "ollama-logs")
  |> range(start: -30d)
  |> filter(fn: (r) => r._value =~ /Listening on.*11434/)
  |> map(fn: (r) => ({
      _time: r._time,
      host: r.host,
      api_version: strings.split(v: strings.split(v: r._value, t: "(version ")[1], t: ")")[0]
  }))
```

**Результат:**
```
,result,table,_time,host,api_version
,_result,0,2025-07-23T01:25:00Z,user-MS-7D18,0.6.5
```

---

## Задача: Извлечение нескольких значений из сложной строки

**Цель:** Получить все параметры GPU из одной строки, где некоторые значения содержат лишние кавычки.

**Исходная строка:**
```
msg="detected gpus" id="GPU-xxx" library="cuda" name="\"NVIDIA GeForce RTX 3060\"" total="11.8 GiB"
```

**Решение:** Сначала очищаем строку от `\"` с помощью `strings.replaceAll()`, а затем для каждого параметра применяем `strings.split()` с уникальными разделителями.

```flux
import "strings"

data = from(bucket: "ollama-logs")
  |> range(start: -30d)
  |> filter(fn: (r) => r._value =~ /inference compute/)
  |> map(fn: (r) => ({ r with message: strings.replaceAll(v: r._value, t: "\\\"", u: "")}))

gpu_name = data |> map(fn: (r) => ({ _time: r._time, _field: "gpu_name", _value: strings.split(v: strings.split(v: r.message, t: "name=")[1], t: " total")[0]}))
gpu_total = data |> map(fn: (r) => ({ _time: r._time, _field: "gpu_total", _value: strings.split(v: strings.split(v: r.message, t: "total=")[1], t: " available")[0]}))
// ... и так далее для всех полей
```

**Результат (после объединения полей):**
```
,result,table,_time,gpu_name,gpu_total
,_result,0,2025-07-23T01:25:00Z,NVIDIA GeForce RTX 3060,11.8 GiB
```

---

## Задача: Объединение разрозненных событий в одну запись

**Цель:** Собрать информацию о запуске сервиса, готовности API и параметрах GPU, которая появляется в логах в разное время, в одну сводную строку.

**Исходные строки:**
```
_value: ... msg="Started ollama.service"
_value: ... msg="Listening on [::]:11434 (version 0.6.5)"
_value: ... msg="detected gpus" ... name="\"NVIDIA GeForce RTX 3060\"" ...
```

**Решение:** Используем `union()` для сбора всех событий в одну таблицу, `aggregateWindow()` для их группировки по времени (например, в 5-минутные окна) и `pivot()` для преобразования строк в столбцы.

```flux
// Это финальный запрос, используемый в Grafana
import "strings"

data = from(bucket: "ollama-logs")
  |> range(start: -30d)
  |> filter(fn: (r) => r.host == "user-MS-7D18")

// Создаем потоки для каждого типа событий
service_starts = data |> filter(fn: (r) => r._value =~ /Started ollama/) |> map(fn: (r) => ({r with _field: "service_start", _value: "Запущен"}))
api_events = data |> filter(fn: (r) => r._value =~ /Listening on/) |> map(fn: (r) => ({r with _field: "api_version", _value: strings.split(v: strings.split(v: r._value, t: "(version ")[1], t: ")")[0]}))
// ...потоки для GPU...

// Объединяем и преобразуем
union(tables: [service_starts, api_events, /*...gpu...*/])
  |> aggregateWindow(every: 5m, fn: last, createEmpty: false)
  |> pivot(rowKey:["_time"], columnKey: ["_field"], valueColumn: "_value")
  |> filter(fn: (r) => exists r.service_start or exists r.api_version or exists r.gpu_name)
```

**Результат:**
```
,result,table,_time,host,api_version,gpu_available,gpu_compute,gpu_driver,gpu_id,gpu_library,gpu_name,gpu_total,gpu_variant,service_start
,_result,0,2025-07-23T01:25:00Z,user-MS-7D18,0.6.5,1,8.6,12.4,GPU-...,cuda,NVIDIA GeForce RTX 3060,11.8 GiB,v12,Запущен
