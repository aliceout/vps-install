#!/usr/bin/env node
// GitHub webhooks receiver.
//
// Config venue de /etc/secrets/webhooks.env (synce par l'agent Infisical
// depuis /services/webhooks/). Clés attendues :
//   WEBHOOKS_REPOS = JSON array: [{"repo":"owner/name","secretEnv":"X_SECRET","script":"x.sh"}, ...]
//   <X_SECRET>     = le secret HMAC partage avec GitHub (un par repo)
//
// Les scripts de deploy vivent dans HOOKS_DIR (default
// /var/lib/services/webhooks/hooks/). Les logs d'execution dans LOG_DIR.

const http    = require("http");
const crypto  = require("crypto");
const fs      = require("fs");
const path    = require("path");
const { exec } = require("child_process");

const PORT      = parseInt(process.env.PORT || "8070", 10);
const HOOKS_DIR = process.env.HOOKS_DIR || "/var/lib/services/webhooks/hooks";
const LOG_DIR   = process.env.LOG_DIR   || "/var/lib/services/webhooks/log";

fs.mkdirSync(LOG_DIR, { recursive: true });

// --- Charge la config repos -> secret + script --------------------------------

const DEPLOY = {};
try {
  const raw = process.env.WEBHOOKS_REPOS || "[]";
  const entries = JSON.parse(raw);
  for (const e of entries) {
    if (!e.repo || !e.secretEnv || !e.script) {
      console.warn(`Skip entree incomplete:`, e);
      continue;
    }
    const secret = process.env[e.secretEnv];
    if (!secret) {
      console.warn(`Pas de secret dans env[${e.secretEnv}] pour ${e.repo}, skip`);
      continue;
    }
    DEPLOY[e.repo] = { secret, script: e.script };
  }
} catch (err) {
  console.error("Parsing WEBHOOKS_REPOS echoue:", err.message);
  process.exit(1);
}

console.log(`HOOKS_DIR: ${HOOKS_DIR}`);
console.log(`Repos configures: ${Object.keys(DEPLOY).join(", ") || "(aucun)"}`);

// --- HMAC verify --------------------------------------------------------------

function verifySignature(req, body, secret) {
  const signature = req.headers["x-hub-signature-256"];
  if (!signature) return false;
  const hmac = crypto.createHmac("sha256", secret);
  const digest = `sha256=${hmac.update(body).digest("hex")}`;
  try {
    return crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(digest));
  } catch {
    return false;
  }
}

// --- HTTP ---------------------------------------------------------------------

const server = http.createServer((req, res) => {
  if (req.method !== "POST" || !["/webhook", "/webhooks"].includes(req.url)) {
    res.writeHead(404);
    return res.end("Not found");
  }

  let body = "";
  req.on("data", chunk => { body += chunk; });

  req.on("end", () => {
    const event = req.headers["x-github-event"];

    let data;
    try { data = JSON.parse(body); }
    catch {
      res.writeHead(400);
      return res.end("Invalid JSON");
    }

    if (event === "ping") {
      console.log("ping from", data.repository?.full_name || "?");
      res.writeHead(200);
      return res.end("pong");
    }

    const repo = data.repository?.full_name;
    if (!repo || !DEPLOY[repo]) {
      console.warn(`Repo non autorise: ${repo}`);
      res.writeHead(400);
      return res.end("Unknown repo");
    }

    const { secret, script } = DEPLOY[repo];

    if (!verifySignature(req, body, secret)) {
      console.warn(`Signature invalide pour ${repo}`);
      res.writeHead(401);
      return res.end("Invalid signature");
    }

    const scriptPath = path.join(HOOKS_DIR, script);
    if (!fs.existsSync(scriptPath)) {
      console.error(`Script introuvable: ${scriptPath}`);
      res.writeHead(500);
      return res.end("Hook script missing");
    }

    console.log(`${repo} OK (event=${event}) -> ${script}`);
    res.writeHead(200);
    res.end("Deploy started");

    const logFile = path.join(LOG_DIR, `${repo.replace(/\//g, "_")}.log`);
    const cmd = `bash "${scriptPath}" >> "${logFile}" 2>&1`;
    exec(cmd, { timeout: 0 }, (err) => {
      if (err) console.error(`${script} exit ${err.code}: ${err.message}`);
      else     console.log(`${script} OK`);
    });
  });
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`Webhook receiver en ecoute sur 127.0.0.1:${PORT}`);
});
