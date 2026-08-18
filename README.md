# One MFA prompt for the whole machine: SSH connection multiplexing

*Authenticate once with OpenSSH's `ControlMaster` and `ControlPersist`, then
share that single connection across every terminal tab, VS Code Remote-SSH
session, `rsync`, `scp` and `git` command — no repeated Duo or 2FA prompts.
Works on macOS and Linux.*

**The problem.** You have a remote host that demands multi-factor
authentication on every login — Duo push, TOTP code, hardware key. Then you
open a terminal tab. Then a second tab. Then VS Code Remote-SSH, which opens
two or three connections of its own. Then `rsync`. Then `git push`. Then a
`scp`. Each one is a separate SSH authentication, so each one is a separate
MFA prompt. You approve six pushes before you have done any work.

**The fix.** Authenticate **once**, in one place, and let every later
connection ride the connection you already opened. This is a built-in OpenSSH
feature — connection multiplexing — plus roughly twenty lines of config and a
few habits.

The result is what it sounds like: the machine, not the session, is connected.
Terminal tabs, editors, file syncs, and git all open instantly with no prompt,
until the underlying TCP connection actually dies.

---

## 1. How it works

An SSH *connection* and an SSH *session* are not the same thing. One
authenticated TCP connection can carry many independent sessions, called
channels. That is the same mechanism that lets a single `ssh` invocation run a
shell and a port forward and an SCP transfer at once.

Multiplexing exposes that mechanism to separate processes:

1. The first `ssh` becomes the **master**. It authenticates — one MFA prompt —
   and creates a Unix domain socket on your local disk.
2. Every later `ssh`, `scp`, `rsync`, `git`, or editor connection to the same
   `user@host:port` finds that socket, opens a **new channel** on the existing
   connection, and skips authentication entirely. There is nothing to skip:
   the connection is already authenticated.
3. The master survives after the process that created it exits, so it outlives
   the terminal window you started it in.

The socket is the whole trick. It is a local file that means "an authenticated
pipe to that host already exists — use it."

---

## 2. The configuration

Put this in `~/.ssh/config`:

```sshconfig
Host remote
    HostName remote.example.edu
    User yourname

    # ── the multiplexing core ──────────────────────────────────────────
    ControlMaster auto
    ControlPath   ~/.ssh/cm-%r@%h:%p
    ControlPersist yes

    # ── keep it alive across sleep and flaky wi-fi ─────────────────────
    ServerAliveInterval 60
    ServerAliveCountMax 30
    TCPKeepAlive no

    # ── fail fast instead of hanging ───────────────────────────────────
    ConnectTimeout 15
```

Then arm it, from a real terminal, once:

```bash
ssh -f -N remote      # -f = background after auth, -N = no command
```

Approve the MFA prompt. That is the last one you will see today.

### What each option actually does

| Option | Meaning | Why this value |
|---|---|---|
| `ControlMaster auto` | Reuse an existing socket if there is one; otherwise become the master. | `yes` fails when a socket already exists. `auto` is the only sane setting for daily use. |
| `ControlPath` | Where the socket file lives. `%r`=remote user, `%h`=host, `%p`=port. | Must be unique per user+host+port, or connections cross-talk. See the socket-path gotcha below. |
| `ControlPersist yes` | The master stays in the background **with no idle timeout**, until the connection dies or you kill it. | A time value like `10m` means "close after 10 minutes idle" — which re-introduces the MFA prompt you are trying to avoid. `yes` and `0` both mean forever. `no` means the master dies with the first client. |
| `ServerAliveInterval 60` | Send an encrypted keepalive every 60 s of silence. | Detects a dead peer, and stops NAT/firewall tables from forgetting the connection. |
| `ServerAliveCountMax 30` | Give up after 30 unanswered keepalives. | 60 s × 30 = **30 minutes**. A closed laptop lid under 30 minutes reconnects to a live master. Raise it if you want longer; the cost is that a genuinely dead connection takes that long to notice. |
| `TCPKeepAlive no` | Do not use kernel-level TCP keepalives. | They are spoofable and they tear the connection down on transient packet loss. The SSH-level probes above are encrypted and more tolerant. |
| `ConnectTimeout 15` | Give up on the initial TCP handshake after 15 s. | Turns "hangs forever on a dead network" into a fast, scriptable error. |

---

## 3. Driving the master

These three commands talk **only to the local socket**. They never
authenticate, never touch the network in a way that could prompt you, and are
safe to call from a status bar polling every few seconds.

```bash
ssh -O check remote     # is the master alive?  exit 0 = yes
ssh -O exit  remote     # close it, dropping every session riding it
ssh -O stop  remote     # stop accepting new channels, let existing ones finish
```

### Add port forwards without reconnecting

This is the underrated one. You can attach and detach forwards on a **live**
master, so a Jupyter or TensorBoard tunnel costs no new authentication:

```bash
ssh -O forward -L 8888:localhost:8888 remote
ssh -O cancel  -L 8888:localhost:8888 remote
```

---

## 4. What rides the master for free

Anything that shells out to the system `ssh` binary and reads your
`~/.ssh/config`:

- extra terminal tabs, `tmux`, `screen`
- `scp`, `sftp`, and `rsync -e ssh`
- **`git`** over SSH to that host — clone, fetch, push
- **VS Code Remote-SSH** on macOS and Linux. It uses the system `ssh` and your
  config, so it reuses the master and opens in a second or two instead of
  demanding two or three fresh prompts.
- **Cursor, Windsurf, JetBrains Gateway** — same mechanism
- **Ansible**, which enables `ControlPersist` in its own `ssh_args` by default
- `sshfs`

### What does *not* ride it

| Tool | Why | Workaround |
|---|---|---|
| **VS Code Remote-SSH on Windows** | Win32 OpenSSH has no Unix-domain-socket support, so `ControlMaster` is unsupported. | Run the client side from WSL. |
| **`mosh`** | Authenticates over SSH, then moves to its own UDP protocol. It cannot share a channel. | Accept one prompt per mosh session. |
| **Paramiko-based Python tools** (Fabric, many deploy scripts) | They implement SSH themselves and never look at your config or socket. | Shell out to `ssh` via `subprocess`, or accept the prompt. |
| **Anything on a different `user@host:port`** | Different socket. | Expected; each distinct target gets its own master. |

---

## 5. What kills the master — and why that is unavoidable

| Trigger | How often, on a laptop |
|---|---|
| **Source-IP change** — switching wi-fi networks, toggling a VPN, tethering | Constantly. This is the number-one cause. The TCP 4-tuple changes, so the connection is gone. |
| **Sleep longer than `ServerAliveInterval × ServerAliveCountMax`** | Daily, with the 30-minute setting above |
| Remote `sshd` restart, host reboot, or a server-side idle-session reaper | Rare |
| You ran `ssh -O exit` | On purpose |

There is no configuration that survives an IP change; that is TCP, not SSH.
Tools like [autossh](https://github.com/Autossh/autossh) restart a dead tunnel
automatically, but restarting means **re-authenticating**, which means an MFA
prompt, which needs a human. On an MFA host, automatic reconnection is not a
solvable problem. What you can do is *notice fast* — see §7.

A hard-killed master sometimes leaves a stale socket file behind. `ssh -O
check` will correctly report it as dead; delete the file if a later connection
complains about it.

---

## 6. Scripts, cron, and agents: the discipline that matters

The moment you have automation using this connection — a sync script, a
`launchd` job, an AI coding agent running shell commands — one rule dominates
everything else:

> **Every non-interactive SSH call must pass `-o BatchMode=yes`.**

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 remote 'whoami'
rsync -av -e 'ssh -o BatchMode=yes' ./src/ remote:~/dst/
```

Without it, a dead master causes `ssh` to fall back to a **fresh
authentication** — and then sit forever on an MFA prompt that no script,
cron job, or agent can ever answer. Your job does not fail; it hangs, silently,
holding a lock or a slot, until you notice hours later. With `BatchMode=yes` it
fails in two seconds with a clear error.

Two supporting habits:

**Distinguish "tunnel down" from "the command failed."** Have your wrapper exit
with a reserved code so callers can tell the difference. `69`
(`EX_UNAVAILABLE`) is the conventional choice:

```bash
require_master() {
    ssh -O check "$1" >/dev/null 2>&1 && return 0
    echo "no live connection to $1 — run 'ssh -f -N $1' in a terminal" >&2
    exit 69
}
```

**Never attempt to re-authenticate on the user's behalf.** An MFA challenge is,
by design, a human in the loop. Automation can *use* an existing master; it can
never *create* one. Design for that asymmetry instead of fighting it.

---

## 7. Optional: make the connection state visible

Because the master dies on network changes and you cannot auto-reconnect, the
one thing worth building is **immediate notice**. Three small pieces, included
in this repo:

- **[`bin/mux`](bin/mux)** — a wrapper CLI: `mux up`, `mux status`, `mux run`, `mux push`,
  `mux pull`, `mux forward`. It enforces `BatchMode` on every non-interactive
  path and exits 69 when the tunnel is down.
- **[`bin/mux-watch`](bin/mux-watch)** — checks the socket, and fires a desktop notification the
  moment an up→down transition happens. It deliberately does **not** try to
  reconnect.
- **[`launchd/com.user.mux.watch.plist`](launchd/com.user.mux.watch.plist)** — a `launchd` agent that runs the watcher on
  a 120-second timer *and* on `WatchPaths` for
  `/etc/resolv.conf` and `/Library/Preferences/SystemConfiguration`. Those
  files are rewritten within seconds of any wi-fi, VPN, or tethering change —
  exactly the events that kill the master. So you learn the connection died
  roughly when it died, not three commands into your next task.

All three read one config file, `~/.config/mux/config`
([example](examples/mux.config)):

```bash
HOSTS="remote jumpbox"          # ssh_config Host aliases, space-separated
DEFAULT_HOST="remote"
LOCAL_ROOT="$HOME/code"         # `mux push foo` syncs $LOCAL_ROOT/foo/
REMOTE_ROOT="/home/yourname"    # remote parent dir; empty = remote $HOME
MAX_PULL=100M                   # `mux pull` refuses anything larger
```

A menu-bar indicator (SwiftBar, xbar, Übersicht, or a Waybar/i3blocks module on
Linux) that shells out to `ssh -O check` closes the loop: a green dot means
everything will just work, a grey one means re-arm before you start.

Install the launchd agent with:

Edit the two `/Users/YOURNAME/` paths in the plist first — `launchd` does not
expand `~` — then:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.mux.watch.plist
```

On Linux, the equivalent is a systemd user timer plus a
`NetworkManager-dispatcher` hook.

---

## 8. Gotchas worth knowing before they bite

**1. Socket paths have a hard length limit.** A Unix domain socket path maxes
out at 104 bytes on macOS, 108 on Linux. Long hostnames, long usernames, or a
deep `ControlPath` will blow it, with a confusing error. Use the hash token
instead — `%C` expands to a hash of local-host + remote-host + port + user:

```sshconfig
ControlPath ~/.ssh/cm-%C
```

**2. Do not put sockets on a network filesystem.** If `$HOME` is NFS-mounted —
common on university and lab machines — sockets there behave badly and can
appear to leak between machines. Point `ControlPath` at local disk:

```sshconfig
ControlPath /tmp/%r@%h:%p.sock
```

**3. Forwarding options are fixed when the master is created.** This one
surprises everyone. If the master was started without `-A` or `-X`, a later
`ssh -A remote` **silently gets no agent forwarding**, because it is only
opening a channel on an existing connection. Same for `-L` and `-R`. Two fixes:
put `ForwardAgent yes` / `ForwardX11 yes` in the `Host` block so the master has
them, or add forwards afterwards with `ssh -O forward` (§3).

**4. `ssh -O exit` drops everyone.** Every tab, sync, and editor session riding
that master dies at once. Use `ssh -O stop` if you want existing sessions to
finish.

**5. The server caps channels per connection.** `sshd`'s `MaxSessions` defaults
to 10. Fan out twenty parallel `rsync`s over one master and you will see
`channel N: open failed: administratively prohibited`. Either raise it
server-side, or let heavy parallel jobs open their own connections.

**6. `ProxyJump` composes with this.** Multiplex both hops — give the jump host
its own `ControlMaster` block — and the whole chain becomes one prompt.

**7. `ControlPersist yes` means forever.** If you want the free-pass window to
expire on its own, use a real duration (`ControlPersist 8h`) and accept one
prompt per working day.

---

## 9. Security: what you are actually trading away

Be honest about this. That socket file **is** a standing bypass of your MFA.
Anyone who can read and write it gets a shell on the remote host without
presenting a second factor.

In practice that means:

- Anyone who has your local user account, or root on your machine, while the
  master is alive. That is the same threat model as an unlocked laptop with an
  unencrypted SSH key and a live agent — but worth naming.
- `ssh` creates the socket mode `0600`; keep `~/.ssh` at `700`. Do not relax
  either.
- On a shared multi-user machine, prefer a socket directory only you can read,
  e.g. `/tmp/ssh-mux-$USER/` created `0700`.
- If your threat model wants a bounded window, `ControlPersist 8h` gives you
  one prompt a day and closes the window overnight.
- `ssh -O exit remote` before handing your machine to someone else, and as part
  of any lock-and-leave habit.

This is the same trade every SSH agent makes: convenience now, in exchange for
a live credential sitting on disk. The trade is usually right. Make it
knowingly.

---

## 10. Setup checklist

```bash
# 1. add the Host block from §2 to ~/.ssh/config
chmod 700 ~/.ssh

# 2. arm the master, in a real terminal — this is the one MFA prompt
ssh -f -N remote

# 3. confirm
ssh -O check remote && echo "connected"

# 4. prove it: these should all be instant and prompt-free
ssh remote hostname
rsync -av -e 'ssh -o BatchMode=yes' ./project/ remote:~/project/
git -C ~/project push        # if the origin is on that host

# 5. open VS Code Remote-SSH at that host — also instant

# 6. (optional) install the wrapper and the watcher from this repo
git clone https://github.com/mehdiforoozandeh/ssh-multiplexing.git
cd ssh-multiplexing
install -m 755 bin/mux bin/mux-watch ~/.local/bin/
mkdir -p ~/.config/mux && cp examples/mux.config ~/.config/mux/config
sed "s|YOURNAME|$USER|g" launchd/com.user.mux.watch.plist \
    > ~/Library/LaunchAgents/com.user.mux.watch.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.mux.watch.plist
```

---

## Summary

Connection multiplexing turns "authenticate per session" into "authenticate per
connection." Set `ControlMaster auto` + `ControlPath` + `ControlPersist yes`,
arm it once from a terminal, and your whole machine is connected: every tab,
editor, sync, and git command rides one authenticated pipe.

The two things that keep it from becoming a liability are `BatchMode=yes` on
every automated call — so a dead tunnel fails fast instead of hanging on a
prompt nobody can answer — and a watcher that tells you the moment a network
change kills the master, since MFA means no script can ever bring it back.

---

## License

MIT — see [LICENSE](LICENSE). Copy any of it into your own dotfiles without
attribution; it is config and glue, not art.

Corrections and additions are welcome, especially platform notes for Linux
desktops, Windows/WSL, and editors other than VS Code.
