"""Synthetic checks of the native Antigravity hook. No provider is contacted."""
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time
import unittest


class AntigravityHookTests(unittest.TestCase):
    conversation = "60fdb3d8-e6c3-485c-b5ef-59fe23a4b304"

    def setUp(self):
        workspace = tempfile.TemporaryDirectory(prefix="Pacer Antigravity ")
        self.addCleanup(workspace.cleanup)
        self.profile = Path(workspace.name) / "config"
        self.profile.mkdir()
        (self.profile / "pacer-progress").mkdir()
        (self.profile / "pacer-progress" / "enabled").write_bytes(b"on\n")
        (self.profile / "pacer-antigravity").mkdir()
        (self.profile / "pacer-antigravity" / "enabled").write_bytes(b"on\n")

    def hook(self, event, client="antigravity", **fields):
        transcript = (
            self.profile.parent / client / "brain" / self.conversation
            / ".system_generated" / "logs" / "transcript.jsonl"
        )
        payload = {
            "conversationId": self.conversation,
            "transcriptPath": str(transcript),
            "modelName": "gemini-test",
            "lastUserInput": "private prompt fixture",
            **fields,
        }
        result = subprocess.run(
            [ENGINE, "--antigravity-hook", event, str(self.profile)],
            input=json.dumps(payload), text=True, capture_output=True, timeout=8, check=True,
        )
        self.assertTrue(result.stdout, "Pacer should acknowledge the Antigravity hook")
        self.assertEqual(len(result.stdout.splitlines()), 1, "Expected one Antigravity hook reply")
        return json.loads(result.stdout)

    def row(self, client="antigravity"):
        path = self.profile / "pacer-antigravity" / (client + "-" + self.conversation + ".json")
        text = path.read_text(encoding="utf-8")
        self.assertNotIn("private prompt fixture", text)
        self.assertNotIn("transcriptPath", text)
        return json.loads(text)

    def test_lifecycle_distinguishes_clients_and_follow_up_turns(self):
        self.hook("PreInvocation", invocationNum=0)
        self.hook("PreInvocation", client="antigravity-ide", invocationNum=0)
        self.assertEqual(self.row()["phase"], "running")
        self.hook("Stop", fullyIdle=False, terminationReason="model_stop")
        self.assertEqual(self.row()["phase"], "running")
        self.hook("Stop", fullyIdle=True, terminationReason="model_stop")
        self.assertEqual(self.row()["phase"], "completed")
        self.assertEqual(self.row("antigravity-ide")["phase"], "running")
        self.hook("Stop", client="antigravity-ide", fullyIdle=True, terminationReason="error")
        self.assertEqual(self.row("antigravity-ide")["phase"], "interrupted")
        started = self.row()["started"]
        self.hook("PreInvocation", invocationNum=0)
        self.assertGreater(self.row()["started"], started)

    def test_progress_matches_the_local_tool_for_this_conversation(self):
        guidance = self.hook("PreInvocation", invocationNum=0)
        self.assertTrue(guidance.get("injectSteps"))
        self.assertFalse(self.hook("PreInvocation", invocationNum=1).get("injectSteps"))
        self.hook("PostToolUse", toolCall={"name": "mcp_pacer_progress_report_progress", "args": {"percent": 40}})
        self.assertEqual(self.row()["percent"], 40)
        for value in (True, 42.5, "42", 101):
            self.hook("PostToolUse", toolCall={"name": "mcp_pacer_progress_report_progress", "args": {"percent": value}})
        self.hook("PostToolUse", error="tool failed", toolCall={
            "name": "mcp_pacer_progress_report_progress", "args": {"percent": 70},
        })
        self.assertEqual(self.row()["percent"], 40)
        self.hook("PostToolUse", toolCall={"name": "call_mcp_tool", "args": {
            "ServerName": "pacer_progress", "ToolName": "report_progress", "Arguments": "{\"percent\":20}",
        }})
        self.assertEqual(self.row()["percent"], 20)
        (self.profile / "pacer-progress" / "enabled").unlink()
        self.hook("PostToolUse", toolCall={"name": "mcp_pacer_progress_report_progress", "args": {"percent": 50}})
        self.assertEqual(self.row()["percent"], 20)
        self.hook("Stop", fullyIdle=True, terminationReason="model_stop")
        self.hook("PreInvocation", invocationNum=0)
        self.assertNotIn("percent", self.row())


    def test_engine_setup_projection_and_removal_preserve_user_config(self):
        hooks_path = self.profile / "hooks.json"
        mcp_path = self.profile / "mcp_config.json"
        cli_settings = self.profile.parent / "antigravity-cli" / "settings.json"
        cli_settings.parent.mkdir()
        cli_settings.write_text('{"theme":"fixture"}', encoding="utf-8")
        hooks = {"existing": {"PreInvocation": [{"type": "command", "command": "echo existing"}]}}
        servers = {"existing": {"command": "fixture.exe", "args": ["--test"]}}
        hooks_path.write_text(json.dumps(hooks), encoding="utf-8")
        mcp_path.write_text(json.dumps({"mcpServers": servers}), encoding="utf-8")

        isolated_local = self.profile.parent / "local"
        isolated_local.mkdir()
        env = dict(os.environ, LOCALAPPDATA=str(isolated_local))
        engine = subprocess.Popen([ENGINE], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env,
                                  stderr=subprocess.DEVNULL, text=True, encoding="utf-8")
        self.addCleanup(engine.stdout.close)
        self.addCleanup(engine.stdin.close)
        self.addCleanup(lambda: engine.wait(timeout=10))
        self.addCleanup(lambda: engine.kill() if engine.poll() is None else None)
        frames = queue.Queue()

        def read():
            for line in engine.stdout:
                frames.put(json.loads(line))

        threading.Thread(target=read, daemon=True).start()

        def request(method, **params):
            frame = {"protocolVersion": 1, "id": method, "method": method, "params": params}
            if method == "initialize":
                frame["supportsHarnessModules"] = True
            engine.stdin.write(json.dumps(frame) + "\n")
            engine.stdin.flush()

        def wait_for(predicate, description):
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                try:
                    if predicate():
                        return
                except (FileNotFoundError, json.JSONDecodeError):
                    pass
                time.sleep(0.05)
            self.fail("Timed out waiting for " + description)

        def hooks_config():
            return json.loads(hooks_path.read_text(encoding="utf-8"))

        def mcp_config():
            return json.loads(mcp_path.read_text(encoding="utf-8"))["mcpServers"]

        def has_projected_progress():
            while not frames.empty():
                frame = frames.get_nowait()
                rows = (frame.get("presentation") or {}).get("rows") or []
                if any(row.get("progressFraction") == .37 for row in rows):
                    return True
            return False

        modes = dict.fromkeys(["codex", "claude", "deepseek", "workbuddy", "workbuddy-ai", "glm"], "disabled")
        modes["antigravity"] = "enabled"
        request("initialize", providerModes=modes, harnessHomes={"antigravity": str(self.profile)},
                monitorSSH=False, monitorWSL=False, monitorDurable=False)
        wait_for(lambda: "codex-pacer-antigravity" in hooks_config() and "pacer_progress" in mcp_config(),
                 "the hooks and MCP registrations")
        request("refresh")

        def has_automatic_progress_setup():
            while not frames.empty():
                frame = frames.get_nowait()
                if any(module.get("provider") == "antigravity"
                       and module.get("hasTaskProgress") is True
                       and module.get("progressConnector") is False
                       and not module.get("progressGuide")
                       for module in frame.get("modules", [])):
                    return True
            return False

        wait_for(has_automatic_progress_setup, "progress without the manual Connectors guide")
        self.assertEqual(hooks_config()["existing"], hooks["existing"])
        self.assertEqual(mcp_config()["existing"], servers["existing"])
        command = mcp_config()["pacer_progress"]
        call = {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}
        reporter = subprocess.run([command["command"], *command["args"]], input=json.dumps(call) + "\n",
                                  capture_output=True, text=True, timeout=10, check=True)
        self.assertEqual(json.loads(reporter.stdout)["result"]["tools"][0]["name"], "report_progress")
        call.update(method="tools/call", params={"name": "report_progress", "arguments": {"percent": 37}})
        reporter = subprocess.run([command["command"], *command["args"]], input=json.dumps(call) + "\n",
                                  capture_output=True, text=True, timeout=10, check=True)
        self.assertIn("pacer-progress:accepted", json.loads(reporter.stdout)["result"]["content"][0]["text"])

        hook_command = hooks_config()["codex-pacer-antigravity"]["PreInvocation"][0]["command"]
        transcript = self.profile.parent / "antigravity" / "brain" / self.conversation / ".system_generated" / "logs" / "transcript.jsonl"
        result = subprocess.run([os.environ["COMSPEC"], "/c", hook_command],
                                input=json.dumps({"conversationId": self.conversation, "transcriptPath": str(transcript)}),
                                text=True, capture_output=True, timeout=8, check=True)
        self.assertTrue(json.loads(result.stdout).get("injectSteps"))
        self.hook("PostToolUse", toolCall={
            "name": "mcp_pacer_progress_report_progress", "args": {"percent": 37},
        })
        request("refreshLocalHarness", provider="antigravity")
        wait_for(has_projected_progress, "a task with 37 percent progress on the island projection")

        def statusline():
            return json.loads(cli_settings.read_text(encoding="utf-8"))

        wait_for(lambda: "statusLine" in statusline(), "the Antigravity CLI quota command")
        line = statusline()["statusLine"]["command"]
        report = {"product": "antigravity", "email": "private@fixture.invalid", "conversation_title": "private prompt fixture",
                  "quota": {"gemini-weekly": {"remaining_fraction": .52, "reset_in_seconds": 3600},
                            "gemini-5h": {"remaining_fraction": 0, "reset_in_seconds": 1800},
                            "3p-5h": {"remaining_fraction": 1, "reset_time": "1970-01-01T00:00:00Z"},
                            "credits": {"remaining_amount": 55}, "invalid": {"remaining_fraction": 1.5},
                            "disabled": {"remaining_fraction": 1, "disabled": True}}}
        # The CLI passes the command as a single argument to cmd.exe. Windows
        # argument escaping here is different from composing a raw command line.
        subprocess.run([os.environ["COMSPEC"], "/c", line], input=json.dumps(report), text=True,
                       capture_output=True, timeout=8, check=True)
        raw = (self.profile / "pacer-antigravity" / "quota.json").read_text(encoding="utf-8")
        self.assertNotIn("private", raw)
        saved = json.loads(raw)
        self.assertEqual({row["id"]: row.get("percent") for row in saved["windows"]},
                         {"gemini-weekly": 52, "gemini-5h": 0, "3p-5h": 100, "credits": None})
        sample_file = self.profile / "pacer-antigravity" / "quota.json"
        subprocess.run([os.environ["COMSPEC"], "/c", line],
                       input=json.dumps({"product": "antigravity", "agent_state": "authenticating"}),
                       env=dict(os.environ, PACER_ANTIGRAVITY_QUOTA_REFRESH="1"), text=True,
                       capture_output=True, timeout=8, check=True)
        self.assertEqual(sample_file.read_text(encoding="utf-8"), raw,
                         "A background CLI sign-in transition must preserve the last reading")
        self.assertEqual(statusline()["theme"], "fixture")
        request("refresh")

        def has_projected_quota():
            while not frames.empty():
                frame = frames.get_nowait()
                quota = frame.get("antigravityQuota") or {}
                rows = quota.get("windows", [])
                if (any(row.get("percent") == 52 for row in rows)
                        and any(row["id"] == "3p-5h" and not row["stale"] for row in rows)):
                    return True
            return False

        wait_for(has_projected_quota, "Antigravity CLI quota in the island snapshot")
        saved["receivedAt"] = time.time() - 601
        (self.profile / "pacer-antigravity" / "quota.json").write_text(json.dumps(saved), encoding="utf-8")
        request("refresh")

        def reading_is_stale():
            while not frames.empty():
                frame = frames.get_nowait()
                rows = (frame.get("antigravityQuota") or {}).get("windows", [])
                if rows and all(row.get("stale") is True for row in rows):
                    return True
            return False

        wait_for(reading_is_stale, "old quota readings marked stale")
        request("retryHarnessProgressSetup", provider="antigravity")
        request("configure", providerModes={"antigravity": "disabled"})
        wait_for(lambda: hooks_config() == hooks and mcp_config() == servers and statusline() == {"theme": "fixture"},
                 "removal of Pacer's registrations")
        request("shutdown")


if __name__ == "__main__":
    ENGINE = sys.argv.pop(1)
    unittest.main()
