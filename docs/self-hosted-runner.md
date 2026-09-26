# Running Claude Code self-hosted sessions against a DDEV project

This guide sets up a **self-hosted environment** for a DDEV project: a
Claude Code runner you host yourself — here, in a
[coder.ddev.com](https://ddev.com/blog/coder-ddev-com-announcement/) workspace.
Sessions still start from claude.ai/code, the Claude app, or `claude --cloud`,
but they run on your workspace, as your user, with your network. The worked
example is DDEV's own trivial
[Drupal 11 quickstart](https://docs.ddev.com/en/stable/users/quickstart/#drupal);
swap in your own project's setup where it differs.

For the Anthropic-hosted sandbox this repo also documents, and its limits,
see [`cloud-environment.md`](cloud-environment.md).

## Why self-host

The Anthropic-hosted sandbox works, but it's restrictive:

| Anthropic-hosted sandbox | Self-hosted runner in a Coder workspace |
| --- | --- |
| Session runs as root; DDEV needs a wrapper that re-runs it as `ubuntu` | Session runs as the workspace user (e.g. `coder`, with passwordless sudo); DDEV runs natively |
| TLS-inspecting egress gateway; its CA has to be injected into DDEV's images | Normal outbound TLS; no CA injection |
| Outbound traffic only on ports 80 and 443 | Whatever the host's network allows |
| `ddev share` fails (cloudflared needs port 7844; ngrok is rejected by the gateway) | `ddev share` works normally |
| Only curl and Playwright inside the container can see the site | You can open the site yourself at its Coder URL (which may be public; see [Seeing the site](#working-with-ddev-in-a-runner-session)) |
| Fresh container each session; database starts empty | Persistent workspace; the DDEV project and database survive between sessions |

## Requirements

- **Plan:** self-hosted environments are a **public beta on Team and
  Enterprise plans only**, off by default. An organization **Owner** turns on
  **Allow self-hosted environments** at
  [Admin settings → Cloud environments](https://claude.ai/admin-settings/cloud-environments).
  Cloud sessions must be enabled for the organization too.
- **Claude Code v2.1.224 or later** on the runner host. The runner is the
  `claude self-hosted-runner` subcommand of the normal `claude` binary.
- **Git 2.32 or later** (needed for `--use-anthropic-git-proxy`).
- Outbound HTTPS to `api.anthropic.com` and `claude.ai`, and a clock synced to
  real time (authentication fails when it's more than five minutes off).
- The Claude GitHub App installed on the repository you'll use for sessions
  (`<owner>/<repo>` below), as for Anthropic-hosted sessions.

Nothing connects **into** the workspace: the runner polls `api.anthropic.com`
and streams session events over outbound HTTPS.

## Setup

### 1. Create the Coder workspace

Create a coder.ddev.com workspace from the **freeform** template, and set
**DDEV project names** to include your project's name (by default, DDEV
derives it from the checkout's directory name, i.e. your repository's name).

Coder only proxies the project names registered here. The workspace shows them
in `CODER_PROJECT_NAMES` and in the startup log. The Coder app forwards to
`localhost:8080`. The freeform template runs DDEV's router on that port
(`router_http_port: "8080"` in `~/.ddev/global_config.yaml`).

The workspace comes with Docker (under Sysbox), DDEV, mkcert and tmux. Claude
Code is installed with Homebrew at `/home/linuxbrew/.linuxbrew/bin/claude`.

### 2. Create the environment (claude.ai)

1. Go to [Admin settings → Cloud environments](https://claude.ai/admin-settings/cloud-environments).
2. Under **Self-hosted environments**, select **New**, name it (for example
   `<project>-coder`), and select **Create**.
3. Select **Copy environment key**. It's shown once and expires after 365
   days. If you lose it, create a new one on the environment's
   **Configuration** tab and revoke the old one.

Alternatively, `claude self-hosted-runner setup` on a machine signed in as an
Owner walks through these steps interactively.

### 3. Prepare the workspace

In a workspace terminal, as the workspace user:

```bash
claude self-hosted-runner --help     # should list --environment-secret-file

# Store the environment key, readable only by you
mkdir -p ~/.claude-runner
(umask 077 && cat > ~/.claude-runner/environment-secret)   # paste, Enter, Ctrl-D

# Trust DDEV's local CA. Needed before the first `ddev start` so the router
# gets trusted certificates, and again after every workspace restart
# (the startup script below does that).
mkcert -install

# Git identity and ignores for sessions (see below). startup.sh installs
# this file as /etc/gitconfig on every boot.
cat > ~/.claude-runner/gitconfig <<'EOF'
[user]
	name = Claude
	email = noreply@anthropic.com
[core]
	excludesFile = ~/.claude-runner/gitignore
EOF
printf '%s\n' .ddev/config.coder.yaml .ddev/docker-compose.coder-describe.yaml \
  > ~/.claude-runner/gitignore
sudo install -m 644 ~/.claude-runner/gitconfig /etc/gitconfig
```

Why `/etc/gitconfig` and not `git config --global`: with
`--use-anthropic-git-proxy`, the runner **wipes `~/.gitconfig` and
`~/.config/git` every time it starts** ("wiping HOME-level git config ... for
cross-session isolation" in its log), and replaces `~/.gitconfig` with its own
credential helper. Inside a session, `GIT_CONFIG_GLOBAL` points at a
per-session file under `~/workspace/_sessions/`, so `git config --global` there
only lasts for that session. System config (`/etc/gitconfig`) is read in
sessions, and the runner leaves it alone (its log names it as the place for
operator git config), but `/etc` is on the ephemeral root filesystem, so the
startup script reinstalls it after each workspace restart.

- **Identity:** without one, `git commit` fails with "Author identity
  unknown". Use your own name and email if you prefer; `Claude
  <noreply@anthropic.com>` is a reasonable default that matches Anthropic-hosted
  sessions. The runner's `--configure-git` flag is the alternative: it sets
  that identity and turns on Anthropic's commit signing (not tested here).
- **Ignores:** `ddev coder-setup` (step 6) generates two files and lists them in
  `~/.config/git/ignore`. The runner wipes that file, and then both show up as
  untracked in `git status`, where a session might commit them.
  `core.excludesFile` points git at a copy that lives outside the wiped paths.

### 4. The runner script

The runner exits by design when its sessions finish, so it needs a restart
loop. Save this as `~/.claude-runner/run.sh` and `chmod +x` it:

```bash
#!/bin/bash
# Keep a Claude Code self-hosted runner running for one project.
while true; do
  claude self-hosted-runner \
    --environment-secret-file "$HOME/.claude-runner/environment-secret" \
    --base-dir "$HOME/workspace" \
    --capacity 1 \
    --use-anthropic-git-proxy \
    --release-idle-session-min 30 \
    --kill-session-after-min 480 \
    --health-port 0
  echo "runner exited ($?); restarting in 5s"
  sleep 5
done
```

What the flags do:

- `--health-port 0` is **required** in a coder-ddev workspace. The runner's
  `/healthz` listener defaults to port 8080, which DDEV's router needs for the
  Coder URL. With the default, `ddev start` says `Port 8080 is busy, using
  33000 instead`, and the Coder URL answers `not found` (that's the runner
  answering).
- `--base-dir "$HOME/workspace"`: the runner clones into
  `<base-dir>/<owner>/<repo>` and keeps per-session files under
  `<base-dir>/_sessions/`.
- `--capacity 1`: one session at a time.
  - `--use-anthropic-git-proxy` requires it.
  - At capacity 1 the runner keeps one reusable checkout and **resets it to
    each session's branch**. So the DDEV project is always the same project,
    and its database carries over between sessions. But don't keep
    workspace-only files in the checkout: they disappear when a session uses a
    branch that doesn't have them. That's why the scripts here live in
    `~/.claude-runner/`.
  - With a higher capacity, parallel checkouts of the same repository would
    all be DDEV projects with the same name and collide.
- `--use-anthropic-git-proxy`: clone and push through Anthropic's git proxy,
  using your existing Claude GitHub connection. The workspace needs no git
  tokens or SSH keys.
- `--release-idle-session-min 30`: frees the slot when a conversation goes
  idle; the session resumes when you send the next message.
- `--kill-session-after-min 480`: hard backstop, because a session with a
  never-ending background task (a `ddev share` tunnel, for example) never
  counts as idle.

### 5. The startup script

Workspace restarts stop every process, and the system trust store is on the
ephemeral root filesystem. Save this as `~/.claude-runner/startup.sh` and
`chmod +x` it. It trusts the mkcert CA, starts the runner loop in a tmux
session, and starts DDEV. It does this at most once per workspace boot. If
`~/.claude-runner/environment-secret` doesn't exist, it does nothing and logs
that the one-time setup is needed:

```bash
#!/usr/bin/env bash
# Start a runner workspace: mkcert CA, runner loop (tmux), DDEV.
# Safe to call repeatedly: it only does work once per workspace boot.
set -u

PROJECT_NAME=<project>   # your DDEV project's name, e.g. your repo's directory name

log=/tmp/claude-runner-startup.log
# No environment key yet: the one-time setup (steps 2-4) hasn't been done.
# Checked before the marker, so the next terminal retries once it has.
if [ ! -f "$HOME/.claude-runner/environment-secret" ]; then
  echo "$(date): no ~/.claude-runner/environment-secret; do the one-time setup first" >>"$log"
  exit 0
fi

marker=/tmp/.claude-runner-startup-done   # /tmp is wiped on workspace restart
[ -e "$marker" ] && exit 0
touch "$marker"
exec >>"$log" 2>&1
echo "=== startup $(date)"

# The CA in ~/.local/share/mkcert persists; the system trust store doesn't.
mkcert -install

# Git identity and ignores for sessions. /etc is on the ephemeral root
# filesystem, and the runner wipes ~/.gitconfig and ~/.config/git (step 3).
if [ -f "$HOME/.claude-runner/gitconfig" ]; then
  sudo install -m 644 "$HOME/.claude-runner/gitconfig" /etc/gitconfig
fi

if ! pgrep -f '^claude self-hosted-runner' >/dev/null; then
  tmux new-session -d -s claude-runner "$HOME/.claude-runner/run.sh"
fi

# Fails with "could not find requested project '$PROJECT_NAME'" until the
# first session has cloned the repository and run `ddev start` there (step 6).
ddev start "$PROJECT_NAME" -y || { sleep 5; ddev start "$PROJECT_NAME" -y; }
```

The first time it runs, before any session has cloned the repository,
`ddev start "$PROJECT_NAME"` fails with `could not find requested project
'<project>'` (twice, because of the retry). That's expected; the rest of the
script has already run. After step 6 it starts the project normally.

Run it from `~/.bashrc` so it starts when you open a terminal:

```bash
echo '[ -x ~/.claude-runner/startup.sh ] && (~/.claude-runner/startup.sh &)' >> ~/.bashrc
```

`~/.bashrc` only runs when an interactive shell starts: a VS Code terminal,
the web terminal, or `coder ssh`. After a workspace restart, **nothing runs
until someone opens a terminal**.

A workspace template can run a user startup hook instead: a template that runs
`~/.coder-startup.sh` (if it's executable) at every workspace start
([ddev/coder-ddev#208](https://github.com/ddev/coder-ddev/pull/208), not
merged yet) starts the runner with no terminal open:

```bash
printf '#!/usr/bin/env bash\nexec "$HOME/.claude-runner/startup.sh"\n' > ~/.coder-startup.sh
chmod +x ~/.coder-startup.sh
```

Tested on a staging workspace: after a restart with no terminal open, the
runner registered and picked up a session. The hook's own output goes to
`/tmp/coder-startup-user.log`; `startup.sh` still logs to
`/tmp/claude-runner-startup.log`.

Now start it: open a new terminal, or run `~/.claude-runner/startup.sh`. Watch
the runner with `tmux attach -t claude-runner` (detach with Ctrl-b d).

### 6. First session and project setup

1. On the **Cloud environments** page, the environment should go from **No
   runners deployed** to **Healthy** within a few seconds.
2. Start a session at [claude.ai/code](https://claude.ai/code), pick your
   repository, and choose the self-hosted environment.
3. The runner logs `Picked up session <session-id>` and clones the repository
   to `~/workspace/<owner>/<repo>`.

Once the checkout exists, set up the DDEV project once (in the session or a
terminal):

```bash
cd ~/workspace/<owner>/<repo>
ddev coder-setup    # before the first ddev start

# If the repo doesn't already carry a DDEV project, build the quickstart:
ddev config --project-type=drupal11 --docroot=web --create-docroot
ddev start
ddev composer create-project drupal/recommended-project
ddev composer require drush/drush
ddev drush site:install --account-name=admin --account-pass=admin -y   # first time only; the database persists

# If it already does, just:
ddev start
```

`ddev coder-setup` writes `.ddev/config.coder.yaml` and
`.ddev/docker-compose.coder-describe.yaml`, adds both to `~/.config/git/ignore`
(which the runner wipes; the `core.excludesFile` from step 3 keeps them
ignored), and adds a post-start hook that publishes Traefik routes for the
Coder URLs. `ddev start` then prints lines like:

```text
  + <project>: http-8080 → <project>-web-80  (https://<project>--<workspace>--<owner>.coder.ddev.com)
  + mailpit-<project>: http-8025 → <project>-web-8025  (https://mailpit-<project>--<workspace>--<owner>.coder.ddev.com)
```

If it says `http-33000` (or anything other than 8080), something else holds
port 8080. See [Troubleshooting](#troubleshooting).

You can also send follow-ups from any machine where you're signed in:
`claude -p "your message" --cloud <session-id>`.

## Working with DDEV in a runner session

None of the sandbox workarounds in the cloud environment guide apply: no
wrapper, no CA files, no setup script. Run `ddev` normally in
`~/workspace/<owner>/<repo>`.

- **Logging in:** `ddev drush uli`.
- If your project has its own install profile or config-import flow, use
  that instead of the plain `drush site:install` above.

Seeing the site:

- **You:** `https://<project>--<workspace>--<owner>.coder.ddev.com`, and
  Mailpit at `https://mailpit-<project>--<workspace>--<owner>.coder.ddev.com`.
  Some Coder servers use a different base domain (e.g. a staging server);
  `ddev start` prints the right URLs.
  - **Check whether the site URL is public.** Whether Coder asks for a login
    depends on the app's share level, and it isn't the same everywhere. In
    testing, one workspace's URL required a Coder login (`303` to
    `/api/v2/applications/auth-redirect` when curled with no cookies), while
    another answered `200` with the site's home page to anyone. Test it with
    no cookies:
    `curl -s -o /dev/null -w '%{http_code}\n' https://<project>--<workspace>--<owner>.coder.ddev.com/`.
    If it says `200`, the site is on the internet: don't leave an admin
    account with a weak or default password.
  - When the Coder URL does require a login, curl from the session can't get
    past it. To check the Coder route from inside the workspace, go straight
    to the router:
    `curl -H 'Host: <project>--<workspace>--<owner>.coder.ddev.com' http://localhost:8080/`
    (Mailpit: the same on port 8025).
- **The session:** curl and Playwright work as on any DDEV host, at
  `https://<project>.ddev.site`, with no proxy settings.
  - curl verifies the certificate once `mkcert -install` has run (it uses the
    system trust store).
  - The workspace has no browser by default. Install one with
    `npm i playwright && npx playwright install --with-deps chromium` (in a
    scratch directory, not the checkout). `--with-deps` uses sudo for the
    system libraries.
  - Chromium doesn't use the system trust store; it uses the NSS database in
    `~/.pki/nssdb`, and `mkcert -install` only adds its CA there if that
    database already exists. Without it, Chromium fails with
    `net::ERR_CERT_AUTHORITY_INVALID`. Create the database, then run
    `mkcert -install` again:
    `mkdir -p ~/.pki/nssdb && certutil -d sql:$HOME/.pki/nssdb -N --empty-password && mkcert -install`
    (`certutil` is in `libnss3-tools`, which the Playwright install adds).
    Or pass `ignoreHTTPSErrors: true` to `newPage()`.
  - `ddev drush uli --uri=https://<project>.ddev.site --no-browser` gives a
    one-time login link for a scripted browser.
- **Someone else:** `ddev share` (ngrok by default; needs `ngrok config
  add-authtoken`). The shared URL is public, so change any default admin
  password first, or use `ddev share --provider-args "--basic-auth user:pass"`.

## Operating the runner

- **Restarting the runner** (to change flags): stop the loop in its tmux
  session and start it again. On SIGTERM the runner waits for an in-flight
  turn to finish before exiting. A session that was running continued after
  the restart, but its working directory moved when `--base-dir` changed.
- **Changing `--base-dir`** moves the checkout, while DDEV still has the
  project registered at the old path. In the new checkout, run
  `ddev stop --unlist <project>`, then `ddev coder-setup` and `ddev start`.
  Check the database afterwards with `ddev drush status`. In testing it came
  up empty and needed a reinstall. Delete the old checkout once you're done
  with it.
- **Stopping the last DDEV project** also removes the router and its network.
  The next `ddev start` can fail once with `network ddev_default declared as
  external, but could not be found`. Run `ddev start` again. The startup
  script retries once.

## Troubleshooting

- **Coder URL says `not found`:** DDEV's router isn't on port 8080. Check
  `ddev describe` or the `coder-routes` lines from `ddev start`. Usually the
  runner was started without `--health-port 0`: `curl -s localhost:8080/`
  answering `not found` means something other than DDEV holds the port. Fix
  the runner, then `ddev restart`.
- **Browser warns about the certificate on `https://<project>.ddev.site`:** run
  `mkcert -install`, then `ddev restart`. For Chromium or Playwright in the
  workspace, create `~/.pki/nssdb` first (see
  [Seeing the site](#working-with-ddev-in-a-runner-session)).
- **Steps 3 and 5 were only partly done** (for example, the runner was started
  by hand with `run.sh` and there's no `startup.sh`): after a workspace
  restart there's no `/etc/gitconfig` and the mkcert CA isn't trusted. Rerun
  `sudo install -m 644 ~/.claude-runner/gitconfig /etc/gitconfig` and
  `mkcert -install`, then set up `startup.sh` so it doesn't happen again.
- **Site redirects to `/core/install.php`:** the database is empty; install
  Drupal as above.
- **`Author identity unknown` on commit:** `/etc/gitconfig` is missing (the
  workspace restarted and `startup.sh` hasn't run), or it has no `[user]`
  section. `git config --show-origin user.email` shows where the identity
  comes from. Check `~/.claude-runner/gitconfig` and rerun the `sudo install`
  line from step 3. `git config --global` doesn't help: the runner wipes it.
- **`.ddev/config.coder.yaml` and `.ddev/docker-compose.coder-describe.yaml`
  show as untracked:** the same cause. They're ignored only through
  `core.excludesFile` in `/etc/gitconfig`. Don't commit them.
- **`could not find requested project '<project>'` in
  `/tmp/claude-runner-startup.log`:** normal before the first session has
  cloned the repository and run `ddev start` in it.
- **Nothing is running after a workspace restart:** open a terminal (see the
  startup script above), or run `~/.claude-runner/startup.sh`. Its log is
  `/tmp/claude-runner-startup.log`. If it says there is no
  `environment-secret`, do steps 2–4 first.

## Caveats

- **Anyone in your organization can dispatch sessions to the environment.**
  Those sessions run model-directed code in your workspace as the workspace
  user, with sudo and access to whatever else is in the workspace. Use a
  dedicated workspace with no unrelated credentials or projects in it.
- **One person at a time per runner.** A runner locks to the owner of the
  first session it picks up. Each person working at the same time needs their
  own runner (or workspace).
- **Workspace auto-stop.** If Coder stops the workspace mid-session, the
  runner dies and the session is requeued. Either turn off auto-stop for this
  workspace, or pass `--retire-at <epoch-seconds>` (a few minutes before the
  stop) so the runner releases sessions cleanly.
- **Shared persistent disk.** Anthropic's hardening guidance is a fresh
  container per session. A persistent workspace trades that isolation for
  speed and a database that survives between sessions. That's reasonable for
  one developer's demo site, not for untrusted users.
- **coder.ddev.com is experimental,** with no uptime or retention guarantees,
  and an always-on runner is a steady load on it.
- **Session content still goes to Anthropic** for model inference; only the
  checkout, build output, and DDEV data stay on your host.

## References

- [Self-hosted environments](https://code.claude.com/docs/en/self-hosted-environments)
- [Self-hosted environments quickstart](https://code.claude.com/docs/en/self-hosted-environments-quickstart)
- [Deploy self-hosted environments to production](https://code.claude.com/docs/en/self-hosted-environments-deploy)
  (hardening, git options, pre-warmed checkouts, known issues)
- [Self-hosted runner reference](https://code.claude.com/docs/en/self-hosted-environments-reference)
  (all flags)
- [Use Claude Code in the cloud](https://code.claude.com/docs/en/claude-code-on-the-web)
- [Introducing coder.ddev.com](https://ddev.com/blog/coder-ddev-com-announcement/)
- [ddev/coder-ddev](https://github.com/ddev/coder-ddev)
- [DDEV Drupal quickstart](https://docs.ddev.com/en/stable/users/quickstart/#drupal)
