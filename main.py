import os
import subprocess
import time
import json
import random

# --- CONFIGURATION ---
FILE_NAME = "bench_data.jsonl"
FILE_SIZE_GB = 1.0 
ZOG_BIN = "./zig-out/bin/zog"

def generate_data(size_gb):
    if os.path.exists(FILE_NAME):
        return
    print(f"--- Generating {size_gb}GB of data... ---")
    levels = ["info", "warn", "error", "debug"]
    messages = ["Login successful", "Timeout", "API Request", "Internal Error"]
    num_lines = int((size_gb * 1024 * 1024 * 1024) / 110)
    
    with open(FILE_NAME, "w") as f:
        for _ in range(num_lines):
            log = {
                "timestamp": "2026-02-20T19:30:00Z", 
                "level": random.choice(levels), 
                "request_id": random.randint(10000, 99999), 
                "message": random.choice(messages)
            }
            f.write(json.dumps(log) + "\n")

def get_result_count(cmd):
    """Runs a command and returns the number of lines in the output."""
    full_cmd = f"{cmd} | wc -l"
    result = subprocess.check_output(full_cmd, shell=True, text=True)
    return int(result.strip())

def check_tool(name):
    return subprocess.run(f"which {name}", shell=True, capture_output=True).returncode == 0

def main():
    # 1. Build and Prep
    print("--- Building zog ---")
    subprocess.run("zig build -Doptimize=ReleaseFast", shell=True)
    generate_data(FILE_SIZE_GB)

    print("\n--- Running Integrity Check ---")
    
    zog_file_cmd = f"{ZOG_BIN} --file {FILE_NAME} --key level --val error"
    zog_pipe_cmd = f"cat {FILE_NAME} | {ZOG_BIN} --key level --val error"
    grep_cmd = f"grep '\"level\": \"error\"' {FILE_NAME}"
    jq_cmd = f"jq -c 'select(.level == \"error\")' {FILE_NAME}"

    # Verify counts across different zog paths
    print("Counting results: Zog (mmap)...")
    zog_file_count = get_result_count(zog_file_cmd)
    
    print("Counting results: Zog (pipe)...")
    zog_pipe_count = get_result_count(zog_pipe_cmd)
    
    print("Counting results: Grep...")
    grep_count = get_result_count(grep_cmd)

    # 1. Compare Zog Internal Consistency
    if zog_file_count == zog_pipe_count:
        print(f"✅ ZOG INTERNAL CONSISTENCY PASSED: File and Pipe both found {zog_file_count:,} matches.")
    else:
        print(f"❌ ZOG INTERNAL CONSISTENCY FAILED!")
        print(f"   mmap found: {zog_file_count:,}")
        print(f"   pipe found: {zog_pipe_count:,}")
        print(f"   Diff:       {abs(zog_file_count - zog_pipe_count)}")

    # 2. Compare against Grep (with whitespace caveat)
    if zog_file_count != grep_count:
        print(f"⚠️  Note: Zog found {abs(zog_file_count - grep_count)} more result than grep.")
        if check_tool("jq"):
            print("Verifying with jq (whitespace-agnostic)...")
            jq_count = get_result_count(jq_cmd)
            if jq_count == zog_file_count:
                print("✅ INTEGRITY PASSED: Zog matches JQ count.")
            else:
                print("❌ INTEGRITY FAILED: Zog and JQ disagree.")
    else:
        print("✅ INTEGRITY PASSED: Zog and Grep agree perfectly.")

    # 3. Performance Benchmarks
    print("\n--- Running Performance Benchmarks ---")
    
    scenarios = {
        "zog (mmap)": zog_file_cmd,
        "zog (pipe)": zog_pipe_cmd,
        "grep (file)": grep_cmd,
        "grep (pipe)": f"cat {FILE_NAME} | grep '\"level\": \"error\"'",
    }

    #if check_tool("jq"):
    #    scenarios["jq (file)"] = jq_cmd
    #    scenarios["jq (pipe)"] = f"cat {FILE_NAME} | jq -c 'select(.level == \"error\")'"

    results = []
    for name, cmd in scenarios.items():
        print(f"Benchmarking {name}...")
        subprocess.run(f"{cmd} > /dev/null", shell=True) # Warmup
        
        start = time.perf_counter()
        subprocess.run(f"{cmd} > /dev/null", shell=True)
        end = time.perf_counter()
        
        duration = end - start
        throughput = FILE_SIZE_GB / duration
        results.append((name, duration, throughput))

    # 4. Final Table
    print("\n" + "="*60)
    print(f"FINAL REPORT ({FILE_SIZE_GB}GB File)")
    print("="*60)
    print(f"{'Tool/Scenario':<25} | {'Time':<10} | {'Throughput'}")
    print("-" * 60)
    for name, duration, throughput in sorted(results, key=lambda x: x[1]):
        print(f"{name:<25} | {duration:>8.2f}s | {throughput:>8.2f} GB/s")
    print("="*60)

if __name__ == "__main__":
    main()