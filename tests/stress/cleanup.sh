#!/bin/bash
# Stop any leftover stress processes (local test server on port 9100, load generators, quota holders).
ME=$$
for p in $(ps -eo pid=,args= | awk '/stress\/(load\.js|ladder\.sh|run_step\.sh|cpu_quota\.py)|bpstress-port-9100/ {print $1}'); do
  [ "$p" = "$ME" ] && continue
  kill -CONT "$p" 2>/dev/null; kill "$p" 2>/dev/null
done
sleep 1
ps -eo pid=,args= | awk '/stress\/(load\.js|ladder\.sh|run_step\.sh|cpu_quota\.py)|bpstress-port-9100/ && !/awk/ {print}'
