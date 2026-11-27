#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
revision=5eaee0cc9024eb9e9a99469199920c8b7f5cb9ec
proxy=()
host=$(/usr/sbin/scutil --proxy | awk '$1 == "HTTPSProxy" {print $3}')
port=$(/usr/sbin/scutil --proxy | awk '$1 == "HTTPSPort" {print $3}')
enabled=$(/usr/sbin/scutil --proxy | awk '$1 == "HTTPSEnable" {print $3}')
if [[ "$enabled" == 1 && -n "$host" && -n "$port" ]]; then proxy=(-c "http.proxy=http://$host:$port"); fi
if [[ ! -d Vendor/whisper.cpp/.git ]]; then
  mkdir -p Vendor/whisper.cpp
  git -C Vendor/whisper.cpp init
  git -C Vendor/whisper.cpp remote add origin https://github.com/ggml-org/whisper.cpp.git
fi
if ! git -C Vendor/whisper.cpp cat-file -e "$revision^{commit}" 2>/dev/null; then
  git "${proxy[@]}" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 -C Vendor/whisper.cpp fetch --depth 1 origin "$revision"
fi
git -C Vendor/whisper.cpp checkout --detach "$revision"
echo 'Pinned whisper.cpp source ready.'
