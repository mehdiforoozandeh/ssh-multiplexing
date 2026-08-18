#!/usr/bin/env bash
#
# <xbar.title>SSH multiplex status</xbar.title>
# <xbar.author>ssh-multiplexing</xbar.author>
# <xbar.desc>Shows whether the multiplexed SSH master is live, and offers a
# one-click reconnect that opens a real terminal for the MFA prompt.</xbar.desc>
# <xbar.dependencies>bash,ssh</xbar.dependencies>
#
# Filename encodes the refresh interval: sshmux.15s.sh = every 15 seconds.
# Drop it in your SwiftBar (or xbar) plugin folder and `chmod +x` it.
#
# `ssh -O check` only talks to the local socket — it never touches the
# network and can never trigger an auth prompt, so polling it every 15
# seconds is free and safe.
#
set -uo pipefail
export PATH="$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

CONFIG="${MUX_CONFIG:-$HOME/.config/mux/config}"
MUX="$HOME/.local/bin/mux"
HOSTS="remote"
[ -f "$CONFIG" ] && . "$CONFIG"

alive() { ssh -O check "$1" >/dev/null 2>&1; }

# The glyph tracks the first host — your primary. The rest show in the dropdown.
PRIMARY="${HOSTS%% *}"
any_up=0

if alive "$PRIMARY"; then
    # SwiftBar renders SF Symbols directly. xbar users: swap for  echo "🟢"
    echo "| sfimage=antenna.radiowaves.left.and.right sfcolor=green"
else
    echo "| sfimage=antenna.radiowaves.left.and.right.slash sfcolor=secondary"
fi

echo "---"
for h in $HOSTS; do
    if alive "$h"; then
        printf '%-12s up | font=Menlo size=12 color=green\n' "$h"
        any_up=1
    else
        printf '%-12s down | font=Menlo size=12\n' "$h"
    fi
done
echo "---"

# The one action that genuinely needs a human gets a one-click path.
# terminal=true is load-bearing: an MFA prompt needs a real TTY, so this
# must open Terminal rather than run headless.
for h in $HOSTS; do
    alive "$h" || \
        echo "Connect $h… | bash=$MUX param1=up param2=$h terminal=true refresh=true"
done

if [ "$any_up" = 1 ]; then
    echo "Disconnect all | bash=$MUX param1=down terminal=false refresh=true"
fi
echo "Refresh | refresh=true"
