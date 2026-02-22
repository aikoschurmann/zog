# ⚡ zog
*A blisteringly fast, zero-allocation JSONL search engine.*

**zog** is a high-performance command-line tool designed to query massive JSONL datasets at the physical speed limit of your hardware. It doesn't fully parse JSON; it blasts through it—giving you `jq`-like data extraction at `grep`-beating speeds.

---

## 🚀 Benchmarks

Tested on a **1 GB JSONL dataset** (6.7 million lines) on a modern NVMe SSD.

| Benchmark              | zog (file) | zog (pipe) | ripgrep    | jq/jaq     |
|------------------------|------------|------------|------------|------------|
| Simple Key Match       | **3.03 GB/s** | 2.16 GB/s  | 2.24 GB/s  | 0.07 GB/s |
| Substring Match (HAS)  | **2.21 GB/s** | 1.98 GB/s  | 1.42 GB/s  | 0.07 GB/s |
| Numeric Comparison     | **2.78 GB/s** | 2.17 GB/s  | 2.82 GB/s  | 0.10 GB/s |
| Field Extraction (TSV) | **2.36 GB/s** | 1.80 GB/s  | N/A        | 0.10 GB/s |
| JSON Re-Formatting     | **2.33 GB/s** | 1.85 GB/s  | N/A        | 0.10 GB/s |
| Aggregations           | **2.01 GB/s** | 1.68 GB/s  | N/A        | 0.05 GB/s |
| Complex Logic (OR/AND) | **1.82 GB/s** | 1.56 GB/s  | 0.54 GB/s  | 0.06 GB/s |

**Performance Summary:**
- **20–40x faster** than `jq/jaq` for typical queries
- **Competitive with ripgrep** for simple pattern matching while offering structured field extraction
- **1-2x faster than ripgrep** for complex multi-condition logic
- Maintains **1.8–2.8 GB/s** throughput even with field extraction and aggregations
- **Unique capability:** Aggregations (COUNT, SUM, MIN, MAX) at near line-speed (~2 GB/s)

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
# {"name": "Bob", "age": 30, "balance": -50.25, "active": false, "tier": 2}
# {"name": "Charlie", "age": 30, "balance": 0.0, "active": true, "tier": 3}
```

Or from stdin:

```bash
cat demo.jsonl | zog age eq 30
```

### Logical Operators

**AND** - All conditions must match:

```bash
zog --file demo.jsonl age eq 30 AND tier gt 2
# {"name": "Charlie", "age": 30, "balance": 0.0, "active": true, "tier": 3}
```

**OR** - Any condition can match:

```bash
zog --file demo.jsonl tier eq 1 OR tier eq 5
# {"name": "Alice", "age": 25, "balance": 100.50, "active": true, "tier": 1}
# {"name": "Eve", "age": "45", "balance": "99.99", "active": "true", "tier": 5}
```

**Mixed Logic:**

```bash
zog --file demo.jsonl age eq 30 AND balance lt 0 OR tier eq 1
# {"name": "Alice", "age": 25, "balance": 100.50, "active": true, "tier": 1}
# {"name": "Bob", "age": 30, "balance": -50.25, "active": false, "tier": 2}
```

### Query Semantics & Order of Operations

**Operator Precedence:** `AND` binds tighter than `OR`

zog evaluates conditions left-to-right, grouping consecutive `AND` conditions together. Each `OR` creates a new group.

**Examples:**

```bash
# A AND B OR C AND D
# Evaluated as: (A AND B) OR (C AND D)
zog --file demo.jsonl age eq 30 AND balance lt 0 OR tier eq 1 AND active eq true
# {"name": "Alice", "age": 25, "balance": 100.50, "active": true, "tier": 1}
# {"name": "Bob", "age": 30, "balance": -50.25, "active": false, "tier": 2}

# A OR B AND C
# Evaluated as: A OR (B AND C)
zog --file demo.jsonl tier eq 1 OR age eq 30 AND balance lt 0
# {"name": "Alice", "age": 25, "balance": 100.50, "active": true, "tier": 1}
# {"name": "Bob", "age": 30, "balance": -50.25, "active": false, "tier": 2}
```

**No Parentheses:** zog does not support explicit parentheses. For complex logic requiring different groupings, use multiple zog invocations:

```bash
# To get (A OR B) AND C, run two stages:
cat data.jsonl | zog A OR B | zog C
```

**Field Evaluation:** When multiple fields are specified in SELECT, they're extracted independently—order doesn't affect results, only output column order.

### Comparison Operators

```bash
# Greater than
zog --file demo.jsonl balance gt 100
# {"name": "Alice", "age": 25, "balance": 100.50, "active": true, "tier": 1}
# {"name": "Dave", "age": 45, "balance": 5000.00, "active": true, "tier": 4}

# Less than or equal
zog --file demo.jsonl tier lte 2
# {"name": "Alice", "age": 25, "balance": 100.50, "active": true, "tier": 1}
# {"name": "Bob", "age": 30, "balance": -50.25, "active": false, "tier": 2}

# Not equal
zog --file demo.jsonl age neq 30
# {"name": "Alice", "age": 25, "balance": 100.50, "active": true, "tier": 1}
# {"name": "Dave", "age": 45, "balance": 5000.00, "active": true, "tier": 4}
# {"name": "Eve", "age": "45", "balance": "99.99", "active": "true", "tier": 5}
```

### Substring Matching

Use the `has` operator to search for substrings within values:

```bash
# Find all entries with names containing "li"
zog --file demo.jsonl name has li
# {"name": "Alice", "age": 25, "balance": 100.50, "active": true, "tier": 1}
# {"name": "Charlie", "age": 30, "balance": 0.0, "active": true, "tier": 3}
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

### Aggregations

zog can compute aggregations over matching records at near line-speed (~2 GB/s):

**Available Aggregations:**
- `count:field` - Count non-null values
- `sum:field` - Sum numeric values
- `min:field` - Find minimum value
- `max:field` - Find maximum value

**Syntax:** zog supports shell-safe colon syntax (`count:field`). The colon syntax avoids shell escaping issues.

**Computation:** All aggregations are computed in a single pass over the data. Each field maintains its own independent aggregation state—`min:age` and `max:balance` don't conflict; they compute the minimum age and maximum balance separately.

**Important:** If you include **any** aggregation (count, sum, min, max), zog switches to "aggregation mode" and outputs a single summary row. Raw fields (without an aggregation function) will output as `null` in JSON or empty in TSV/CSV:

```bash
# Mixing raw field with aggregations - raw field outputs null/empty
zog --file demo.jsonl SELECT name,count:name WHERE tier gte 2
# Output: <empty>    4
# (name has no aggregation, so it's empty in the summary row)

# Solution: Either use all raw fields or all aggregations
zog --file demo.jsonl SELECT name WHERE tier gte 2        # Raw mode: prints each line
zog --file demo.jsonl SELECT count:name WHERE tier gte 2  # Aggregation mode: prints summary
```

**Examples:**

```bash
# Independent aggregations on different fields
zog --file demo.jsonl SELECT min:age,max:balance WHERE active eq true
# Output: 25.0000    5000.0000
# (minimum age is 25, maximum balance is 5000 - completely independent)

# You can even do min AND max on the same field
zog --file demo.jsonl SELECT min:age,max:age WHERE active eq true
# Output: 25.0000    45.0000

# Count all matching records
zog --file demo.jsonl SELECT count:name WHERE tier gte 2
# Output: 4

# Multiple aggregations
zog --file demo.jsonl SELECT count:name,sum:balance,min:age,max:tier WHERE active eq true
# Output: 4    5200.4900    25.0000    5.0000

# Total balance across all records (no WHERE clause needed)
cat demo.jsonl | zog SELECT sum:balance
# Output: 5150.2400
```

**Output Formats:**

```bash
# TSV (default)
zog --file demo.jsonl SELECT count:name,sum:balance WHERE tier gte 2
# 4    5049.7400

# JSON
zog --file demo.jsonl --format json SELECT count:name,sum:balance WHERE tier gte 2
# {"count:name": 4, "sum:balance": 5049.7400}

# CSV
zog --file demo.jsonl --format csv SELECT count:name,sum:balance WHERE tier gte 2
# 4,5049.7400
```

**Performance:** Aggregations run at ~2 GB/s—**40x faster** than jq while using zero heap allocations.

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

# Aggregate pipeline analytics
cat logs.jsonl | zog SELECT sum:bytes,count:request_id WHERE status eq 200
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
✅ **Analytics:** Compute aggregations (COUNT, SUM, MIN, MAX) over billions of records at 2+ GB/s  
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