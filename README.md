# ⚡ zog
*A blisteringly fast, zero-allocation JSONL search engine.*

**zog** is a high-performance command-line tool designed to query massive JSONL datasets at the physical speed limit of your hardware. It doesn't fully parse JSON, it blasts through it—giving you `jq`-like data extraction at `grep`-beating speeds.

---

## 🚀 Benchmarks

Tested on a **1.0 GB JSONL file** (~15 million lines) on a modern NVMe SSD:

| Tool | Wall-Clock Time | Throughput |
|-----|-----------------|------------|
| jq | 23.04s | 0.04 GB/s |
| grep | 8.71s | 0.11 GB/s |
| **zog** | **0.69s** | **1.46 GB/s** |

---

## 🛠️ Usage

### Basic Search

Find all JSONL objects where the key `level` has the value `error`:

```bash
./zog --file logs.jsonl --key level --val error
```

### Data extraction (Plucking)
Instead of printing the entire JSONL line, extract only a specific field.
This is ideal for collecting IDs, metrics, or log messages without extra noise:
```bash
./zog --file logs.jsonl --key level --val error --pluck user_id
```

output example:
```42a9f3c1
9bc17e8a
f01d992e
```

### Unix Pipelining
`zog` works seamlessly with `stdin`. You can pipe data from tools like `cat`, `curl`, or `tail`:

```bash
cat large_data.jsonl | ./zog --key status --val 500 --pluck message
```

### 📦 Installation
`zog` is a single, static binary with zero dependencies.
### Download Prebuilt Binary
Download the latest binary for your OS from the Releases page (windows not yet supported).
```bash
# Example for macOS (Apple Silicon)
curl -L https://github.com/aikoschurmann/zog/releases/latest/download/zog-macos-arm64 -o zog
chmod +x zog
mv zog /usr/local/bin/
```

### Build from Source
If you have Zig installed, you can build `zog` from source:
```bash
git clone https://github.com/aikoschurmann/zog.git
cd zog
zig build -Doptimize=ReleaseFast
```
The binary will be located at:
```bash
./zig-out/bin/zog
```

## 🧠 The "Blind Scanner" Architecture (Or: Why is it so fast?)

Traditional JSON tools like `jq` build a full Abstract Syntax Tree (AST) to validate and understand the nested structure of your data. This is 100% accurate, but computationally expensive, which is why it bottlenecks at ~0.04 GB/s.

`zog` takes a completely different approach. It acts as a **"Blind Scanner"**:

### 1. Zero-Copy I/O
Standard tools copy data from the OS kernel into application buffers. `zog` uses `mmap` to map the file directly into the process address space, allowing the CPU to read data straight from the OS page cache.

### 2. SIMD Everything
Instead of checking every byte one by one, `zog` loads 64-byte chunks of your log file into **512-bit SIMD** registers. It uses bitmasking (`@ctz`) to identify newlines and search keys simultaneously—skipping dozens of CPU branches per cycle.

### 3. Zero Heap Allocations
`zog` never allocates memory on the heap. It scans the raw bytes for `"key":"value"` patterns, intelligently skips whitespace and colons, counts backslashes to respect JSON escaping rules, and extracts your data in-place.

### ⚠️ The Trade-off: False Positives
Because `zog` processes raw bytes instead of building an AST state machine, it does not know if it is currently "inside" a string value. 

This means it can theoretically hit perfectly formatted false positives. For example, if you search for `--key level --val error` in the following log:
`{"event": "req", "payload": "{\"level\": \"error\"}", "level": "info"}`

`zog` will return this line because the exact byte sequence `"level": "error"` exists inside the `payload` string.

For incident response, DevOps telemetry, and massive log filtering, this is standard behavior (standard `grep` does the same thing). For most users, accepting this edge-case is well worth the **30x speedup** over full JSON parsers.


### 🧪 Running Benchmarks
A Python script is included to generate test data and compare performance against `grep` and `jq`. To run the benchmarks:
```bash
python3 benchmark.py
```