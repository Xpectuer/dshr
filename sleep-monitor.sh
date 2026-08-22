#!/bin/bash
# 每秒清屏计数（无限）；相邻时间戳间隔超过阈值（默认 3 秒）判定为睡眠/卡顿，打醒目标语。
threshold="${GAP_THRESHOLD:-3}"
last=""
last_ts=""
count=0
while true; do
  read -r d t epoch <<< "$(date '+%Y-%m-%d %H:%M:%S %s')"
  ts="$d $t"
  count=$((count + 1))
  if [[ -t 1 ]]; then
    clear
  fi
  echo "$ts $count"
  if [[ -n "$last" ]]; then
    gap=$((epoch - last))
    if (( gap > threshold )); then
      if [[ -t 1 ]]; then
        echo -e "\033[1;31m============================================================\033[0m"
        echo -e "\033[1;31m!!! SLEEP DETECTED: ${gap}s gap between $last_ts and $ts !!!\033[0m"
        echo -e "\033[1;31m============================================================\033[0m"
      else
        echo "============================================================"
        echo "!!! SLEEP DETECTED: ${gap}s gap between $last_ts and $ts !!!"
        echo "============================================================"
      fi
      sleep 5
    fi
  fi
  last="$epoch"
  last_ts="$ts"
  sleep 1
done
