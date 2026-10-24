const fs = require("node:fs");
const path = require("node:path");

// The pipeline writes the git SHA into VERSION when it packages a release.
function readVersion() {
  if (process.env.APP_VERSION) return process.env.APP_VERSION;
  try {
    return fs.readFileSync(path.join(__dirname, "..", "VERSION"), "utf8").trim();
  } catch {
    return "dev";
  }
}

// The SPA is served from another origin (CloudFront) than the API (ALB), so the
// browser needs CORS. Allowed origins are set per environment, e.g.
// CORS_ALLOWED_ORIGINS=https://app.example.com (comma-separated).
function parseOrigins(value) {
  return new Set(
    (value || "")
      .split(",")
      .map((o) => o.trim())
      .filter(Boolean),
  );
}

function createHandler({ allowedOrigins = parseOrigins(process.env.CORS_ALLOWED_ORIGINS), version = readVersion() } = {}) {
  return function handler(req, res) {
    const origin = req.headers.origin;
    const headers = { "Content-Type": "application/json", Vary: "Origin" };
    if (origin && allowedOrigins.has(origin)) {
      headers["Access-Control-Allow-Origin"] = origin;
    }

    const send = (status, body) => {
      res.writeHead(status, headers);
      res.end(body === undefined ? "" : JSON.stringify(body));
    };

    // CORS preflight for API routes.
    if (req.method === "OPTIONS" && req.url.startsWith("/api/")) {
      if (!headers["Access-Control-Allow-Origin"]) return send(403, { error: "origin not allowed" });
      headers["Access-Control-Allow-Methods"] = "GET, OPTIONS";
      headers["Access-Control-Allow-Headers"] = "Content-Type";
      headers["Access-Control-Max-Age"] = "600";
      return send(204);
    }

    if (req.method === "GET" && req.url === "/health") {
      return send(200, { status: "ok", version });
    }
    if (req.method === "GET" && req.url === "/api/hello") {
      return send(200, { message: "Hello from the backend" });
    }
    return send(404, { error: "not found" });
  };
}

const version = readVersion();
const handler = createHandler({ version });

module.exports = { createHandler, handler, parseOrigins, version };
