#!/usr/bin/env node
// GitHub webhooks receiver.
//
// Sources :
//  - process.env.HOOKS_ENV_DIR (default /etc/secrets/webhooks/) :
//    un .env par hook, chacun contenant REPO, WEBHOOK_SECRET, SCRIPT.
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
    const { REPO, WEBHOOK_SECRET, SCRIPT, WORKFLOW, BRANCH, GIT_PROVIDER } = cfg;
    if (!REPO || !WEBHOOK_SECRET || !SCRIPT || !GIT_PROVIDER) {
      console.warn(`Skip ${f}: REPO / WEBHOOK_SECRET / SCRIPT / GIT_PROVIDER manquants`);
      continue;
    }
    const providerLower = GIT_PROVIDER.toLowerCase();
    if (providerLower !== "github" && providerLower !== "gitlab") {
      console.warn(`Skip ${f}: GIT_PROVIDER='${GIT_PROVIDER}' inconnu (attendu: github | gitlab)`);
      continue;
    }
    map[REPO] = {
      secret: WEBHOOK_SECRET,
      script: SCRIPT,
      provider: providerLower,
      workflow: WORKFLOW || null,  // github: filtre sur workflow_run.name
      branch:   BRANCH   || null,  // github: filtre sur workflow_run.head_branch
      source: f,
    };
  }
  return map;
}

// --- Replay protection (dedup X-GitHub-Delivery, TTL 1h) -------------------

const DELIVERY_TTL_MS = 60 * 60 * 1000;
const seenDeliveries  = new Map(); // deliveryId -> insertion timestamp ms

function isDuplicateDelivery(id) {
  if (!id) return false;
  const now = Date.now();
  for (const [k, ts] of seenDeliveries) if (now - ts > DELIVERY_TTL_MS) seenDeliveries.delete(k);
  if (seenDeliveries.has(id)) return true;
  seenDeliveries.set(id, now);
  return false;
}

// --- Auth verify (GitHub HMAC / GitLab plain token) -------------------------

function verifyGithubSignature(req, body, secret) {
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

function verifyGitlabToken(req, secret) {
  // GitLab envoie le secret en clair dans X-Gitlab-Token et attend une
  // comparaison stricte. Pas de HMAC, mais timing-safe quand meme.
  const token = req.headers["x-gitlab-token"];
  if (!token) return false;
  try {
    const a = Buffer.from(token);
    const b = Buffer.from(secret);
    if (a.length !== b.length) return false;
    return crypto.timingSafeEqual(a, b);
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
    // Detection du provider par headers (GitLab envoie x-gitlab-event,
    // GitHub envoie x-github-event). Si aucun, on rejette.
    const githubEvent = req.headers["x-github-event"];
    const gitlabEvent = req.headers["x-gitlab-event"];
    const incomingProvider = githubEvent ? "github" : (gitlabEvent ? "gitlab" : null);
    if (!incomingProvider) {
      res.writeHead(400);
      return res.end("Missing X-GitHub-Event or X-Gitlab-Event");
    }

    let data;
    try { data = JSON.parse(body); }
    catch {
      res.writeHead(400);
      return res.end("Invalid JSON");
    }

    // Ping events : early-return sans auth (pour le test de config)
    if (incomingProvider === "github" && githubEvent === "ping") {
      console.log("github ping from", data.repository?.full_name || "?");
      res.writeHead(200);
      return res.end("pong");
    }

    // Re-charge a chaque requete : pas besoin de restart si on ajoute un hook
    const DEPLOY = loadDeployConfig();

    // Extraction du slug repo selon le provider
    //   GitHub : data.repository.full_name   (ex: "aliceout/Work-resume")
    //   GitLab : data.project.path_with_namespace (ex: "riana/mon-projet")
    const repo = incomingProvider === "gitlab"
      ? data.project?.path_with_namespace
      : data.repository?.full_name;

    if (!repo || !DEPLOY[repo]) {
      console.warn(`Repo non autorise: ${repo}`);
      res.writeHead(400);
      return res.end("Unknown repo");
    }

    const { secret, script, provider: configProvider, workflow, branch } = DEPLOY[repo];

    // Sanity : si la config dit "github" mais on recoit un event GitLab
    // (ou inverse), refuse. Protege contre un mis-cable de webhook cote
    // forge (secret + URL d'un autre provider).
    if (configProvider !== incomingProvider) {
      console.warn(`Mismatch provider pour ${repo}: config=${configProvider} vs event=${incomingProvider}`);
      res.writeHead(400);
      return res.end("Provider mismatch");
    }

    // Auth selon le provider
    let authOK = false;
    if (incomingProvider === "github") {
      authOK = verifyGithubSignature(req, body, secret);
    } else if (incomingProvider === "gitlab") {
      authOK = verifyGitlabToken(req, secret);
    }
    if (!authOK) {
      console.warn(`Auth invalide pour ${repo} (${incomingProvider})`);
      res.writeHead(401);
      return res.end("Invalid auth");
    }

    // Dedup post-auth : refuse de rejouer un meme X-GitHub-Delivery sur la
    // fenetre TTL. Pas applicable a GitLab (pas d'equivalent natif).
    if (incomingProvider === "github") {
      const deliveryId = req.headers["x-github-delivery"];
      if (isDuplicateDelivery(deliveryId)) {
        console.warn(`${repo}: duplicate delivery ${deliveryId}, ignored`);
        res.writeHead(200);
        return res.end("Ignored: duplicate delivery");
      }
    }

    // Filtre CI (workflow_run GitHub / Pipeline Hook GitLab) :
    //   Ne deploie que sur build reussi (completed + success). Optionnel :
    //   filtre sur nom du workflow (WORKFLOW=) et branche (BRANCH=) pour
    //   ne pas declencher sur chaque CI qui passe (lint, test, etc.) ou
    //   sur chaque feature branch.
    if (incomingProvider === "github" && githubEvent === "workflow_run") {
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

    if (incomingProvider === "gitlab" && gitlabEvent === "Pipeline Hook") {
      // GitLab Pipeline Hook : data.object_attributes.status, ref, name
      const status   = data.object_attributes?.status;
      const plName   = data.object_attributes?.name || data.object_attributes?.pipeline_name;
      const plBranch = data.object_attributes?.ref;

      if (status !== "success") {
        console.log(`${repo}: pipeline ignored (status=${status})`);
        res.writeHead(200);
        return res.end("Ignored: pipeline not success");
      }
      if (workflow && plName && plName !== workflow) {
        console.log(`${repo}: pipeline '${plName}' != WORKFLOW='${workflow}', ignored`);
        res.writeHead(200);
        return res.end(`Ignored: pipeline '${plName}'`);
      }
      if (branch && plBranch !== branch) {
        console.log(`${repo}: pipeline branch '${plBranch}' != BRANCH='${branch}', ignored`);
        res.writeHead(200);
        return res.end(`Ignored: branch '${plBranch}'`);
      }
    }

    const scriptPath = path.join(HOOKS_DIR, script);
    if (!fs.existsSync(scriptPath)) {
      console.error(`Script introuvable: ${scriptPath}`);
      res.writeHead(500);
      return res.end("Hook script missing");
    }

    const eventTag = githubEvent || gitlabEvent || "?";
    console.log(`${repo} OK (provider=${incomingProvider}, event=${eventTag}) -> ${script}`);
    res.writeHead(200);
    res.end("Deploy started");

    const logFile = path.join(LOG_DIR, `${repo.replace(/\//g, "_")}.log`);
    const cmd     = `bash "${scriptPath}" >> "${logFile}" 2>&1`;
    // Timeout 30 min : un hook qui hang (docker pull stalled, network KO,
    // git clone bloque) laissait sinon un zombie pour toujours -- timeout: 0
    // signifie 'pas de timeout'. 30 min couvre les deploys les plus lourds.
    const HOOK_TIMEOUT_MS = 30 * 60 * 1000;
    exec(cmd, { timeout: HOOK_TIMEOUT_MS, killSignal: "SIGTERM" }, (err) => {
      if (err) {
        if (err.killed && err.signal === "SIGTERM") {
          console.error(`${script} TIMEOUT after ${HOOK_TIMEOUT_MS / 60000} min, killed`);
        } else {
          console.error(`${script} exit ${err.code}: ${err.message}`);
        }
      } else {
        console.log(`${script} OK`);
      }
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
