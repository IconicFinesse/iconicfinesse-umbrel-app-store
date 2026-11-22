# Nod secrets: generated once on first install, then read back from the
# app's data folder on every start. Nothing secret is in the package
# itself. Formats match upstream's setup.sh (auth token + database
# password are hex, the vault key is base64 for 32 bytes).

NOD_APP_DIR="${APP_DATA_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
NOD_SECRETS_FILE="${NOD_APP_DIR}/data/nod-secrets.env"

if [ ! -f "${NOD_SECRETS_FILE}" ]; then
  mkdir -p "${NOD_APP_DIR}/data"
  {
    echo "NOD_AUTH_TOKEN=$(openssl rand -hex 32)"
    echo "NOD_VAULT_KEY=$(openssl rand -base64 32)"
    echo "NOD_POSTGRES_PASSWORD=$(openssl rand -hex 24)"
  } > "${NOD_SECRETS_FILE}"
  chmod 600 "${NOD_SECRETS_FILE}"
fi

# shellcheck disable=SC1090
. "${NOD_SECRETS_FILE}"
export NOD_AUTH_TOKEN NOD_VAULT_KEY NOD_POSTGRES_PASSWORD

# Optional operator-seeded LLM provider key (never part of the package).
# Drop a file at data/nod-llm.env containing:
#   OPENAI_COMPATIBLE_API_KEY=<key>
NOD_LLM_FILE="${NOD_APP_DIR}/data/nod-llm.env"
if [ -f "${NOD_LLM_FILE}" ]; then
  # shellcheck disable=SC1090
  . "${NOD_LLM_FILE}"
  export OPENAI_COMPATIBLE_API_KEY
fi

# --- Edge proxy script -------------------------------------------------
# The package's "web" service runs edge-proxy.mjs from the app folder.
# umbreld's package copy did not deliver this file on fresh installs
# (v1.0.1: it arrived as an empty directory and the web service
# crash-looped), so exports.sh writes it — it runs before the stack
# starts, every start, and refreshes the file when the package changes.
NOD_EDGE_FILE="${NOD_APP_DIR}/edge-proxy.mjs"
NOD_EDGE_TMP="${NOD_EDGE_FILE}.tmp"
cat > "${NOD_EDGE_TMP}" <<'NOD_EDGE_EOF'
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
NOD_EDGE_EOF
if [ -d "${NOD_EDGE_FILE}" ]; then
  rm -rf "${NOD_EDGE_FILE}"
fi
if [ -f "${NOD_EDGE_FILE}" ] && cmp -s "${NOD_EDGE_TMP}" "${NOD_EDGE_FILE}"; then
  rm -f "${NOD_EDGE_TMP}"
else
  mv "${NOD_EDGE_TMP}" "${NOD_EDGE_FILE}"
fi
