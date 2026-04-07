#!/usr/bin/env python3
"""
CodeLight Relay - bridges remote Claude Code sessions to CodeLight backend.

Runs on a remote server (via SSH) alongside Claude Code. Receives hook events
from codeisland-state.py via Unix socket, monitors JSONL session files, and
forwards everything to the CodeLight backend server over HTTP.

Usage:
    python3 relay.py setup          # First-time setup: generates config
    python3 relay.py start          # Run the relay daemon
    python3 relay.py status         # Show current relay status

Config stored at: ~/.codelight-relay/config.json
"""

import asyncio
import glob
import json
import os
import signal
import socket
import subprocess
import sys
import time
import hashlib
import hmac
from pathlib import Path

CONFIG_DIR = Path.home() / ".codelight-relay"
CONFIG_FILE = CONFIG_DIR / "config.json"
SOCKET_PATH = "/tmp/codeisland.sock"
CLAUDE_DIR = Path.home() / ".claude"
JSONL_POLL_INTERVAL = 2


def load_config():
    if not CONFIG_FILE.exists():
        return None
    with open(CONFIG_FILE) as f:
        return json.load(f)


def save_config(cfg):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    with open(CONFIG_FILE, "w") as f:
        json.dump(cfg, f, indent=2)


def detect_mux_info(claude_pid):
    info = {"mux_type": None, "session_name": None, "tab_index": None}
    try:
        environ_path = f"/proc/{claude_pid}/environ"
        if os.path.exists(environ_path):
            with open(environ_path, "rb") as f:
                env_data = f.read()
            for entry in env_data.split(b"\x00"):
                if entry.startswith(b"ZELLIJ_SESSION_NAME="):
                    info["mux_type"] = "zellij"
                    info["session_name"] = entry.split(b"=", 1)[1].decode()
                    break
    except (PermissionError, OSError):
        pass
    if info["mux_type"]:
        return info
    try:
        result = subprocess.run(
            ["tmux", "list-panes", "-a", "-F",
             "#{pane_pid} #{session_name}:#{window_index}.#{pane_index}"],
            capture_output=True, text=True, timeout=3)
        if result.returncode == 0:
            for line in result.stdout.strip().split("\n"):
                parts = line.split(" ", 1)
                if len(parts) == 2:
                    pane_pid = int(parts[0])
                    target = parts[1]
                    if _is_descendant(claude_pid, pane_pid):
                        info["mux_type"] = "tmux"
                        info["session_name"] = target.split(":")[0]
                        break
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        pass
    return info


def _is_descendant(target_pid, ancestor_pid):
    current = target_pid
    for _ in range(30):
        if current == ancestor_pid:
            return True
        if current <= 1:
            return False
        try:
            with open(f"/proc/{current}/stat") as f:
                stat = f.read().split(")")[-1].split()
                current = int(stat[1])
        except (OSError, IndexError, ValueError):
            return False
    return False


class HookSocketServer:
    def __init__(self, on_event):
        self.on_event = on_event
        self._server = None

    async def start(self):
        if os.path.exists(SOCKET_PATH):
            os.unlink(SOCKET_PATH)
        self._server = await asyncio.start_unix_server(
            self._handle_client, path=SOCKET_PATH)
        os.chmod(SOCKET_PATH, 0o666)
        print(f"[relay] Hook socket listening on {SOCKET_PATH}")

    async def _handle_client(self, reader, writer):
        try:
            data = await asyncio.wait_for(reader.read(65536), timeout=5)
            if not data:
                writer.close()
                return
            event = json.loads(data.decode())
            if event.get("status") == "waiting_for_approval":
                response = await self.on_event(event)
                if response:
                    writer.write(json.dumps(response).encode())
                    await writer.drain()
            else:
                asyncio.create_task(self.on_event(event))
            writer.close()
        except (asyncio.TimeoutError, json.JSONDecodeError, OSError):
            try:
                writer.close()
            except OSError:
                pass

    async def stop(self):
        if self._server:
            self._server.close()
            await self._server.wait_closed()
        if os.path.exists(SOCKET_PATH):
            os.unlink(SOCKET_PATH)


class JsonlWatcher:
    def __init__(self, on_message):
        self.on_message = on_message
        self._offsets = {}
        self._running = False

    async def start(self):
        self._running = True
        while self._running:
            try:
                await self._poll()
            except Exception as e:
                print(f"[relay] JSONL poll error: {e}")
            await asyncio.sleep(JSONL_POLL_INTERVAL)

    def stop(self):
        self._running = False

    async def _poll(self):
        projects_dir = CLAUDE_DIR / "projects"
        if not projects_dir.exists():
            return
        pattern = str(projects_dir / "**" / "*.jsonl")
        for filepath in glob.iglob(pattern, recursive=True):
            basename = os.path.basename(filepath)
            if basename.startswith("agent-"):
                continue
            try:
                size = os.path.getsize(filepath)
            except OSError:
                continue
            last_offset = self._offsets.get(filepath, 0)
            if size <= last_offset:
                continue
            try:
                with open(filepath, "r") as f:
                    f.seek(last_offset)
                    new_content = f.read()
                    self._offsets[filepath] = f.tell()
            except OSError:
                continue
            session_id = os.path.splitext(basename)[0]
            for line in new_content.strip().split("\n"):
                if not line.strip():
                    continue
                try:
                    parsed = json.loads(line)
                    await self.on_message(session_id, parsed)
                except json.JSONDecodeError:
                    continue


class BackendConnection:
    def __init__(self, config):
        self.server_url = config["server_url"].rstrip("/")
        self.device_id = config["device_id"]
        self.device_secret = config["device_secret"]
        self.token = None

    async def authenticate(self):
        import urllib.request, urllib.error
        auth_url = f"{self.server_url}/v1/auth"
        ts = str(int(time.time()))
        payload = json.dumps({
            "publicKey": self.device_id,
            "challenge": ts,
            "signature": self._sign_challenge(ts),
        }).encode()
        req = urllib.request.Request(auth_url, data=payload,
            headers={"Content-Type": "application/json"}, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read().decode())
                self.token = data.get("token")
                if self.token:
                    print("[relay] Authenticated with backend")
                    return True
        except (urllib.error.URLError, OSError) as e:
            print(f"[relay] Auth failed: {e}")
        return False

    def _sign_challenge(self, challenge):
        return hmac.new(self.device_secret.encode(),
            challenge.encode(), hashlib.sha256).hexdigest()

    async def emit_event(self, event_type, data):
        if not self.token:
            return
        import urllib.request, urllib.error
        url = f"{self.server_url}/v1/relay/event"
        payload = json.dumps({"type": event_type, "data": data}).encode()
        req = urllib.request.Request(url, data=payload, headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {self.token}",
        }, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                return json.loads(resp.read().decode())
        except (urllib.error.URLError, OSError) as e:
            print(f"[relay] Event send failed: {e}")
            return None

    async def poll_commands(self):
        if not self.token:
            return []
        import urllib.request, urllib.error
        url = f"{self.server_url}/v1/relay/commands"
        req = urllib.request.Request(url,
            headers={"Authorization": f"Bearer {self.token}"}, method="GET")
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                return json.loads(resp.read().decode()).get("commands", [])
        except (urllib.error.URLError, OSError):
            return []


def execute_focus(command):
    mux_type = command.get("mux_type")
    session_name = command.get("mux_session")
    tab_index = command.get("tab_index")
    if mux_type == "zellij":
        cmd = f"zellij --session {session_name} action go-to-tab {tab_index}"
        subprocess.run(["bash", "-l", "-c", cmd], timeout=5, capture_output=True)
    elif mux_type == "tmux":
        target = command.get("tmux_target", session_name)
        subprocess.run(["tmux", "select-window", "-t", target],
            timeout=5, capture_output=True)


class Relay:
    def __init__(self):
        self.config = load_config()
        self.sessions = {}
        self.backend = None
        self.hook_server = None
        self.jsonl_watcher = None

    async def start(self):
        if not self.config:
            print("[relay] No config found. Run: python3 relay.py setup")
            sys.exit(1)
        self.backend = BackendConnection(self.config)
        if not await self.backend.authenticate():
            print("[relay] Failed to authenticate. Check config.")
            sys.exit(1)
        self.hook_server = HookSocketServer(self._on_hook_event)
        await self.hook_server.start()
        self.jsonl_watcher = JsonlWatcher(self._on_jsonl_message)
        print("[relay] Relay started. Waiting for Claude Code sessions...")
        await asyncio.gather(
            self.jsonl_watcher.start(),
            self._poll_commands_loop(),
        )

    async def _on_hook_event(self, event):
        session_id = event.get("session_id", "unknown")
        status = event.get("status")
        cwd = event.get("cwd", "")
        pid = event.get("pid")
        if session_id not in self.sessions and pid:
            mux_info = detect_mux_info(pid)
            self.sessions[session_id] = {"mux_info": mux_info, "cwd": cwd, "pid": pid}
            print(f"[relay] New session: {session_id[:8]} cwd={cwd} "
                  f"mux={mux_info['mux_type']}:{mux_info.get('session_name')}")
        if session_id in self.sessions:
            self.sessions[session_id]["last_status"] = status
            self.sessions[session_id]["cwd"] = cwd
        session_meta = self.sessions.get(session_id, {})
        mux = session_meta.get("mux_info", {})
        message = {
            "session_id": session_id, "status": status, "cwd": cwd,
            "event": event.get("event"), "tool": event.get("tool"),
            "tool_input": event.get("tool_input"),
            "tool_use_id": event.get("tool_use_id"),
            "notification_type": event.get("notification_type"),
            "message": event.get("message"),
            "remote_info": {
                "host": socket.gethostname(),
                "user": os.environ.get("USER", "unknown"),
                "mux_type": mux.get("mux_type"),
                "mux_session": mux.get("session_name"),
                "mux_tab_index": mux.get("tab_index"),
            },
        }
        if status == "waiting_for_approval":
            response = await self.backend.emit_event("permission_request", message)
            if response and response.get("decision"):
                return {"decision": response["decision"], "reason": response.get("reason", "")}
            return None
        await self.backend.emit_event("hook_event", message)
        return None

    async def _on_jsonl_message(self, session_id, parsed_line):
        msg_type = parsed_line.get("type")
        if msg_type in ("human", "assistant", "tool_use", "tool_result"):
            await self.backend.emit_event("jsonl_message", {
                "session_id": session_id, "content": parsed_line})

    async def _poll_commands_loop(self):
        while True:
            try:
                commands = await self.backend.poll_commands()
                for cmd in commands:
                    if cmd.get("type") == "focus-session":
                        execute_focus(cmd)
                    elif cmd.get("type") == "launch-session":
                        self._launch_session(cmd)
            except Exception as e:
                print(f"[relay] Command poll error: {e}")
            await asyncio.sleep(3)

    def _launch_session(self, cmd):
        mux_type = cmd.get("mux_type", "zellij")
        cwd = cmd.get("cwd", str(Path.home()))
        command = cmd.get("command", "claude")
        if mux_type == "zellij":
            session_name = cmd.get("mux_session", f"claude-{int(time.time())}")
            launch_cmd = f"zellij --session {session_name} action new-tab --cwd {cwd} -- {command}"
            subprocess.Popen(["bash", "-l", "-c", launch_cmd])
        elif mux_type == "tmux":
            session_name = cmd.get("mux_session", "claude")
            subprocess.Popen(["tmux", "new-window", "-t", session_name, "-c", cwd, command])


def setup():
    print("CodeLight Relay Setup")
    print("=" * 40)
    server_url = input("Backend server URL (e.g., https://your-server.com): ").strip()
    if not server_url:
        print("Server URL is required.")
        sys.exit(1)
    device_id = hashlib.sha256(
        f"{socket.gethostname()}-{os.environ.get('USER', 'relay')}-{time.time()}".encode()
    ).hexdigest()[:32]
    device_secret = hashlib.sha256(os.urandom(32)).hexdigest()
    cfg = {
        "server_url": server_url, "device_id": device_id,
        "device_secret": device_secret,
        "host": socket.gethostname(),
        "user": os.environ.get("USER", "unknown"),
    }
    save_config(cfg)
    print(f"\nConfig saved to {CONFIG_FILE}")
    print(f"Device ID: {device_id}")
    print(f"\nThe relay will register as device '{socket.gethostname()}' on first connection.")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(0)
    command = sys.argv[1]
    if command == "setup":
        setup()
    elif command == "start":
        relay = Relay()
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, lambda: asyncio.ensure_future(_shutdown(relay, loop)))
        try:
            loop.run_until_complete(relay.start())
        except KeyboardInterrupt:
            pass
        finally:
            loop.close()
    elif command == "status":
        cfg = load_config()
        if cfg:
            print(f"Config: {CONFIG_FILE}")
            print(f"Server: {cfg.get('server_url')}")
            print(f"Device: {cfg.get('device_id', 'N/A')[:16]}...")
            print(f"Host:   {cfg.get('host')}")
        else:
            print("Not configured. Run: python3 relay.py setup")
    else:
        print(f"Unknown command: {command}")
        sys.exit(1)


async def _shutdown(relay, loop):
    print("\n[relay] Shutting down...")
    if relay.hook_server:
        await relay.hook_server.stop()
    if relay.jsonl_watcher:
        relay.jsonl_watcher.stop()
    loop.stop()


if __name__ == "__main__":
    main()
