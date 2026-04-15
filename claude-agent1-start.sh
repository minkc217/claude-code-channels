#!/bin/bash
TMUX_SOCKET=/tmp/tmux-claude-agent1

export BUN_INSTALL="/home/hsy/.bun"
export PATH="$BUN_INSTALL/bin:/home/hsy/.local/bin:/usr/local/bin:/usr/bin:/bin"
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
tmux -S $TMUX_SOCKET kill-session -t claude-agent1 2>/dev/null || true
pkill -9 -f "telegram.*start" 2>/dev/null || true
pkill -9 -f "bun server.ts" 2>/dev/null || true
sleep 2

cd /home/hsy/agent1

tmux -u -S $TMUX_SOCKET new-session -d -s claude-agent1 \
  "claude --channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions"

sleep 2
chmod 700 $TMUX_SOCKET
tmux -S $TMUX_SOCKET ls
