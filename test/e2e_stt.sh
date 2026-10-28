#!/usr/bin/env bash
# End-to-end test of the stt provider: drives nvim in a tmux pane with the
# REAL `stt stream` on its fake provider (no key, no network; text arrives as
# "fake turn N ..."), plus test/fake_stt.sh for what that provider cannot do;
# then :checkhealth in a headless nvim.
# STT_BIN names the stt command (default: stt on PATH); skips without it.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${E2E_OUT:-/tmp/dictation-e2e-stt}"
S=dictation-e2e-stt
FAIL=0

STT="$(command -v "${STT_BIN:-stt}")"
if [ -z "$STT" ]; then
  echo "SKIP  stt not found (put it on PATH or set STT_BIN)"
  exit 0
fi
mkdir -p "$OUT"
rm -f "$OUT"/*.txt
CONF="$OUT/stt.conf" # the only stt config this test uses
printf 'provider = fake\n' >"$CONF"

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
hold_space() { # n_rapid: initial press + 300ms repeat delay + rapid stream
  send ' '
  sleep 0.3
  for _ in $(seq 1 "$1"); do
    send ' '
    sleep 0.015
  done
}
start_case() { # first line of the buffer; leaves nvim appending to it
  cmd "messages clear"
  cmd "call setline(1, '$1')"
  send 'A'
  sleep 0.15
}

# "pid args" of every process below pid $1 (only this test's processes, so
# other stt sessions on the machine do not count)
below() {
  ps -e -o pid=,ppid=,args= | awk -v root="$1" '
    { pid[NR] = $1; ppid[NR] = $2; $1 = ""; $2 = ""; args[NR] = $0 }
    END {
      keep[root] = 1
      do {
        grew = 0
        for (i = 1; i <= NR; i++)
          if ((ppid[i] in keep) && !(pid[i] in keep)) { keep[pid[i]] = 1; grew = 1 }
      } while (grew)
      for (i = 1; i <= NR; i++) if (pid[i] != root && (pid[i] in keep)) print pid[i] args[i]
    }'
}
sidecar_pid() { below "$PANE" | awk '/sidecar\/main\.ts/ { print $1; exit }'; }
sidecar_children() {
  local sc
  sc="$(sidecar_pid)"
  [ -n "$sc" ] && below "$sc"
}
sidecar_files() { # how many files the sidecar has open (Linux /proc)
  local sc
  sc="$(sidecar_pid)"
  [ -n "$sc" ] && ls "/proc/$sc/fd" | wc -l
}
# After a finished session the sidecar must hold no more files than after
# case A. Checked after every case, as a leaked pipe may be closed later.
FILES=""
FILES_GREW=0
files_after() { # $1 = case
  local n
  n="$(sidecar_files)"
  FILES="$FILES $1=$n"
  [ -n "$n" ] && [ -n "$FILES_A" ] && [ "$n" -le "$FILES_A" ] || FILES_GREW=1
}

# Real-time silence: the fake provider only counts bytes. 3000 bytes per
# 0.1 s never fills its 64000-byte turns exactly within a hold, so the end of
# audio always finds a turn open and answers it with "... end total=...".
MIC='while :; do head -c 3000 /dev/zero; sleep 0.1; done'

tmux kill-session -t $S 2>/dev/null || true
tmux new-session -d -s $S -x 120 -y 30 \
  "TERM=xterm-256color STT_CONFIG='$CONF' \
   DICT_TEST_PROVIDER=stt DICT_TEST_STT='$STT' \
   DICT_TEST_STT_LANGUAGES=en,de DICT_TEST_STT_TERMS=-O2,beta \
   DICT_TEST_MIC='$MIC' \
   nvim --noplugin -i NONE -u '$ROOT/test/e2e_init.lua'"
trap 'tmux kill-session -t $S 2>/dev/null' EXIT
sleep 2.5
PANE="$(tmux display -p -t $S '#{pane_pid}')"

# A) hold: live partials, then the finals stt sends at the end of audio -----
start_case 'a'
hold_space 100 &
HOLD=$!
sleep 1.6
tmux capture-pane -t $S -p >"$OUT/mid.txt"
wait $HOLD
sleep 2 # release + end of audio + stt's finals + commit
cmd "DDump $OUT/stt.txt"
cmd "DMessages $OUT/stt_msgs.txt"
sidecar_children >"$OUT/stt_procs.txt"
FILES_A="$(sidecar_files)"

check "interim from stt shown mid-hold" "grep -q 'fake turn 0 word' '$OUT/mid.txt'"
check "final from stt's end of audio committed" "head -1 '$OUT/stt.txt' | grep -qE '^a fake turn 0 .*end total=[0-9]+ '"
check "language hints and key terms (one starting with -) reach stt" "head -1 '$OUT/stt.txt' | grep -q 'terms=2 languages=en,de\$'"
check "partials replaced, not appended" "! head -1 '$OUT/stt.txt' | grep -q word"
check "session idle after commit" "sed -n 2p '$OUT/stt.txt' | grep -qx 'idle'"
check "no leftover extmarks" "sed -n 4p '$OUT/stt.txt' | grep -qx '0'"
check "no warning or error on a normal dictation" "! grep -q 'dictation:' '$OUT/stt_msgs.txt'"
check "stt stream gone after commit" "! grep -q 'stt stream' '$OUT/stt_procs.txt'"

# B) Escape during recording cancels: rollback, stt killed ------------------
start_case 'z'
hold_space 80 &
HOLD=$!
sleep 1.0
sidecar_children >"$OUT/cancel_running.txt"
key Escape # still "holding": recording is active
wait $HOLD # the rest of the spaces land in Normal mode
sleep 0.8
cmd "DDump $OUT/cancel.txt"
sidecar_children >"$OUT/cancel_procs.txt"
files_after B

check "stt stream runs while recording" "grep -q 'stt stream' '$OUT/cancel_running.txt'"
check "esc during recording cancels cleanly" "head -1 '$OUT/cancel.txt' | grep -qx 'z'"
check "idle after cancel" "sed -n 2p '$OUT/cancel.txt' | grep -qx 'idle'"
check "cancel leaves no extmarks" "sed -n 4p '$OUT/cancel.txt' | grep -qx '0'"
check "cancel leaves no process under the sidecar" "[ ! -s '$OUT/cancel_procs.txt' ]"

# C) stt refuses at connect: rollback and the error shown -------------------
# A real provider answers a bad key after about a second; the delay keeps the
# failure after the release, as it would be.
printf 'provider = fake\nfake_fail = connect:auth\nfake_connect_delay = 1.5\n' >"$CONF"
start_case 'q'
hold_space 20
sleep 2.5
cmd "DDump $OUT/fatal.txt"
cmd "DMessages $OUT/fatal_msgs.txt"
sidecar_children >"$OUT/fatal_procs.txt"
files_after C
printf 'provider = fake\n' >"$CONF"

check "failed start rolls the buffer back" "head -1 '$OUT/fatal.txt' | grep -qx 'q'"
check "idle after the failed start" "sed -n 2p '$OUT/fatal.txt' | grep -qx 'idle'"
check "failed start leaves no extmarks" "sed -n 4p '$OUT/fatal.txt' | grep -qx '0'"
check "stt's error message reaches the user" "grep -q 'dictation: stt: fake auth failure at connect' '$OUT/fatal_msgs.txt'"
check "failed start leaves no process under the sidecar" "[ ! -s '$OUT/fatal_procs.txt' ]"

# D) stt fails while Space is still held: the words heard so far are kept ----
# After 1 s of audio stt sends the open turn as a final, then the error.
printf 'provider = fake\nfake_fail = after:1:network\n' >"$CONF"
start_case 'm'
hold_space 150
sleep 2
cmd "DDump $OUT/midfail.txt"
cmd "DMessages $OUT/midfail_msgs.txt"
sidecar_children >"$OUT/midfail_procs.txt"
files_after D
printf 'provider = fake\n' >"$CONF"

check "words heard before a mid-hold failure are committed at release" "head -1 '$OUT/midfail.txt' | grep -qE '^m fake turn 0 word( word)*\$'"
check "the mid-hold failure is a warning" "grep -q 'dictation: stt: fake network failure after 1 s of audio; release Space' '$OUT/midfail_msgs.txt'"
check "no mic-ended warning after a mid-hold failure" "! grep -q 'mic ended' '$OUT/midfail_msgs.txt'"
check "idle after the mid-hold failure" "sed -n 2p '$OUT/midfail.txt' | grep -qx 'idle'"
check "mid-hold failure leaves no extmarks" "sed -n 4p '$OUT/midfail.txt' | grep -qx '0'"
check "mid-hold failure leaves no process under the sidecar" "[ ! -s '$OUT/midfail_procs.txt' ]"

# E) stt fails after the end of audio: the words are kept, with a warning ----
cmd "lua require('dictation').config.stt.cmd = { '$ROOT/test/fake_stt.sh', 'fail-on-stop' }"
start_case 'k'
hold_space 40
sleep 2
cmd "DDump $OUT/stopfail.txt"
cmd "DMessages $OUT/stopfail_msgs.txt"
files_after E

check "words heard before a failed finish are committed" "head -1 '$OUT/stopfail.txt' | grep -qx 'k kept words'"
check "the failure is reported" "grep -q 'dictation: stt: network went away' '$OUT/stopfail_msgs.txt'"
check "idle after the failed finish" "sed -n 2p '$OUT/stopfail.txt' | grep -qx 'idle'"

# F) stt never answers the end of audio: the sidecar's 5 s stop timeout -----
cmd "lua require('dictation').config.stt.cmd = { '$ROOT/test/fake_stt.sh', 'hang' }"
start_case 'h'
hold_space 40
sleep 6.5 # 5 s stop timeout, before the plugin's own 6 s finalize timeout
cmd "DDump $OUT/hang.txt"
cmd "DMessages $OUT/hang_msgs.txt"
sidecar_children >"$OUT/hang_procs.txt"
files_after F

check "stop timeout commits the last partial" "head -1 '$OUT/hang.txt' | grep -qx 'h unconfirmed words'"
check "committed by the sidecar, not the plugin's fallback" "! grep -q 'timed out' '$OUT/hang_msgs.txt'"
check "the hung stt is killed" "[ ! -s '$OUT/hang_procs.txt' ]"
check "idle after the stop timeout" "sed -n 2p '$OUT/hang.txt' | grep -qx 'idle'"

echo "sidecar open files after each case: A=$FILES_A$FILES" >"$OUT/files.txt"
check "no stt session leaves a pipe open in the sidecar" "[ $FILES_GREW = 0 ]"

# G) an unknown provider fails loudly instead of falling back ---------------
cmd "lua require('dictation').config.provider = 'nope'"
start_case 'u'
hold_space 6
sleep 1
cmd "DDump $OUT/unknown.txt"
cmd "DMessages $OUT/unknown_msgs.txt"

check "unknown provider reported" "grep -q 'dictation: unknown provider: nope' '$OUT/unknown_msgs.txt'"
check "unknown provider rolls back" "head -1 '$OUT/unknown.txt' | grep -qE '^u *\$'"
check "idle after unknown provider" "sed -n 2p '$OUT/unknown.txt' | grep -qx 'idle'"

tmux kill-session -t $S 2>/dev/null || true

# H) :checkhealth asks the stt that stt.cmd runs, with its options ----------
# nvim's own config names a provider with no key; each stt.cmd reaches the
# fake one another way.
printf 'provider = soniox\n' >"$OUT/nokey.conf"
health() { # $1 = stt.cmd as a Lua list, $2 = report file
  STT_CONFIG="$OUT/nokey.conf" nvim --headless --clean --cmd "set rtp+=$ROOT" \
    -c "lua require('dictation').setup({ provider = 'stt', stt = { cmd = $1 } })" \
    -c 'checkhealth dictation' -c "write! $2" -c 'qa!' >/dev/null 2>&1
}
health "{ '$STT', 'stream', '--provider', 'fake' }" "$OUT/health_provider.txt"
health "{ '$STT', 'stream', '--provider=fake' }" "$OUT/health_provider_eq.txt"
health "{ 'env', 'STT_CONFIG=$CONF', '$STT', 'stream' }" "$OUT/health_wrapper.txt"
health "{ '$STT', 'stream' }" "$OUT/health_nokey.txt"

check "checkhealth passes stt.cmd's --provider on" "grep -q 'OK stt: provider fake' '$OUT/health_provider.txt'"
check "checkhealth passes stt.cmd's --provider= on" "grep -q 'OK stt: provider fake' '$OUT/health_provider_eq.txt'"
check "checkhealth runs stt through a wrapper command" "grep -q 'OK stt: provider fake' '$OUT/health_wrapper.txt'"
check "checkhealth reports a config stt cannot stream with" "grep -q 'ERROR stt: live transcription cannot start: soniox_api_key is not set' '$OUT/health_nokey.txt'"

if [ $FAIL -eq 0 ]; then
  echo "ALL PASS"
else
  echo "$FAIL FAILURE(S)"
fi
exit $((FAIL > 0))
