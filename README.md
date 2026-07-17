# nvim-dictation

Hold **Space** in Insert mode to dictate. Release to commit the transcript at
the cursor. A normal Space tap stays a normal space.

Terminals have no key-up events, so a "hold" is detected from key auto-repeat:
a stream of rapid Space events activates recording, the warmup spaces are
removed, further repeats are swallowed, and silence on the event stream means
the key was released. Interim transcripts appear dimmed at the cursor while
you speak; the final transcript replaces them.

## Requirements

- Neovim 0.10+ (developed against 0.12)
- [deno](https://deno.land) — runs the STT sidecar (Neovim itself has no
  TLS/WebSocket support)
- An audio capture tool: `pw-record`, `arecord`, `parec`, or `rec` (sox)
- An [AssemblyAI](https://assemblyai.com) API key (default provider) or a
  [Deepgram](https://deepgram.com) one
- Terminal key auto-repeat enabled (it almost certainly is); repeat **delay**
  must be below `hold.chain_gap_ms` (default 700 ms — X11's default 660 ms
  delay fits; raise it if your delay is longer)

Run `:checkhealth dictation` to verify all of the above.

## Install

lazy.nvim:

```lua
{
  'gabrielgydu/nvim-dictation', -- or: dir = '~/development/neovim-dictation'
  event = 'InsertEnter',
  opts = {},
}
```

## Configuration (defaults)

```lua
require('dictation').setup({
  provider = 'assemblyai', -- 'assemblyai' | 'deepgram' | 'fake' (deterministic test text)
  spawn = 'insert',        -- start sidecar on first InsertEnter ('eager'|'insert'|'lazy')
  hold = {
    rapid_gap_ms = 120,            -- gap ≤ this = auto-repeat event
    chain_gap_ms = 700,            -- gap ≤ this keeps warmup spaces strippable
    activation_rapid_events = 4,   -- consecutive rapid events to activate
    release_timeout_ms = 200,      -- event silence = key released
    poll_interval_ms = 50,
  },
  audio = {
    mic_cmd = nil, -- auto-detect; override with argv list producing s16le/16kHz/mono raw on stdout
  },
  assemblyai = {
    endpoint = 'wss://streaming.assemblyai.com/v3/ws',
    token_endpoint = 'https://streaming.assemblyai.com/v3/token',
    keyterms = {}, -- domain words to boost (untested against the live API)
    api_key_env = 'ASSEMBLYAI_API_KEY',
    api_key_cmd = nil, -- argv list printing the key; alternative to the env var
  },
  deepgram = {
    endpoint = 'wss://api.deepgram.com/v1/listen',
    model = 'nova-3',
    language = 'multi', -- 'multi' = multilingual (en/de/pt/...); or 'en', 'de', ...
    smart_format = true,
    keyterms = {},
    api_key_env = 'DEEPGRAM_API_KEY',
    api_key_cmd = nil,
  },
  finalize_timeout_ms = 6000, -- give up waiting for the final transcript after this
  exclude = { filetypes = {}, buftypes = { 'prompt' } },
  debug = false, -- notify sidecar stderr lines
})
```

Reusing an existing key from a file instead of an env var:

```lua
assemblyai = {
  api_key_cmd = { 'sh', '-c', [[sed -nE 's/^assemblyai_api_key[ =]+//p' ~/.config/audiorecorder/config | tr -d ' ']] },
},
```

### Provider notes

- **AssemblyAI** (default): Universal-Streaming v3. Live interim turns while
  you speak, formatted finals, multilingual without configuration (English and
  German verified live). Auth uses a short-lived token fetched over HTTPS.
- **Deepgram**: nova-3 streaming, `language = 'multi'`. Protocol verified
  against a mock server; not yet tested against the live API.
- **OpenAI Realtime was evaluated and deliberately not included**: its
  transcription deltas only arrive after the audio buffer is committed (i.e.
  after you release Space), so there is no live interim text while speaking —
  the main point of this UI.

Statusline: `require('dictation').status()` returns `''`, `'● dictating'`, or
`'… transcribing'`. Cancel an in-flight dictation with `:DictationCancel`
(leaving Insert mode while recording also cancels).

Highlights: `DictationInterim` (default: `Comment`) for the dimmed interim
text, `DictationHint` (default: `NonText`) for the virtual-text hints.

## How activation feels

With a 300 ms repeat delay at 50 Hz (this machine), dictation starts ~380 ms
after you start holding. Timeline: tap = 1 space; hold = space, tiny pause,
then `keep holding ␣ …` appears, then recording starts, the warmup spaces
vanish, and a `🎙` level meter shows at end of line. Release, and the dimmed
text solidifies.

## Architecture

```
Neovim (Lua)                          sidecar (deno, long-lived)
  keyhold: auto-repeat heuristics       owns mic process (pw-record/arecord/…)
  buffer:  extmark-owned range   stdin  owns wss:// to Deepgram (token subprotocol)
  session: state machine        ------> {cmd:start|stop|cancel|quit}
  ui:      hints, level meter   <------ {event:interim|final|level|error|…}
  sidecar: NDJSON plumbing      stdout  buffers audio until socket opens, retries once
```

The buffer layer only ever mutates text it wrote itself: the owned range is
tracked with paired extmarks and verified against the last written text before
every update. If you edit inside the range while a transcript is finalizing,
dictation detaches and the final text lands in register `d` instead of
clobbering your edit. Edits *outside* the range (before/after) are fine.

## Safety properties (all tested)

- A single Space tap inserts exactly one space, with no added latency.
- Warmup spaces are fully removed on activation — including the initial
  press's space across the keyboard repeat-delay gap.
- Macro replay (`@q`) never triggers dictation; pasting doesn't either.
- Any non-space key resets hold detection.
- Cancel/errors/timeouts roll back interim text and clean up extmarks, timers,
  and the mic process. STT timeout commits the last interim rather than losing
  your words.

## Tests

```sh
# pure-Lua layers, headless
nvim --headless --clean --cmd "set rtp+=$(pwd)" -l test/unit_keyhold.lua
nvim --headless --clean --cmd "set rtp+=$(pwd)" -l test/unit_buffer.lua

# real-TTY end-to-end in tmux (fake provider — no audio, no network)
./test/e2e_tmux.sh

# Deepgram protocol path against a local mock server (espeak-ng as mic)
./test/e2e_deepgram_mock.sh

# LIVE AssemblyAI streaming through the whole plugin (needs a key; costs
# a few seconds of streaming credit; skips when no key is found)
./test/e2e_assemblyai_live.sh

# everything
./test/run_all.sh
```

## Notes & limitations

- Very fast deliberate Space tapping (5 taps, each gap under 120 ms) would
  activate dictation — that's inherent to the auto-repeat heuristic. Tune
  `activation_rapid_events`/`rapid_gap_ms` if it ever bites.
- If your keyboard repeat delay exceeds `chain_gap_ms`, one warmup space can
  leak into the buffer on activation. Raise `chain_gap_ms` above your delay.
- Normal mode Space is untouched (it's commonly `<Leader>`).
- The first dictation after startup may clip the first ~100 ms of speech if
  `spawn = 'lazy'`; the default `'insert'` avoids this in practice.
