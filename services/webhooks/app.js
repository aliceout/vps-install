#!/usr/bin/env node
// GitHub webhooks receiver.
//
// Sources :
//  - process.env.HOOKS_ENV_DIR (default /etc/secrets/webhooks/) :
//    un .env par hook, chacun contenant REPO, SECRET, SCRIPT.
//  - process.env.HOOKS_DIR : ou trouver les scripts shell.
//  - process.env.LOG_DIR   : ou logger l'execution.
//
// Re-scan automatique du HOOKS_ENV_DIR a chaque requete : ajouter / modifier
// un sous-dossier dans Infisical -> 60s plus tard l'agent ecrit le nouveau
// fichier .env -> la prochaine requete le voit, sans restart du service.

const http     = require("http");
const crypto   = require("crypto");
const fs       = require("fs");
const path     = require("path");
const { exec } = require("child_process");

const PORT          = parseInt(process.env.PORT || "8070", 10);
const HOOKS_DIR     = process.env.HOOKS_DIR     || "/var/lib/services/webhooks/hooks";
const LOG_DIR       = process.env.LOG_DIR       || "/var/lib/services/webhooks/log";
const HOOKS_ENV_DIR = process.env.HOOKS_ENV_DIR || "/etc/secrets/webhooks";

fs.mkdirSync(LOG_DIR, { recursive: true });

// --- Lecture des hooks -------------------------------------------------------

function parseEnvFile(file) {
  const out = {};
  for (const raw of fs.readFileSync(file, "utf8").split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq <= 0) continue;
    let v = line.slice(eq + 1).trim();
    // strip surrounding quotes
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
      v = v.slice(1, -1);
    }
    out[line.slice(0, eq).trim()] = v;
  }
  return out;
}

function loadDeployConfig() {
  const map = {};
  if (!fs.existsSync(HOOKS_ENV_DIR)) return map;

  for (const f of fs.readdirSync(HOOKS_ENV_DIR)) {
    if (!f.endsWith(".env")) continue;
    const full = path.join(HOOKS_ENV_DIR, f);
    let cfg;
    try { cfg = parseEnvFile(full); }
    catch (e) {
      console.warn(`Skip ${f}: ${e.message}`);
      continue;
    }
    const { REPO, SECRET, SCRIPT, WORKFLOW, BRANCH } = cfg;
    if (!REPO || !SECRET || !SCRIPT) {
      console.warn(`Skip ${f}: REPO / SECRET / SCRIPT manquants`);
      continue;
    }
    map[REPO] = {
      secret: SECRET,
      script: SCRIPT,
      workflow: WORKFLOW || null,  // filtre optionnel sur workflow_run.name
      branch:   BRANCH   || null,  // filtre optionnel sur workflow_run.head_branch
      source: f,
    };
  }
  return map;
}

// --- HMAC verify -------------------------------------------------------------

function verifySignature(req, body, secret) {
  const signature = req.headers["x-hub-signature-256"];
  if (!signature) return false;
  const hmac   = crypto.createHmac("sha256", secret);
  const digest = `sha256=${hmac.update(body).digest("hex")}`;
  try {
    return crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(digest));
  } catch {
    return false;
  }
}

// --- HTTP --------------------------------------------------------------------

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

    // Re-charge a chaque requete : pas besoin de restart si on ajoute un hook
    const DEPLOY = loadDeployConfig();

    const repo = data.repository?.full_name;
    if (!repo || !DEPLOY[repo]) {
      console.warn(`Repo non autorise: ${repo}`);
      res.writeHead(400);
      return res.end("Unknown repo");
    }

    const { secret, script, workflow, branch } = DEPLOY[repo];

    if (!verifySignature(req, body, secret)) {
      console.warn(`Signature invalide pour ${repo}`);
      res.writeHead(401);
      return res.end("Invalid signature");
    }

    // Filtre workflow_run :
    //   - action=completed + conclusion=success (sinon : build en cours,
    //     echoue, cancel, etc -> pas de deploy)
    //   - optionnellement le nom du workflow (WORKFLOW= dans le env file)
    //     pour ne matcher qu'un CI precis (eviter les lint/test/scan qui
    //     passent aussi)
    //   - optionnellement la branche (BRANCH=) pour ignorer les runs sur
    //     feature branches / PRs
    if (event === "workflow_run") {
      const action     = data.action;
      const conclusion = data.workflow_run?.conclusion;
      const wfName     = data.workflow_run?.name;
      const wfBranch   = data.workflow_run?.head_branch;

      if (action !== "completed" || conclusion !== "success") {
        console.log(`${repo}: workflow_run ignored (action=${action}, conclusion=${conclusion})`);
        res.writeHead(200);
        return res.end("Ignored: not completed+success");
      }
      if (workflow && wfName !== workflow) {
        console.log(`${repo}: workflow '${wfName}' != WORKFLOW='${workflow}', ignored`);
        res.writeHead(200);
        return res.end(`Ignored: workflow '${wfName}'`);
      }
      if (branch && wfBranch !== branch) {
        console.log(`${repo}: workflow_run branch '${wfBranch}' != BRANCH='${branch}', ignored`);
        res.writeHead(200);
        return res.end(`Ignored: branch '${wfBranch}'`);
      }
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
    const cmd     = `bash "${scriptPath}" >> "${logFile}" 2>&1`;
    exec(cmd, { timeout: 0 }, (err) => {
      if (err) console.error(`${script} exit ${err.code}: ${err.message}`);
      else     console.log(`${script} OK`);
    });
  });
});

server.listen(PORT, "127.0.0.1", () => {
  const initial = loadDeployConfig();
  console.log(`Webhook receiver en ecoute sur 127.0.0.1:${PORT}`);
  console.log(`HOOKS_DIR     = ${HOOKS_DIR}`);
  console.log(`HOOKS_ENV_DIR = ${HOOKS_ENV_DIR}`);
  console.log(`Repos charges au boot: ${Object.keys(initial).join(", ") || "(aucun)"}`);
});
