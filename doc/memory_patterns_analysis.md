# Анализ паттернов памяти в логах Ollama

## Обзор

Данный документ содержит полный анализ всех найденных паттернов, связанных с памятью в логах Ollama. Исследование проведено на основе реальных данных из InfluxDB за последние 24 часа.

## 1. Основные категории событий памяти

### 1.1 Обновления VRAM (GPU Memory Updates)
**Паттерн**: `updated VRAM based on existing loaded models`
**Пример**:
```
time=2025-07-30T10:53:50.023+10:00 level=INFO source=sched.go:548 msg="updated VRAM based on existing loaded models" gpu=GPU-72c48c23-32a4-2e54-95c9-99bb82483caa library=cuda total="11.8 GiB" available="3.1 GiB"
```

**Извлекаемые данные**:
- GPU ID: `GPU-72c48c23-32a4-2e54-95c9-99bb82483caa`
- Общий объем VRAM: `11.8 GiB`
- Доступный объем VRAM: `3.1 GiB`
- Используемый объем: `11.8 - 3.1 = 8.7 GiB`

### 1.2 Системная память (System Memory)
**Паттерн**: `system memory`
**Пример**:
```
time=2025-07-30T10:49:00.715+10:00 level=INFO source=server.go:135 msg="system memory" total="31.2 GiB" free="24.0 GiB" free_swap="16.0 GiB"
```

**Извлекаемые данные**:
- Общий объем RAM: `31.2 GiB`
- Свободная RAM: `24.0 GiB`
- Используемая RAM: `31.2 - 24.0 = 7.2 GiB`
- Свободный swap: `16.0 GiB`

### 1.3 Загрузка моделей в VRAM
**Паттерн**: `new model will fit in available VRAM in single GPU, loading`
**Пример**:
```
time=2025-07-30T10:49:13.672+10:00 level=INFO source=sched.go:788 msg="new model will fit in available VRAM in single GPU, loading" model=/root/.ollama/models/blobs/sha256-7cd4618c1faf8b7233c6c906dac1694b6a47684b37b8895d470ac688520b9c01 gpu=GPU-72c48c23-32a4-2e54-95c9-99bb82483caa parallel=2 available=3377552306 required="1.8 GiB"
```

**Извлекаемые данные**:
- Модель (hash): `sha256-7cd4618c1faf8b7233c6c906dac1694b6a47684b37b8895d470ac688520b9c01`
- GPU ID: `GPU-72c48c23-32a4-2e54-95c9-99bb82483caa`
- Доступная память (в байтах): `3377552306`
- Требуемая память: `1.8 GiB`
- Параллельность: `2`

### 1.4 Детальная информация о распределении памяти
**Паттерн**: `msg=offload library=cuda`
**Пример**:
```
time=2025-07-30T10:53:50.069+10:00 level=INFO source=server.go:175 msg=offload library=cuda layers.requested=-1 layers.model=29 layers.offload=29 layers.split="" memory.available="[3.1 GiB]" memory.gpu_overhead="0 B" memory.required.full="1.9 GiB" memory.required.partial="1.9 GiB" memory.required.kv="224.0 MiB" memory.required.allocations="[1.9 GiB]" memory.weights.total="934.7 MiB" memory.weights.repeating="752.1 MiB" memory.weights.nonrepeating="182.6 MiB" memory.graph.full="299.8 MiB" memory.graph.partial="482.3 MiB"
```

**Извлекаемые данные**:
- Количество слоев модели: `29`
- Слоев на GPU: `29`
- Доступная память: `3.1 GiB`
- Требуемая память (полная): `1.9 GiB`
- Требуемая память (частичная): `1.9 GiB`
- KV cache: `224.0 MiB`
- Веса модели (общие): `934.7 MiB`
- Веса (повторяющиеся): `752.1 MiB`
- Веса (неповторяющиеся): `182.6 MiB`
- График (полный): `299.8 MiB`
- График (частичный): `482.3 MiB`

### 1.5 Буферы памяти
**Паттерны**:
- `compute graph` - вычислительные графы
- `model weights` - веса модели
- `KV buffer` - буферы ключ-значение
- `compute buffer` - вычислительные буферы

**Примеры**:
```
time=2025-07-30T10:49:14.013+10:00 level=INFO source=ggml.go:666 msg="compute graph" backend=CPU buffer_type=CPU size="2.2 MiB"
time=2025-07-30T10:49:00.901+10:00 level=INFO source=ggml.go:377 msg="model weights" buffer=CUDA0 size="6.0 GiB"
llama_kv_cache_unified: KV self size = 224.00 MiB, K (f16): 112.00 MiB, V (f16): 112.00 MiB
llama_context: CUDA0 compute buffer size = 560.00 MiB
```

### 1.6 Таймауты VRAM
**Паттерн**: `gpu VRAM usage didn't recover within timeout`
**Пример**:
```
time=2025-07-30T10:53:49.905+10:00 level=WARN source=sched.go:687 msg="gpu VRAM usage didn't recover within timeout" seconds=5.044882538 runner.size="1.8 GiB" runner.vram="1.8 GiB" runner.parallel=2 runner.pid=14006 runner.model=/root/.ollama/models/blobs/sha256-7cd4618c1faf8b7233c6c906dac1694b6a47684b37b8895d470ac688520b9c01
```

**Извлекаемые данные**:
- Время ожидания: `5.044882538` секунд
- Размер runner: `1.8 GiB`
- VRAM runner: `1.8 GiB`
- Параллельность: `2`
- PID процесса: `14006`
- Модель: `sha256-7cd4618c1faf8b7233c6c906dac1694b6a47684b37b8895d470ac688520b9c01`

### 1.7 Информация о GPU
**Паттерн**: `inference compute`
**Пример**:
```
time=2025-07-30T10:36:51.789+10:00 level=INFO source=types.go:130 msg="inference compute" id=GPU-72c48c23-32a4-2e54-95c9-99bb82483caa library=cuda variant=v12 compute=8.6 driver=12.4 name="NVIDIA GeForce RTX 3060" total="11.8 GiB" available="11.6 GiB"
```

**Извлекаемые данные**:
- GPU ID: `GPU-72c48c23-32a4-2e54-95c9-99bb82483caa`
- Библиотека: `cuda`
- Версия CUDA: `v12`
- Compute capability: `8.6`
- Драйвер: `12.4`
- Название GPU: `NVIDIA GeForce RTX 3060`
- Общая память: `11.8 GiB`
- Доступная память: `11.6 GiB`

### 1.8 Кэши токенов
**Паттерны**:
- `token to piece cache size`
- `special tokens cache size`

**Примеры**:
```
load: token to piece cache size = 0.9310 MB
load: special tokens cache size = 22
```

### 1.9 Размеры файлов моделей
**Паттерн**: `file size`
**Примеры**:
```
print_info: file size = 934.69 MiB (5.08 BPW)
print_info: file size = 8.43 GiB (4.94 BPW)
print_info: file size = 4.33 GiB (4.64 BPW)
```

**Извлекаемые данные**:
- Размер файла: `934.69 MiB`, `8.43 GiB`, `4.33 GiB`
- Биты на вес (BPW): `5.08`, `4.94`, `4.64`

## 2. Временные паттерны

### 2.1 Последовательность загрузки модели
1. `starting llama server` - запуск сервера
2. `new model will fit in available VRAM` - проверка памяти
3. `offload library=cuda` - детали распределения
4. `model weights buffer=CUDA0` - загрузка весов
5. `compute graph backend=CUDA0` - создание графа
6. `KV buffer size` - создание KV кэша
7. `llama runner started in X seconds` - завершение загрузки

### 2.2 Мониторинг памяти
- Обновления VRAM происходят при изменении загруженных моделей
- Системная память отслеживается периодически
- Таймауты VRAM указывают на проблемы с освобождением памяти

## 3. Идентифицированные модели

По размерам файлов и метаданным:
- **Модель 1.5B**: `934.69 MiB` (5.08 BPW) - вероятно Qwen2.5-Coder 1.5B
- **Модель 8B**: `4.33 GiB` (4.64 BPW) - вероятно Llama3 8B
- **Модель 15B**: `8.43 GiB` (4.94 BPW) - вероятно Phi4 15B

## 4. Рекомендации для мониторинга

### 4.1 Ключевые метрики для дашборда
1. **VRAM Usage**: `total - available` из `updated VRAM`
2. **System Memory**: `total - free` из `system memory`
3. **Model Loading Events**: события `new model will fit`
4. **VRAM Timeouts**: события `didn't recover within timeout`
5. **Memory Distribution**: детали из `offload library=cuda`

### 4.2 Алерты
1. **High VRAM Usage**: > 90% использования
2. **High System Memory**: > 85% использования
3. **VRAM Timeouts**: любые события таймаута
4. **Model Loading Failures**: неудачные загрузки

### 4.3 Регулярные выражения для парсинга

#### VRAM Updates:
```regex
updated VRAM.*gpu=([^\\s]+).*total="([\\d\\.]+) GiB".*available="([\\d\\.]+) GiB"
```

#### System Memory:
```regex
system memory.*total="([\\d\\.]+) GiB".*free="([\\d\\.]+) GiB"
```

#### VRAM Timeouts:
```regex
gpu VRAM usage didn't recover within timeout.*seconds=([\\d\\.]+).*runner\\.size="([\\d\\.]+) GiB"
```

#### Model Loading:
```regex
new model will fit.*model=([^\\s]+).*gpu=([^\\s]+).*available=([\\d]+).*required="([\\d\\.]+) GiB"
```

### 1.10 Загрузка тензоров и слоев
**Паттерны**:
- `load_tensors: loading model tensors`
- `offloading X layers to GPU`
- `offloaded X/Y layers to GPU`
- `offloading output layer to CPU`

**Примеры**:
```
load_tensors: loading model tensors, this can take a while... (mmap = true)
time=2025-07-30T00:19:25.758+10:00 level=INFO source=ggml.go:375 msg="offloaded 48/49 layers to GPU"
time=2025-07-30T10:49:00.901+10:00 level=INFO source=ggml.go:363 msg="offloading output layer to CPU"
load_tensors: offloading output layer to GPU
```

**Извлекаемые данные**:
- Количество слоев на GPU: `48/49`
- Тип загрузки: `mmap = true`
- Направление offload: `to GPU`, `to CPU`

### 1.11 Параметры моделей и производительность
**Паттерны**:
- `model params = X B`
- `file size = X (Y BPW)`
- `llama runner started in X seconds`

**Примеры**:
```
print_info: model params = 1.54 B
print_info: model params = 8.03 B  
print_info: model params = 14.66 B
print_info: file size = 934.69 MiB (5.08 BPW)
print_info: file size = 8.43 GiB (4.94 BPW)
time=2025-07-30T14:23:12.820+10:00 level=INFO source=server.go:637 msg="llama runner started in 8.78 seconds"
```

**Извлекаемые данные**:
- Количество параметров: `1.54 B`, `8.03 B`, `14.66 B`
- Размер файла: `934.69 MiB`, `8.43 GiB`
- Биты на вес (BPW): `5.08`, `4.94`
- Время загрузки: `8.78 seconds`, `1.00 seconds`

### 1.12 Серверы и runner'ы
**Паттерны**:
- `starting llama server`
- `starting go runner`
- `starting ollama engine`
- `Server listening on`
- `loaded runners`

**Примеры**:
```
time=2025-07-30T10:53:50.259+10:00 level=INFO source=server.go:438 msg="starting llama server" cmd="/usr/local/bin/ollama runner --model /root/.ollama/models/blobs/sha256-6a77366395772462c84f0c4d226ac404674327cbe78c01e4391cc7e0c698851e --ctx-size 8192 --batch-size 512 --n-gpu-layers 29 --threads 6 --parallel 2 --port 39609"
time=2025-07-30T10:53:50.267+10:00 level=INFO source=runner.go:815 msg="starting go runner"
time=2025-07-30T10:49:13.795+10:00 level=INFO source=runner.go:925 msg="starting ollama engine"
time=2025-07-30T14:17:23.236+10:00 level=INFO source=runner.go:874 msg="Server listening on 127.0.0.1:36891"
time=2025-07-30T14:17:23.187+10:00 level=INFO source=sched.go:483 msg="loaded runners" count=1
```

**Извлекаемые данные**:
- Модель (hash): `sha256-6a77366395772462c84f0c4d226ac404674327cbe78c01e4391cc7e0c698851e`
- Размер контекста: `--ctx-size 8192`
- Размер батча: `--batch-size 512`
- Слои на GPU: `--n-gpu-layers 29`
- Потоки: `--threads 6`
- Параллельность: `--parallel 2`
- Порт: `--port 39609`
- IP и порт сервера: `127.0.0.1:36891`
- Количество runner'ов: `count=1`

### 1.13 Метаданные моделей
**Паттерны**:
- `llama_model_loader: - kv`
- `embedding_length`
- `context_length`
- `rope.freq_base`
- `attention.layer_norm_rms_epsilon`
- `quantization_version`

**Примеры**:
```
llama_model_loader: - kv   4: llama.embedding_length u32 = 4096
llama_model_loader: - kv   3: llama.context_length u32 = 8192
llama_model_loader: - kv   8: llama.rope.freq_base f32 = 500000.000000
llama_model_loader: - kv  20: qwen2.attention.layer_norm_rms_epsilon f32 = 0.000001
llama_model_loader: - kv  21: general.quantization_version u32 = 2
```

**Извлекаемые данные**:
- Размер эмбеддингов: `4096`
- Длина контекста: `8192`, `32768`
- Частота RoPE: `500000.000000`
- Epsilon нормализации: `0.000001`, `0.000010`
- Версия квантизации: `2`

### 1.14 Типы тензоров
**Паттерны**:
- `llama_model_loader: - type`
- `f32: X tensors`
- `q4_K: X tensors`
- `q5_K: X tensors`
- `q6_K: X tensors`

**Примеры**:
```
llama_model_loader: - type f32: 141 tensors
llama_model_loader: - type q4_K: 168 tensors
llama_model_loader: - type q5_K: 40 tensors
llama_model_loader: - type q6_K: 29 tensors
```

**Извлекаемые данные**:
- Тип квантизации: `f32`, `q4_K`, `q5_K`, `q6_K`
- Количество тензоров каждого типа: `141`, `168`, `40`, `29`

## 2. Дополнительные временные паттерны

### 2.1 Полная последовательность загрузки модели (расширенная)
1. `starting llama server` - запуск сервера с параметрами
2. `starting go runner` - запуск Go runner
3. `starting ollama engine` - запуск движка Ollama
4. `new model will fit in available VRAM` - проверка памяти
5. `load_tensors: loading model tensors` - начало загрузки тензоров
6. `offload library=cuda` - детали распределения памяти
7. `offloaded X/Y layers to GPU` - загрузка слоев на GPU
8. `model weights buffer=CUDA0` - загрузка весов
9. `compute graph backend=CUDA0` - создание вычислительного графа
10. `KV buffer size` - создание KV кэша
11. `Server listening on IP:PORT` - сервер готов
12. `llama runner started in X seconds` - завершение загрузки

### 2.2 Метрики производительности
- Время загрузки модели: от `1.00 seconds` до `8.78 seconds`
- Размеры моделей: `1.54B`, `8.03B`, `14.66B` параметров
- Эффективность квантизации: `4.94-5.08 BPW`

## 3. Расширенная классификация моделей

### 3.1 По размерам параметров:
- **1.5B модели**: `1.54 B` параметров, `934.69 MiB`, `5.08 BPW`
- **8B модели**: `8.03 B` параметров, `4.33 GiB`, `4.64 BPW`
- **15B модели**: `14.66 B` параметров, `8.43 GiB`, `4.94 BPW`

### 3.2 По архитектурам:
- **Qwen2.5-Coder**: 1.5B параметров, контекст 32768
- **Llama3**: 8B параметров, контекст 8192
- **Phi4**: 15B параметров, контекст 4096

## 4. Дополнительные регулярные выражения

### 4.1 Загрузка тензоров:
```regex
load_tensors: loading model tensors.*mmap = (true|false)
offloaded ([\\d]+)/([\\d]+) layers to GPU
```

### 4.2 Параметры моделей:
```regex
model params\\s+=\\s+([\\d\\.]+)\\s+B
file size\\s+=\\s+([\\d\\.]+)\\s+(MiB|GiB)\\s+\\(([\\d\\.]+)\\s+BPW\\)
llama runner started in ([\\d\\.]+) seconds
```

### 4.3 Конфигурация сервера:
```regex
starting llama server.*--ctx-size ([\\d]+).*--batch-size ([\\d]+).*--n-gpu-layers ([\\d]+).*--threads ([\\d]+).*--parallel ([\\d]+).*--port ([\\d]+)
Server listening on ([\\d\\.]+):([\\d]+)
loaded runners.*count=([\\d]+)
```

### 4.4 Метаданные моделей:
```regex
llama_model_loader: - kv\\s+([\\d]+):\\s+([^\\s]+)\\s+([^\\s]+)\\s+=\\s+(.+)
- type\\s+([^:]+):\\s+([\\d]+) tensors
```

## 5. Заключение

Расширенный анализ выявил **14 категорий** событий памяти и ресурсов в логах Ollama:

### Основные категории:
1. **Обновления VRAM** - текущее состояние видеопамяти
2. **Системная память** - состояние RAM и swap
3. **Загрузка моделей** - события размещения в VRAM
4. **Детальное распределение памяти** - компоненты и их размеры
5. **Буферы памяти** - compute, KV, model weights
6. **Таймауты VRAM** - критические события
7. **Информация о GPU** - характеристики устройств
8. **Кэши токенов** - размеры кэшей
9. **Размеры файлов** - модели и их характеристики
10. **Загрузка тензоров** - процесс offload на GPU/CPU
11. **Параметры моделей** - количество параметров, BPW, время загрузки
12. **Серверы и runner'ы** - процессы и их конфигурация
13. **Метаданные моделей** - технические характеристики
14. **Типы тензоров** - квантизация и распределение

### Новые возможности для мониторинга:
- **Время загрузки моделей** - от 1 до 9 секунд
- **Эффективность квантизации** - BPW метрики
- **Конфигурация серверов** - параметры запуска
- **Распределение слоев** - GPU vs CPU offload
- **Типы тензоров** - детали квантизации
- **Метаданные архитектур** - технические параметры

Эти данные позволяют создать максимально детальный дашборд для мониторинга всех аспектов работы Ollama с памятью и ресурсами.