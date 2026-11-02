"""Exercise the fetcher with fake curl/git/helm; no network or cloud calls."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "modules/migration-assistant/scripts/fetch-chart.sh"
STUB = r"""#!/usr/bin/env python3
import json, os, pathlib, sys, time
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["COMMAND_LOG"], "a") as log:
    log.write(json.dumps([name, *args]) + "\n")
if name == "curl":
    pathlib.Path(args[args.index("--output") + 1]).write_text("downloaded-chart")
    print(os.environ.get("HTTP_STATUS", "200"), end="")
    sys.exit(int(os.environ.get("CURL_EXIT", "0")))
elif name == "git":
    pathlib.Path(args[-1]).mkdir()
    time.sleep(float(os.environ.get("GIT_DELAY", "0")))
    sys.exit(int(os.environ.get("GIT_EXIT", "0")))
elif args[0] == "package":
    sys.exit_code = int(os.environ.get("PACKAGE_EXIT", "0"))
    if sys.exit_code:
        sys.exit(sys.exit_code)
    destination = pathlib.Path(args[args.index("--destination") + 1])
    (destination / "migration-assistant-1.2.3.tgz").write_text("packaged-chart")
elif args[:2] == ["show", "chart"]:
    sys.exit(int(os.environ.get("SHOW_EXIT", "0")))
else:
    raise AssertionError("Unexpected command: " + repr(args))
"""


class FetchChartTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="chart fetch ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for command in ("curl", "git", "helm"):
            path = self.bin / command
            path.write_text(STUB)
            path.chmod(0o755)
        self.cache = self.root / "cache $(touch injected)"
        self.cache.mkdir()
        self.target = self.cache / "migration-assistant-1.2.3.tgz"
        self.target.write_text("existing-chart")
        self.log = self.root / "commands.jsonl"

    def run_fetch(self, **values):
        env = {
            **os.environ,
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "CHART_VERSION": "1.2.3",
            "CHART_CACHE_DIR": str(self.cache),
            "COMMAND_LOG": str(self.log),
            **values,
        }
        result = subprocess.run(["bash", str(SCRIPT)], env=env, cwd=self.root,
                                capture_output=True, text=True, timeout=15)
        self.assertFalse((self.root / "injected").exists())
        self.assertEqual(list(self.cache.glob(".download.*")), [])
        return result

    def commands(self):
        return [json.loads(line)[0] for line in self.log.read_text().splitlines()]

    def test_download_handles_spaces_and_shell_metacharacters_literally(self):
        result = self.run_fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.target.read_text(), "downloaded-chart")
        self.assertEqual(self.commands(), ["curl", "helm"])

    def test_missing_asset_packages_exact_tag(self):
        result = self.run_fetch(HTTP_STATUS="404")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.target.read_text(), "packaged-chart")
        self.assertEqual(self.commands(), ["curl", "git", "helm", "helm"])
        self.assertIn('"--branch", "1.2.3"', self.log.read_text())

    def test_transport_and_http_failures_preserve_cache_without_fallback(self):
        for settings in ({"CURL_EXIT": "7"}, {"HTTP_STATUS": "503"}):
            with self.subTest(settings=settings):
                self.log.unlink(missing_ok=True)
                self.assertNotEqual(self.run_fetch(**settings).returncode, 0)
                self.assertEqual(self.target.read_text(), "existing-chart")
                self.assertEqual(self.commands(), ["curl"])

    def test_source_clone_failure_and_timeout_preserve_cache_without_packaging(self):
        for settings in ({"GIT_EXIT": "17"},
                         {"GIT_DELAY": "30", "CHART_SOURCE_TIMEOUT_SECONDS": "0.2"}):
            with self.subTest(settings=settings):
                self.log.unlink(missing_ok=True)
                result = self.run_fetch(HTTP_STATUS="404", **settings)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.target.read_text(), "existing-chart")
                self.assertEqual(self.commands(), ["curl", "git"])
                if "GIT_DELAY" in settings:
                    self.assertIn("Source clone exceeded", result.stderr)

    def test_invalid_chart_and_packaging_failures_preserve_cache(self):
        for settings in ({"SHOW_EXIT": "1"}, {"HTTP_STATUS": "404", "PACKAGE_EXIT": "1"}):
            with self.subTest(settings=settings):
                self.assertNotEqual(self.run_fetch(**settings).returncode, 0)
                self.assertEqual(self.target.read_text(), "existing-chart")

    def test_invalid_versions_fail_before_any_command(self):
        for version in ("../outside", "1.2.3;touch injected", "$(touch injected)", ""):
            with self.subTest(version=version):
                self.assertNotEqual(self.run_fetch(CHART_VERSION=version).returncode, 0)
                self.assertFalse(self.log.exists())
                self.assertEqual(self.target.read_text(), "existing-chart")


if __name__ == "__main__":
    unittest.main()
