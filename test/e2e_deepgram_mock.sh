#!/usr/bin/env bash
# End-to-end test of the Deepgram provider path against a local mock server:
# real mic pipeline (espeak-ng synthesised speech), real WebSocket, real
# CloseStream flush. Verifies auth subprotocol, URL params, and audio flow.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${E2E_OUT:-/tmp/dictation-e2e-dg}"
S=dictation-e2e-dg
PORT=8791
FAIL=0
mkdir -p "$OUT"
rm -f "$OUT"/*.txt

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

deno run --quiet --no-lock --allow-net "$ROOT/test/mock_deepgram.ts" $PORT &
MOCK=$!
trap 'kill $MOCK 2>/dev/null; tmux kill-session -t $S 2>/dev/null' EXIT
sleep 1

MIC='espeak-ng "hello world one two three" --stdout | sox -t wav - -t raw -r 16000 -e signed -b 16 -c 1 -; sleep 30'

tmux kill-session -t $S 2>/dev/null || true
tmux new-session -d -s $S -x 100 -y 30 \
  "TERM=xterm-256color DEEPGRAM_API_KEY=testkey123 \
   DICT_TEST_PROVIDER=deepgram DICT_TEST_ENDPOINT='ws://127.0.0.1:$PORT' \
   DICT_TEST_MIC='$MIC' \
   nvim --noplugin -i NONE -u '$ROOT/test/e2e_init.lua'"
sleep 2.5

send 'i'
sleep 0.15
send ' '
sleep 0.3
for _ in $(seq 1 60); do
  send ' '
  sleep 0.015
done &
HOLD=$!
sleep 1.0
tmux capture-pane -t $S -p >"$OUT/mid.txt"
wait $HOLD
sleep 2.5 # release + CloseStream + mock final + commit
cmd "DDump $OUT/dg.txt"

check "interim from mock STT shown mid-hold" "grep -q 'mockinterim' '$OUT/mid.txt'"
check "final committed" "head -1 '$OUT/dg.txt' | grep -q 'mockfinal'"
check "audio reached the STT socket" "head -1 '$OUT/dg.txt' | grep -q 'audio_ok'"
check "API key sent via token subprotocol" "head -1 '$OUT/dg.txt' | grep -q 'auth_ok'"
check "model param" "head -1 '$OUT/dg.txt' | grep -q 'model_nova-3'"
check "language param" "head -1 '$OUT/dg.txt' | grep -q 'lang_multi'"
check "encoding params" "head -1 '$OUT/dg.txt' | grep -q 'format_ok'"
check "session idle after commit" "sed -n 2p '$OUT/dg.txt' | grep -qx 'idle'"

if [ $FAIL -eq 0 ]; then
  echo "ALL PASS"
else
  echo "$FAIL FAILURE(S)"
fi
exit $((FAIL > 0))
