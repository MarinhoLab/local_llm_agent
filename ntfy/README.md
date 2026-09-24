# ntfy — per-PC self-hosted push server

A small [ntfy](https://ntfy.sh) server for **this PC only**, so the Agent
Canvas notifier (`agent_canvas_native/ntfy_notifier.py`) can push
"your agent finished / errored / needs input" notifications to your phone.

One of these runs on every PC that runs Agent Canvas. Each instance is
independent: own data, own access token, own topic(s) — no cross-machine
coordination. Phones subscribe to each PC's server over **Tailscale**.

```
 PC A (mac.tail)                     PC B (laptop.tail)
 ┌─────────────────────────┐         ┌─────────────────────────┐
 │ Agent Canvas  :8020      │         │ Agent Canvas  :8020      │
 │ ntfy server   :2020      │         │ ntfy server   :2020      │
 │ notifier → 127.0.0.1:2020│         │ notifier → 127.0.0.1:2020│
 └─────────────────────────┘         └─────────────────────────┘
            ▲                                  ▲
            │  Tailscale (WireGuard-encrypted) │
            └──────────────────────────────────┘
                                 phone
        ntfy app subscribed to http://mac.tail:2020/<topic-A>
                          and http://laptop.tail:2020/<topic-B>
```

## Quick start (on each PC)

```bash
# 1. configure
cd ntfy
cp example.env .env
#    edit .env: set NTFY_BASE_URL=http://<this-pc>.tail:<NTFY_PORT>

# 2. start (Docker required on this PC)
docker compose up -d
docker compose ps        # ntfy should be "healthy"
```

The notifier (`agent_canvas_native/`) and the phone both talk to the **same**
`NTFY_PORT`; the notifier reaches it on `127.0.0.1`, the phone over Tailscale.

> **`command: serve` is required.** The official image's `ENTRYPOINT` is bare
> `ntfy` with no default subcommand, so without it the container prints the CLI
> help and exits (that's the symptom if `docker compose logs ntfy` shows a
> usage screen instead of startup logs). `compose.yml` already sets it.

## Authentication (how to secure the server)

**Default — no account auth (recommended for this repo).** The server runs
without a user database, and the **unguessable topic name is the credential** —
the same model ntfy.sh uses for its public topics. Your protection is
Tailscale reachability + a long random `NTFY_TOPIC`. The notifier publishes
with no token, so `NTFY_AUTH_TOKEN` stays empty. This is the path the rest of
the docs assume.

**Optional — account auth (users, ACLs, access tokens).** If you want the
stronger model, do this:

1. In `ntfy/.env`, set `NTFY_AUTH_FILE=/var/lib/ntfy/user.db`, then
   `docker compose up -d`. The user DB is created on the `ntfy-auth` volume.
2. Create a user and an access token (verified commands):
   ```bash
   docker compose exec -e NTFY_PASSWORD=<choose-a-password> ntfy \
     ntfy user add --role=admin agent-canvas
   docker compose exec ntfy ntfy token add agent-canvas
   # -> prints a token like  tk_...
   ```
3. Put that token in `agent_canvas_native/.env` as `NTFY_AUTH_TOKEN`.
4. (Recommended) lock the server so anonymous access is denied:
   ```bash
   docker compose exec ntfy ntfy access --help   # see syntax
   ```

> The `ntfy token create` command does not exist in the current CLI (it is
> `add`), and `add`/`user` require an `auth-file` to be configured — hence
> step 1 above.

## Subscribe on your phone

Install the [ntfy app](https://ntfy.sh) (Android: Play Store or F-Droid;
iOS: App Store), then subscribe to this PC's topic URL:

```
http://<this-pc>.tail:2020/<NTFY_TOPIC>
```

`<NTFY_TOPIC>` is the topic from `agent_canvas_native/.env`
(`NTFY_TOPIC=`). Pick something unguessable — on a private server the topic
name is part of the access control.

**Android** — the app uses *instant delivery* by default on self-hosted
servers: a small persistent foreground service keeps a live connection, so
messages arrive immediately even with the screen off. (You can see the
service as a permanent "ntfy" notification; long-press it to change settings.
The F-Droid build does exactly this and always.)

**iOS** — Apple restricts background networking, so the standard app can only
wake your phone through a relay. Our compose file sets
`NTFY_UPSTREAM_BASE_URL=https://ntfy.sh` for exactly this: your server
forwards a tiny *poll request* to ntfy.sh, which pings your iOS app via
APNs; the app then fetches the real message from *your* server. The message
content stays private; only a poll marker transits ntfy.sh. (If you ever hit
ntfy.sh's upstream rate limits with many PCs, run a shared ntfy.sh account /
set `NTFY_UPSTREAM_ACCESS_TOKEN`.)

**Deep links** — when you tap a notification, the app opens the URL in the
`X-Click` header, i.e. `http://<this-pc>.tail:8020/conversations/<id>`. Your
phone just needs to be on Tailscale (it is, by definition) and the Agent
Canvas port 8020 reachable on that PC.

## Security notes

- Reachability: allow the port only on the Tailscale interface (or rely on
  WireGuard encryption alone if you accept the trade-off). The server
  otherwise answers plain HTTP.
- The message cache (`/var/cache/ntfy`) is retained on the named Docker
  volume; it contains past notification text. Treat the volume like any other
  local state — it is git-ignored and local.
- To stop the server: `docker compose down`. To wipe its state:
  `docker compose down -v`.

## Upgrading

`docker compose pull && docker compose up -d` — the `ntfy-data` volume keeps
the message cache and attachments across upgrades.

## Advanced: Firebase / custom Android APK

The standard ntfy Android app does **not** use Firebase for self-hosted
servers (instant delivery instead). If you specifically want Firebase-based
push on a self-hosted server, ntfy supports a `firebase-key-file` config, but
it only works with a **custom-built ntfy Android APK** — so it is not the
default here. The iOS relay above is the supported cross-platform path for
the stock apps.
