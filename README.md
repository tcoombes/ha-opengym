# openGym for Home Assistant

A Home Assistant add-on repository that runs [openGym](https://github.com/DuarteSantos8/openGym)
on Home Assistant OS, and keeps itself up to date with upstream releases.

Two add-ons, one per openGym container: **openGym API** and **openGym Web**.
Both wrap upstream's published multi-arch images, so Home Assistant builds a
thin layer on the Pi and there's nothing to compile.

## Repository layout

```
repository.yaml              tells Home Assistant this is an add-on repository
opengym-api/                 the API add-on
opengym-web/                 the web add-on
.github/workflows/
  upstream.yml               daily: track upstream releases, bump, test, ship
  test.yml                   lint + arm64 build + smoke test, on every change
work-pc/                     MCP wrapper for a PC away from home (not an add-on)
nginx/                       reverse-proxy config for your nginx box (not an add-on)
```

## How automatic updates work

Once a day, `upstream.yml` checks upstream's latest stable release. When it's
newer than what's pinned, it:

1. checks both the `api` and `web` images are published **with a
   `linux/arm64` build** - upstream publishes releases slightly before images
   finish, and has once shipped a release whose web image never built;
2. pins both Dockerfiles to it and sets both add-on versions to match, on a
   branch;
3. runs `test.yml` against that branch: lints both add-on configs, builds both
   add-ons **natively on arm64**, starts them the way Supervisor would, and
   checks a request makes it through web -> nginx -> API and back;
4. **passes**: merges to `main` if the repo variable `AUTO_MERGE` is `true`,
   otherwise opens a PR with upstream's release notes for you to merge.
   **Fails**: opens a draft PR marked as failing, and never merges.

When a change lands on `main`, Home Assistant offers the update - or installs
it itself if you switch on **Auto update** on the add-ons' pages.

The smoke test is the important part: it's what catches upstream changing
something the `run.sh` scripts depend on - the start command, nginx template
variables, file paths - before it reaches your Pi. Everything we hit while
first setting this up would have failed it.

### One-time GitHub setup

1. Create the repo **public** (Home Assistant can't authenticate to a private
   add-on repository), push these files, and put its URL in `repository.yaml`.
   The add-on defaults include `gym.tcoombes.co.uk`, which is public in DNS
   anyway.
2. Settings -> Actions -> General -> Workflow permissions: **Read and write
   permissions**, and tick **Allow GitHub Actions to create and approve pull
   requests**.
3. Optional, for fully hands-off: Settings -> Secrets and variables -> Actions
   -> Variables -> new repository variable `AUTO_MERGE` = `true`.
4. Actions tab -> **Test add-ons** -> Run workflow, to confirm the smoke test
   passes on the current pins before relying on it.

Two things GitHub does on its own: scheduled workflows are disabled after 60
days without commits, which the workflow counters by re-enabling itself on
every run; and it emails you when a scheduled run fails.

### Fully hands-off, or review first?

With `AUTO_MERGE` on and **Auto update** on in Home Assistant, a new openGym
release reaches your Pi with nobody looking at it - gated only by the arm64
check and the smoke test. The smoke test proves the add-ons start and talk to
each other; it can't prove a release didn't change behaviour you care about.
Leaving `AUTO_MERGE` off costs you one tap on a PR from the GitHub app, with
the release notes right there. Either way, keep Home Assistant's scheduled
backups on - that's your rollback.

### Changing the add-ons yourself

Edit, commit, push. Raise `version:` in the add-on's `config.yaml` or Home
Assistant won't notice: keep upstream's version and add a fourth part for your
own changes (`1.3.8.1`, `1.3.8.2`). The next upstream bump resets it to plain
`1.3.9`, which is always newer. Use dots only - no `-2` style suffixes.

## Installing

Settings -> Add-ons -> Add-on Store -> top-right menu -> **Repositories** ->
add the repo URL. Install **openGym API**, then **openGym Web**. Start the API
first.

The web add-on finds the API by itself: Home Assistant names add-on hostnames
after the repository they came from, and the web add-on derives its sibling's
name from its own. Its log shows `api host: <prefix>-opengym-api (derived ...)`.

## Migrating from the local add-ons

A repository add-on is a *different* add-on to a local one as far as Home
Assistant is concerned, with its own empty `/data`. Your openGym data -
profiles, passkeys, workouts, the session secret - has to be copied across.
Done properly, nobody notices: same data, same secret, so existing passkeys,
signed-in sessions and the paired work-PC token all keep working.

Nothing here touches the old add-ons' data until the very last step, so it's
reversible up to that point.

1. **Back up.** Settings -> System -> Backups -> create a backup including
   both local openGym add-ons.
2. **Copy your options across.** On the old API add-on's Configuration tab,
   switch to YAML and copy it - options don't migrate.
3. **Install the new pair** from the repository (above). Paste the options into
   the new API add-on. Leave the new web add-on's options alone.
4. **Start the new API once, then stop it.** That creates its container and
   `/data`.
5. **Stop the old web and old API add-ons.** The new web add-on needs port 8080.
6. **Copy the data.** In the Advanced SSH & Web Terminal add-on, turn
   **Protection mode off**, restart it, then:
   ```sh
   NEW=$(docker ps -a --format '{{.Names}}' | grep -E '^addon_[0-9a-f]{8}_opengym_api$')
   echo "$NEW"    # should print exactly one name
   docker cp addon_local_opengym_api:/data/opengym /tmp/opengym-migrate
   docker cp /tmp/opengym-migrate/. "$NEW":/data/opengym/
   rm -rf /tmp/opengym-migrate
   ```
   Then turn Protection mode back **on**.
7. **Start the new API, then the new web.** Check the web log for the derived
   `api host:` line, then sign in at `https://gym.tcoombes.co.uk` - your
   existing passkey should just work. Nothing changes on your nginx: the new web
   add-on is on the same port 8080.
8. **Tidy up**, once you're happy: uninstall the two *local* add-ons (this
   deletes their `/data` - your backup from step 1 still has it), delete
   `/addons/opengym-api` and `/addons/opengym-web`, then Add-on Store -> Check
   for updates.

If `mcp_export` was on, it carries over with the options you pasted in step 3.
The exercise media isn't copied - the new web add-on re-downloads it.

## Reverse proxy

On your nginx box:

- `nginx/gym.tcoombes.co.uk.conf` -> `/etc/nginx/sites-available/`, symlinked
  into `sites-enabled/`
- `nginx/opengym-proxy.conf` -> `/etc/nginx/snippets/`

Replace `HA_PI_IP` with the Pi's address, issue a certificate for
`gym.tcoombes.co.uk`, then `nginx -t && systemctl reload nginx`.

## Verify

```
curl -s https://gym.tcoombes.co.uk/api/health     # {"ok":true,...}
```

If that returns JSON, the proxy, the web add-on and the API add-on are all
talking to each other.

Then open `https://gym.tcoombes.co.uk` on your phone, create a profile, and add
it to the home screen.

## Things that will bite you

**Passkeys need HTTPS and an exact hostname.** `http://<pi-ip>:8080` will never
show a passkey prompt — that's a browser rule, not an openGym one. Over LAN
you'll only get guest mode, which stores data in that browser alone. Test
through the proxy hostname from the start.

**Changing `rp_id` later invalidates every passkey already registered**, because
they were bound to the old hostname. Settle on `gym.tcoombes.co.uk` before
anyone signs up.

**`www` counts as a different hostname.** Don't let the proxy serve both.

**Never uninstall the API add-on to force a refresh.** Uninstalling deletes its
`/data` - every profile, passkey and workout. Restore from a Home Assistant
backup if it happens.

**Anyone who can reach the URL can create a profile** - that's openGym's
default. Register your own profile first, then set `admin_uids`, `invite_only:
true` and `allow_guest: false` on the API add-on (see *Changing openGym's
settings*) and hand out invite codes from the admin dashboard.

## Changing openGym's settings

Upstream configures everything through a `.env` file
(https://opengym.duarte-santos.ch/docs.html#env). Here each of those is an
option on the **openGym API** add-on's Configuration tab instead. Switch on
**Show unused optional configuration options** to see them all; anything left
unset keeps openGym's own default.

| Option                 | openGym setting        |
|------------------------|------------------------|
| `session_days`         | `SESSION_DAYS`         |
| `admin_uids`           | `ADMIN_UIDS`           |
| `invite_only`          | `INVITE_ONLY`          |
| `allow_guest`          | `ALLOW_GUEST`          |
| `audit_log`            | `AUDIT_LOG`            |
| `audit_max`            | `AUDIT_MAX`            |
| `audit_days`           | `AUDIT_DAYS`           |
| `audit_ip`             | `AUDIT_IP`             |
| `vapid_subject`        | `VAPID_SUBJECT`        |
| `coach_disabled`       | `COACH_DISABLED`       |
| `coach_job_timeout_ms` | `COACH_JOB_TIMEOUT_MS` |
| `extra_env`            | anything else, as `KEY=value` entries |

Save, then **restart** the API add-on - options are read at every start, so no
rebuild is needed. The API log lists what it applied.

Upstream settings that are handled differently here:

- `WEB_PORT` - change the host port in the web add-on's **Network** section,
  then update your nginx upstream to match.
- `BACKEND`, `NGINX_PORT`, `RESOLVER` - set automatically by the web add-on.
- `PORT` - the `api_port` option; keep it the same on both add-ons.
- `DATA_DIR` - pinned to `/data/opengym`, deliberately not overridable.

## MCP server (ask Claude about your training)

openGym's MCP server (https://github.com/DuarteSantos8/openGym/blob/main/mcp/README.md)
is stdio-only: your AI client launches it on your own PC, and it reads openGym's
data files directly. On HAOS those files are locked inside the API add-on, so
the add-on can publish a read-only snapshot to HA's `share` folder for it.

The snapshot holds each profile's `state-<uid>.json` and a `db.json` cut down
to user ids and names. The session secret, password hashes, push keys, invites
and the activity log are never copied. It refreshes every 5 minutes by default
(`mcp_export_minutes`), so answers can lag your last set by that much.

### On the Pi

1. API add-on -> Configuration -> set `mcp_export: true` -> Save -> restart.
2. Check `\\homeassistant\share\opengym-mcp` from Windows Explorer. You should
   see `db.json` and a `state-...json` per profile. Tick **Remember my
   credentials** when Explorer asks - Claude Desktop runs as you and reuses
   them.
3. Your user id is in that `db.json` - the same id `admin_uids` wants.

### On your Windows PC

```powershell
winget install OpenJS.NodeJS.LTS
git clone --depth 1 --branch v1.3.2 https://github.com/DuarteSantos8/openGym C:\opengym
cd C:\opengym\mcp
npm install
```

The whole repo is needed, not just `mcp/`, because the MCP server imports the
frontend's own calculation code. Check out the tag matching your server version
so the numbers match the app; if that tag name isn't found, drop `--branch`.

Test it before involving Claude:

```powershell
$env:OPENGYM_DATA = "\\homeassistant\share\opengym-mcp"
$env:OPENGYM_UID  = "<your-uid>"
node src\index.js
```

It should print `serving profile <name>` and then wait. Ctrl+C to stop.

### Claude Desktop

Edit `%APPDATA%\Claude\claude_desktop_config.json` - backslashes doubled, and
no `//` comments, since upstream's example has one and JSON doesn't allow it:

```json
{
  "mcpServers": {
    "opengym": {
      "command": "node",
      "args": ["C:\\opengym\\mcp\\src\\index.js"],
      "env": {
        "OPENGYM_DATA": "\\\\homeassistant\\share\\opengym-mcp",
        "OPENGYM_UID": "<your-uid>"
      }
    }
  }
}
```

Quit Claude Desktop fully from the system tray and reopen it. The eight
openGym tools should appear.

### From outside your home network (e.g. at work)

The Samba snapshot only works on your LAN. Anywhere else, use
`work-pc/opengym-mcp-remote.mjs` instead: Claude Desktop launches it, it pulls
**your own profile** through `https://gym.tcoombes.co.uk` with a paired bearer
token (the same mechanism openGym's mobile app uses), starts the real MCP
server on that local copy, and refreshes every 5 minutes while Claude runs.
Nothing new is exposed on your nginx, and only your profile leaves the server.

Install Node, clone the repo and `npm install` in `mcp\` exactly as above, then
copy `opengym-mcp-remote.mjs` to e.g. `C:\opengym-remote\`.

1. In openGym in any signed-in browser: Settings -> **Pair the mobile app**.
   The code is valid for 5 minutes.
2. On the work PC:
   ```powershell
   node C:\opengym-remote\opengym-mcp-remote.mjs pair K7WQ2MZP
   node C:\opengym-remote\opengym-mcp-remote.mjs sync
   ```
   The second line should report `synced Tom's data`.
3. Claude Desktop config (`%APPDATA%\Claude\claude_desktop_config.json`):
   ```json
   {
     "mcpServers": {
       "opengym": {
         "command": "node",
         "args": ["C:\\opengym-remote\\opengym-mcp-remote.mjs"],
         "env": {
           "OPENGYM_URL": "https://gym.tcoombes.co.uk",
           "OPENGYM_REPO": "C:\\opengym"
         }
       }
     }
   }
   ```
   The token is deliberately *not* in this file - it lives in
   `%LOCALAPPDATA%\opengym-mcp\token.json`, private to your Windows account.

If you only ever use the MCP server away from home, set `mcp_export: false` on
the API add-on - the Samba snapshot is no longer needed.

The token is a login to your openGym profile. It lasts `SESSION_DAYS` (90 by
default), after which the wrapper logs that it needs re-pairing and keeps
serving the last snapshot. "Sign out everywhere" in openGym revokes it
immediately. If your work network forces traffic through a proxy or TLS
inspection, Node needs `HTTPS_PROXY` / `NODE_EXTRA_CA_CERTS` set accordingly.

### Worth knowing

- The snapshot holds *every* profile's training data, so anyone with access to
  the Samba share can read the household's workouts. `OPENGYM_UID` scopes what
  the MCP server answers about, not what's in the folder.
- Whatever the tools return is sent to your AI provider as part of the chat.
- When you update the add-ons, `git pull` / re-clone the matching tag too.

## Backups

openGym's data lives at `/data/opengym` inside the API add-on — profiles,
passkeys and history. That's the add-on's persistent volume, so it's already
included in Home Assistant's own backups and survives add-on rebuilds and HAOS
updates. Nothing extra to schedule.

The exercise media is cached separately at `/data/media` in the web add-on and
is re-downloadable, so it doesn't need backing up.

## Exercise media

Upstream fetches the exercise images with a separate one-shot `media` compose
service. Here the web add-on does the same job itself on first start: it clones
the dataset into `/data/media` in the background and serves it from there, so
it downloads once and survives rebuilds. The UI is usable immediately and the
images appear when the log says `exercise media ready`.

If the download fails it retries on the next start. The media is excluded from
Home Assistant backups (`backup_exclude`) because it re-downloads automatically
after a restore.

The images and GIFs are (c) Gym visual, used under the exercises-dataset terms.
openGym doesn't redistribute them and neither does this add-on - fine for your
own instance, not for reuse elsewhere.
