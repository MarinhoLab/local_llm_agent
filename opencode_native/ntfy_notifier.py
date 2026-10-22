#!/usr/bin/env python3
"""ntfy_notifier.py — push OpenCode session status changes to ntfy.

A small daemon that watches a local `opencode serve` instance (its HTTP API)
and publishes ntfy notifications when a session transitions into a state of
interest: a turn finished (idle), a permission/question prompt is waiting for
you, the model errored, or a request is stuck in the retry loop.

It is dependency-free (Python stdlib only) so it runs on any PC next to
OpenCode without a venv. It speaks to opencode's HTTP API
and derives the statuses opencode does
not expose directly (finished vs. error, needs-input) from the primitives it
does: /session/status, /permission, /question and the last assistant message.

Configuration (environment variables, normally set in opencode_native/.env by
run.sh):

    NTFY_ENABLED=false        # set true to run this daemon
    NTFY_SERVER=http://127.0.0.1:2020   # or https://ntfy.sh for the public server
    NTFY_TOPIC=opencode       # topic to publish to (unguessable!)
    NTFY_AUTH_TOKEN=          # access token for a protected/self-hosted server
    NTFY_TOPIC_MODE=shared    # shared | one-per-PC | one-per-conv
    NTFY_HOSTNAME=            # machine label, default: os hostname
    NTFY_DEEP_LINK_BASE=http://mac.tail:4096
                              # reachable URL of the web UI; taps open
                              # <base>/server/<key>/session/<id>. Defaults to
                              # NTFY_BASE_URL (localhost form). Set this to the
                              # exact host:port the browser saved the server
                              # under, or taps will not find it.
    NTFY_DEEP_LINK_PREFIX=    # alternative: literal prefix, session id appended
                              # (wins over BASE; for non-default UI routings)
    NTFY_POLL_SECONDS=5       # poll interval
    NTFY_COOLDOWN_SECONDS=120 # per-(session,status) re-notify cooldown
    NTFY_MAX_BODY=4000        # max message body chars (ntfy hard limit is 4096B)
    NTFY_PRIORITIES=finished=3,error=5,waiting_for_input=4,retrying=2
    NTFY_EVENTS=              # comma list of statuses to notify on
                              # (default: finished,error,waiting_for_input)
    NTFY_INCLUDE_MESSAGE=true # include a snippet of the last agent message
    NTFY_DRY_RUN=false        # true = run the loop but publish nothing
    NTFY_STATE_FILE=...       # state json; run.sh uses <state>/ntfy_notifier_state.json
    NTFY_BASE_URL=http://127.0.0.1:4096    # the opencode server to watch

Server credentials (HTTP basic auth, read never printed) in this order:
  1. $OPENCODE_SERVER_PASSWORD (+ $OPENCODE_SERVER_USERNAME, default 'opencode')
  2. $NTFY_SERVER_USER / $NTFY_SERVER_PASSWORD

State (last-seen status per session, with timestamps for cooldowns) lives in
<state_dir>/ntfy_notifier_state.json next to the stack's other state, so
nothing depends on memory across restarts.

Signal handling: SIGTERM/SIGINT stop the loop cleanly; SIGUSR1 (re)publishes
the current status snapshot for every watched session (useful to re-test the
pipeline after changing phone settings).

Note: run.sh only starts this daemon when NTFY_ENABLED is true, and only in
server mode (the TUI spawns its own private server on a random port). To test
the pipeline without turning notifications on permanently, run it by hand with
NTFY_DRY_RUN=true: nothing is published, and with no NTFY_STATE_FILE no state
is written.
"""

from __future__ import annotations

import base64
import json
import os
import signal
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

VERSION = "1.0.0"

# ntfy hard limit: messages longer than 4096 bytes become attachments.
NTFY_MESSAGE_LIMIT = 4096

# Statuses this notifier synthesizes. OpenCode reports only whether a session
# is *doing something* (/session/status), so 'finished', 'error' and 'idle'
# are derived from the last assistant message; 'waiting_for_input' and
# 'retrying' come from /permission, /question and the retry state.
KNOWN_STATUSES = {
    "running",           # the model is streaming / a tool is executing
    "waiting_for_input", # a permission or question request is pending
    "retrying",          # the server is backing off on a failing request
    "finished",          # a turn ended with assistant output — ball is with you
    "error",             # the last assistant message carries an error
    "idle",              # session exists but has produced no assistant output
}

# 'running' and 'idle' are tracked but not notified by default: they are the
# baseline every transition is measured against, and neither needs you.
DEFAULT_EVENTS = {
    "finished",
    "error",
    "waiting_for_input",
}

# status -> (title, priority, tags, emoji prefix)
NOTIFICATION_PRESETS = {
    "finished": ("Agent finished a turn — needs your input", 3, "eyes,robot", "👀"),
    "waiting_for_input": ("Agent is waiting for your approval", 4, "warning,robot", "🚦"),
    "error": ("Agent hit an error", 5, "rotating_light,robot", "🚨"),
    "retrying": ("Agent request is retrying", 2, "arrows_counterclockwise,robot", "🔁"),
    "running": ("Agent started running", 2, "rocket,robot", "🚀"),
    "idle": ("Agent session is idle", 2, "zzz,robot", "💤"),
}


# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------


def env(key: str, default: str = "") -> str:
    return os.environ.get(key, "").strip() or default


def env_bool(key: str, default: bool = False) -> bool:
    raw = os.environ.get(key, "").strip().lower()
    if not raw:
        return default
    return raw in ("1", "true", "yes", "on")


def log(msg: str) -> None:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    print(f"[ntfy_notifier {ts}] {msg}", flush=True)


def parse_priorities(raw: str) -> dict[str, int]:
    """Parse `idle=3,finished=3,error=5,...` into {status: priority}.

    Empty/malformed entries are skipped with a warning so one typo in .env
    cannot take the notifier down.
    """
    out: dict[str, int] = {}
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        status, sep, value = item.partition("=")
        try:
            out[status.strip()] = int(value) if sep else int(status)
        except ValueError:
            log(f"WARNING: ignoring malformed NTFY_PRIORITIES entry {item!r}")
    return out


def rfc2047_header(value: str) -> str:
    """Encode a header value as RFC 2047 if it can't be sent as latin-1.

    HTTP headers are ISO-8859-1, so arbitrary Unicode (an em dash, a non-ASCII
    session title) must be encoded. ntfy decodes RFC 2047 on Title/Tags.
    """
    try:
        value.encode("latin-1")
        return value
    except UnicodeEncodeError:
        b64 = base64.b64encode(value.encode("utf-8")).decode("ascii")
        return f"=?UTF-8?B?{b64}?="


def http_request(
    url: str,
    method: str = "GET",
    headers: dict | None = None,
    body: bytes | None = None,
    timeout: int = 15,
) -> tuple[int, bytes]:
    req = urllib.request.Request(url, data=body, method=method)
    for k, v in (headers or {}).items():
        if v:
            req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise ConnectionError(str(e)) from e


# ---------------------------------------------------------------------------
# opencode server
# ---------------------------------------------------------------------------


class OpenCodeServer:
    """Read-only view of an `opencode serve` instance.

    Endpoints used (verified against opencode 1.18.30, see the README's
    Troubleshooting table for what to check when they change):
      GET /global/health, /session, /session/status, /permission, /question,
      /session/{id}/message
    """

    def __init__(self, base_url: str, username: str = "", password: str = ""):
        self.base_url = base_url.rstrip("/")
        self.auth = None
        if password:
            token = base64.b64encode(f"{username or 'opencode'}:{password}".encode()).decode()
            self.auth = f"Basic {token}"

    def _headers(self) -> dict:
        return {"Authorization": self.auth} if self.auth else {}

    def _get(self, path: str):
        status, body = http_request(self.base_url + path, headers=self._headers())
        if status != 200:
            raise RuntimeError(f"GET {path} failed: HTTP {status} ({body[:200]!r})")
        return json.loads(body or b"null")

    def health(self) -> str:
        """Return the server version, or '' if it is not answering."""
        try:
            data = self._get("/global/health")
        except (ConnectionError, RuntimeError, ValueError):
            return ""
        return (data or {}).get("version", "") if isinstance(data, dict) else ""

    def list_sessions(self) -> list[dict]:
        data = self._get("/session")
        return data if isinstance(data, list) else []

    def status_map(self) -> dict:
        """{sessionID: {"type": "busy"|"retry"|..., ...}} for active sessions.

        A session absent from this map is idle (opencode only reports sessions
        that are doing something).
        """
        data = self._get("/session/status")
        return data if isinstance(data, dict) else {}

    def pending_requests(self) -> tuple[dict[str, int], dict[str, int]]:
        """({sessionID: n_pending_permissions}, {sessionID: n_pending_questions})."""
        perms: dict[str, int] = {}
        questions: dict[str, int] = {}
        for path, bucket in (("/permission", perms), ("/question", questions)):
            try:
                data = self._get(path)
            except (ConnectionError, RuntimeError, ValueError):
                # /permission and /question exist on `opencode serve` (verified
                # on 1.18.30), but a server that lacks them should degrade to
                # "no pending prompt" rather than kill the daemon.
                continue
            if not isinstance(data, list):
                continue
            for item in data:
                sid = item.get("sessionID") if isinstance(item, dict) else None
                if sid:
                    bucket[sid] = bucket.get(sid, 0) + 1
        return perms, questions

    def last_message(self, session_id: str, limit: int = 10) -> tuple[str, str]:
        """Return (text, error) for the newest assistant message of a session.

        error is the APIError message when the assistant message carries one,
        else ''. Text is the concatenated text parts (or the error text, so an
        error notification still says something useful).
        """
        try:
            msgs = self._get(f"/session/{session_id}/message?limit={limit}")
        except (ConnectionError, RuntimeError, ValueError):
            return "", ""
        if not isinstance(msgs, list):
            return "", ""
        assistants = [m for m in msgs if isinstance(m, dict)
                      and (m.get("info") or {}).get("role") == "assistant"]
        if not assistants:
            return "", ""
        info = assistants[-1].get("info") or {}
        err = info.get("error") or {}
        err_msg = ""
        if isinstance(err, dict) and err:
            err_msg = str((err.get("data") or {}).get("message") or err.get("name") or "error")
        parts = assistants[-1].get("parts") or []
        texts = [str(p.get("text", "")) for p in parts
                 if isinstance(p, dict) and p.get("type") == "text"]
        text = "\n".join(t for t in texts if t).strip()
        return text, err_msg


# ---------------------------------------------------------------------------
# ntfy publisher
# ---------------------------------------------------------------------------


class NtfyPublisher:
    def __init__(
        self,
        server: str,
        topic: str,
        token: str = "",
        topic_mode: str = "shared",
        hostname: str = "",
        deep_link_prefix: str = "",
        deep_link_base: str = "",
        max_body: int = 4000,
        dry_run: bool = False,
        priorities: dict[str, int] | None = None,
    ):
        self.server = server.rstrip("/")
        self.base_topic = topic.strip()
        self.token = token
        self.topic_mode = topic_mode
        self.hostname = hostname
        self.deep_link_prefix = deep_link_prefix.rstrip("/")
        self.deep_link_base = deep_link_base.rstrip("/")
        self.max_body = max_body
        self.dry_run = dry_run
        self.priorities = priorities or {}

    def _auth_headers(self) -> dict:
        # ntfy accepts Bearer for access tokens.
        return {"Authorization": f"Bearer {self.token}"} if self.token else {}

    def _topic_for(self, session: dict) -> str:
        if self.topic_mode == "one-per-conv":
            return f"{self.base_topic}-{session['id'][:8]}"
        return self.base_topic

    def click_url(self, session: dict) -> str:
        """Tap-to-open URL for a session.

        OpenCode's web UI serves a session at
        ``<base>/server/<serverKey>/session/<id>``, where the UI itself
        derives ``serverKey`` from the server URL as base64url without padding
        (see ``cn()`` in the UI bundle). Deriving it here from the same base
        the user configured is what makes the link resolve to the server entry
        the browser saved — a hand-written prefix cannot do that, so
        ``NTFY_DEEP_LINK_BASE`` is the normal setting; ``NTFY_DEEP_LINK_PREFIX``
        is the escape hatch that wins when set, for non-default UI routings.
        """
        sid = session["id"]
        if self.deep_link_prefix:
            return f"{self.deep_link_prefix}/{sid}"
        if self.deep_link_base:
            key = base64.urlsafe_b64encode(
                self.deep_link_base.encode("utf-8")
            ).decode("ascii").rstrip("=")
            return f"{self.deep_link_base}/server/{key}/session/{sid}"
        return ""

    def publish(self, session: dict, status: str, snippet: str = "") -> None:
        preset = NOTIFICATION_PRESETS.get(status)
        if preset is None:
            title, priority, tags, emoji = f"Agent status: {status}", 2, "robot", "•"
        else:
            title, priority, tags, emoji = preset
        priority = max(1, min(5, self.priorities.get(status, priority)))

        sess_title = (session.get("title") or session["id"][:12]).strip()
        if sess_title and sess_title != session["id"][:12]:
            title = f"{title} — {sess_title}"
        if self.hostname:
            title = f"{self.hostname}: {title}"

        headers = {
            "Title": rfc2047_header(title),
            "Priority": str(priority),
            "Tags": rfc2047_header(tags),
            **self._auth_headers(),
        }
        click = self.click_url(session)
        if click:
            headers["Click"] = click

        body = snippet.strip() or f"{emoji} {status}"
        if len(body) > self.max_body:
            body = body[: self.max_body - 1] + "…"

        topic = self._topic_for(session)
        url = f"{self.server}/{topic}"
        if self.dry_run:
            log(
                f"DRY-RUN publish to {url} :: title={title!r} priority={priority} "
                f"tags={tags} click={headers.get('Click')} body={body[:80]!r}"
            )
            return

        code, _ = http_request(url, method="PUT", headers=headers,
                               body=body.encode("utf-8"))
        if code >= 400:
            # Do not dump the body — it may echo back our auth header.
            log(f"WARN: ntfy publish failed HTTP {code}")
        else:
            log(f"published {status} for session {session['id'][:12]} "
                f"(topic={topic}, priority={priority}"
                + (f", click={click}" if click else "") + ")")


# ---------------------------------------------------------------------------
# state
# ---------------------------------------------------------------------------


def load_state(path: Path) -> dict:
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict) and isinstance(data.get("sessions"), dict):
            return data
    except (OSError, json.JSONDecodeError):
        pass
    return {"sessions": {}}


def save_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2)
    os.replace(tmp, path)


# ---------------------------------------------------------------------------
# notifier
# ---------------------------------------------------------------------------


class Notifier:
    def __init__(self):
        self.base_url = env("NTFY_BASE_URL", "http://127.0.0.1:4096")
        self.poll_seconds = float(env("NTFY_POLL_SECONDS", "5") or 5)
        self.cooldown = float(env("NTFY_COOLDOWN_SECONDS", "120") or 120)
        self.include_message = env_bool("NTFY_INCLUDE_MESSAGE", True)
        self.dry_run = env_bool("NTFY_DRY_RUN", False)
        state_file = env("NTFY_STATE_FILE")
        self.state_path = Path(state_file) if state_file else None

        raw_events = env("NTFY_EVENTS", "")
        if raw_events:
            self.events = {s.strip() for s in raw_events.split(",") if s.strip()}
            unknown = self.events - KNOWN_STATUSES
            if unknown:
                log(f"WARNING: unknown status(es) in NTFY_EVENTS: {unknown}")
        else:
            self.events = set(DEFAULT_EVENTS)

        self.priorities = parse_priorities(env("NTFY_PRIORITIES", ""))

        # The web UI keys its saved servers on the exact URL string the
        # browser used, so the default deep-link base has to match what
        # run.sh advertises (localhost) rather than the 127.0.0.1 API host
        # this daemon polls.
        default_base = env(
            "NTFY_DEEP_LINK_BASE",
            self.base_url.replace("//127.0.0.1:", "//localhost:"),
        )

        self.publisher = NtfyPublisher(
            server=env("NTFY_SERVER", "http://127.0.0.1:2020"),
            topic=env("NTFY_TOPIC", "opencode"),
            token=env("NTFY_AUTH_TOKEN", ""),
            topic_mode=env("NTFY_TOPIC_MODE", "shared"),
            hostname=self._hostname(),
            deep_link_prefix=env("NTFY_DEEP_LINK_PREFIX", ""),
            deep_link_base=default_base,
            max_body=int(env("NTFY_MAX_BODY", str(min(4000, NTFY_MESSAGE_LIMIT))) or 4000),
            dry_run=self.dry_run,
            priorities=self.priorities,
        )

        self._stop = False
        self._signal = 0
        self._force_all = False
        self.server: OpenCodeServer | None = None

    @staticmethod
    def _hostname() -> str:
        val = env("NTFY_HOSTNAME", "")
        if val:
            return val
        if hasattr(os, "uname"):
            return os.uname().nodename
        return os.environ.get("HOSTNAME", "agent")

    def ensure_server(self) -> bool:
        """Create the server handle once it answers /global/health.

        run.sh backgrounds this daemon next to `opencode serve`, so the server
        may still be booting when the notifier starts — wait for it rather
        than spinning up a handle that only produces connection errors.
        """
        if self.server is not None:
            return True
        password = env("OPENCODE_SERVER_PASSWORD") or env("NTFY_SERVER_PASSWORD")
        username = env("OPENCODE_SERVER_USERNAME") or env("NTFY_SERVER_USER", "opencode")
        candidate = OpenCodeServer(self.base_url, username, password)
        version = candidate.health()
        if not version:
            return False
        self.server = candidate
        log(f"connected to opencode server v{version} at {self.base_url}")
        return True

    # -- classification -----------------------------------------------------

    def classify(self, session: dict, status_entry: dict | None,
                 n_perms: int, n_questions: int) -> tuple[str, str]:
        """Return (status, snippet) — one status per session, ordered by what
        needs you most.

        Pending permission/question beats busy: a session blocked on approval
        is 'busy' in opencode's own view, but the actionable fact is that it is
        waiting for you. The retry state is reported by /session/status and
        carries its own error message, so it needs no extra request. Only the
        not-busy branch has to read the last assistant message — and it is read
        once here and reused as the notification snippet.
        """
        if n_perms or n_questions:
            what = "permission" if n_perms else "question"
            return "waiting_for_input", (
                f"waiting for {n_perms or n_questions} pending {what} request(s)"
            )
        stype = (status_entry or {}).get("type")
        if stype == "retry":
            msg = str((status_entry or {}).get("message", ""))
            return "retrying", msg
        if stype == "busy":
            return "running", ""
        text, err = ("", "")
        # The message read is also what makes 'error' detectable, so it stays
        # worthwhile even with snippets off; when off, only the status matters.
        if self.server is not None:
            text, err = self.server.last_message(session["id"])
        if err:
            return "error", (err if self.include_message else "")
        # Not busy, not blocked, and it has produced at least one assistant
        # message: the turn is over. A session with no messages (just created)
        # is idle and not worth a notification.
        return ("finished", text if self.include_message else "") if text else ("idle", "")

    @staticmethod
    def trim(text: str) -> str:
        if not text:
            return ""
        return text if len(text) <= 900 else "… " + text[-900:]

    def _cooldown_ok(self, state: dict, key: str) -> bool:
        last = state.get("last_notified", {}).get(key, 0)
        return (time.time() - last) >= self.cooldown

    def _record(self, state: dict, key: str) -> None:
        state.setdefault("last_notified", {})[key] = time.time()

    # -- main loop -----------------------------------------------------------

    def poll_once(self, state: dict, force_all: bool = False) -> None:
        if self.server is None:
            return
        try:
            sessions = self.server.list_sessions()
            statuses = self.server.status_map()
            perms, questions = self.server.pending_requests()
        except (ConnectionError, RuntimeError) as e:
            log(f"WARN: could not list sessions: {e}")
            return

        now = time.time()
        seen: set[str] = set()
        for sess in sessions:
            sid = sess.get("id")
            if not sid:
                continue
            seen.add(sid)
            status, snippet = self.classify(
                sess, statuses.get(sid), perms.get(sid, 0), questions.get(sid, 0)
            )
            if not self.include_message:
                snippet = ""

            prev = state["sessions"].get(sid, {})
            prev_status = prev.get("status")
            first_sight = prev_status is None
            interesting = status in self.events
            # First sighting records silently, unless the session already
            # announced itself before (catch-up after a notifier restart).
            should_notify = force_all or (
                interesting and prev_status != status and (not first_sight or prev.get("notified"))
            )

            if prev_status != status:
                state["sessions"][sid] = {
                    "status": status,
                    "updated_at": now,
                    "title": sess.get("title", ""),
                }

            if should_notify:
                key = f"{sid}:{status}"
                if force_all or self._cooldown_ok(state, key):
                    try:
                        self.publisher.publish(sess, status, self.trim(snippet))
                        self._record(state, key)
                        state["sessions"][sid]["notified"] = True
                    except (ConnectionError, OSError) as e:
                        log(f"WARN: publish error: {e}")

        # Drop deleted sessions so the state file stays small.
        stale = [s for s in list(state["sessions"]) if s not in seen]
        for s in stale:
            del state["sessions"][s]
        if stale:
            cutoff = now - max(self.cooldown * 10, 3600)
            state.setdefault("last_notified", {})
            for k in [k for k, v in state["last_notified"].items() if v < cutoff]:
                del state["last_notified"][k]

    def run(self) -> int:
        log(
            f"ntfy_notifier v{VERSION} starting — opencode={self.base_url} "
            f"ntfy={self.publisher.server} topic={self.publisher.base_topic!r} "
            f"mode={self.publisher.topic_mode} events={sorted(self.events)} "
            f"dry_run={self.dry_run}"
            + (f" priorities={self.priorities}" if self.priorities else "")
        )
        if self.state_path is None:
            if self.dry_run:
                log("NTFY_STATE_FILE is not set and this is a dry run — no state file")
            else:
                self.state_path = Path("opencode-state") / "ntfy_notifier_state.json"
                log(f"NTFY_STATE_FILE is not set — falling back to {self.state_path}")

        signal.signal(signal.SIGTERM, self._handle_signal)
        signal.signal(signal.SIGINT, self._handle_signal)
        signal.signal(signal.SIGUSR1, self._handle_usr1)

        wait_start = time.time()
        while not self.ensure_server():
            if time.time() - wait_start > 300:
                log(f"ERROR: no opencode server answering at {self.base_url} after 300s; exiting.")
                return 1
            log("waiting for the opencode server (run ./opencode_native/run.sh server)...")
            time.sleep(2)

        state = load_state(self.state_path) if self.state_path else {"sessions": {}}
        if self.state_path is not None:
            log(f"state file: {self.state_path}")

        last_save = 0.0
        while not self._stop:
            t0 = time.time()
            if self._signal:
                signum, self._signal = self._signal, 0
                log(f"received signal {signum}; "
                    + ("stopping..." if self._stop else "forcing snapshot"))
            force, self._force_all = self._force_all, False
            if force:
                log("SIGUSR1: force-publishing current statuses")
            try:
                self.poll_once(state, force_all=force)
            except Exception as e:  # noqa: BLE001 - daemon must keep running
                log(f"ERROR in poll loop: {e}")
            if self.state_path is not None and t0 - last_save >= 5:
                save_state(self.state_path, state)
                last_save = t0
            deadline = t0 + self.poll_seconds
            while not self._stop and time.time() < deadline:
                time.sleep(0.2)

        if self.state_path is not None:
            save_state(self.state_path, state)
        log("stopped.")
        return 0

    def _handle_signal(self, signum, _frame):
        # Signal-safe: a handler that writes can re-enter an interrupted
        # print()/flush and die with "reentrant call inside <stdout>". Only set
        # the flag; run() logs it once the loop exits.
        self._signal = signum
        self._stop = True

    def _handle_usr1(self, signum, _frame):
        # Signal-safe: flag only, the loop does the work (see _handle_signal).
        self._force_all = True


def main() -> int:
    if not env_bool("NTFY_ENABLED", False) and not env_bool("NTFY_DRY_RUN", False):
        log("NTFY_ENABLED is not set — nothing to do (this is expected when")
        log("ntfy notifications are disabled). To test the pipeline without")
        log("publishing, run with NTFY_DRY_RUN=true.")
        return 0
    return Notifier().run()


if __name__ == "__main__":
    sys.exit(main())
