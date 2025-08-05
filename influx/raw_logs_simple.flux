// Простой запрос для получения всех логов за указанный период
// Этот запрос можно использовать для получения полной таблицы логов

from(bucket: "ollama-logs")
    |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
    |> filter(fn: (r) => r._measurement == "ollama_logs" and r._field == "message" and r.host == "${host}")
    |> sort(columns: ["_time"])
    |> keep(columns: ["_time", "_value", "host", "_measurement", "_field"])
    |> limit(n: 1000)
