import "strings"
import "regexp"
import "experimental"
import "date"

// --- Часть 1: Получаем сессии и модели с максимально широким диапазоном ---
// Это гарантирует, что мы всегда найдем начало сессии, независимо от зума.
sessions_with_sha_and_ctx = from(bucket: "ollama-logs")
  |> range(start: date.sub(d: 1d, from: v.timeRangeStart))
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
      ip_raw = strings.trimSpace(v: parts[3])
      endpoint = ip_raw
      return { _time: r._time, endpoint: endpoint, latency_ms: numeric_val * multiplier, status: int(v: strings.trimSpace(v: parts[1])) }
  })
  |> keep(columns: ["_time", "endpoint", "latency_ms", "status"])

// --- Финальная сборка ---
union(tables: [requests, session_starts_with_models])
  |> group()
  |> sort(columns: ["_time"])
  |> fill(column: "session_label", usePrevious: true)
  |> filter(fn: (r) => r.endpoint != "" and exists r.session_label)
  |> rename(columns: {_time: "request_end"})
  |> map(fn: (r) => ({
      _time: experimental.subDuration(d: duration(v: int(v: r.latency_ms * 1000000.0)), from: r.request_end),
      endTime: r.request_end,
      _value: r.endpoint, 
      session_label: r.session_label
  }))
  |> pivot(rowKey:["_time", "endTime"], columnKey: ["session_label"], valueColumn: "_value")