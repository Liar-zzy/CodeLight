# CodeLight Relay

Lightweight daemon that bridges remote Claude Code sessions (running on SSH servers) to the CodeLight ecosystem.

## What it does

When Claude Code runs on a remote server via SSH, the relay:
- Receives hook events from `codeisland-state.py` via Unix socket
- Monitors JSONL session files for chat history
- Detects multiplexer (zellij/tmux) session info
- Forwards everything to the CodeLight backend server
- Accepts remote commands (focus tab, launch session)

## Requirements

- Python 3.8+ (stdlib only, no pip dependencies)
- Claude Code installed on the remote server
- codeisland-state.py hook configured in `~/.claude/settings.json`

## Quick Start

```bash
# 1. Copy relay.py to the remote server
scp relay.py user@remote:~/

# 2. Setup (first time only)
python3 relay.py setup

# 3. Start
python3 relay.py start

# 4. Check status
python3 relay.py status
```
