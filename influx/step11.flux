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

// --- Часть 2: Поиск интервалов загрузки модели без лишних заголовков ---

// Создаем базовую таблицу со всеми событиями, привязанными к сессиям
all_events = union(tables: [session_starts_with_models, from(bucket: "ollama-logs") |> range(start: v.timeRangeStart, stop: v.timeRangeStop) |> filter(fn: (r) => r._measurement == "ollama_logs" and r._field == "message" and r.host == "${host}")])
    |> group()
    |> sort(columns: ["_time"])
    |> fill(column: "session_label", usePrevious: true)
    |> filter(fn: (r) => exists r.session_label and exists r._value)

// Находим события окончания загрузки и вычисляем начало
loading_phase = all_events
    |> filter(fn: (r) => strings.containsStr(v: r._value, substr: "llama runner started in"))
    |> map(fn: (r) => {
        // Извлекаем число и единицу измерения напрямую из строки лога
        found_duration_str = regexp.findString(r: regexp.compile(v: "in [0-9.]+ [a-zA-Z]+"), v: r._value) // e.g. "in 5.52 seconds"
        duration_clean = strings.trimPrefix(v: found_duration_str, prefix: "in ")          // "5.52 seconds"
        parts = strings.split(v: duration_clean, t: " ")                                  // ["5.52", "seconds"]
        time_val_str = parts[0]
        unit_str = if length(arr: parts) > 1 then parts[1] else ""

        time_val_float = if time_val_str != "" then float(v: time_val_str) else 0.0

        // Конвертируем в наносекунды для duration
        duration_ns = if unit_str == "seconds" then
            int(v: time_val_float * 1000000000.0)
        else if unit_str == "ms" then
            int(v: time_val_float * 1000000.0)
        else if unit_str == "µs" then
            int(v: time_val_float * 1000.0)
        else
            0

        load_duration = duration(v: duration_ns)
        start_time = experimental.subDuration(d: load_duration, from: r._time)

        return {
            _time: start_time,
            endTime: r._time,
            _value: "model_loading",
            session_label: r.session_label
        }
    })
    |> filter(fn: (r) => r._value == "model_loading")

// --- Финальная сборка ---
loading_phase
    |> pivot(rowKey:["_time", "endTime"], columnKey: ["session_label"], valueColumn: "_value")