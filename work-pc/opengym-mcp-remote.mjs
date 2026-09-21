#!/usr/bin/env node
// ---------------------------------------------------------------------------
// openGym MCP over HTTPS - for a PC that isn't on your home network.
//
// openGym's MCP server reads data files from local disk. This wrapper keeps a
// local copy of YOUR profile fresh by pulling it through your normal openGym
// URL with a paired bearer token - the same mechanism the mobile app uses - and
// then launches the real MCP server pointed at that copy.
//
//   node opengym-mcp-remote.mjs pair <CODE>   one-time setup (code from
//                                              Settings -> Pair the mobile app)
//   node opengym-mcp-remote.mjs sync          pull once, to test
//   node opengym-mcp-remote.mjs unpair        delete the saved token
//   node opengym-mcp-remote.mjs               what Claude Desktop runs
//
// Settings (environment variables, all optional):
//   OPENGYM_URL           your instance          default https://gym.tcoombes.co.uk
//   OPENGYM_REPO          openGym checkout       default C:\opengym
//   OPENGYM_SYNC_MINUTES  refresh interval       default 5
//   OPENGYM_HOME          token + data folder    default %LOCALAPPDATA%\opengym-mcp
//
// Only your own profile ever comes down. The token is a login to that profile:
// "Sign out everywhere" in openGym's settings revokes it instantly.
// ---------------------------------------------------------------------------
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";

const BASE = (process.env.OPENGYM_URL || "https://gym.tcoombes.co.uk").replace(/\/+$/, "");
const REPO = process.env.OPENGYM_REPO || "C:\\opengym";
const MINUTES = Math.max(1, Number(process.env.OPENGYM_SYNC_MINUTES) || 5);
const HOME =
    process.env.OPENGYM_HOME ||
    path.join(process.env.LOCALAPPDATA || path.join(os.homedir(), ".local", "share"), "opengym-mcp");
const DATA = path.join(HOME, "data");
const TOKEN_FILE = path.join(HOME, "token.json");
const REV_FILE = path.join(HOME, "rev.json");

// stdout is the MCP protocol channel once the server is running - anything
// else written there corrupts it. Everything human-readable goes to stderr.
const log = (...args) => console.error("[opengym-mcp]", ...args);

function readJson(file) {
    try {
        return JSON.parse(fs.readFileSync(file, "utf8"));
    } catch {
        return null;
    }
}

// Temp file + rename, so the MCP server never reads a half-written file. On
// Windows the rename can briefly fail while the MCP server has the target
// open, so retry a few times before falling back to a direct write.
function writeAtomic(file, text, mode) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const tmp = `${file}.tmp`;
    fs.writeFileSync(tmp, text, mode ? { mode } : undefined);
    for (let i = 0; i < 5; i++) {
        try {
            fs.renameSync(tmp, file);
            return;
        } catch {
            Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100);
        }
    }
    fs.writeFileSync(file, text, mode ? { mode } : undefined);
    fs.rmSync(tmp, { force: true });
}

async function api(method, route, { token, body } = {}) {
    const headers = {};
    if (token) headers.Authorization = `Bearer ${token}`;
    if (body) headers["Content-Type"] = "application/json";
    const res = await fetch(BASE + route, {
        method,
        headers,
        body: body ? JSON.stringify(body) : undefined,
        signal: AbortSignal.timeout(10_000),
    });
    let json = null;
    try {
        json = await res.json();
    } catch {
        // non-JSON (e.g. a proxy error page) - status tells the story
    }
    return { status: res.status, json };
}

async function pair(code) {
    const { status, json } = await api("POST", "/api/pair/redeem", { body: { code } });
    if (status !== 200 || !json?.token) {
        log(`pairing failed (${status}): ${json?.error || "no token returned"}`);
        log("Codes are one-shot and expire after 5 minutes - generate a fresh one and retry.");
        process.exit(1);
    }
    writeAtomic(TOKEN_FILE, JSON.stringify({ token: json.token, user: json.user, server: BASE }), 0o600);
    log(`paired as ${json.user?.name} (${json.user?.id})`);
    log(`token saved to ${TOKEN_FILE} - treat it like a password`);
}

// Returns the user id on success, or null (keep serving the last snapshot).
async function sync() {
    const saved = readJson(TOKEN_FILE);
    if (!saved?.token) {
        log("not paired yet - run: node opengym-mcp-remote.mjs pair <CODE>");
        return null;
    }
    if (saved.server && saved.server !== BASE) {
        log(`warning: token was issued by ${saved.server}, but OPENGYM_URL is ${BASE}`);
    }
    const token = saved.token;

    const me = await api("GET", "/api/me", { token });
    if (me.status === 401) {
        log("token rejected - expired, or 'Sign out everywhere' was used. Re-pair with:");
        log("  node opengym-mcp-remote.mjs pair <CODE>   (serving the last snapshot until then)");
        return null;
    }
    if (me.status !== 200 || !me.json?.user?.id) {
        log(`/api/me answered ${me.status} - serving the last snapshot`);
        return null;
    }
    const { id: uid, name } = me.json.user;
    const stateFile = path.join(DATA, `state-${uid}.json`);

    // Skip the full download when nothing changed. Older servers without
    // /api/data/rev answer 404, and we just fetch the document every time.
    const lastRev = readJson(REV_FILE)?.rev;
    const rev = await api("GET", "/api/data/rev", { token });
    if (
        rev.status === 200 &&
        typeof rev.json?.rev === "number" &&
        rev.json.rev !== 0 &&
        rev.json.rev === lastRev &&
        fs.existsSync(stateFile)
    ) {
        return uid;
    }

    const data = await api("GET", "/api/data", { token });
    if (data.status !== 200) {
        log(`/api/data answered ${data.status} - serving the last snapshot`);
        return null;
    }
    if (data.json?.state) {
        writeAtomic(stateFile, JSON.stringify(data.json.state));
    } else {
        log("the server has no synced state for this profile yet - log something in the app first");
    }
    // The MCP server resolves the profile from db.json; it only needs you in it.
    writeAtomic(path.join(DATA, "db.json"), JSON.stringify({ users: [{ id: uid, name }] }, null, 2));
    writeAtomic(REV_FILE, JSON.stringify({ rev: data.json?.rev ?? null }));
    log(`synced ${name}'s data (rev ${data.json?.rev ?? "?"})`);
    return uid;
}

async function safeSync() {
    try {
        return await sync();
    } catch (e) {
        log(`sync failed: ${e.cause?.code || e.message} - serving the last snapshot`);
        return null;
    }
}

async function serve() {
    const entry = path.join(REPO, "mcp", "src", "index.js");
    if (!fs.existsSync(entry)) {
        log(`openGym MCP server not found at ${entry} - set OPENGYM_REPO to your checkout`);
        process.exit(1);
    }
    fs.mkdirSync(DATA, { recursive: true });

    // With a snapshot on disk, start the MCP server straight away and refresh
    // in the background - Claude Desktop shouldn't wait on the network. On the
    // very first run there's nothing to serve, so pull first.
    const haveSnapshot = fs.readdirSync(DATA).some((f) => /^state-.+\.json$/.test(f));
    let uid = null;
    if (haveSnapshot) {
        safeSync();
    } else {
        uid = await safeSync();
    }
    uid = uid || readJson(TOKEN_FILE)?.user?.id;

    const env = { ...process.env, OPENGYM_DATA: DATA };
    if (uid) env.OPENGYM_UID = uid;

    const child = spawn(process.execPath, [entry], { stdio: "inherit", env });
    const timer = setInterval(safeSync, MINUTES * 60_000);
    child.on("exit", (code, signal) => {
        clearInterval(timer);
        process.exit(code ?? (signal ? 1 : 0));
    });
    for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => child.kill(sig));
}

const [cmd, arg] = process.argv.slice(2);
if (cmd === "pair") {
    if (!arg) {
        log("usage: node opengym-mcp-remote.mjs pair <CODE>");
        process.exit(2);
    }
    await pair(arg.trim());
} else if (cmd === "sync") {
    process.exit((await safeSync()) ? 0 : 1);
} else if (cmd === "unpair") {
    fs.rmSync(TOKEN_FILE, { force: true });
    log("token deleted. To revoke it server-side too, use 'Sign out everywhere' in openGym.");
} else if (cmd) {
    log(`unknown command '${cmd}' - use pair, sync, unpair, or no argument`);
    process.exit(2);
} else {
    await serve();
}
