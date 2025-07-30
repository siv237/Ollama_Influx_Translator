// VRAM Usage - полный график с несколькими источниками данных
import "strings"
import "regexp"

// 1. Основные обновления VRAM
vram_updates = from(bucket: "ollama-logs")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "ollama_logs" and r._field == "message")
  |> filter(fn: (r) => r.host =~ /^${host}$/)
  |> filter(fn: (r) => strings.containsStr(v: r._value, substr: "updated VRAM"))
  |> map(fn: (r) => {
    total_match = regexp.findString(r: regexp.compile(v: "total=\"([\\d\\.]+) GiB\""), v: r._value)
    available_match = regexp.findString(r: regexp.compile(v: "available=\"([\\d\\.]+) GiB\""), v: r._value)
    
    total_gb = if total_match != "" then float(v: strings.split(v: strings.split(v: total_match, t: "\"")[1], t: " ")[0]) else 0.0
    available_gb = if available_match != "" then float(v: strings.split(v: strings.split(v: available_match, t: "\"")[1], t: " ")[0]) else 0.0
    
    used_gb = total_gb - available_gb
    used_bytes = used_gb * 1073741824.0
    
    return {
      _time: r._time,
      _field: "vram_used_bytes", 
      _value: used_bytes
    }
  })

// 2. События inference compute
inference_events = from(bucket: "ollama-logs")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "ollama_logs" and r._field == "message")
  |> filter(fn: (r) => r.host =~ /^${host}$/)
  |> filter(fn: (r) => strings.containsStr(v: r._value, substr: "inference compute"))
  |> map(fn: (r) => {
    total_match = regexp.findString(r: regexp.compile(v: "total=\"([\\d\\.]+) GiB\""), v: r._value)
    available_match = regexp.findString(r: regexp.compile(v: "available=\"([\\d\\.]+) GiB\""), v: r._value)
    
    total_gb = if total_match != "" then float(v: strings.split(v: strings.split(v: total_match, t: "\"")[1], t: " ")[0]) else 0.0
    available_gb = if available_match != "" then float(v: strings.split(v: strings.split(v: available_match, t: "\"")[1], t: " ")[0]) else 0.0
    
    used_gb = total_gb - available_gb
    used_bytes = used_gb * 1073741824.0
    
    return {
      _time: r._time,
      _field: "vram_used_bytes", 
      _value: used_bytes
    }
  })

// 3. События загрузки моделей
model_loading = from(bucket: "ollama-logs")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "ollama_logs" and r._field == "message")
  |> filter(fn: (r) => r.host =~ /^${host}$/)
  |> filter(fn: (r) => strings.containsStr(v: r._value, substr: "new model will fit"))
  |> map(fn: (r) => {
    required_match = regexp.findString(r: regexp.compile(v: "required=\"([\\d\\.]+) GiB\""), v: r._value)
    
    required_gb = if required_match != "" then float(v: strings.split(v: strings.split(v: required_match, t: "\"")[1], t: " ")[0]) else 0.0
    required_bytes = required_gb * 1073741824.0
    
    return {
      _time: r._time,
      _field: "vram_used_bytes", 
      _value: required_bytes
    }
  })

// 4. События offload с информацией о памяти
offload_events = from(bucket: "ollama-logs")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "ollama_logs" and r._field == "message")
  |> filter(fn: (r) => r.host =~ /^${host}$/)
  |> filter(fn: (r) => strings.containsStr(v: r._value, substr: "msg=offload library=cuda"))
  |> map(fn: (r) => {
    // Ищем конкретные значения памяти
    value_bytes = if strings.containsStr(v: r._value, substr: "8.6 GiB") then 9235906150.4
      else if strings.containsStr(v: r._value, substr: "11.2 GiB") then 12026175897.6
      else 0.0
    
    return {
      _time: r._time,
      _field: "vram_used_bytes", 
      _value: value_bytes
    }
  })
  |> filter(fn: (r) => r._value > 0.0)

// Объединяем все источники VRAM
union(tables: [vram_updates, inference_events, model_loading, offload_events])
  |> sort(columns: ["_time"])