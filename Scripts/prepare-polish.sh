#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
engine=""
for candidate in /opt/homebrew/bin/ollama /usr/local/bin/ollama /Applications/Ollama.app/Contents/Resources/ollama; do
  if [[ -x "$candidate" ]]; then engine="$candidate"; break; fi
done
if [[ -z "$engine" ]]; then echo '请先安装 Ollama：https://ollama.com/download/mac' >&2; exit 1; fi
mkdir -p Models/Ollama work
owned_pid=""
cleanup() { if [[ -n "$owned_pid" ]]; then kill "$owned_pid" 2>/dev/null || true; fi; }
trap cleanup EXIT
if ! curl --noproxy '*' -fsS --max-time 2 http://127.0.0.1:11435/api/version >/dev/null 2>&1; then
  proxy_host=$(/usr/sbin/scutil --proxy | awk '$1 == "HTTPSProxy" {print $3}')
  proxy_port=$(/usr/sbin/scutil --proxy | awk '$1 == "HTTPSPort" {print $3}')
  proxy_enabled=$(/usr/sbin/scutil --proxy | awk '$1 == "HTTPSEnable" {print $3}')
  if [[ "$proxy_enabled" == 1 && -n "$proxy_host" && -n "$proxy_port" ]]; then export HTTPS_PROXY="http://$proxy_host:$proxy_port"; fi
  OLLAMA_HOST=127.0.0.1:11435 OLLAMA_MODELS="$root/Models/Ollama" OLLAMA_NO_CLOUD=1 OLLAMA_NUM_PARALLEL=1 OLLAMA_MAX_LOADED_MODELS=1 "$engine" serve > work/ollama-setup.log 2>&1 &
  owned_pid=$!
  for _ in {1..60}; do
    if curl --noproxy '*' -fsS --max-time 2 http://127.0.0.1:11435/api/version >/dev/null 2>&1; then break; fi
    sleep 0.25
  done
fi
OLLAMA_HOST=127.0.0.1:11435 "$engine" pull qwen3:4b-instruct
printf '\n润色模型准备完成。打开 LocalTranscript.app 即可使用。\n'
