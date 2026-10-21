"""Starts and stops the real Minecraft client (gradle runClient, Fabric dev environment) on a virtual display."""
import os
import re
import signal
import subprocess
import time


class MinecraftClient:
    def __init__(self, mod_dir, log_path, world="TestFlat", display=":99"):
        self.mod_dir = mod_dir
        self.log_path = log_path
        self.world = world
        self.display = display
        self.proc = None
        self.log_offset = 0

    def _ensure_display(self):
        if subprocess.run(["pgrep", "-x", "Xvfb"], capture_output=True).returncode != 0:
            subprocess.Popen(["Xvfb", self.display, "-screen", "0", "1280x720x24"], stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
            time.sleep(1.5)

    @staticmethod
    def stop_all():
        """Stops any Minecraft dev client left running (only java processes, never the caller)."""
        out = subprocess.run(["ps", "-eo", "pid,comm,args"], capture_output=True, text=True).stdout
        for line in out.splitlines()[1:]:
            parts = line.split(None, 2)
            if len(parts) == 3 and parts[1] == "java" and ("devlaunchinjector" in parts[2] or "gradle-wrapper.jar runClient" in parts[2]):
                try:
                    os.kill(int(parts[0]), signal.SIGTERM)
                except Exception:
                    pass
        time.sleep(3)

    def build(self):
        r = subprocess.run(["./gradlew", "build", "-q"], cwd=self.mod_dir, capture_output=True, text=True)
        out = "\n".join(l for l in (r.stdout + r.stderr).splitlines() if "JAVA_TOOL_OPTIONS" not in l)
        return r.returncode == 0, out

    def start(self, config_path, output_file, timeout=150):
        self.stop_all()
        self._ensure_display()
        os.makedirs(os.path.dirname(config_path), exist_ok=True)
        with open(config_path, "w") as f:
            f.write(output_file + "\n")
        log = open(self.log_path, "w")
        env = dict(os.environ, DISPLAY=self.display)
        self.proc = subprocess.Popen(["./gradlew", "runClient", "--args=--quickPlaySingleplayer " + self.world + " --username Tester"],
                                     cwd=self.mod_dir, stdout=log, stderr=subprocess.STDOUT, env=env, start_new_session=True)
        end = time.time() + timeout
        while time.time() < end:
            time.sleep(2)
            text = self.read_log()
            if re.search(r"Loaded \d+ advancements", text):
                time.sleep(3)
                return True
            if self.proc.poll() is not None:
                return False
        return False

    def stop(self):
        if self.proc is not None:
            try:
                os.killpg(self.proc.pid, signal.SIGTERM)
            except Exception:
                pass
            self.proc = None
        self.stop_all()

    def read_log(self):
        try:
            with open(self.log_path, errors="replace") as f:
                return f.read()
        except Exception:
            return ""

    def mark(self):
        """Remembers the current end of the log; chat_since() returns what came after."""
        self.log_offset = len(self.read_log())

    def chat_since(self):
        text = self.read_log()[self.log_offset:]
        return [l.split("[CHAT] ", 1)[1] for l in text.splitlines() if "[CHAT] " in l]

    def log_since(self):
        return self.read_log()[self.log_offset:]
