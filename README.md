# ⚡ zog
*A blisteringly fast JSONL search engine.*

**zog** queries line-delimited JSON with a small SQL-like language: filter lines, pull out fields, and compute aggregates. It works in two layers. A SIMD search over the raw bytes rules out every line that provably can't match, and a validating JSON parser then decides the rest exactly. You get `jq`'s exact answers at close to `grep` speed: 20–60x faster than `jq`/`jaq` with exact results, and with `--fast` (bytes only, approximate) 30–180x faster and ahead of `ripgrep` on every search below.

```bash
zog --file app.jsonl level eq error AND status gte 500
zog --file app.jsonl SELECT service,count:bytes,avg:latency_ms WHERE status eq 200
tail -f app.jsonl | zog level eq error
```

---

## 🚀 Benchmarks

All numbers are the best of 3 runs (5 for exact zog, 1 for jq/jaq), with the file in the OS page cache, on an Apple M2 Pro (16 GB). Versions: zog 1.0.0 (`ReleaseFast`), ripgrep 15.1.0, jaq 2.3.0, jq 1.7.1. Every tool returned the same matches. The `--fast` and ripgrep numbers were measured with zog 1.0.0, which only had the byte-level layer. The commands are listed under [Reproducing the benchmarks](#reproducing-the-benchmarks).

### Synthetic logs: 968 MB, 4 million lines

Each line is a flat-ish log record of about 240 bytes with a nested `user` object and an array (see the generator below).

| Query | zog (exact) | zog `--fast` (file) | zog `--fast` (pipe) | ripgrep | jaq |
|-------|-----------:|-----------:|-----------:|--------:|----:|
| Key match: `level eq error` | 0.26 s · 3.7 GB/s | **0.10 s** · 10.0 GB/s | 0.27 s · 3.6 GB/s | 0.14 s · 6.9 GB/s | 8.6 s · 0.11 GB/s |
| Numeric: `status gte 500` | 0.42 s · 2.3 GB/s | **0.15 s** · 6.3 GB/s | 0.27 s · 3.6 GB/s | 0.18 s · 5.5 GB/s | 8.8 s · 0.11 GB/s |
| Substring: `msg has beef` | 0.40 s · 2.4 GB/s | **0.30 s** · 3.2 GB/s | 0.37 s · 2.6 GB/s | 0.58 s · 1.7 GB/s | 8.2 s · 0.12 GB/s |
| AND/OR: `level eq error AND status eq 500 OR service eq auth AND status eq 404` | 0.32 s · 3.0 GB/s | **0.21 s** · 4.6 GB/s | 0.28 s · 3.5 GB/s | 1.48 s · 0.65 GB/s | 10.2 s · 0.09 GB/s |
| TSV extraction: `SELECT service,status,bytes WHERE level eq warn` | 0.29 s · 3.4 GB/s | **0.13 s** · 7.3 GB/s | 0.26 s · 3.7 GB/s | — | 18.0 s · 0.05 GB/s |
| JSON output: `--format json SELECT ts,user,latency_ms WHERE status eq 503` | 0.39 s · 2.5 GB/s | **0.23 s** · 4.2 GB/s | 0.31 s · 3.2 GB/s | — | 8.7 s · 0.11 GB/s |
| Aggregates: `SELECT count:bytes,sum:bytes,avg:latency_ms WHERE status eq 200` | 0.58 s · 1.7 GB/s | **0.26 s** · 3.7 GB/s | 0.33 s · 3.0 GB/s | — | 11.1 s · 0.09 GB/s |
| No match (full scan): `nosuchkey exists` | 0.12 s · 8.3 GB/s | **0.10 s** · 10.2 GB/s | 0.25 s · 3.8 GB/s | 0.11 s · 8.6 GB/s | — |

jq 1.7.1 took 17.4 s (0.06 GB/s) on the key match, about twice as long as jaq, so it was only run once.

How to read this:
- **Exact mode pays for the lines it parses.** Lines that can't match cost the same as in `--fast` (`nosuchkey exists`). Every line that might match is validated and evaluated by the parser, at roughly 1.3 GB/s. So the more lines match, the bigger the gap: `level eq error` matches a sixth of the lines, `status eq 200` over a third. A query that can't be ruled out from the bytes, such as `NOT level eq info`, parses every line (0.77 s here, vs 0.18 s with `--fast`).
- **Pipe numbers are capped by the pipe.** Just `cat logs.jsonl | wc -c` takes 0.22 s (4.4 GB/s) here, and zog's pipe times sit right at that ceiling. When you can, pass `--file`.
- **ripgrep compares raw text**, so its patterns are approximations. The AND/OR regex (`"level":"error".*"status":500|…`) only works because the keys always appear in the same order, and ripgrep can't parse numbers (`status gte 500` became `"status":5[0-9][0-9]`). zog's queries understand JSON values and don't depend on key order.
- ripgrep can't extract fields or aggregate, hence the dashes.

### Real-world data: GitHub Archive, 3.1 GB

These were measured with zog 1.0.0, so they correspond to `--fast`. In exact mode, keys inside nested objects need their path: `login eq torvalds` becomes `actor.login eq torvalds`.

Three hours of [GH Archive](https://www.gharchive.org/) events: 791,615 deeply nested lines, median 945 bytes. For reference, `rg -cF '"type":"MemberEvent"'` takes 0.33 s on this file.

| Query | zog |
|-------|----:|
| `type eq MemberEvent` | 0.31 s |
| `type eq ForkEvent OR type eq WatchEvent` | 0.30 s |
| `type eq ForkEvent OR action eq reopened` | 0.30 s |
| `login eq torvalds OR language eq Zig OR type eq GollumEvent` | 0.39 s |
| 8-way OR of different keys (`login`, `language`, `type`, `ref_type`, `pusher_type`, `action`, `state`, `license`) | 0.50 s |
| `type eq PullRequestEvent AND action eq closed OR type eq IssuesEvent AND action eq opened` | 0.30 s |
| `type eq PushEvent AND size gte 10` | 0.28 s |
| `NOT type eq PushEvent` | 0.30 s |
| `title has segfault` | 0.30 s |
| `SELECT login,name WHERE type eq WatchEvent` | 0.32 s |
| `SELECT count:size,sum:size,avg:size WHERE type eq PushEvent` | 0.30 s |

Most queries run at about 10 GB/s, on par with ripgrep's plain fixed-string count. An `OR` over many different keys costs little extra: 8 keys take 0.50 s, where testing each key separately would take over a second (see [Many-key ORs](#4-many-key-ors-teddy)).

---

## 🛠️ Usage

```text
zog [options] [SELECT <fields> [WHERE]] <condition> [AND|OR <condition> ...]
```

zog reads the file given with `--file`, or standard input when it is omitted.

### Options

| Option | Meaning |
|--------|---------|
| `--file <path>` | JSONL file to read (default: stdin) |
| `--format tsv\|csv\|json` | Output format for `SELECT` (default: `tsv`) |
| `--count`, `-c` | Print only the number of matching lines |
| `--header` | Print a header row of field names (TSV/CSV) |
| `--limit <n>` | Stop after `n` matches |
| `--fast` | Match on the raw bytes only, without the exact parse: faster, but approximate (see [Limitations](#️-limitations--trade-offs)) |
| `--help`, `-h` | Show help |
| `--version`, `-v` | Show the version |
| `--` | Treat all following arguments as query terms (for keys starting with `--`) |

### Conditions

A condition is `<key> <op> <value>`, or `<key> exists`.

| Operator | Matches when the key's value… |
|----------|-------------------------------|
| `eq` / `neq` | equals / doesn't equal the value (numbers compare by value: `eq 90` matches `90.0` and `9e1`) |
| `gt`, `gte`, `lt`, `lte` | compares numerically (the value must be a number) |
| `has` | contains the value as a substring (strings, and the text of numbers and literals; never objects or arrays) |
| `in` | equals one of a comma-separated list: `level in error,warn` |
| `exists` | the key is present, whatever its value |

Keys name members of the top-level object. Use dots to reach into nested objects, and `\.` for a dot that is part of a key:

```bash
echo '{"id": 5, "user": {"id": 10}, "a.b": 1}' | zog user.id eq 10    # matches
echo '{"id": 5, "user": {"id": 10}, "a.b": 1}' | zog id eq 10         # doesn't
echo '{"id": 5, "user": {"id": 10}, "a.b": 1}' | zog 'a\.b' exists     # matches
```

When a key appears twice in the same object, the last one counts, as in `jq`. Lines that aren't valid JSON never match, not even `NOT` conditions.

Prefix a condition with `NOT` to negate it. `AND` binds tighter than `OR`, and there are no parentheses:

```bash
# A AND B OR C AND D  ==  (A AND B) OR (C AND D)
zog --file demo.jsonl age eq 30 AND balance lt 0 OR tier eq 1 AND active eq true
```

To get `(A OR B) AND C`, chain two runs: `zog A OR B | zog C`.

**`neq` vs `NOT … eq`:** every operator, `neq` included, requires the key to be present. `NOT` simply inverts the result, so `NOT a eq 1` also matches lines that have no `a` at all:

```bash
printf '{"a":1}\n{"a":2}\n{"b":1}\n' | zog a neq 1       # {"a":2}
printf '{"a":1}\n{"a":2}\n{"b":1}\n' | zog NOT a eq 1    # {"a":2} and {"b":1}
```

### Example dataset

The examples below use this `demo.jsonl` (it's in the repo):

```json
{"name": "Alice", "age": 25, "balance": 100.50, "active": true, "tier": 1}
{"name": "Bob", "age": 30, "balance": -50.25, "active": false, "tier": 2}
{"name": "Charlie", "age": 30, "balance": 0.0, "active": true, "tier": 3}
{"name": "Dave", "age": 45, "balance": 5000.00, "active": true, "tier": 4}
{"name": "Eve", "age": "45", "balance": "99.99", "active": "true", "tier": 5}
```

### Filtering

Without `SELECT`, matching lines are printed as they are.

```bash
zog --file demo.jsonl age eq 30
# {"name": "Bob", "age": 30, "balance": -50.25, "active": false, "tier": 2}
# {"name": "Charlie", "age": 30, "balance": 0.0, "active": true, "tier": 3}

zog --file demo.jsonl age eq 30 AND tier gt 2
# {"name": "Charlie", "age": 30, "balance": 0.0, "active": true, "tier": 3}

zog --file demo.jsonl tier eq 1 OR tier eq 5
# {"name": "Alice", "age": 25, "balance": 100.50, "active": true, "tier": 1}
# {"name": "Eve", "age": "45", "balance": "99.99", "active": "true", "tier": 5}

zog --file demo.jsonl NOT age eq 30
# {"name": "Alice", ...}
# {"name": "Dave", ...}
# {"name": "Eve", ...}

zog --file demo.jsonl balance gt 100
# {"name": "Alice", ...}
# {"name": "Dave", ...}

zog --file demo.jsonl name has li
# {"name": "Alice", ...}
# {"name": "Charlie", ...}

zog --file demo.jsonl tier in 1,3,5
# {"name": "Alice", ...}
# {"name": "Charlie", ...}
# {"name": "Eve", ...}

zog --file demo.jsonl balance exists          # every line
zog --file demo.jsonl --count active eq true  # 4 (Eve's "true" string counts, see Types)
zog --file demo.jsonl --limit 2 active eq true
```

### Types

By default a value matches both its JSON type and its string form: `active eq true` matches `true` and `"true"`, and `balance lt 100` matches `-50.25` and `"99.99"`. Numbers inside strings are compared as numbers. To force a type, prefix the value:

| Prefix | Matches |
|--------|---------|
| `s:` | strings only |
| `n:` | numbers, booleans and `null` only |
| `b:` | same as `n:`, reads better for booleans |

```bash
zog --file demo.jsonl SELECT name WHERE active eq true      # Alice Charlie Dave Eve
zog --file demo.jsonl SELECT name WHERE active eq b:true    # Alice Charlie Dave
zog --file demo.jsonl SELECT name,tier WHERE balance lt s:100
# Eve     5
zog --file demo.jsonl SELECT name,tier WHERE balance lt n:100
# Bob     2
# Charlie 3
```

`has` follows the prefixes too: `has s:42` only searches string values, `has n:42` only numbers and other literals.

Strings are compared after decoding their escapes, so `msg eq 'say "hi"'` matches `"msg": "say \"hi\""` and `name eq café` matches `"name": "caf\u00e9"`. Keys are decoded the same way.

### Field extraction (SELECT)

`SELECT` prints the listed fields of each matching line. `WHERE` is optional: a bare `SELECT` reads every line.

```bash
zog --file demo.jsonl SELECT name,tier WHERE balance lt 100
# Bob     2
# Charlie 3
# Eve     5

zog --file demo.jsonl --limit 3 SELECT name,age
# Alice   25
# Bob     30
# Charlie 30

zog --file demo.jsonl --header SELECT name,tier WHERE balance lt 100
# name    tier
# Bob     2
# ...
```

Output formats:

```bash
zog --file demo.jsonl --format json SELECT name,age WHERE tier eq 5
# {"name": "Eve", "age": "45"}

zog --file demo.jsonl --format csv --header SELECT name,balance WHERE tier lte 2
# name,balance
# "Alice","100.50"
# "Bob","-50.25"
```

- **TSV** (default) prints string contents as they appear in the JSON, so `\t`, `\n` and `\"` stay escaped and the columns stay intact.
- **CSV** quotes every field, decodes JSON escapes (`\n`, `é`, surrogate pairs) and doubles embedded quotes.
- **JSON** prints one object per line, keeping strings quoted and escaped. `--header` is ignored, since every object already names its fields.

Missing fields print as empty in TSV/CSV and as `null` in JSON. Objects and arrays are extracted whole (`{"b": [1, 2]}`).

### Aggregations

| Function | Result |
|----------|--------|
| `count:field` | number of values that are present and not `null` |
| `sum:field` | sum of numeric values |
| `min:field` / `max:field` | smallest / largest numeric value |
| `avg:field` | mean of numeric values |

```bash
zog --file demo.jsonl SELECT count:name WHERE tier gte 2
# 4

zog --file demo.jsonl SELECT min:age,max:balance WHERE active eq true
# 25.0000 5000.0000

zog --file demo.jsonl SELECT count:name,sum:balance,avg:age,min:age,max:tier WHERE active eq true
# 4       5200.4900       36.2500 25.0000 5.0000

zog --file demo.jsonl --format json SELECT count:name,sum:balance WHERE tier gte 2
# {"count:name": 4, "sum:balance": 5049.7400}

cat demo.jsonl | zog SELECT sum:balance
# 5150.2400
```

- All aggregates are computed in one pass, each field independently.
- Numbers stored as strings (`"99.99"`) are included. Values that aren't JSON numbers (`"abc"`, `"nan"`, `"inf"`) are skipped.
- If `SELECT` contains **any** aggregate, zog prints one summary row at the end. Plain fields in that row come out empty (TSV/CSV) or `null` (JSON): `SELECT name,count:name` prints an empty column, then `4`.

### Pipelines and scripting

```bash
# Live monitoring: matches print as soon as their lines arrive
tail -f app.jsonl | zog level eq error

# Stop at the first match, even on a stream that never ends
tail -f app.jsonl | zog --limit 1 level eq error

# Chain with other tools
zog --file demo.jsonl SELECT name WHERE tier gte 3 | sort

# Query terms that start with "--" go after "--"
zog --file logs.jsonl -- --weird-key exists

# Exit codes work like grep's
if zog --file logs.jsonl --count level eq error > /dev/null; then echo "errors found"; fi
```

| Exit code | Meaning |
|-----------|---------|
| `0` | At least one line matched (also when the reader closes early, e.g. `| head`) |
| `1` | No lines matched |
| `2` | Error: bad arguments, unreadable input, a non-numeric value for `gt`/`lt`/…, or a failed write |

---

## 📦 Installation

zog is a single static binary with no dependencies.

### Prebuilt binaries

Download the latest binary for your platform from the [Releases](https://github.com/aikoschurmann/zog/releases) page.

```bash
# macOS (Apple Silicon)
curl -L https://github.com/aikoschurmann/zog/releases/latest/download/zog-macos-arm64 -o zog
chmod +x zog && sudo mv zog /usr/local/bin/

# Linux (x86_64)
curl -L https://github.com/aikoschurmann/zog/releases/latest/download/zog-linux-x64 -o zog
chmod +x zog && sudo mv zog /usr/local/bin/
```

The Linux binary targets baseline x86_64 so that it runs on any 64-bit CPU. That means 16-byte SSE2 vectors and no byte shuffle, which leaves out the [Teddy](#4-many-key-ors-teddy) path for many-key `OR`s. For full speed, build from source with `-Dcpu=native`.

### Build from source

Requires [Zig](https://ziglang.org/download/) 0.16.0.

```bash
git clone https://github.com/aikoschurmann/zog.git
cd zog
zig build -Doptimize=ReleaseFast              # add -Dcpu=native for your CPU's widest SIMD
zig build test                                # run the test suite
```

The binary ends up at `./zig-out/bin/zog`.

---

## 🧠 How it works

Tools like `jq` parse every line into a tree before they look at it. That is exact, but it caps them at roughly 0.1 GB/s. zog first treats the input as bytes and searches it with SIMD for lines that *could* match. Only those lines are parsed (sections 6 and 7), and the parse decides. The byte search is built so that it never drops a line the parser would accept: it may let through lines that don't match, but never lose one that does.

### 1. Query compilation

Before scanning, the query is compiled into a plan. Key paths are split and gathered into a tree for the parser, keys and values are JSON-escaped and quoted for the byte search, numbers are parsed once, type prefixes are resolved, and the SIMD comparison vectors are built. Nothing in the hot loop depends on the query text.

### 2. Anchored block search

Input is processed in 8 MB blocks, not line by line. Every matching line must pass at least one non-negated condition of some `OR` group, so zog picks one such **anchor** per group and searches the whole block for anchors. Line boundaries are only looked up once an anchor passes. A line without an anchor costs a few vector compares and is never split out.

For a string `eq`, the anchor is the quoted **value** rather than the key: `"GollumEvent"` is far rarer than `"type"`, which appears in nearly every event. A hit counts only when `"type":` directly precedes it.

### 3. SIMD key matching

Keys are found with vector compares sized to the target (NEON, SSE, AVX2, AVX-512). A position is a candidate only when the opening quote, the key's first and last byte, and the closing quote all line up. A full compare runs only on the rare candidates, followed by checks that the quote isn't escaped and that a `:` follows. Requiring the colon means a *value* that happens to equal a key name is never mistaken for the key.

All anchors are searched for in a single pass, so an `OR` of several keys still reads each byte once.

### 4. Many-key ORs (Teddy)

Testing each key separately gets slower with every key you add. From four different anchors on, zog switches to [Teddy](https://github.com/intel/hyperscan), the multi-literal matcher from Intel's Hyperscan. Keys are spread over 8 buckets. For each of the three bytes after a quote, two 16-entry nibble tables, looked up with a single byte-shuffle instruction (`tbl` on ARM, `pshufb` on x86), say which buckets allow that byte there. ANDing the lookups leaves the buckets whose keys may start at each position. The cost per chunk is fixed, however many keys there are, and only keys from the matching buckets are compared in full.

On the GH Archive file this takes a 12-key `OR` from 1.92 s to 0.52 s.

### 5. Double-buffered I/O

A reader thread fills the next buffer while the main thread scans the current one, so the disk and the CPU work in parallel. For pipes, blocks are handed over at 128 KB, or sooner when no more input is immediately available. That keeps the data in cache while it's scanned, and makes slow streams like `tail -f` print matches right away. Lines longer than a block grow the buffer.

### 6. Ruling lines out without losing matches

The byte search finds a key wherever it appears, nested or not, and the value at a key's path is always one of those occurrences. A condition is tested on each occurrence with exactly the code the parser later uses on the value at the path. So if no occurrence passes, the parser can't find a passing value either, and the line is dropped. Two things would break that argument, and zog handles both:

- **Escapes.** The search compares escaped text, as zog writes it: `"`, `\` and control characters escaped, everything else as is. JSON allows two other spellings, `\uXXXX` for any character and `\/` for `/`, and those would hide a key or value from the search. So the search also stops at every `\u` and `\/`, folded into the same SIMD pass. If the escape stands for a character that occurs in one of the searched keys or values, the line goes to the parser. Other escapes, such as the `\u003c` that Go writes for `<`, cost one check and nothing more.
- **`NOT`.** Bytes can show that a key is missing, but not that the value at its path fails, since a nested copy of the key may be the one that fails. The search therefore ignores negated conditions and leaves them to the parser.

`zig build test` fuzzes this: it runs random queries over random lines full of escapes, nesting, repeated keys and odd whitespace, with and without the byte search, and requires the same output.

### 7. The exact layer

Lines that may match are parsed by a validating parser (RFC 8259, including UTF-8) that works in two stages, like [simdjson](https://github.com/simdjson/simdjson):

- **Stage 1** classifies 64 bytes at a time with SIMD compares and turns them into bitmasks: quotes, backslashes, `{}[]:,` and whitespace. Escaped quotes are found from runs of backslashes, and a prefix XOR over the remaining quotes marks everything inside strings. What's left is one bit per structural character: `{}[]:,` outside strings, each quote, and the first byte of each number or literal. The same pass rejects control characters in strings and malformed escapes, and lines with non-ASCII bytes get a SIMD UTF-8 check (the lookup algorithm from simdjson).
- **Stage 2** checks the grammar by visiting only the marked positions, so the bytes inside strings are never looked at again. It takes the positions straight from the bitmask, and stage 1 classifies the next 64 bytes when the mask runs out, so nothing is stored per line.

Stage 2 only descends into the objects on the query's key paths. Everything else is checked and skipped by a non-recursive loop, so deep nesting can't overflow the stack. It records where the value of each path starts and ends in the line, and the conditions and `SELECT` read the values from there. Strings are decoded only when they contain escapes.

On the synthetic logs this parses 1.7x as fast as the single-pass parser it replaced, and 1.2–1.4x as fast on short lines and on nested, escape-heavy lines.

### 8. No per-line allocation

Apart from the two I/O buffers, the compiled plan and a reusable buffer for decoded strings, the scan allocates nothing. Values are extracted in place, output goes through one buffered writer, and aggregates are plain counters.

---

## ⚠️ Limitations & trade-offs

### 1. Exact mode parses every line that might match

Lines the byte search rules out cost almost nothing, but the rest are parsed at roughly 1.3 GB/s. Queries that match many lines, and `NOT`-only queries, which can't be ruled out from bytes at all, run several times slower than with `--fast` (see the benchmarks).

### 2. `--fast` is approximate

`--fast` skips the parser and decides on the bytes alone, like zog 1.0:

- A key matches at any depth. For a path, only its last key is used. A condition passes if **any** occurrence of the key passes, and `SELECT` takes the **first** occurrence.
- Escapes aren't decoded: `"\u006cevel"` isn't the key `level`.
- Lines aren't validated.

```bash
echo '{"id": 5, "metadata": {"id": 10}}' | zog --fast id eq 10    # matches
echo '{"id": 5, "metadata": {"id": 10}}' | zog id eq 10           # doesn't
```

For flat logs without escapes, `--fast` gives the same answers.

### 3. One JSON document per line

Only JSONL/NDJSON is supported. Pretty-printed, multi-line JSON isn't. Input must be UTF-8, and lines that aren't valid JSON are skipped.

### 4. Lone surrogates

Strings are compared after decoding. An unpaired `\ud800`-style escape decodes to U+FFFD, as in `jq`, so it equals any other lone surrogate and a literal U+FFFD.

---

## Reproducing the benchmarks

Generate the synthetic file:

```python
# gen.py: python3 gen.py logs.jsonl 4000000
import random, json, sys
random.seed(1)
levels = ["debug", "info", "info", "info", "warn", "error"]
svcs = ["auth", "billing", "search", "shipping", "storage"]
with open(sys.argv[1], "w") as f:
    for i in range(int(sys.argv[2])):
        d = {"ts": 1700000000 + i, "level": random.choice(levels), "service": random.choice(svcs),
             "status": random.choice([200, 200, 200, 201, 301, 404, 500, 503]),
             "latency_ms": round(random.random() * 900, 3),
             "user": {"id": random.randint(1, 10**6), "name": "user%d" % random.randint(1, 99999)},
             "msg": "request handled for session %x with some padding text here" % random.getrandbits(64),
             "tags": ["a", "b", "c"], "bytes": random.randint(100, 100000)}
        f.write(json.dumps(d, separators=(",", ":")) + "\n")
```

The GH Archive file:

```bash
for h in 15 16 17; do curl -sLO https://data.gharchive.org/2024-03-12-$h.json.gz; done
gunzip -c 2024-03-12-*.json.gz > gha.jsonl
```

Commands per tool (key match shown; the other rows follow the same pattern):

```bash
zog --file logs.jsonl -c level eq error
cat logs.jsonl | zog -c level eq error
rg -c '"level":"error"' logs.jsonl
jaq -c 'select(.level=="error")' logs.jsonl | wc -l
```

Match queries are timed with `-c` on both zog and ripgrep, because ripgrep stops after the first match when its output is `/dev/null`. Extraction and aggregation queries write their full output to a file.

---

## 🎯 Use cases

✅ **DevOps & SRE:** filter production logs for errors, slow requests or 5xx responses
✅ **Security:** hunt through audit and access logs
✅ **Data engineering:** pre-filter large datasets before loading them elsewhere
✅ **Analytics:** count, sum and average over gigabytes in a single pass
✅ **CLI workflows:** chain with `sort`, `uniq`, `awk` and friends
✅ **Live monitoring:** filter `tail -f` or `journalctl -f` output as it arrives

❌ **Not suitable for:** validating JSON, queries that depend on nesting, pretty-printed JSON, or formats other than JSONL.

---

## 🤝 Contributing

Contributions are welcome! Open an issue or a pull request on [GitHub](https://github.com/aikoschurmann/zog).
