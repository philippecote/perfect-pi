"""Installer integration tests: real Bash/Node, isolated homes, fake installers."""
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "install-perfect-pi.sh"
NODE = shutil.which("node")


@unittest.skipUnless(NODE, "Node is required for configuration tests")
class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="perfect-pi-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home with spaces"
        self.home.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.agent = self.home / ".pi/agent"
        self.shared = self.home / ".config/mcp/mcp.json"
        self.calls = self.root / "calls.jsonl"
        self.env = dict(os.environ, HOME=str(self.home), PATH=f"{self.bin}:/usr/bin:/bin",
                        TMPDIR=str(self.root), MOCK_CALLS=str(self.calls),
                        MOCK_NPM_ROOT=str(self.root / "global modules"), TERM="xterm-256color",
                        JINA_API_KEY="test-key-must-not-be-written")
        for key in ("PI_CODING_AGENT_DIR", "XDG_CONFIG_HOME", "CI", "NO_COLOR"):
            self.env.pop(key, None)
        mock = self.bin / "mock"
        mock.write_text(f"#!{sys.executable}\n" + r'''
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
if args == ['-v'] or args == ['--version']:
    print('10.9.3')
    sys.exit(0)
if name == 'npm' and args == ['root', '-g']:
    print(os.environ['MOCK_NPM_ROOT'])
    sys.exit(0)
with open(os.environ['MOCK_CALLS'], 'a') as f:
    f.write(json.dumps({'name': name, 'args': args}) + '\n')
if os.environ.get('MOCK_FAIL') and os.environ['MOCK_FAIL'] in ' '.join([name] + args):
    print('simulated install failure', file=sys.stderr)
    sys.exit(42)
if name == 'pi' and args[:1] == ['install']:
    root = pathlib.Path(os.environ['PI_CODING_AGENT_DIR'])
    file = root / 'settings.json'
    data = json.loads(file.read_text()) if file.exists() else {}
    packages = data.setdefault('packages', [])
    if args[1] not in packages: packages.append(args[1])
    root.mkdir(parents=True, exist_ok=True)
    file.write_text(json.dumps(data))
if name == 'pi' and '--mode' in args and os.environ.get('MOCK_EXTENSION_ERROR'):
    print('Failed to load extension: test extension', file=sys.stderr)
''')
        mock.chmod(0o755)
        for name in ("npm", "pi", "git", "rg", "go", "rustup", "xcrun"):
            (self.bin / name).symlink_to(mock)
        (self.bin / "node").symlink_to(NODE)

    def write_json(self, file, value):
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(json.dumps(value, indent=2) + "\n")

    def run_installer(self, *args, pipe=False):
        command = ["/bin/bash", "-s", "--"] if pipe else ["/bin/bash", str(SCRIPT)]
        return subprocess.run(command + list(args), input=SCRIPT.read_text() if pipe else "",
                              capture_output=True, text=True, env=self.env, cwd=self.home, timeout=20)

    def installed_calls(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def test_dry_runs_need_no_dependencies_and_write_nothing(self):
        self.env["PATH"] = str(self.root / "missing-bin")
        for thinking, args in (("medium", ()), ("high", ("--thinking", "high"))):
            with self.subTest(thinking=thinking):
                result = self.run_installer("--dry-run", *args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"Thinking         {thinking}", result.stdout)
                self.assertNotIn("\x1b", result.stdout)
        self.assertEqual(list(self.home.iterdir()), [])
        self.assertEqual(self.installed_calls(), [])

    def test_invalid_arguments_stop_before_writes(self):
        for args in (("--profile",), ("--profile", "turbo"), ("--thinking", "huge"),
                     ("--with", "bogus"), ("--with", "index,"), ("--oops",)):
            with self.subTest(args=args):
                result = self.run_installer(*args)
                self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.agent.exists())

    def test_defaults_merge_back_up_disable_and_rerun(self):
        original = {
            "theme": "my-theme", "userSetting": {"keep": True},
            "packages": ["npm:custom", "npm:pi-subagents@1.2.3",
                         {"source": "npm:open-codebase-index", "skills": []}],
            "modelThinkingLevels": {"openai-codex/gpt-5.6-sol": "high", "other/model": "high"},
            "compaction": {"modelOverrides": {"openai-codex/gpt-5.6-sol": {"reserveTokens": 12000}}},
            "subagents": {"agentOverrides": {"worker": {"model": "custom/worker"}}},
        }
        settings_file = self.agent / "settings.json"
        self.write_json(settings_file, original)
        before = settings_file.read_bytes()
        self.write_json(self.shared, {"mcpServers": {"custom": {"url": "https://example.com/mcp"}}})
        self.write_json(self.agent / "mcp.json", {"settings": {"idleTimeout": 2}, "mcpServers": {"keep": {"directTools": True}}})
        permissions_file = self.agent / "permission-mode/permission-mode.json"
        permissions = {"defaultMode": "default", "modes": {"build": {"permission": {"tool": "ask"}}}}
        self.write_json(permissions_file, permissions)
        permissions_before = permissions_file.read_bytes()
        args = ("--yes", "--without", "servers,subagents")
        result = self.run_installer(*args)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        s = json.loads(settings_file.read_text())
        self.assertEqual(s["defaultThinkingLevel"], "medium")
        self.assertEqual(s["defaultModel"], "gpt-5.6-sol")
        self.assertEqual(s["theme"], "my-theme")
        self.assertEqual(s["userSetting"], {"keep": True})
        self.assertIn("npm:custom", s["packages"])
        self.assertFalse(any("pi-subagents" in str(p) or "open-codebase-index" in str(p) for p in s["packages"]))
        self.assertIn("npm:@mrclrchtr/supi-context@6.4.0", s["packages"])
        self.assertEqual(s["modelThinkingLevels"]["openai-codex/gpt-5.6-sol"], "medium")
        self.assertEqual(s["modelThinkingLevels"]["other/model"], "high")
        self.assertEqual(s["compaction"]["modelOverrides"]["openai-codex/gpt-5.6-sol"], {"reserveTokens": 12000, "keepRecentTokens": 20000})
        self.assertEqual(s["subagents"]["agentOverrides"]["worker"]["model"], "custom/worker")
        adapter = json.loads((self.agent / "mcp.json").read_text())
        self.assertEqual(adapter["settings"]["outputGuard"]["maxBytes"], 24576)
        self.assertEqual(adapter["settings"]["idleTimeout"], 2)
        self.assertTrue(adapter["mcpServers"]["keep"]["directTools"])
        self.assertIn("${JINA_API_KEY}", self.shared.read_text())
        self.assertNotIn(self.env["JINA_API_KEY"], self.shared.read_text())
        backups = list((self.agent / "backups").glob("*/settings.json"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), before)
        self.assertEqual(backups[0].stat().st_mode & 0o777, 0o600)
        self.assertEqual((backups[0].parent / "permissions.json").read_bytes(), permissions_before)
        permission_config = json.loads(permissions_file.read_text())
        self.assertEqual(permission_config["defaultMode"], "build")
        self.assertEqual(permission_config["modes"]["build"]["permission"]["tool"], "ask")
        self.assertEqual(permission_config["modes"]["build"]["permission"]["path"][str(self.agent / "auth.json")], "deny")
        self.assertEqual(permission_config["modes"]["build"]["permission"]["external_directory"][str(self.agent / "*")], "allow")
        manifest = json.loads((self.agent / "npm/package.json").read_text())
        self.assertEqual(manifest["overrides"]["lsp-pi"]["vscode-languageserver-protocol"], "3.17.5")
        result = self.run_installer(*args)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(settings_file.read_text()), s)

    def test_pipe_install_with_context_mode_and_custom_paths(self):
        self.agent = self.home / "custom agent"
        self.env["PI_CODING_AGENT_DIR"] = str(self.agent)
        self.env["XDG_CONFIG_HOME"] = str(self.home / "custom config")
        custom_shared = self.home / "custom config/mcp/mcp.json"
        existing_jina = {"url": "https://example.com/custom-jina", "disabled": True}
        self.write_json(custom_shared, {"mcpServers": {"jina-mcp-server": existing_jina}})
        result = self.run_installer("--yes", "--with", "context-mode",
                                    "--without", "servers", "--provider", "custom", "--model", "fast",
                                    "--thinking", "minimal", pipe=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        s = json.loads((self.agent / "settings.json").read_text())
        self.assertIn("custom/fast", s["enabledModels"])
        self.assertEqual(s["defaultThinkingLevel"], "minimal")
        self.assertIn("npm:context-mode@1.0.169", s["packages"])
        self.assertIn("npm:pi-subagents", s["packages"])
        children = json.loads((self.agent / "extensions/subagent/config.json").read_text())
        self.assertEqual(children["globalConcurrencyLimit"], 2)
        self.assertEqual(children["maxSubagentSpawnsPerSession"], 12)
        self.assertEqual(children["defaultSubagentContext"], "fresh")
        adapter = json.loads((self.agent / "mcp.json").read_text())
        self.assertNotIn("context-mode", adapter["mcpServers"])
        self.assertFalse((self.home / ".pi").exists())
        rpc = [c for c in self.installed_calls() if "rpc" in c["args"]]
        self.assertEqual(len(rpc), 1)
        self.assertIn("--no-session", rpc[0]["args"])
        self.assertIn("--no-approve", rpc[0]["args"])
        self.assertEqual(json.loads(custom_shared.read_text())["mcpServers"]["jina-mcp-server"], existing_jina)

    def test_high_override_installs_selected_servers_and_bounds_children(self):
        result = self.run_installer("--yes", "--thinking", "high", "--with", "index")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        s = json.loads((self.agent / "settings.json").read_text())
        self.assertEqual(s["defaultThinkingLevel"], "high")
        self.assertIn("npm:open-codebase-index", s["packages"])
        self.assertIn("npm:context-mode@1.0.169", s["packages"])
        self.assertEqual(s["subagents"]["defaultThinking"], "high")
        self.assertEqual(s["subagents"]["agentOverrides"]["scout"]["thinking"], "low")
        self.assertFalse(s["subagents"]["agentOverrides"]["worker"]["fast"])
        children = json.loads((self.agent / "extensions/subagent/config.json").read_text())
        self.assertEqual(children["maxSubagentSpawnsPerSession"], 12)
        calls = self.installed_calls()
        self.assertTrue(any(c["name"] == "npm" and "pyright" in c["args"] for c in calls))
        self.assertTrue(any(c["name"] == "go" for c in calls))
        self.assertTrue(any(c["name"] == "rustup" for c in calls))
        self.assertTrue(all("--no-approve" in c["args"] for c in calls if c["name"] == "pi" and c["args"][0] == "install"))

    def test_default_permissions_and_toolkit(self):
        result = self.run_installer("--yes", "--without", "servers")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        s = json.loads((self.agent / "settings.json").read_text())
        self.assertEqual(s["defaultProvider"], "openai-codex")
        self.assertEqual(s["defaultModel"], "gpt-5.6-sol")
        self.assertEqual(s["defaultThinkingLevel"], "medium")
        self.assertEqual(s["subagents"]["defaultThinking"], "medium")
        self.assertIn("npm:context-mode@1.0.169", s["packages"])
        self.assertIn("npm:pi-subagents", s["packages"])
        self.assertNotIn("npm:open-codebase-index", s["packages"])
        permissions = json.loads((self.agent / "permission-mode/permission-mode.json").read_text())
        self.assertEqual(permissions["defaultMode"], "build")
        pi_root = Path(self.env["MOCK_NPM_ROOT"]) / "@earendil-works/pi-coding-agent"
        for mode in ("default", "plan", "build", "yolo"):
            policy = permissions["modes"][mode]["permission"]
            self.assertEqual(policy["path"][str(self.agent / "auth.json")], "deny")
        for mode in ("default", "plan", "build"):
            external = permissions["modes"][mode]["permission"]["external_directory"]
            self.assertEqual(external[str(self.agent / "*")], "allow")
            self.assertEqual(external[str(pi_root / "docs" / "*")], "allow")
            self.assertEqual(external[str(pi_root / "examples" / "*")], "allow")
        self.assertEqual(permissions["modes"]["build"]["permission"]["write"][str(self.agent / "*")], "ask")
        self.assertEqual(permissions["modes"]["build"]["permission"]["edit"][str(pi_root / "*")], "deny")
        children = json.loads((self.agent / "extensions/subagent/config.json").read_text())
        self.assertEqual(children["maxSubagentSpawnsPerRun"], 6)
        self.assertEqual(s["retry"]["maxRetries"], 2)

    def test_bad_permissions_stop_before_install(self):
        target = self.agent / "permission-mode/permission-mode.json"
        self.write_json(target, {"modes": []})
        before = target.read_bytes()
        result = self.run_installer("--yes")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_bytes(), before)
        self.assertEqual(self.installed_calls(), [])

    def test_bad_config_does_not_install_or_overwrite(self):
        target = self.agent / "settings.json"
        for value in (None, [], {"packages": {}}, {"compaction": {"modelOverrides": []}},
                      {"subagents": {"agentOverrides": {"worker": None}}}):
            with self.subTest(value=value):
                self.write_json(target, value)
                before = target.read_bytes()
                result = self.run_installer("--yes")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(target.read_bytes(), before)
        target.write_text("{broken json")
        self.assertNotEqual(self.run_installer("--yes").returncode, 0)
        self.assertFalse((self.agent / "backups").exists())
        self.assertEqual(self.installed_calls(), [])

    def test_install_failure_has_diagnostics_and_does_not_continue(self):
        self.env["MOCK_FAIL"] = "pi install npm:lsp-pi"
        result = self.run_installer("--yes", "--without", "servers")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("simulated install failure", result.stderr)
        self.assertIn("exit 42", result.stderr)
        self.assertIn("Log:", result.stderr)
        self.assertNotIn("READY TO SHIP", result.stdout)
        self.assertFalse(any("pi-permission-modes" in str(c) for c in self.installed_calls()))

    def test_extension_error_is_not_false_success(self):
        self.env["MOCK_EXTENSION_ERROR"] = "1"
        result = self.run_installer("--yes", "--without", "servers")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Failed to load extension", result.stderr)
        self.assertNotIn("READY TO SHIP", result.stdout)

    def terminal_session(self, actions, args=(), rows=24, cols=80):
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(self.home)
            os.execve("/bin/bash", ["bash", str(SCRIPT), *args], self.env)
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        output = b""
        pending = b""
        try:
            for expected, response in actions:
                deadline = time.monotonic() + 8
                while expected not in pending:
                    if time.monotonic() > deadline:
                        self.fail(f"Timed out waiting for {expected!r}: {output.decode(errors='replace')}")
                    if select.select([fd], [], [], 0.1)[0]:
                        chunk = os.read(fd, 65536)
                        if not chunk: self.fail("Unexpected terminal EOF")
                        output += chunk
                        pending += chunk
                pending = pending.split(expected, 1)[1]
                os.write(fd, response)
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                if select.select([fd], [], [], 0.1)[0]:
                    try:
                        chunk = os.read(fd, 65536)
                        if not chunk: break
                        output += chunk
                    except OSError as error:
                        if error.errno != errno.EIO: raise
                        break
                done, status = os.waitpid(pid, os.WNOHANG)
                if done:
                    pid = 0
                    return os.waitstatus_to_exitcode(status), output.decode(errors="replace")
            while time.monotonic() < deadline:
                done, status = os.waitpid(pid, os.WNOHANG)
                if done:
                    pid = 0
                    return os.waitstatus_to_exitcode(status), output.decode(errors="replace")
                time.sleep(0.05)
            self.fail(f"Terminal process did not exit: {output.decode(errors='replace')}")
        finally:
            os.close(fd)
            if pid:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)

    def test_keyboard_wizard_and_cancel_restore_terminal(self):
        status, output = self.terminal_session([
            (b"Space: toggle", b" \x1b[B \n"),
            (b"Install this setup?", b"n\n"),
        ])
        self.assertEqual(status, 130, output)
        self.assertNotIn("Choose your cost profile", output)
        self.assertIn("Thinking         medium", output)
        self.assertIn("monitor           off", output)
        self.assertIn("context-mode      off", output)
        self.assertIn("\x1b[?1049h", output)
        self.assertIn("\x1b[?1049l", output)
        self.assertIn("\x1b[?25h", output)
        self.assertFalse(self.agent.exists())

    def test_no_color_numbered_menu_and_eof(self):
        self.env["NO_COLOR"] = "1"
        status, output = self.terminal_session([(b"q to cancel:", b"\x04")], rows=18, cols=50)
        self.assertEqual(status, 130, output)
        self.assertNotIn("\x1b", output)
        self.assertFalse(self.agent.exists())


if __name__ == "__main__":
    unittest.main()
