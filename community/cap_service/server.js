// 流萤社区 · Cap 本机验证服务
// 只监听 127.0.0.1，由 Python community 服务代理；不向公网暴露。
import http from "node:http";
import { randomBytes } from "node:crypto";
import { generateChallenge, validateChallenge } from "capjs-core";

const PORT = Number(process.env.CAP_PORT || 8791);
const HOST = "127.0.0.1";
const SECRET = (process.env.CAP_SECRET || "").trim();
const SCOPE = "send-code";
const CHALLENGE_TTL_MS = 5 * 60 * 1000;
const TOKEN_TTL_MS = 20 * 60 * 1000;
const TEST_MODE = process.env.CAP_TEST_MODE === "1";

if (SECRET.length < 32) {
  console.error("[cap] CAP_SECRET missing or shorter than 32 chars");
  process.exit(1);
}

// 单进程部署；重启后旧 token 失效，用户重新验证即可。
const usedChallenges = new Map(); // JWT signature -> expiry ms
const issuedTokens = new Map(); // token -> expiry ms

function cleanup() {
  const now = Date.now();
  for (const [key, expires] of usedChallenges) {
    if (expires <= now) usedChallenges.delete(key);
  }
  for (const [key, expires] of issuedTokens) {
    if (expires <= now) issuedTokens.delete(key);
  }
}
setInterval(cleanup, 60 * 1000).unref();

function json(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
  });
  res.end(body);
}

function readJson(req, limit = 512 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(new Error("body too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}"));
      } catch {
        reject(new Error("invalid json"));
      }
    });
    req.on("error", reject);
  });
}

function friendlyFailure(reason) {
  if (reason === "instr_automated_browser") return "检测到自动化环境，请使用正常浏览器";
  if (reason === "instr_blocked") return "安全校验未通过，请重试";
  if (reason?.startsWith?.("instr_")) return "安全校验未通过，请重试";
  if (reason === "already_redeemed") return "安全验证已使用，请重试";
  if (reason === "expired") return "安全验证已过期，请重试";
  return "安全验证失败，请重试";
}

async function handleChallenge(req, res) {
  const challenge = await generateChallenge(SECRET, {
    format: 2,
    protocols: ["sha256-pow", "instrumentation"],
    challengeCount: Number(process.env.CAP_COUNT || 50),
    challengeSize: 32,
    challengeDifficulty: Number(process.env.CAP_DIFF || 4),
    expiresMs: CHALLENGE_TTL_MS,
    scope: SCOPE,
    instrumentation: {
      blockAutomatedBrowsers: !TEST_MODE,
      blockAutomatedInteractions: !TEST_MODE,
      obfuscationLevel: 5,
    },
  });
  json(res, 200, challenge);
}

async function handleRedeem(req, res) {
  const body = await readJson(req);
  const result = await validateChallenge(SECRET, body, {
    scope: SCOPE,
    tokenTtlMs: TOKEN_TTL_MS,
    consumeNonce: async (sig, ttlMs) => {
      if (usedChallenges.has(sig)) return false;
      usedChallenges.set(sig, Date.now() + Math.max(1000, ttlMs));
      return true;
    },
  });
  if (!result.success) {
    json(res, 200, { success: false, error: friendlyFailure(result.reason), code: result.reason });
    return;
  }
  // instrumentation / 行为层识别出的 AI Agent 直接拒绝，不签发可用 token。
  const flags = Array.isArray(result.riskFlags) ? result.riskFlags : [];
  const agentHit = result.agent?.detected === true || flags.some((x) => String(x).startsWith("agent:"));
  if (agentHit) {
    json(res, 200, { success: false, error: "检测到自动化环境，请使用正常浏览器", code: "agent_detected" });
    return;
  }
  if (typeof result.token === "string" && result.token && result.expires > Date.now()) {
    issuedTokens.set(result.token, result.expires);
  }
  json(res, 200, { success: true, token: result.token, expires: result.expires });
}

async function handleValidate(req, res) {
  const body = await readJson(req);
  const token = typeof body.token === "string" ? body.token : "";
  if (!token) {
    json(res, 200, { success: false });
    return;
  }
  const expires = issuedTokens.get(token);
  if (!expires || expires <= Date.now()) {
    issuedTokens.delete(token);
    json(res, 200, { success: false });
    return;
  }
  issuedTokens.delete(token); // 一次性消费
  json(res, 200, { success: true, expires });
}

const server = http.createServer(async (req, res) => {
  try {
    if (req.method === "GET" && req.url === "/health") {
      json(res, 200, { ok: true, service: "cap", uptime: process.uptime() });
      return;
    }
    if (req.method === "POST" && req.url.split("?")[0] === "/challenge") {
      await handleChallenge(req, res);
      return;
    }
    if (req.method === "POST" && req.url.split("?")[0] === "/redeem") {
      await handleRedeem(req, res);
      return;
    }
    if (req.method === "POST" && req.url.split("?")[0] === "/validate") {
      await handleValidate(req, res);
      return;
    }
    json(res, 404, { error: "not found" });
  } catch (e) {
    console.error("[cap] request failed", e?.message || e);
    json(res, 400, { success: false, error: "安全验证请求异常，请重试" });
  }
});

server.listen(PORT, HOST, () => {
  console.log(`[cap] listening on http://${HOST}:${PORT}`);
});
