# ⚡ zog
*A blisteringly fast, zero-allocation JSONL search engine.*

**zog** is a high-performance command-line tool designed to query massive JSONL datasets at the physical speed limit of your hardware. It doesn't fully parse JSON; it blasts through it—giving you `jq`-like data extraction at `grep`-beating speeds.

---

## 🚀 Benchmarks

Tested on a **10 GB JSONL dataset** (67 million lines) on a modern NVMe SSD.

| Benchmark              | zog (file) | zog (pipe) | grep       | jq         |
|------------------------|------------|------------|------------|------------|
| Simple Query           | **3.13 GB/s** | 1.90 GB/s  | ~0.10 GB/s | ~0.04 GB/s |
| Logical OR             | **2.21 GB/s** | 1.37 GB/s  | ~0.06 GB/s | ~0.05 GB/s |
| Substring Match (HAS)  | **2.09 GB/s** | 1.35 GB/s  | ~0.10 GB/s | ~0.04 GB/s |
| Multi-Filter (AND)     | **3.11 GB/s** | 1.77 GB/s  | ~0.05 GB/s | ~0.05 GB/s |
| Numeric Comparison     | **3.11 GB/s** | 1.77 GB/s  | N/A        | ~0.05 GB/s |
| Field Extraction       | **2.04 GB/s** | 1.47 GB/s  | N/A        | ~0.04 GB/s |
| Complex Logic          | **2.00 GB/s** | 1.52 GB/s  | ~0.05 GB/s | ~0.05 GB/s |

**Performance Summary:**
- **30–60x faster** than `jq` for typical queries
- **20–50x faster** than `grep` for structured searches
- Saturates NVMe bandwidth at **3+ GB/s** for simple patterns
- Maintains **1.5–2 GB/s** throughput even for complex multi-condition logic

---

## 🛠️ Usage

### Example Dataset

All examples below use this `demo.jsonl` file:

```json
{"name": "Alice", "age": 25, "balance": 100.50, "active": true, "tier": 1}
{"name": "Bob", "age": 30, "balance": -50.25, "active": false, "tier": 2}
{"name": "Charlie", "age": 30, "balance": 0.0, "active": true, "tier": 3}
{"name": "Dave", "age": 45, "balance": 5000.00, "active": true, "tier": 4}
{"name": "Eve", "age": "45", "balance": "99.99", "active": "true", "tier": 5}
```

### Basic Syntax

```bash
zog [--file <path>] [SELECT <fields> WHERE] <key> <op> <val> [AND/OR ...]
```

**Operators:** `eq`, `neq`, `gt`, `lt`, `gte`, `lte`, `has`

**Type Prefixes:** `s:` (string), `n:` (numeric/primitive), `b:` (boolean/primitive - alias for `n:`)

### Simple Equality Query

Find all entries where `age` equals `30`:

```bash
zog --file demo.jsonl age eq 30
# {"name": "Bob", "age": 30, "balance": -50.25, "tier": 2}
# {"name": "Charlie", "age": 30, "balance": 0.0, "tier": 3}
```

Or from stdin:

```bash
cat demo.jsonl | zog age eq 30
```

### Logical Operators

**AND** - All conditions must match:

```bash
zog --file demo.jsonl age eq 30 AND tier gt 2
# {"name": "Charlie", "age": 30, "balance": 0.0, "tier": 3}
```

**OR** - Any condition can match:

```bash
zog --file demo.jsonl tier eq 1 OR tier eq 5
# {"name": "Alice", "age": 25, "balance": 100.50, "tier": 1}
# {"name": "Eve", "age": "45", "balance": "99.99", "tier": 5}
```

**Mixed Logic:**

```bash
zog age eq 30 AND balance lt 0 OR tier eq 1
# {"name": "Alice", "age": 25, "balance": 100.50, "tier": 1}
# {"name": "Bob", "age": 30, "balance": -50.25, "tier": 2}
```

### Comparison Operators

```bash
# Greater than
zog --file demo.jsonl balance gt 100
# {"name": "Dave", "age": 45, "balance": 5000.00, "tier": 4}

# Less than or equal
zog --file demo.jsonl tier lte 2
# {"name": "Alice", "age": 25, "balance": 100.50, "tier": 1}
# {"name": "Bob", "age": 30, "balance": -50.25, "tier": 2}

# Not equal
zog --file demo.jsonl age neq 30
# {"name": "Alice", "age": 25, "balance": 100.50, "tier": 1}
# {"name": "Dave", "age": 45, "balance": 5000.00, "tier": 4}
# {"name": "Eve", "age": "45", "balance": "99.99", "tier": 5}
```

### Substring Matching

Use the `has` operator to search for substrings within values:

```bash
# Find all entries with names containing "li"
zog --file demo.jsonl name has li
# {"name": "Alice", "age": 25, "balance": 100.50, "tier": 1}
# {"name": "Charlie", "age": 30, "balance": 0.0, "tier": 3}
```

### Field Extraction (SELECT)

Extract specific fields instead of printing entire JSONL lines:

```bash
zog --file demo.jsonl SELECT name,tier WHERE balance lt 100
```

**Output:**

```plaintext
Bob     2
Charlie 3
Eve     5
```

### Type Handling

zog automatically detects JSON types (strings, numbers, booleans, null). You can force strict type matching using prefixes:
- `s:` - Force string match only
- `n:` - Force numeric/primitive match only (numbers, booleans, null)
- `b:` - Alias for `n:` (semantic clarity when matching booleans)

**Auto-detection (Inclusive - Default):**

```bash
zog --file demo.jsonl SELECT name,tier WHERE balance lt 100
# Bob     2
# Charlie 3
# Eve     5
# Matches both numeric values (-50.25, 0.0) AND string "99.99"
```

**Force String Match Only:**

```bash
zog --file demo.jsonl SELECT name,tier WHERE balance lt s:100
# Eve     5
# Only matches "balance": "99.99" (string type)
# Excludes numeric -50.25 and 0.0
```

**Force Numeric/Primitive Match Only:**

```bash
zog --file demo.jsonl SELECT name,tier WHERE balance lt n:100
# Bob     2
# Charlie 3
# Only matches numeric values
# Excludes string "99.99"
```

**Boolean Matching (n: vs b:):**

```bash
# Auto-detection matches both boolean true AND string "true"
zog --file demo.jsonl SELECT name WHERE active eq true
# Alice
# Charlie
# Dave
# Eve

# Using b: (or n:) matches only the boolean primitive
zog --file demo.jsonl SELECT name WHERE active eq b:true
# Alice
# Charlie
# Dave
# Excludes Eve (who has "active": "true" as a string)
```

**Note:** Both `n:` and `b:` are functionally identical—they force primitive (non-string) matching. Use `b:` for semantic clarity when matching booleans.

**When to use type forcing:**
- Use `s:` when you specifically need string matches (e.g., version numbers stored as strings)
- Use `n:` or `b:` when you want to exclude string values from primitive comparisons
- Default behavior (no prefix) is inclusive and matches both—ideal for most cases

### Unix Pipelining

zog works seamlessly with standard Unix tools:

```bash
# Live log monitoring
tail -f app.jsonl | zog level eq error

# Chain with other tools
cat large_data.jsonl | zog status gte 500 | wc -l

# Extract and process
zog --file demo.jsonl SELECT name WHERE tier gte 3 | sort
# Charlie
# Dave
# Eve
```

---

## 📦 Installation

zog is a single, static binary with zero dependencies.

### Download Prebuilt Binary

Download the latest binary for your OS from the [Releases](https://github.com/aikoschurmann/zog/releases) page.

```bash
# macOS (Apple Silicon)
curl -L https://github.com/aikoschurmann/zog/releases/latest/download/zog-macos-arm64 -o zog
chmod +x zog
sudo mv zog /usr/local/bin/

# macOS (Intel)
curl -L https://github.com/aikoschurmann/zog/releases/latest/download/zog-macos-x64 -o zog
chmod +x zog
sudo mv zog /usr/local/bin/

# Linux (x86_64)
curl -L https://github.com/aikoschurmann/zog/releases/latest/download/zog-linux-x64 -o zog
chmod +x zog
sudo mv zog /usr/local/bin/
```

### Build from Source

If you have [Zig](https://ziglang.org/download/) installed:

```bash
git clone https://github.com/aikoschurmann/zog.git
cd zog
zig build -Doptimize=ReleaseFast
```

The compiled binary will be located at `./zig-out/bin/zog`.

---

## 🧠 Architecture: The "Blind Scanner"

Traditional JSON tools like `jq` build a full Abstract Syntax Tree (AST) to validate and understand the nested structure of your data. This is 100% accurate, but computationally expensive—bottlenecking at ~0.04 GB/s.

zog takes a fundamentally different approach. It acts as a **"Blind Scanner"**:

### 1. Double-Buffered Async I/O

Instead of the standard "Read-then-Process" loop which stalls the CPU while waiting for the disk, zog uses a background producer thread. While your CPU is busy SIMD-scanning the current 8 MB block, the disk is already filling the next buffer in parallel. This saturates NVMe bandwidth, keeping the CPU fed with data at all times.

### 2. SIMD Fast Path

Instead of checking every byte one by one, zog loads 32-byte chunks of your log file into 256-bit SIMD (AVX2/NEON) registers. It uses bitmasking and trailing-zero counts (`@ctz`) to identify newlines and search keys simultaneously—skipping dozens of CPU branches per cycle.

### 3. Zero Heap Allocations

zog never allocates memory on the heap during the scan. It searches the raw bytes for `"key":"value"` patterns, intelligently skips whitespace and colons, validates primitive boundaries, counts backslashes to respect JSON escaping rules, and extracts your data strictly in-place.

### 4. Pre-Compilation of Query Plans

Before scanning begins, zog "compiles" your query into an optimized execution plan. Keys are pre-quoted, numeric values are pre-parsed, SIMD character vectors are pre-built, and type-forcing flags are resolved—eliminating all runtime overhead from the hot path.

---

## ⚠️ Limitations & Trade-offs

zog achieves its performance by treating JSON as a literal sequence of UTF-8 bytes rather than a hierarchical data structure. To maintain speeds of 2–3+ GB/s, zog makes the following architectural trade-offs:

### 1. Structural Ignorance (Nesting)

zog does not track object nesting or balance braces, so it cannot distinguish between a "root" key and a key located inside a nested sub-object.

**False Positive Example:**

```json
{"id": 5, "metadata": {"id": 10}}
```

Searching for `id eq 10` will match this line, even though the root `id` is `5`.

**When This Matters:** Rarely. For standard JSONL logs (flat or lightly nested), this is not an issue.

### 2. Literal Numeric Matching

zog identifies numbers as raw byte sequences rather than logical values and does not perform numeric normalization.

**Example:**

- Searching for `balance eq 90` will **not** match `"balance": 90.0`
- Searching for `count eq 99` will **not** match `"count": 995` (boundary integrity is enforced)

**Workaround:** Use comparison operators (`gte`, `lte`) for numeric ranges when precision varies.

### 3. Single-Line JSONL Only

zog is strictly designed for line-delimited JSON (JSONL/NDJSON). Multi-line pretty-printed JSON is not supported.

### 4. UTF-8 Literal Keys

zog matches the exact bytes of your search key. If your JSON uses Unicode escape sequences in keys (e.g., `"le\u0076el"`), the literal match will fail.

**Supported Encodings:** UTF-8 only. UTF-16/UTF-32 are not supported.

---

## 🎯 Use Cases

zog is purpose-built for high-throughput log analysis and incident response:

✅ **DevOps & SRE:** Filter production logs for errors, slow queries, or HTTP 5xx responses  
✅ **Security:** Hunt for suspicious activity in audit logs or access logs  
✅ **Data Engineering:** Pre-filter massive datasets before loading into analysis tools  
✅ **CLI Workflows:** Chain with `grep`, `awk`, `sort`, `uniq` for powerful one-liners  
✅ **Real-time Monitoring:** Pipe live log streams (`tail -f`, `journalctl -f`) for instant filtering

❌ **NOT suitable for:**
- Validating JSON schema or syntax
- Queries requiring deep nesting awareness
- Pretty-printed JSON files
- Non-JSONL formats (XML, YAML, etc.)

---

## 🤝 Contributing

Contributions are welcome! Please open an issue or submit a pull request on [GitHub](https://github.com/aikoschurmann/zog).

