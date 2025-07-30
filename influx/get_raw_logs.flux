// Универсальный запрос для получения сырых логов из бакета ollama-logs
// Принимает переменные Grafana: v.timeRangeStart, v.timeRangeStop, ${host}

from(bucket: "ollama-logs")
    |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
    |> filter(fn: (r) => r._measurement == "ollama_logs" and r._field == "message" and r.host =~ /^${host}$/)
    |> sort(columns: ["_time"])
    |> keep(columns: ["_time", "_value"])
