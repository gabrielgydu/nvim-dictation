#!/bin/sh
# Stand-in for `stt stream` with behaviour stt's own fake provider lacks, for
# test/e2e_stt.sh. $1 picks it (further arguments are ignored):
#   fail-on-stop  a partial; at the end of audio an error line, exit 5
#   hang          a partial; the end of audio is never answered
# Both start with a line that is not JSON, which the sidecar must skip.
echo 'not json'
echo '{"type": "ready", "provider": "fake_stt.sh", "model": "none"}'
case "$1" in
fail-on-stop)
  echo '{"type": "partial", "turn": 0, "text": "kept words", "start_ms": 0}'
  cat >/dev/null
  echo '{"type": "error", "kind": "network", "fatal": false, "routine": false, "retry_after": null, "message": "network went away"}'
  echo 'stt: network went away' >&2
  exit 5
  ;;
hang)
  echo '{"type": "partial", "turn": 0, "text": "unconfirmed words", "start_ms": 0}'
  cat >/dev/null
  exec sleep 60
  ;;
esac
echo "stt: fake_stt.sh: unknown mode '$1'" >&2
exit 2
