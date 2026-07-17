#!/usr/bin/env bash
# Real-TTY end-to-end test: drives nvim in a tmux pane with the fake STT
# provider. Space "hold" is simulated by sending spaces at auto-repeat pace.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${E2E_OUT:-/tmp/dictation-e2e}"
S=dictation-e2e
mkdir -p "$OUT"
rm -f "$OUT"/*.txt
FAIL=0

check() { # name, command
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
hold_space() { # n_rapid: initial press + 300ms repeat delay + rapid stream
  send ' '
  sleep 0.3
  for _ in $(seq 1 "$1"); do
    send ' '
    sleep 0.015
  done
}

tmux kill-session -t $S 2>/dev/null || true
tmux new-session -d -s $S -x 100 -y 30 \
  "TERM=xterm-256color nvim --noplugin -i NONE -u '$ROOT/test/e2e_init.lua'"
sleep 2.5 # nvim + deno sidecar startup

# A) single tap inserts exactly one space -----------------------------------
send 'iab'
sleep 0.1
send ' '
sleep 0.1
send 'cd'
sleep 0.1
cmd "DDump $OUT/single_tap.txt"
check "single tap inserts one space" "head -1 '$OUT/single_tap.txt' | grep -qx 'ab cd'"

# B) hold on 'hi': strip, swallow, interim, final, cursor after text --------
cmd "call setline(1, 'hi')"
send 'A'
sleep 0.15
hold_space 45 &
HOLD=$!
sleep 0.8
tmux capture-pane -t $S -p >"$OUT/mid_hold.txt"
wait $HOLD
sleep 2 # release watchdog + fake final + commit
send 'END' # types at cursor: proves cursor sits after the dictated text
sleep 0.2
cmd "DDump $OUT/hold.txt"
check "interim transcript visible mid-hold" "grep -q 'hi the' '$OUT/mid_hold.txt'"
check "no stray spaces mid-hold" "grep -q 'hi the' '$OUT/mid_hold.txt' && ! grep -q 'hi  ' '$OUT/mid_hold.txt'"
check "hold commits final transcript, cursor after it" "head -1 '$OUT/hold.txt' | grep -qE '^hi The [a-z ]+\.END$'"
check "session idle after commit" "sed -n 2p '$OUT/hold.txt' | grep -qx 'idle'"
check "no leftover extmarks" "sed -n 4p '$OUT/hold.txt' | grep -qx '0'"

# C) hold on an empty line: the warmup-space-leak regression test -----------
cmd "call setline(1, '')"
send 'A'
sleep 0.15
hold_space 40
sleep 2
cmd "DDump $OUT/leak.txt"
check "no warmup space leaks on empty line" "head -1 '$OUT/leak.txt' | grep -qE '^The [a-z ]+\.$'"

# D) Escape during recording cancels and rolls back --------------------------
cmd "call setline(1, 'z')"
send 'A'
sleep 0.15
hold_space 25
key Escape # still "holding" — recording is active
sleep 0.8
cmd "DDump $OUT/cancel.txt"
check "esc during recording cancels cleanly" "head -1 '$OUT/cancel.txt' | grep -qx 'z'"
check "idle after cancel" "sed -n 2p '$OUT/cancel.txt' | grep -qx 'idle'"
check "cancel leaves no extmarks" "sed -n 4p '$OUT/cancel.txt' | grep -qx '0'"

tmux kill-session -t $S 2>/dev/null || true

if [ $FAIL -eq 0 ]; then
  echo "ALL PASS"
else
  echo "$FAIL FAILURE(S)"
fi
exit $((FAIL > 0))
