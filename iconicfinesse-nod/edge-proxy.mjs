// Edge proxy for the Umbrel package of Nod.
//
// Why this exists: the Nod server permits exactly ONE host — the host
// of its configured public origin — and that origin must be HTTPS or
// HTTP on localhost (src/server/access.ts + network.ts upstream).
// Upstream's own deployment runs a Caddy proxy on the same machine
// and users browse to localhost. On Umbrel the app is opened as
// umbrel.local:4310 or the LAN address, which the server would refuse
// with "This host is not permitted."
//
// This proxy is the app's public "web" service. It forwards to the
// real server and presents every request as the server's own origin
// (Host / Origin / Referer rewritten to http://localhost:4310), and
// rewrites redirect targets back to the address the visitor actually
// used. All of Nod's own checks still run — including its access
// token sign-in — they just see the one origin the server trusts.
import http from 'node:http';
import net from 'node:net';

const listenPort = Number(process.env.PORT || 4310);
const upstreamHost = process.env.UPSTREAM_HOST || 'server';
const upstreamPort = Number(process.env.UPSTREAM_PORT || 4310);
const publicHost = process.env.PUBLIC_HOST || 'localhost:4310';
const publicOrigin = `http://${publicHost}`;

const rewriteRequestHeaders = (headers) => {
  const out = { ...headers, host: publicHost };
  if (out.origin) out.origin = publicOrigin;
  if (out.referer) {
    try {
      const ref = new URL(out.referer);
      out.referer = publicOrigin + ref.pathname + ref.search;
    } catch {
      delete out.referer;
    }
  }
  return out;
};

const rewriteLocation = (value, visitorHost) => {
  if (typeof value !== 'string') return value;
  if (value.startsWith(publicOrigin))
    return `http://${visitorHost}${value.slice(publicOrigin.length)}`;
  if (value.startsWith('http://localhost') || value.startsWith('http://127.0.0.1')) {
    try {
      const u = new URL(value);
      return `http://${visitorHost}${u.pathname}${u.search}`;
    } catch {
      return value;
    }
  }
  return value;
};

const server = http.createServer((request, response) => {
  const visitorHost = request.headers.host || publicHost;
  const upstream = http.request(
    {
      host: upstreamHost,
      port: upstreamPort,
      method: request.method,
      path: request.url,
      headers: rewriteRequestHeaders(request.headers),
    },
    (up) => {
      const headers = { ...up.headers };
      if (headers.location) headers.location = rewriteLocation(headers.location, visitorHost);
      response.writeHead(up.statusCode || 502, headers);
      up.pipe(response);
    },
  );
  upstream.on('error', () => {
    if (!response.headersSent) response.writeHead(502, { 'Content-Type': 'text/plain' });
    response.end('Nod is starting up — try again in a few seconds.');
  });
  request.pipe(upstream);
});

// WebSocket / upgrade passthrough (same header treatment, then raw pipe).
server.on('upgrade', (request, socket, head) => {
  const upstream = net.connect(upstreamPort, upstreamHost, () => {
    const headers = rewriteRequestHeaders(request.headers);
    const lines = [`${request.method} ${request.url} HTTP/${request.httpVersion}`];
    for (const [name, value] of Object.entries(headers))
      lines.push(`${name}: ${Array.isArray(value) ? value.join(', ') : value}`);
    upstream.write(lines.join('\r\n') + '\r\n\r\n');
    if (head && head.length) upstream.write(head);
    upstream.pipe(socket);
    socket.pipe(upstream);
  });
  upstream.on('error', () => socket.destroy());
  socket.on('error', () => upstream.destroy());
});

server.listen(listenPort, '0.0.0.0', () => {
  console.log(`edge proxy listening on ${listenPort} -> ${upstreamHost}:${upstreamPort} as ${publicOrigin}`);
});
