#!/usr/bin/env bash
# LIVE end-to-end test of the AssemblyAI provider: real streaming API, real
# token auth, espeak-ng synthesised speech as the microphone. Costs a few
# seconds of streaming credit. Skips if no key is found.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${E2E_OUT:-/tmp/dictation-e2e-aai}"
S=dictation-e2e-aai
FAIL=0
mkdir -p "$OUT"
rm -f "$OUT"/*.txt

KEY="${ASSEMBLYAI_API_KEY:-$(sed -nE 's/^assemblyai_api_key[ =]+//p' ~/.config/audiorecorder/config 2>/dev/null | tr -d ' ')}"
if [ -z "$KEY" ]; then
  echo "SKIP  no AssemblyAI key (env ASSEMBLYAI_API_KEY or ~/.config/audiorecorder/config)"
  exit 0
fi

check() {
  if eval "$2" >/dev/null 2>&1; then
    echo "PASS  $1"
  else
    echo "FAIL  $1"
    FAIL=$((FAIL + 1))
  fi
}

send() { tmux send-keys -t $S -l "$1"; }
key() { tmux send-keys -t $S "$1"; }
cmd() {
  key Escape
  sleep 0.3
  tmux send-keys -t $S ":$1" Enter
  sleep 0.3
}

MIC='espeak-ng "hello world one two three testing dictation" --stdout | sox -t wav - -t raw -r 16000 -e signed -b 16 -c 1 -; sleep 30'

tmux kill-session -t $S 2>/dev/null || true
tmux new-session -d -s $S -x 100 -y 30 \
  "TERM=xterm-256color ASSEMBLYAI_API_KEY=$KEY \
   DICT_TEST_PROVIDER=assemblyai DICT_TEST_MIC='$MIC' \
   nvim --noplugin -i NONE -u '$ROOT/test/e2e_init.lua'"
trap 'tmux kill-session -t $S 2>/dev/null' EXIT
sleep 2.5

send 'i'
sleep 0.15
send ' '
sleep 0.3
for _ in $(seq 1 80); do
  send ' '
  sleep 0.015
done
sleep 5 # release + Terminate + final turn + commit (live API latency)
cmd "DDump $OUT/aai.txt"

check "live AssemblyAI transcript committed" "head -1 '$OUT/aai.txt' | grep -qi 'hello world'"
check "transcript complete" "head -1 '$OUT/aai.txt' | grep -qi 'dictation'"
check "session idle after commit" "sed -n 2p '$OUT/aai.txt' | grep -qx 'idle'"
check "no leftover extmarks" "sed -n 4p '$OUT/aai.txt' | grep -qx '0'"

head -1 "$OUT/aai.txt" | sed 's/^/transcript: /'

if [ $FAIL -eq 0 ]; then
  echo "ALL PASS"
else
  echo "$FAIL FAILURE(S)"
fi
exit $((FAIL > 0))
