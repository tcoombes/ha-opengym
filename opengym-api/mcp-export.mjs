// ---------------------------------------------------------------------------
// openGym MCP snapshot exporter
//
// openGym's MCP server is stdio-only: it runs on the machine where your AI
// client runs and reads openGym's data files straight off disk. On Home
// Assistant OS that data sits in the API add-on's private /data, out of
// reach. This copies just what the MCP server reads into a folder your PC
// can see over Samba.
//
// What goes across:
//   state-<uid>.json  each profile's plan, workouts, body weight, settings
//   db.json           reduced to the users list, credentials stripped
//
// What never goes across: secret (session signing key), auth.db (password
// hashes and sessions), vapid.json (push keys), audit.log (sign-in history).
//
// Each file is JSON-parsed before it's copied, and written via a temp file
// plus rename, so the snapshot never holds a half-written file - if openGym
// happens to be mid-write, that file just keeps its previous copy until the
// next run.
//
// Usage: node /mcp-export.mjs <openGym data dir> <snapshot dir>
// ---------------------------------------------------------------------------
import fs from "node:fs";
import path from "node:path";

const [src, dst] = process.argv.slice(2);
if (!src || !dst) {
    console.error("usage: node mcp-export.mjs <data dir> <snapshot dir>");
    process.exit(2);
}

// Keys removed wherever they appear. Broad for db.json (it holds credential
// material); narrow for state files, which are training data and shouldn't
// lose anything the MCP tools need.
const DB_SENSITIVE = /cred|passkey|public.?key|secret|token|push|subscr|invite|hash|password|session/i;
const STATE_SENSITIVE = /secret|token|password|api.?key|credential/i;

function scrub(value, pattern) {
    if (Array.isArray(value)) return value.map((v) => scrub(v, pattern));
    if (value && typeof value === "object") {
        const out = {};
        for (const [k, v] of Object.entries(value)) {
            if (pattern.test(k)) continue;
            out[k] = scrub(v, pattern);
        }
        return out;
    }
    return value;
}

function writeAtomic(file, text) {
    const tmp = `${file}.tmp`;
    fs.writeFileSync(tmp, text);
    fs.renameSync(tmp, file);
}

fs.mkdirSync(dst, { recursive: true });

let copied = 0;
let skipped = 0;

for (const name of fs.readdirSync(src)) {
    if (!/^state-.+\.json$/.test(name)) continue;
    try {
        const data = JSON.parse(fs.readFileSync(path.join(src, name), "utf8"));
        writeAtomic(path.join(dst, name), JSON.stringify(scrub(data, STATE_SENSITIVE)));
        copied++;
    } catch {
        skipped++; // mid-write or unreadable: keep last good copy, retry next run
    }
}

const dbPath = path.join(src, "db.json");
if (fs.existsSync(dbPath)) {
    try {
        const db = JSON.parse(fs.readFileSync(dbPath, "utf8"));
        const users = scrub(db.users || [], DB_SENSITIVE);
        writeAtomic(path.join(dst, "db.json"), JSON.stringify({ users }, null, 2));
    } catch {
        skipped++;
    }
}

// Drop snapshots of profiles that no longer exist on the server.
for (const name of fs.readdirSync(dst)) {
    if (/^state-.+\.json$/.test(name) && !fs.existsSync(path.join(src, name))) {
        fs.unlinkSync(path.join(dst, name));
    }
}

if (skipped) {
    console.log(`[openGym MCP export] ${copied} profile(s) exported, ${skipped} skipped (retrying next run)`);
}
