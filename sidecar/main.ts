// Dictation sidecar: owns microphone capture and STT streaming so Neovim
// never has to (libuv has no TLS/WebSocket).
//
// stdin  (NDJSON): {cmd:"start",session,provider,options} | {cmd:"stop",session}
//                  | {cmd:"cancel",session} | {cmd:"quit"}
// stdout (NDJSON): {event:"ready"} | {event:"recording"|"interim"|"final"
//                  |"level"|"error"|"end", session, ...}

type Json = Record<string, unknown>;

interface StartOptions {
  micCmd?: string[];
  apiKeyEnv?: string;
  apiKeyCmd?: string[];
  deepgram?: {
    endpoint?: string;
    model?: string;
    language?: string;
    smart_format?: boolean;
    keyterms?: string[];
  };
  assemblyai?: {
    endpoint?: string;
    token_endpoint?: string;
    keyterms?: string[];
  };
}

function emit(ev: Json) {
  console.log(JSON.stringify(ev));
}

function asArray(v: unknown): string[] {
  return Array.isArray(v) ? v : [];
}

abstract class Session {
  constructor(public id: number) {}
  abstract start(opts: StartOptions): void;
  abstract stop(): void;
  abstract cancel(): void;
}

// ---------------------------------------------------------------- fake

class FakeSession extends Session {
  private words = ["the", "quick", "brown", "fox", "jumps", "over", "the", "lazy", "dog"];
  private acc: string[] = [];
  private timer: ReturnType<typeof setInterval> | undefined;
  private done = false;

  start(_opts: StartOptions) {
    emit({ event: "recording", session: this.id });
    let i = 0;
    this.timer = setInterval(() => {
      if (i < this.words.length) {
        this.acc.push(this.words[i++]);
        emit({ event: "interim", session: this.id, text: this.acc.join(" ") });
      }
      emit({ event: "level", session: this.id, rms: 0.05 + 0.05 * (i % 3) });
    }, 250);
  }

  stop() {
    if (this.done) return;
    this.done = true;
    clearInterval(this.timer);
    const text = this.acc.join(" ");
    const final = text ? text[0].toUpperCase() + text.slice(1) + "." : "";
    emit({ event: "final", session: this.id, text: final });
    emit({ event: "end", session: this.id });
  }

  cancel() {
    if (this.done) return;
    this.done = true;
    clearInterval(this.timer);
    emit({ event: "end", session: this.id });
  }
}

// -------------------------------------------------- streaming base class

const DEFAULT_MIC = ["arecord", "-q", "-f", "S16_LE", "-r", "16000", "-c", "1", "-t", "raw", "-"];
const MAX_REPLAY_BYTES = 8_000_000; // ~250s of 16kHz mono s16le

abstract class StreamingSession extends Session {
  protected opts!: StartOptions;
  protected ws?: WebSocket;
  protected wsOpen = false;
  protected stopRequested = false;
  protected cancelled = false;
  protected finished = false;
  protected retried = false;
  protected pending: Uint8Array[] = []; // audio waiting for the socket to open
  protected replay: Uint8Array[] = []; // full session audio, kept for one retry
  private replayBytes = 0;
  private mic?: Deno.ChildProcess;
  private stderrTail = "";
  private lastLevelAt = 0;
  private stopTimeout: ReturnType<typeof setTimeout> | undefined;

  /** Look up the API key + open the first connection. Emit + finish on failure. */
  protected abstract init(): void;
  /** Deliver one audio chunk to an open socket. */
  protected abstract sendAudio(chunk: Uint8Array): void;
  /** Ask the provider to flush and finish (mic is already dead). */
  protected abstract requestStop(): void;
  /** Best final transcript with whatever has arrived so far. */
  protected abstract finalText(): string;

  start(opts: StartOptions) {
    this.opts = opts;
    this.init();
    if (!this.finished) this.startMic(opts.micCmd);
  }

  protected getKey(defaultEnv: string): string | null {
    const env = Deno.env.get(this.opts.apiKeyEnv || defaultEnv);
    if (env) return env.trim();
    const cmd = this.opts.apiKeyCmd;
    if (cmd && cmd.length) {
      try {
        const out = new Deno.Command(cmd[0], { args: cmd.slice(1), stdout: "piped", stderr: "null" }).outputSync();
        const key = new TextDecoder().decode(out.stdout).trim();
        if (key) return key;
      } catch {
        /* fall through */
      }
    }
    return null;
  }

  protected fatal(message: string) {
    emit({ event: "error", session: this.id, fatal: true, message });
    this.finish();
  }

  protected sendOrQueue(chunk: Uint8Array) {
    if (this.wsOpen) this.sendAudio(chunk);
    else this.pending.push(chunk);
  }

  protected flushPending() {
    const p = this.pending;
    this.pending = [];
    for (const c of p) this.sendAudio(c);
  }

  private async startMic(micCmd?: string[]) {
    const cmd = micCmd && micCmd.length ? micCmd : DEFAULT_MIC;
    let proc: Deno.ChildProcess;
    try {
      proc = new Deno.Command(cmd[0], {
        args: cmd.slice(1),
        stdout: "piped",
        stderr: "piped",
        stdin: "null",
      }).spawn();
    } catch (e) {
      this.fatal(`mic spawn failed (${cmd[0]}): ${e}`);
      return;
    }
    this.mic = proc;
    emit({ event: "recording", session: this.id });
    this.drainStderr(proc);
    try {
      for await (const chunk of proc.stdout) {
        if (this.cancelled || this.stopRequested) break;
        this.level(chunk);
        this.replay.push(chunk);
        this.replayBytes += chunk.length;
        if (this.replayBytes > MAX_REPLAY_BYTES) {
          emit({ event: "error", session: this.id, fatal: false, message: "recording too long, stopping capture" });
          break;
        }
        this.sendOrQueue(chunk);
      }
    } catch {
      /* stream broke — handled below */
    }
    if (!this.stopRequested && !this.cancelled && !this.finished) {
      emit({
        event: "error",
        session: this.id,
        fatal: false,
        message: "mic ended early" + (this.stderrTail ? `: ${this.stderrTail.trim().slice(-160)}` : ""),
      });
    }
  }

  private async drainStderr(proc: Deno.ChildProcess) {
    const dec = new TextDecoder();
    try {
      for await (const chunk of proc.stderr) {
        this.stderrTail = (this.stderrTail + dec.decode(chunk)).slice(-500);
      }
    } catch {
      /* ignore */
    }
  }

  private level(chunk: Uint8Array) {
    const now = Date.now();
    if (now - this.lastLevelAt < 100 || chunk.length < 4) return;
    this.lastLevelAt = now;
    const view = new DataView(chunk.buffer, chunk.byteOffset, chunk.byteLength);
    const n = Math.floor(chunk.byteLength / 2);
    let sum = 0;
    let count = 0;
    for (let i = 0; i < n; i += 4) {
      const s = view.getInt16(i * 2, true) / 32768;
      sum += s * s;
      count++;
    }
    if (count > 0) {
      emit({ event: "level", session: this.id, rms: Math.sqrt(sum / count) });
    }
  }

  protected killMic() {
    try {
      this.mic?.kill("SIGTERM");
    } catch {
      /* already gone */
    }
  }

  stop() {
    if (this.stopRequested || this.finished || this.cancelled) return;
    this.stopRequested = true;
    this.killMic();
    if (this.wsOpen) {
      try {
        this.requestStop();
      } catch {
        this.finish();
        return;
      }
    } else if (!this.ws || this.ws.readyState === WebSocket.CLOSED) {
      this.finish();
      return;
    }
    // if the socket is still connecting, onopen flushes audio + requestStop
    this.stopTimeout = setTimeout(() => this.finish(), 5000);
  }

  protected finish() {
    if (this.finished) return;
    this.finished = true;
    clearTimeout(this.stopTimeout);
    this.killMic();
    if (this.stopRequested && !this.cancelled) {
      emit({ event: "final", session: this.id, text: this.finalText() });
    }
    emit({ event: "end", session: this.id });
    try {
      this.ws?.close();
    } catch {
      /* ignore */
    }
  }

  cancel() {
    this.cancelled = true;
    this.finish();
  }
}

// ------------------------------------------------------------ deepgram

class DeepgramSession extends StreamingSession {
  private key = "";
  private finals: string[] = [];
  private lastInterim = "";

  protected init() {
    const key = this.getKey("DEEPGRAM_API_KEY");
    if (!key) {
      this.fatal(`no Deepgram API key ($${this.opts.apiKeyEnv || "DEEPGRAM_API_KEY"} unset, no api_key_cmd result)`);
      return;
    }
    this.key = key;
    this.connect();
  }

  private url(): string {
    const dg = this.opts.deepgram ?? {};
    const p = new URLSearchParams({
      encoding: "linear16",
      sample_rate: "16000",
      channels: "1",
      interim_results: "true",
      model: dg.model ?? "nova-3",
      language: dg.language ?? "multi",
      smart_format: String(dg.smart_format ?? true),
    });
    for (const kt of asArray(dg.keyterms)) p.append("keyterm", kt);
    return (dg.endpoint ?? "wss://api.deepgram.com/v1/listen") + "?" + p.toString();
  }

  private connect() {
    // Deepgram accepts auth via the WebSocket subprotocol; Deno's WebSocket
    // cannot set an Authorization header.
    const ws = new WebSocket(this.url(), ["token", this.key]);
    this.ws = ws;
    ws.onopen = () => {
      if (this.cancelled) {
        ws.close();
        return;
      }
      this.wsOpen = true;
      this.flushPending();
      if (this.stopRequested) this.requestStop();
    };
    ws.onmessage = (m) => this.onMessage(m);
    ws.onclose = () => {
      this.wsOpen = false;
      if (this.stopRequested || this.cancelled) {
        this.finish();
      } else {
        this.maybeRetry();
      }
    };
    ws.onerror = () => {
      /* onclose always follows */
    };
  }

  private maybeRetry() {
    if (this.finished) return;
    if (this.retried) {
      this.fatal("STT connection lost");
      return;
    }
    this.retried = true;
    this.pending = this.replay.slice();
    this.connect();
  }

  private onMessage(m: MessageEvent) {
    if (typeof m.data !== "string") return;
    let msg: any;
    try {
      msg = JSON.parse(m.data);
    } catch {
      return;
    }
    if (msg.type === "Results") {
      const t: string = msg.channel?.alternatives?.[0]?.transcript ?? "";
      if (msg.is_final) {
        if (t) this.finals.push(t);
        this.lastInterim = "";
      } else {
        this.lastInterim = t;
      }
      const combined = [...this.finals, this.lastInterim].filter(Boolean).join(" ");
      emit({ event: "interim", session: this.id, text: combined });
    }
  }

  protected sendAudio(chunk: Uint8Array) {
    this.ws!.send(chunk);
  }

  protected requestStop() {
    this.ws!.send('{"type":"CloseStream"}');
  }

  protected finalText(): string {
    return this.finals.join(" ") || this.lastInterim;
  }
}

// ----------------------------------------------------------- assemblyai

// Universal-Streaming v3 wants audio chunks of 50ms..1000ms.
const AAI_MIN_CHUNK = 1600; // 50ms of 16kHz s16le
const AAI_MAX_CHUNK = 25600; // 800ms

class AssemblyAISession extends StreamingSession {
  private key = "";
  private turns = new Map<number, string>();
  private sendBuf: Uint8Array[] = [];
  private sendBufBytes = 0;

  protected init() {
    const key = this.getKey("ASSEMBLYAI_API_KEY");
    if (!key) {
      this.fatal(`no AssemblyAI API key ($${this.opts.apiKeyEnv || "ASSEMBLYAI_API_KEY"} unset, no api_key_cmd result)`);
      return;
    }
    this.key = key;
    this.connect();
  }

  private async connect() {
    const aai = this.opts.assemblyai ?? {};
    let token: string;
    try {
      const resp = await fetch(
        (aai.token_endpoint ?? "https://streaming.assemblyai.com/v3/token") + "?expires_in_seconds=60",
        { headers: { Authorization: this.key } },
      );
      if (!resp.ok) {
        this.fatal(`AssemblyAI token request failed: HTTP ${resp.status} ${(await resp.text()).slice(0, 160)}`);
        return;
      }
      token = (await resp.json()).token;
    } catch (e) {
      this.fatal(`AssemblyAI token request failed: ${e}`);
      return;
    }
    if (this.cancelled || this.finished) return;

    const p = new URLSearchParams({ sample_rate: "16000", format_turns: "true", token });
    const keyterms = asArray(aai.keyterms);
    if (keyterms.length) p.set("keyterms_prompt", JSON.stringify(keyterms));
    const ws = new WebSocket((aai.endpoint ?? "wss://streaming.assemblyai.com/v3/ws") + "?" + p.toString());
    this.ws = ws;
    ws.onopen = () => {
      if (this.cancelled) {
        ws.close();
        return;
      }
      this.wsOpen = true;
      this.flushPending();
      if (this.stopRequested) this.requestStop();
    };
    ws.onmessage = (m) => this.onMessage(m);
    ws.onclose = () => {
      this.wsOpen = false;
      if (this.stopRequested || this.cancelled) {
        this.finish();
      } else {
        this.maybeRetry();
      }
    };
    ws.onerror = () => {
      /* onclose always follows */
    };
  }

  private maybeRetry() {
    if (this.finished) return;
    if (this.retried) {
      this.fatal("STT connection lost");
      return;
    }
    this.retried = true;
    this.sendBuf = [];
    this.sendBufBytes = 0;
    this.pending = this.replay.slice();
    this.connect(); // fetches a fresh one-time token
  }

  private onMessage(m: MessageEvent) {
    if (typeof m.data !== "string") return;
    let msg: any;
    try {
      msg = JSON.parse(m.data);
    } catch {
      return;
    }
    if (msg.type === "Turn") {
      const order: number = msg.turn_order ?? 0;
      this.turns.set(order, msg.transcript ?? "");
      emit({ event: "interim", session: this.id, text: this.combined() });
    }
    // Begin / Termination need no action: close handling covers the end.
  }

  private combined(): string {
    return [...this.turns.entries()]
      .sort((a, b) => a[0] - b[0])
      .map((e) => e[1])
      .filter(Boolean)
      .join(" ");
  }

  // accumulate into [AAI_MIN_CHUNK, AAI_MAX_CHUNK] byte sends
  protected sendAudio(chunk: Uint8Array) {
    this.sendBuf.push(chunk);
    this.sendBufBytes += chunk.length;
    if (this.sendBufBytes < AAI_MIN_CHUNK) return;
    const all = new Uint8Array(this.sendBufBytes);
    let off = 0;
    for (const c of this.sendBuf) {
      all.set(c, off);
      off += c.length;
    }
    let i = 0;
    while (all.length - i >= AAI_MIN_CHUNK) {
      const n = Math.min(AAI_MAX_CHUNK, all.length - i);
      this.ws!.send(all.subarray(i, i + n));
      i += n;
    }
    const rest = all.subarray(i);
    this.sendBuf = rest.length ? [rest] : [];
    this.sendBufBytes = rest.length;
  }

  protected requestStop() {
    if (this.sendBufBytes > 0) {
      // pad the trailing sub-50ms remainder with silence so it's accepted
      const padded = new Uint8Array(AAI_MIN_CHUNK);
      let off = 0;
      for (const c of this.sendBuf) {
        padded.set(c.subarray(0, AAI_MIN_CHUNK - off), off);
        off += c.length;
      }
      this.ws!.send(padded);
      this.sendBuf = [];
      this.sendBufBytes = 0;
    }
    this.ws!.send('{"type":"Terminate"}');
  }

  protected finalText(): string {
    return this.combined();
  }
}

// ---------------------------------------------------------------- main

let current: Session | null = null;

function handle(cmd: any) {
  switch (cmd.cmd) {
    case "start": {
      current?.cancel();
      const provider = cmd.provider;
      current = provider === "fake"
        ? new FakeSession(cmd.session)
        : provider === "assemblyai"
        ? new AssemblyAISession(cmd.session)
        : new DeepgramSession(cmd.session);
      current.start((cmd.options ?? {}) as StartOptions);
      break;
    }
    case "stop":
      if (current && current.id === cmd.session) current.stop();
      break;
    case "cancel":
      if (current && current.id === cmd.session) current.cancel();
      break;
    case "quit":
      current?.cancel();
      Deno.exit(0);
  }
}

emit({ event: "ready" });

const dec = new TextDecoder();
let buf = "";
for await (const chunk of Deno.stdin.readable) {
  buf += dec.decode(chunk, { stream: true });
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    let cmd: unknown;
    try {
      cmd = JSON.parse(line);
    } catch {
      continue;
    }
    handle(cmd);
  }
}

// stdin closed: Neovim exited
handle({ cmd: "quit" });
