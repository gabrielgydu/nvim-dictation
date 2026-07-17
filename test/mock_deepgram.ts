// Mock Deepgram streaming endpoint for the e2e test. Speaks just enough of
// the protocol: accepts the token subprotocol, counts binary audio, sends one
// interim Result, and on CloseStream sends a final Result whose transcript
// encodes what it observed (so the nvim-side assertion reads the committed
// text).
const port = Number(Deno.args[0] ?? 8790);

Deno.serve({ port, hostname: "127.0.0.1" }, (req) => {
  const protoHeader = req.headers.get("sec-websocket-protocol") ?? "";
  const url = new URL(req.url);
  const { socket, response } = Deno.upgradeWebSocket(req, { protocol: "token" });
  socket.binaryType = "arraybuffer";

  let audioBytes = 0;
  let interimSent = false;

  socket.onmessage = (m) => {
    if (typeof m.data === "string") {
      let msg: any;
      try {
        msg = JSON.parse(m.data);
      } catch {
        return;
      }
      if (msg.type === "CloseStream") {
        const parts = [
          "mockfinal",
          audioBytes > 1000 ? "audio_ok" : "audio_missing",
          protoHeader.includes("testkey123") ? "auth_ok" : "auth_missing",
          "model_" + (url.searchParams.get("model") ?? "none"),
          "lang_" + (url.searchParams.get("language") ?? "none"),
          url.searchParams.get("encoding") === "linear16" && url.searchParams.get("sample_rate") === "16000"
            ? "format_ok"
            : "format_bad",
        ];
        socket.send(JSON.stringify({
          type: "Results",
          is_final: true,
          channel: { alternatives: [{ transcript: parts.join(" ") }] },
        }));
        socket.close();
      }
    } else {
      audioBytes += (m.data as ArrayBuffer).byteLength;
      if (!interimSent) {
        interimSent = true;
        socket.send(JSON.stringify({
          type: "Results",
          is_final: false,
          channel: { alternatives: [{ transcript: "mockinterim" }] },
        }));
      }
    }
  };

  return response;
});
