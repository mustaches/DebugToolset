#!/bin/bash
# 看门狗：flutter run 跑基准，日志出现完成标记后强杀 flutter run 进程树
# 用法: run_bench_watchdog.sh <target> <log> <marker_regex> [max_seconds]
target=$1; log=$2; marker=$3; maxs=${4:-2700}
shift $(( $# >= 4 ? 4 : $# ))
flutter run "$target" -d windows --release "$@" > "$log" 2>&1 &
fpid=$!
elapsed=0
while [ $elapsed -lt $maxs ]; do
  sleep 15; elapsed=$((elapsed+15))
  if grep -qE "$marker" "$log" 2>/dev/null; then break; fi
  kill -0 $fpid 2>/dev/null || break
done
sleep 8
if kill -0 $fpid 2>/dev/null; then
  wpid=$(ps -W | awk -v p=$fpid '$1==p {print $4}')
  if [ -n "$wpid" ]; then taskkill //F //T //PID "$wpid"; else kill -9 $fpid; fi
fi
wait $fpid 2>/dev/null
echo "WATCHDOG_DONE $target (elapsed=${elapsed}s)"
