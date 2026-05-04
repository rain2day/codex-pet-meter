import fs from "node:fs/promises";
import http from "node:http";
import https from "node:https";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const STATIC_ROOT = path.dirname(fileURLToPath(import.meta.url));
const HOST = process.env.OPENUSAGE_PET_HOST || "127.0.0.1";
const PORT = Number(process.env.OPENUSAGE_PET_PORT || 43741);

const AUTH_FILE = "auth.json";
const AUTH_BASES = [
  process.env.CODEX_HOME,
  path.join(process.env.HOME || "", ".codex"),
  path.join(process.env.HOME || "", ".config", "codex"),
].filter(Boolean);

const CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
const REFRESH_URL = "https://auth.openai.com/oauth/token";
const USAGE_URL = "https://chatgpt.com/backend-api/wham/usage";
const REFRESH_AGE_MS = 8 * 24 * 60 * 60 * 1000;
const PERIOD_SESSION_MS = 5 * 60 * 60 * 1000;
const PERIOD_WEEKLY_MS = 7 * 24 * 60 * 60 * 1000;

const MIME = new Map([
  [".html", "text/html; charset=utf-8"],
  [".css", "text/css; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".webp", "image/webp"],
  [".png", "image/png"],
]);

function json(res, status, value) {
  const body = JSON.stringify(value, null, 2);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
  });
  res.end(body);
}

function clampPercent(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) return null;
  return Math.max(0, Math.min(100, n));
}

function toIsoFromWindow(window) {
  if (!window) return null;
  if (typeof window.reset_at === "number") return new Date(window.reset_at * 1000).toISOString();
  if (typeof window.reset_after_seconds === "number") {
    return new Date(Date.now() + window.reset_after_seconds * 1000).toISOString();
  }
  return null;
}

function requestJson(url, options = {}) {
  return new Promise((resolve, reject) => {
    const req = https.request(url, {
      method: options.method || "GET",
      headers: options.headers || {},
      timeout: options.timeoutMs || 10000,
    }, (res) => {
      let body = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => {
        body += chunk;
      });
      res.on("end", () => {
        let parsed = null;
        try {
          parsed = body ? JSON.parse(body) : null;
        } catch {}
        resolve({ status: res.statusCode || 0, headers: res.headers, body, parsed });
      });
    });
    req.on("error", reject);
    req.on("timeout", () => req.destroy(new Error("request timed out")));
    if (options.body) req.write(options.body);
    req.end();
  });
}

async function readAuth() {
  for (const base of AUTH_BASES) {
    const authPath = path.join(base, AUTH_FILE);
    try {
      const auth = JSON.parse(await fs.readFile(authPath, "utf8"));
      if (auth?.tokens?.access_token || auth?.OPENAI_API_KEY) {
        return { auth, authPath };
      }
    } catch {}
  }
  return null;
}

function shouldRefresh(auth) {
  if (!auth?.tokens?.refresh_token) return false;
  const last = Date.parse(auth.last_refresh || "");
  return !Number.isFinite(last) || Date.now() - last > REFRESH_AGE_MS;
}

async function persistAuth(authState) {
  await fs.writeFile(authState.authPath, `${JSON.stringify(authState.auth, null, 2)}\n`, "utf8");
}

async function refreshToken(authState) {
  const refreshTokenValue = authState.auth?.tokens?.refresh_token;
  if (!refreshTokenValue) return null;

  const body = new URLSearchParams({
    grant_type: "refresh_token",
    client_id: CLIENT_ID,
    refresh_token: refreshTokenValue,
  }).toString();
  const resp = await requestJson(REFRESH_URL, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
    timeoutMs: 15000,
  });
  if (resp.status < 200 || resp.status >= 300 || !resp.parsed?.access_token) {
    return null;
  }

  authState.auth.tokens.access_token = resp.parsed.access_token;
  if (resp.parsed.refresh_token) authState.auth.tokens.refresh_token = resp.parsed.refresh_token;
  if (resp.parsed.id_token) authState.auth.tokens.id_token = resp.parsed.id_token;
  authState.auth.last_refresh = new Date().toISOString();
  await persistAuth(authState);
  return authState.auth.tokens.access_token;
}

async function fetchCodexUsage() {
  const authState = await readAuth();
  if (!authState) {
    return { ok: false, error: "Codex auth not found. Run codex login first." };
  }
  if (authState.auth.OPENAI_API_KEY) {
    return { ok: false, error: "Usage is not available for API-key auth." };
  }

  let accessToken = authState.auth.tokens.access_token;
  if (shouldRefresh(authState)) {
    accessToken = await refreshToken(authState) || accessToken;
  }

  const requestUsage = (token) => requestJson(USAGE_URL, {
    headers: {
      authorization: `Bearer ${token}`,
      accept: "application/json",
      "user-agent": "CodexUsagePetOverlay",
      ...(authState.auth.tokens.account_id ? { "ChatGPT-Account-Id": authState.auth.tokens.account_id } : {}),
    },
    timeoutMs: 10000,
  });

  let resp = await requestUsage(accessToken);
  if (resp.status === 401 || resp.status === 403) {
    const refreshed = await refreshToken(authState);
    if (refreshed) resp = await requestUsage(refreshed);
  }
  if (resp.status < 200 || resp.status >= 300 || !resp.parsed) {
    return { ok: false, error: `Usage request failed (${resp.status || "no status"}).` };
  }

  const data = resp.parsed;
  const rateLimit = data.rate_limit || {};
  const primary = rateLimit.primary_window || null;
  const secondary = rateLimit.secondary_window || null;
  const headerPrimary = clampPercent(resp.headers["x-codex-primary-used-percent"]);
  const headerSecondary = clampPercent(resp.headers["x-codex-secondary-used-percent"]);

  return {
    ok: true,
    updatedAt: new Date().toISOString(),
    plan: data.plan_type || null,
    session: {
      usedPercent: headerPrimary ?? clampPercent(primary?.used_percent),
      resetsAt: toIsoFromWindow(primary),
      periodDurationMs: typeof primary?.limit_window_seconds === "number"
        ? primary.limit_window_seconds * 1000
        : PERIOD_SESSION_MS,
    },
    weekly: {
      usedPercent: headerSecondary ?? clampPercent(secondary?.used_percent),
      resetsAt: toIsoFromWindow(secondary),
      periodDurationMs: typeof secondary?.limit_window_seconds === "number"
        ? secondary.limit_window_seconds * 1000
        : PERIOD_WEEKLY_MS,
    },
  };
}

async function listPets() {
  const entries = await fs.readdir(ROOT, { withFileTypes: true });
  const pets = [];
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const dir = path.join(ROOT, entry.name);
    try {
      const spec = JSON.parse(await fs.readFile(path.join(dir, "pet.json"), "utf8"));
      const spritesheetPath = path.join(dir, spec.spritesheetPath || "spritesheet.webp");
      await fs.access(spritesheetPath);
      pets.push({
        folder: entry.name,
        id: String(spec.id || entry.name),
        displayName: String(spec.displayName || spec.id || entry.name),
        description: String(spec.description || ""),
        spritesheetUrl: `/pets/${encodeURIComponent(entry.name)}/spritesheet.webp`,
      });
    } catch {}
  }
  return pets.sort((a, b) => a.displayName.localeCompare(b.displayName));
}

async function serveFile(res, filePath) {
  const ext = path.extname(filePath);
  try {
    const data = await fs.readFile(filePath);
    res.writeHead(200, {
      "content-type": MIME.get(ext) || "application/octet-stream",
      "cache-control": ext === ".webp" || ext === ".png" ? "public, max-age=60" : "no-store",
    });
    res.end(data);
  } catch {
    res.writeHead(404);
    res.end("not found");
  }
}

async function handler(req, res) {
  const url = new URL(req.url || "/", `http://${HOST}:${PORT}`);
  try {
    if (url.pathname === "/api/usage") return json(res, 200, await fetchCodexUsage());
    if (url.pathname === "/api/pets") return json(res, 200, { pets: await listPets() });
    if (url.pathname.startsWith("/pets/")) {
      const [, , folder, asset] = url.pathname.split("/");
      if (asset !== "spritesheet.webp") {
        res.writeHead(404);
        return res.end("not found");
      }
      const safeFolder = decodeURIComponent(folder || "");
      const pet = (await listPets()).find((item) => item.folder === safeFolder);
      if (!pet) {
        res.writeHead(404);
        return res.end("not found");
      }
      return serveFile(res, path.join(ROOT, pet.folder, "spritesheet.webp"));
    }

    const pathname = url.pathname === "/" ? "/index.html" : url.pathname;
    const safePath = path.normalize(pathname).replace(/^(\.\.[/\\])+/, "");
    return serveFile(res, path.join(STATIC_ROOT, safePath));
  } catch (error) {
    return json(res, 500, { ok: false, error: error instanceof Error ? error.message : String(error) });
  }
}

export function startServer({ host = HOST, port = PORT } = {}) {
  const server = http.createServer((req, res) => void handler(req, res));
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, host, () => {
      server.off("error", reject);
      resolve({ server, url: `http://${host}:${server.address().port}/` });
    });
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const { url } = await startServer();
  console.log(`Codex usage pet overlay: ${url}`);
}
