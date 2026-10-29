# Re-record from a directory holding logs.jsonl (made with the generator under
# "Reproducing the benchmarks" in the README, 2000000 lines) and a zog binary:
#   vhs demo.tape
Output demo.gif
Set Shell "bash"
Set FontSize 18
Set Width 1340
Set Height 470
Set Padding 24
Set Theme "Catppuccin Mocha"
Set TypingSpeed 30ms

Hide
Type `export PATH=$PWD:$PATH PS1='$ ' TIMEFORMAT='took %Rs' && zog --file logs.jsonl -c level eq error >/dev/null && clear`
Enter
Sleep 500ms
Show

Type `ls -lh logs.jsonl | awk '{print $5, $9}'`
Enter
Sleep 1s
Type `time jq -c 'select(.level=="error")' logs.jsonl | wc -l`
Enter
# jq takes ~9 s; skip the frozen frames, its "took" line still shows the real time
Sleep 1.2s
Hide
Sleep 9s
Show
Sleep 1.5s
Type `time zog --file logs.jsonl -c level eq error`
Enter
Sleep 2.5s
Type `zog --file logs.jsonl --limit 3 SELECT ts,service,latency_ms WHERE level eq error AND status gte 500`
Enter
Sleep 2.5s
Type `zog --file logs.jsonl --format json SELECT count:bytes,avg:latency_ms WHERE service eq auth AND status eq 200`
Enter
Sleep 4s
