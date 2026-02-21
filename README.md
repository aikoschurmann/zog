# ⚡ zog
*A blisteringly fast, zero-allocation JSONL search engine.*

**zog** is a high-performance command-line tool designed to query massive JSONL datasets at the physical speed limit of your hardware. It doesn't fully parse JSON; it blasts through it—giving you `jq`-like data extraction at `grep`-beating speeds.

---

## 🚀 Benchmarks

Tested on a **1.0 GB JSONL file** (~13.4 million lines) on a modern NVMe SSD.

### 1. Simple Query

| TYPE         | TIME     | SPEED     | COMMAND                                                                 |
|--------------|----------|-----------|-------------------------------------------------------------------------|
| zog (file)   |  0.716s  |  1.40 GB/s | `./zog --file chaos.jsonl --key service --val auth-api`                 |
| zog (pipe)   |  0.932s  |  1.07 GB/s | `cat chaos.jsonl \| ./zog --key service --val auth-api`                 |
| grep         | 10.100s  |  0.10 GB/s | `grep -E '"service": "auth-api"' chaos.jsonl`                        |
| jq           | 23.212s  |  0.04 GB/s | `jq -c 'select(.metadata.service == "auth-api")' chaos.jsonl`         |

### 2. Logical OR

| TYPE         | TIME     | SPEED     | COMMAND                                                                 |
|--------------|----------|-----------|-------------------------------------------------------------------------|
| zog (file)   |  1.439s  |  0.69 GB/s | `./zog --file chaos.jsonl --key level --val critical --or --key load --val 99.0` |
| zog (pipe)   |  1.498s  |  0.67 GB/s | `cat chaos.jsonl \| ./zog --key level --val critical --or --key load --val 99.0` |
| grep         | 16.489s  |  0.06 GB/s | `grep -E '"level": "critical"\|"load": 99.0' chaos.jsonl`          |
| jq           | 21.917s  |  0.05 GB/s | `jq -c 'select(.level == "critical" or .load == 99)' chaos.jsonl`      |

### 3. Multi-Filter (AND)

| TYPE         | TIME     | SPEED     | COMMAND                                                                 |
|--------------|----------|-----------|-------------------------------------------------------------------------|
| zog (file)   |  0.868s  |  1.15 GB/s | `./zog --file chaos.jsonl --key region --val eu --key level --val error` |
| zog (pipe)   |  0.934s  |  1.07 GB/s | `cat chaos.jsonl  ./zog --key region --val eu --key level --val error` |
| grep         | 21.328s  |  0.05 GB/s | `grep -E '"region": "eu".*"level": "error"\|...' chaos.jsonl`      |
| jq           | 19.032s  |  0.05 GB/s | `jq -c 'select(.metadata.region == "eu" and .level == "error")' chaos.jsonl` |

---

## 🛠️ Usage

### Basic Search

Find all JSONL objects where the key `level` has the string value `"error"`:

```bash
./zog --file logs.jsonl --key level --val error
```

### Logical OR Queries

Use the `--or` flag to combine multiple conditions. This matches any line where `level=critical` OR `load=99.0`:

```bash
./zog --file logs.jsonl --key level --val critical --or --key load --val 99.0
```

### Searching Primitives (Numbers, Booleans, Nulls)

`zog` automatically detects JSON primitives. If you pass a number or boolean, it searches for the raw primitive.

```bash
# Searches for the boolean: "active": true
./zog --file logs.jsonl --key active --val true

# Searches for the string: "active": "true"
./zog --file logs.jsonl --key active --val '"true"'
```

**Note**: Wrap the value in single quotes `'"..."'` in your shell to ensure the double quotes are passed directly to `zog`.

### Data Extraction (Plucking)

Instead of printing the entire JSONL line, extract only a specific field. This is ideal for collecting IDs, metrics, or log messages without extra noise:

```bash
./zog --file logs.jsonl --key level --val error --pluck user_id
```

**Output:**

```plaintext
42a9f3c1
9bc17e8a
```

### Unix Pipelining

`zog` works seamlessly with `stdin`. Pipe data directly from tools like `cat`, `curl`, or `tail`:

```bash
tail -f large_data.jsonl | ./zog --key status --val 500 --pluck message
```

---

## 📦 Installation

`zog` is a single, static binary with zero dependencies.

### Download Prebuilt Binary

Download the latest binary for your OS from the Releases page (Windows not yet supported).

```bash
# Example for macOS (Apple Silicon)
curl -L https://github.com/aikoschurmann/zog/releases/latest/download/zog-macos-arm64 -o zog
chmod +x zog
mv zog /usr/local/bin/
```

### Build from Source

If you have Zig installed, you can build `zog` for maximum speed:

```bash
git clone https://github.com/aikoschurmann/zog.git
cd zog
zig build -Doptimize=ReleaseFast
```

The compiled binary will be located at `./zig-out/bin/zog`.

---

## 🧠 The "Blind Scanner" Architecture

Traditional JSON tools like `jq` build a full Abstract Syntax Tree (AST) to validate and understand the nested structure of your data. This is 100% accurate, but computationally expensive, which is why it bottlenecks at ~0.04 GB/s.

`zog` takes a completely different approach. It acts as a **"Blind Scanner"**:

### 1. Double-Buffered Async I/O

Instead of the standard "Read-then-Process" loop which stalls the CPU while waiting for the SSD, `zog` uses a background Producer thread. While your CPU is busy SIMD-scanning the current 8MB block, the SSD is already filling the next buffer in parallel. This saturates NVMe bandwidth, keeping the CPU fed with data at all times.

### 2. SIMD Fast Path

Instead of checking every byte one by one, `zog` loads 32-byte chunks of your log file into 256-bit SIMD (AVX2/NEON) registers. It uses bitmasking and trailing-zero counts (`@ctz`) to identify newlines and search keys simultaneously—skipping dozens of CPU branches per cycle.

### 3. Zero Heap Allocations

`zog` never allocates memory on the heap during the scan. It searches the raw bytes for `"key":"value"` patterns, intelligently skips whitespace and colons, validates primitive boundaries, counts backslashes to respect JSON escaping rules, and extracts your data strictly in-place.

---

## ⚠️ Limitations & Trade-offs: The "Blind Scanner"

zog achieves its performance by treating JSON as a literal sequence of UTF-8 bytes rather than a hierarchical data structure. To maintain speeds of 1.4+ GB/s, zog makes the following architectural trade-offs:

1. **Structural Ignorance (Nesting)**
   - zog does not track object nesting or balance braces, so it cannot distinguish between a "root" key and a key located inside a nested sub-object.
   - **False Positive Example**: Searching for `--key id --val 10` will match a line even if `id: 10` is buried deep within a metadata sub-object or an array.

2. **Strict Numeric Matching (90 vs 90.0)**
   - zog identifies numbers as raw byte sequences rather than logical values and does not perform numeric normalization.
   - **Literalness**: Searching for `--val 90` will not match `90.0`.
   - **Boundary Integrity**: The scanner ensures that a number match is followed by a valid JSON boundary (e.g., `,`, `}`, `]`, or whitespace). For example, searching for `99` correctly ignores `995`.

3. **Whitespace & Multi-line JSON**
   - zog is strictly designed for single-line JSONL to maintain its SIMD "fast path."

4. **UTF-8 & Encoding**
   - **Literal Keys**: zog matches the exact bytes of your search key. If your JSON uses Unicode escape sequences in keys (e.g., `"le\u0076el"`), the literal match will fail.
   - **Encoding**: zog is a UTF-8 (u8) scanner and does not support multi-byte encodings like UTF-16 or UTF-32.

For incident response, DevOps telemetry, and massive log filtering, this is standard behavior (standard `grep` does the same thing). For most users, accepting this structural edge-case is well worth the **30x speedup** over full JSON parsers.