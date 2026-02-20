# ⚡ zog
*A blisteringly fast, zero-allocation JSONL search engine.*

**zog** is a high-performance command-line tool designed to query massive JSONL datasets at the physical speed limit of your hardware. By leveraging **memory mapping (mmap)** and **SIMD vector instructions**, it avoids the overhead of traditional JSON parsing to achieve near-instant results.

---

## 🚀 Benchmarks

Tested on a **1.0 GB JSONL file** (~15 million lines) on a modern NVMe SSD:

| Tool | Wall-Clock Time | Throughput | CPU Load |
|-----|-----------------|------------|----------|
| jq | 23.04s | 0.04 GB/s | 99% |
| grep | 8.71s | 0.11 GB/s | 97% |
| **zog** | **0.75s** | **1.33 GB/s** | **61%** |

> **Note:** At 1.33 GB/s, zog is effectively **I/O bound**, meaning it processes data as fast as the operating system can feed it from the disk cache.

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
Download the latest binary for your OS from the Releases page.
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

### 🧠 Why is it so fast?
### 1. Zero-Copy I/O
Standard tools copy data from the kernel into application buffers.
`zog` uses mmap to map the file directly into the process address space, allowing the CPU to read data straight from the OS page cache.
### 2. SIMD Newline Discovery
Instead of checking every byte for `\n`, `zog` loads** 64-byte chunks** into **512-bit SIMD** registers and identifies line boundaries with a single instruction — skipping dozens of branches per cycle.
### 3. No Heap Allocations
`zog` does not use a traditional JSON parser. It scans raw bytes for `"key":"value"` patterns and performs zero heap allocations inside the hot search loop, resulting in a flat memory profile regardless of file size.


### 🧪 Running Benchmarks
A Python script is included to generate test data and compare performance against `grep` and `jq`. To run the benchmarks:
```bash
python3 benchmark.py
```