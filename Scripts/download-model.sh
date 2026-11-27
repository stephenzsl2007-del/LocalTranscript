#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Models
expected=1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b
file=Models/ggml-small.bin
verify() { [[ "$(shasum -a 256 "$1" | awk '{print $1}')" == "$expected" ]]; }
if [[ -f "$file" ]] && verify "$file"; then echo 'Model verified.'; exit 0; fi
proxy=()
# curl does not automatically use macOS system proxies. Read only proxy host/port.
host=$(/usr/sbin/scutil --proxy | awk '$1 == "HTTPSProxy" {print $3}')
port=$(/usr/sbin/scutil --proxy | awk '$1 == "HTTPSPort" {print $3}')
enabled=$(/usr/sbin/scutil --proxy | awk '$1 == "HTTPSEnable" {print $3}')
if [[ "$enabled" == 1 && -n "$host" && -n "$port" ]]; then proxy=(--proxy "http://$host:$port"); fi
url=https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small.bin
curl -fL "${proxy[@]}" --connect-timeout 20 --max-time 1800 --retry 3 -o "$file.part" "$url"
if ! verify "$file.part"; then echo 'SHA-256 mismatch; partial model not installed.' >&2; exit 1; fi
mv "$file.part" "$file"
echo 'Model downloaded and verified. Run Scripts/build.sh to embed it.'
