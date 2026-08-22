# dshr

Remote development in [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh) made easy.

`dshr` is a single-file bash CLI that turns any SSH-reachable Linux machine into a
remote DSH development server, and wires up the local tunnel to reach it:

```sh
dshr up my-server          # install (idempotent) + start remote server + open tunnel
dshr dsh my-server plugin --profile web add @some/plugin   # run a dsh CLI command on the remote
dshr local                 # run a local DSH server via npx (no ssh, cwd = $PWD)
dshr list                  # every managed host: tunnel / HTTP / remote status
dshr down my-server        # stop the tunnel (add --server to stop the remote too)
dshr local down            # stop the local server
```

Open the printed URL (`http://localhost:308x`) and you get the full DSH WebUI —
sessions, file tools, skills, subagents — with the **workspace living on the remote
machine**. Browse and pick remote directories from the UI's built-in workspace
dialog.

## Why

The harness's own file/shell capabilities are designed to act on the machine the
harness process runs on. Instead of bolting SSH onto a local session, `dshr` moves
the whole environment: run the DSH web server on the remote host, reach it through
an SSH tunnel, and everything (bash, read/write/edit, grep, workspaces, session
history) is natively remote. No plugins, no extra protocol.

## What `up` does (all idempotent — re-run anytime)

1. **Install** — user-space Node.js (LTS) to `~/.local/node` from a release mirror
   (no root needed), then `@deepseek-ai/dsh` at the latest npmmirror release
   (`$DSHR_DSH_VERSION` pins a specific version).
   Version detection reads `package.json` from disk — reliable over
   non-interactive SSH.
2. **Credentials** — copies local `~/.dsh/.credentials.yaml` / `settings.yaml`
   to the remote only when missing (`--sync` forces overwrite), mode 0600.
3. **Server** — runs `dsh web --port 3080` inside a `tmux` session named
   `dsh-web`, bound to the remote's loopback **only** (cwd `~/workspace`,
   logs `/tmp/dsh-web.log`). Health-checked before proceeding.
4. **Tunnel** — `ssh -f -N -L <local>:127.0.0.1:3080` (daemonized, keepalive).
   Local ports are auto-allocated from `3081` up, so many hosts can be up at once;
   `--port` pins one.
Machine inventory is your existing `~/.ssh/config` — there is no separate `dshr`
configuration. State lives in `~/.dsh/remote/`.

## Local mode

No remote machine handy? `dshr local` runs the same pinned dsh version on this
machine — no ssh:

```sh
dshr local [--port N]       # start (idempotent); default port 3080
dshr local down             # stop it
```

- dsh is installed into `~/.local/dsh` via `npm install --prefix` (the same
  user-space model as the remote `~/.local/node`), at the latest npmmirror
  release by default (`$DSHR_DSH_VERSION` pins a version); the install is
  idempotent and version-checked from `package.json` on disk. When a newer
  dsh appears, `dshr local` upgrades and restarts the server.
- Workspace/cwd is your current directory; logs go to `/tmp/dshr-local.log`.
- The server still binds loopback only, so the security model is unchanged.
- Shows up in `dshr list` under the reserved host `@local` (also stoppable via
  `dshr down @local`). State is tracked in the same `$DSHR_HOME/sessions` file.
- First run downloads the package tree (~250 packages); later runs are
  near-instant. dsh needs node >= 22.6 at runtime.
- Default port 3080 collides with a manually started `dsh web`: on
  `EADDRINUSE`, stop the old instance (`dshr local down`) or pass `--port N`.

## Remote dsh CLI

Need to run a `dsh` command on a remote machine — install a plugin, manage
profiles or sessions — without entering the WebUI?

```sh
dshr dsh my-server plugin --profile web add @some/plugin
dshr dsh my-server --version
```

Runs `dsh <args>` on the remote over SSH using the pinned install in
`~/.local/node`; dsh's output and exit code pass through. The web server does
not need to be up, and stdin is forwarded, so interactive dsh commands work
when your terminal allows it.

Use `localhost`, `127.0.0.1`, or `@local` as the host to skip ssh and run the
same dsh version as `dshr local` from the local prefix (one-off CLI
commands):

```sh
dshr dsh localhost plugin --profile web add @some/plugin
dshr dsh @local --version
```

Pass each dsh argument separately — don't wrap the whole command in quotes.
`dshr dsh` forwards argv verbatim, so a single quoted string arrives at dsh
as one malformed argument (dsh reports `--profile <name> is required`).

## Security model

- The remote server never binds a public interface: SSH is the only path, and it
  is the auth + crypto layer.
- This also satisfies DSH's `/api` browser-trust fence cleanly: the server sees
  plain loopback requests from the tunnel. (DSH deliberately disables
  `--host 0.0.0.0` until it has an authentication layer — don't bypass that.)
- Credentials travel only through your own SSH channel.

## Install

```sh
git clone https://github.com/Xpectuer/dshr.git
ln -s "$PWD/dshr/dshr" /usr/local/bin/dshr   # or anywhere on PATH
```

Requires: bash, ssh (key auth), curl, lsof, tmux on the remote host.
Supports Linux x86_64 / arm64 remotes.

## Environment knobs

| Variable | Default | Meaning |
|---|---|---|
| `DSHR_HOME` | `~/.dsh/remote` | State directory (host/port registry) |
| `DSHR_DSH_VERSION` | *(latest)* | dsh version for remote install + `dshr local`; empty = latest on npmmirror, set to pin; changing it upgrades and restarts the remote server on next `up` |
| `DSHR_NODE_MAJOR` / `DSHR_NODE_VERSION` | `22` / `22.23.2` | Node major version / fallback when the mirror index is unreachable |
| `DSHR_REMOTE_PORT` | `3080` | Remote server port; also the default port for `dshr local` |
| `DSHR_LOCAL_PORT_BASE` | `3081` | Local port allocation base |
| `DSHR_LOCAL_PREFIX` | `~/.local/dsh` | Local dsh install prefix (`dshr local` / `dshr dsh @local`) |
| `DSHR_SSH_OPTS` | — | Extra ssh/scp options (e.g. `-J jump-host`) |

## Notes

- Default mirrors: Aliyun `nodejs-release` and `npmmirror.com` — fast inside
  mainland-China networks where GitHub/raw endpoints are often unreachable.
  Plain `npm` / nodejs.org work fine elsewhere if you edit the two URLs.
- Health probes always use `curl --noproxy '*'` so local proxy environments
  can't interfere with localhost checks.
- The `dshr local` / `dshr dsh @local` npm install runs with proxy env vars
  cleared for the same reason: a stale `http_proxy`/`https_proxy` pointing at
  a dead proxy hangs npm's registry fetch indefinitely.
- npm >= 11 deadlocks on dsh's dependency graph under the default hoisted
  install strategy; dshr switches to `--install-strategy=nested` there (npm
  10 needs no flag). Runtime needs node >= 22.6.
- dshr tracks the latest dsh release by default (checked against npmmirror
  on each `up` / `local`); `DSHR_DSH_VERSION` freezes a version.
- Tunnels don't auto-restore after a local reboot — just `dshr up <host>` again
  (idempotent, takes seconds).
- If the browser ever shows "Failed to load plugins" (e.g. the tunnel blinked
  while a page was loading), refresh the page.

## License

[MIT](LICENSE)
