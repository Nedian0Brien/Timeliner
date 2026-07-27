#!/usr/bin/env node
import http from "node:http";
import net from "node:net";

const listenPort = Number(process.env.PORT || 4300);
const uiPort = Number(process.env.SERVE_SIM_UI_PORT || 3200);
const streamPort = Number(process.env.SERVE_SIM_STREAM_PORT || 3100);

function targetFor(pathname) {
  if (
    pathname === "/ws" ||
    pathname === "/stream.mjpeg" ||
    pathname === "/stream.avcc"
  ) {
    return streamPort;
  }

  return uiPort;
}

function upstreamHeaders(headers, targetPort) {
  return {
    ...headers,
    host: `127.0.0.1:${targetPort}`,
    origin: `http://127.0.0.1:${targetPort}`,
  };
}

function rewriteHtml(body) {
  return body.replace(
    /<script>window\.__SIM_PREVIEW__=(\{.*?\})<\/script>/s,
    (_match, json) => {
      const escaped = JSON.stringify(json);
      return `<script>
try { delete window.VideoDecoder; } catch {}
try { window.VideoDecoder = undefined; } catch {}
window.__SIM_PREVIEW__ = JSON.parse(${escaped});
window.__SIM_PREVIEW__.url = location.origin;
window.__SIM_PREVIEW__.streamUrl = location.origin + "/stream.mjpeg";
window.__SIM_PREVIEW__.wsUrl = (location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/ws";
</script>`;
    },
  );
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url || "/", "http://localhost");
  if (url.pathname === "/simple") {
    const html = `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Timeliner Simulator</title>
  <style>
    html, body { margin: 0; min-height: 100%; background: #0b0b0d; color: #f5f5f7; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
    body { display: grid; place-items: center; padding: 24px; box-sizing: border-box; }
    main { display: grid; gap: 14px; justify-items: center; }
    header { display: flex; align-items: center; justify-content: space-between; gap: 18px; width: min(430px, 92vw); }
    h1 { margin: 0; font-size: 15px; line-height: 1.2; font-weight: 650; letter-spacing: 0; }
    p { margin: 0; color: #a1a1aa; font-size: 12px; }
    img { width: min(430px, 92vw); max-height: 86vh; object-fit: contain; border-radius: 34px; border: 1px solid rgba(255,255,255,.18); box-shadow: 0 24px 80px rgba(0,0,0,.45); background: #000; }
    a { color: #d1d5db; font-size: 12px; text-decoration: none; border: 1px solid rgba(255,255,255,.16); border-radius: 7px; padding: 7px 10px; }
  </style>
</head>
<body>
  <main>
    <header>
      <div>
        <h1>Timeliner Simulator</h1>
        <p>Live iPhone 17 Pro stream</p>
      </div>
      <a href="/">Tools</a>
    </header>
    <img src="/stream.mjpeg" alt="Live iOS Simulator stream">
  </main>
</body>
</html>`;
    res.writeHead(200, {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "content-length": Buffer.byteLength(html),
    });
    res.end(html);
    return;
  }

  const targetPort = targetFor(url.pathname);
  if (url.pathname.endsWith("ws")) {
    console.log(`http ${req.method} ${url.pathname} -> ${targetPort}`);
  }

  const proxyReq = http.request(
    {
      hostname: "127.0.0.1",
      port: targetPort,
      path: req.url,
      method: req.method,
      headers: upstreamHeaders(req.headers, targetPort),
    },
    (proxyRes) => {
      const contentType = proxyRes.headers["content-type"] || "";
      if (!contentType.includes("text/html")) {
        res.writeHead(proxyRes.statusCode || 502, proxyRes.headers);
        proxyRes.pipe(res);
        return;
      }

      const chunks = [];
      proxyRes.on("data", (chunk) => chunks.push(chunk));
      proxyRes.on("end", () => {
        const rewritten = rewriteHtml(Buffer.concat(chunks).toString("utf8"));
        const headers = {
          ...proxyRes.headers,
          "content-length": Buffer.byteLength(rewritten),
        };
        res.writeHead(proxyRes.statusCode || 200, headers);
        res.end(rewritten);
      });
    },
  );

  proxyReq.on("error", (error) => {
    res.writeHead(502, { "content-type": "text/plain; charset=utf-8" });
    res.end(`Proxy error: ${error.message}\n`);
  });

  req.pipe(proxyReq);
});

server.on("upgrade", (req, socket, head) => {
  const url = new URL(req.url || "/", "http://localhost");
  const targetPort = targetFor(url.pathname);
  console.log(`upgrade ${url.pathname} -> ${targetPort}`);
  const upstream = net.connect(targetPort, "127.0.0.1", () => {
    upstream.write(
      `${req.method} ${req.url} HTTP/${req.httpVersion}\r\n` +
        Object.entries(upstreamHeaders(req.headers, targetPort))
          .map(([key, value]) => `${key}: ${value}`)
          .join("\r\n") +
        "\r\n\r\n",
    );
    if (head.length > 0) upstream.write(head);
    socket.pipe(upstream).pipe(socket);
  });

  upstream.on("error", () => socket.destroy());
});

server.listen(listenPort, "127.0.0.1", () => {
  console.log(
    `serve-sim Cloudflare proxy listening on http://127.0.0.1:${listenPort}`,
  );
  console.log(`UI -> http://127.0.0.1:${uiPort}`);
  console.log(`Stream/WebSocket -> http://127.0.0.1:${streamPort}`);
});
