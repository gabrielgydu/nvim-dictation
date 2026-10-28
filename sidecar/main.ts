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
  stt?: {
    cmd?: string[];
    languages?: string[] | string;
    terms?: string[] | string;
    termsFile?: string;
  };
}

function emit(ev: Json) {
  console.log(JSON.stringify(ev));
}

function asArray(v: unknown): string[] {
  return Array.isArray(v) ? v : [];
}

/** Lines of a byte stream, trimmed, blank ones skipped. */
async function* lines(stream: ReadableStream<Uint8Array>): AsyncGenerator<string> {
  const dec = new TextDecoder();
  let buf = "";
  for await (const chunk of stream) {
    buf += dec.decode(chunk, { stream: true });
    let nl;
    while ((nl = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, nl).trim();
      buf = buf.slice(nl + 1);
      if (line) yield line;
    }
  }
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
  protected stopRequested = false;
  protected cancelled = false;
  protected finished = false;
  protected retried = false;
  protected pending: Uint8Array[] = []; // audio waiting for the socket to open
  protected replay: Uint8Array[] = []; // full session audio, kept for one retry
  private replayBytes = 0;
  private mic?: Deno.ChildProcess;
  private micKilled = false;
  private stderrTail = "";
  private lastLevelAt = 0;
  private stopTimeout: ReturnType<typeof setTimeout> | undefined;

  /** Look up the API key + open the first connection. Emit + finish on failure. */
  protected abstract init(): void;
  /** True while audio can go out (sendAudio / requestStop may be called). */
  protected abstract isOpen(): boolean;
  /** Not open yet, not closed either: the transport's own handlers carry on. */
  protected abstract isConnecting(): boolean;
  /** Close the provider transport; finish() calls it, also on cancel. */
  protected abstract closeTransport(): void;
  /** Deliver one audio chunk to an open transport. */
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
    if (this.isOpen()) this.sendAudio(chunk);
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
    if (!this.stopRequested && !this.cancelled && !this.finished && !this.micKilled) {
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
    this.micKilled = true;
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
    if (this.isOpen()) {
      try {
        this.requestStop();
      } catch {
        this.finish();
        return;
      }
    } else if (!this.isConnecting()) {
      this.finish();
      return;
    }
    // if the transport is still connecting, it flushes audio + requestStop once open
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
      this.closeTransport();
    } catch {
      /* ignore */
    }
  }

  cancel() {
    this.cancelled = true;
    this.finish();
  }
}

// ------------------------------------------------- websocket base class

abstract class WebSocketSession extends StreamingSession {
  protected ws?: WebSocket;
  protected wsOpen = false;

  protected isOpen(): boolean {
    return this.wsOpen;
  }

  protected isConnecting(): boolean {
    return !!this.ws && this.ws.readyState !== WebSocket.CLOSED;
  }

  protected closeTransport() {
    this.ws?.close();
  }
}

// ------------------------------------------------------------ deepgram

class DeepgramSession extends WebSocketSession {
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

class AssemblyAISession extends WebSocketSession {
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

// ------------------------------------------------------------------ stt

// One line of `stt stream` output (only the fields used here).
interface SttEvent {
  type?: string;
  text?: string;
  message?: string;
}

/** A list as one comma-separated argument; a string passes as is. */
function csv(v: string[] | string | undefined): string | undefined {
  return Array.isArray(v) ? v.join(",") : v;
}

// Runs `stt stream` (or any command speaking its protocol) once per
// dictation: raw PCM on the child's stdin, one JSON event per line on its
// stdout. stt owns the provider, key, language hints and key terms. It reads
// stdin from the start and buffers while it connects, so the transport is
// open as soon as the child runs. stt never reconnects: after a failure
// nothing more is heard, and the words heard before it are kept.
class SttSession extends StreamingSession {
  private proc?: Deno.ChildProcess;
  private stdin?: WritableStreamDefaultWriter<Uint8Array>;
  private exited = false;
  private finals: string[] = [];
  private partial = "";
  private errorMessage = ""; // from stt's error line
  private lastStderr = ""; // stt's last stderr line is `stt: <message>`

  protected init() {
    const stt = this.opts.stt ?? {};
    const cmd = stt.cmd ?? ["stt", "stream"];
    if (!Array.isArray(cmd) || !cmd.length) {
      this.fatal("stt.cmd must be an argv list, e.g. { 'stt', 'stream' }");
      return;
    }
    // one argument each: a value starting with "-" would read as an option
    const args = cmd.slice(1);
    const languages = csv(stt.languages);
    if (languages !== undefined) args.push(`--languages=${languages}`);
    const terms = csv(stt.terms);
    if (terms !== undefined) args.push(`--terms=${terms}`);
    if (stt.termsFile) args.push(`--terms-file=${stt.termsFile}`);
    let proc: Deno.ChildProcess;
    try {
      proc = new Deno.Command(cmd[0], {
        args,
        stdin: "piped",
        stdout: "piped",
        stderr: "piped",
      }).spawn();
    } catch (e) {
      this.fatal(
        e instanceof Deno.errors.NotFound
          ? `${cmd[0]} not found (put it on PATH or set stt.cmd to its full path)`
          : `stt spawn failed (${cmd[0]}): ${e}`,
      );
      return;
    }
    this.proc = proc;
    this.stdin = proc.stdin.getWriter();
    this.watch(proc);
  }

  // Reads the child to the end, then settles the session by how it ended.
  private async watch(proc: Deno.ChildProcess) {
    const [status] = await Promise.all([proc.status, this.readEvents(proc.stdout), this.readStderr(proc.stderr)]);
    this.exited = true;
    this.dropStdin(); // nothing reads it any more
    if (this.finished) return; // cancelled, or the stop timeout already committed
    if (status.success && this.stopRequested) {
      this.finish();
      return;
    }
    const reason = this.errorMessage || this.lastStderr.replace(/^stt: /, "") ||
      (status.success ? "ended before the dictation did" : `exited with status ${status.code}`);
    const message = `stt: ${reason}`;
    if (!this.finalText()) {
      this.fatal(message);
    } else if (this.stopRequested) {
      // keep the words heard so far, and say why they may be incomplete
      emit({ event: "error", session: this.id, fatal: false, message });
      this.finish();
    } else {
      // Space is still held: nothing more can be heard, but the words so far
      // stay on screen, and the release commits them (stop() finds no
      // transport and finishes at once)
      emit({
        event: "error",
        session: this.id,
        fatal: false,
        message: `${message}; release Space to insert the words heard so far`,
      });
      this.killMic();
    }
  }

  private async readEvents(stdout: ReadableStream<Uint8Array>) {
    try {
      for await (const line of lines(stdout)) this.onEvent(line);
    } catch {
      /* the child is gone */
    }
  }

  private async readStderr(stderr: ReadableStream<Uint8Array>) {
    try {
      for await (const line of lines(stderr)) {
        this.lastStderr = line;
        console.error(line); // shown with debug = true
      }
    } catch {
      /* the child is gone */
    }
  }

  private onEvent(line: string) {
    let ev: SttEvent | null;
    try {
      ev = JSON.parse(line);
    } catch {
      return; // not a protocol line
    }
    switch (ev?.type) {
      case "partial": // the open turn's whole text so far
        this.partial = ev.text ?? "";
        break;
      case "final": // closes the open turn
        if (ev.text) this.finals.push(ev.text);
        this.partial = "";
        break;
      case "error": // the exit status follows; watch() reports it
        this.errorMessage = ev.message ?? "";
        return;
      case "note":
        console.error(`stt note: ${ev.message}`);
        return;
      default: // ready, end
        return;
    }
    emit({ event: "interim", session: this.id, text: this.finalText() });
  }

  protected isOpen(): boolean {
    return !!this.stdin && !this.exited;
  }

  protected isConnecting(): boolean {
    return false; // stt buffers while it connects: open from the start
  }

  protected sendAudio(chunk: Uint8Array) {
    // not awaited: writes queue in order; a dead child rejects them
    this.stdin!.write(chunk).catch(() => {});
  }

  protected requestStop() {
    // EOF: stt finalizes, prints the last finals and `end`, exits 0
    this.stdin!.close().catch(() => {});
  }

  protected closeTransport() {
    // cancel, or a stop that timed out: stt cuts the provider session at once
    if (!this.exited) this.proc?.kill("SIGTERM");
    this.dropStdin();
  }

  /** Closes our end of the child's stdin pipe; a no-op once it is closed. */
  private dropStdin() {
    this.stdin?.abort().catch(() => {});
  }

  protected finalText(): string {
    return [...this.finals, this.partial].filter(Boolean).join(" ");
  }
}

// ---------------------------------------------------------------- main

const PROVIDERS = new Map<string, new (id: number) => Session>([
  ["fake", FakeSession],
  ["deepgram", DeepgramSession],
  ["assemblyai", AssemblyAISession],
  ["stt", SttSession],
]);

let current: Session | null = null;

function handle(cmd: any) {
  switch (cmd.cmd) {
    case "start": {
      current?.cancel();
      current = null;
      const Provider = PROVIDERS.get(cmd.provider);
      if (!Provider) {
        emit({ event: "error", session: cmd.session, fatal: true, message: `unknown provider: ${cmd.provider}` });
        emit({ event: "end", session: cmd.session });
        break;
      }
      current = new Provider(cmd.session);
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

for await (const line of lines(Deno.stdin.readable)) {
  let cmd: unknown;
  try {
    cmd = JSON.parse(line);
  } catch {
    continue;
  }
  handle(cmd);
}

// stdin closed: Neovim exited
handle({ cmd: "quit" });
