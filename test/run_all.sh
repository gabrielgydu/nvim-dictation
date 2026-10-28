#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0

echo "== deno check =="
deno check "$ROOT/sidecar/main.ts" || FAIL=1

for t in unit_keyhold unit_buffer; do
  echo "== $t =="
  out="$(mktemp)"
  if TEST_RESULTS="$out" nvim --headless --clean --cmd "set rtp+=$ROOT" -l "$ROOT/test/$t.lua" >/dev/null 2>&1; then
    cat "$out"
  else
    cat "$out"
    FAIL=1
  fi
  rm -f "$out"
done

echo "== e2e tmux (fake provider) =="
"$ROOT/test/e2e_tmux.sh" || FAIL=1

echo "== e2e deepgram mock =="
"$ROOT/test/e2e_deepgram_mock.sh" || FAIL=1

echo "== e2e stt (fake provider; skips without stt) =="
"$ROOT/test/e2e_stt.sh" || FAIL=1

# the live test spends streaming credit: only on request
if [ "${DICT_LIVE:-}" = 1 ]; then
  echo "== e2e assemblyai live (skips without key) =="
  "$ROOT/test/e2e_assemblyai_live.sh" || FAIL=1
else
  echo "== e2e assemblyai live: skipped (costs credit; DICT_LIVE=1 runs it) =="
fi

[ $FAIL -eq 0 ] && echo "SUITE PASS" || echo "SUITE FAIL"
exit $FAIL
