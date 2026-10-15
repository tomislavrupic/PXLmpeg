import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
GUARD = REPO / "Scripts/safe-dev.py"

class SafeDevelopmentTests(unittest.TestCase):
    def run_guard(self, *args):
        return subprocess.run([sys.executable, str(GUARD), *map(str,args)], capture_output=True, text=True)

    def test_editor_cannot_truncate_outside_repository_or_follow_symlink(self):
        with tempfile.TemporaryDirectory(prefix="pxl-safety-") as external:
            original = Path(external).resolve()/"original.mxf"
            original.write_bytes(b"harmless decoy original")
            link = REPO/".work/safety/escape-link"
            link.parent.mkdir(parents=True,exist_ok=True)
            link.symlink_to(original)
            try:
                for target in [original, link]:
                    result = self.run_guard("edit", "--", sys.executable, "-c", "from pathlib import Path; import sys; Path(sys.argv[1]).write_bytes(b'bad')", target)
                    self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                    self.assertIn("PermissionError",result.stderr)
                    self.assertEqual(original.read_bytes(),b"harmless decoy original")
            finally:
                link.unlink()

    def test_stage_is_independent_and_probe_cannot_write_input_or_read_original(self):
        with tempfile.TemporaryDirectory(prefix="pxl-safety-") as external:
            original = Path(external).resolve()/"original.MXF"
            original.write_bytes(bytes(range(256))*16)
            before = original.read_bytes()
            result = self.run_guard("stage", original)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            fixture = Path(result.stdout.strip())
            manifest = json.loads((fixture/"manifest.json").read_text())
            copied = fixture/"input"/manifest["filename"]
            self.assertEqual(copied.read_bytes(),before)
            self.assertNotEqual(copied.stat().st_ino,original.stat().st_ino)
            self.assertEqual(manifest["sha256"],hashlib.sha256(before).hexdigest())
            for mode in ["edit","probe"]:
                command = [mode] + (["--fixture",fixture] if mode == "probe" else [])
                result = self.run_guard(*command,"--",sys.executable,"-c","from pathlib import Path; import sys; Path(sys.argv[1]).write_bytes(b'bad')",copied)
                self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn("PermissionError",result.stderr)
                self.assertEqual(copied.read_bytes(),before)
            result = self.run_guard("probe","--fixture",fixture,"--",sys.executable,"-c","from pathlib import Path; import sys; Path(sys.argv[1]).read_bytes()",original)
            self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn("PermissionError",result.stderr)
            result = self.run_guard("probe","--fixture",fixture,"--",sys.executable,"-c","from pathlib import Path; import os; Path(os.environ['PXL_DISPOSABLE_OUTPUT']).joinpath('allowed.txt').write_text('ok')")
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            # Editors can summarize existing reports but cannot read input,
            # receipt or arbitrary fixture output, or mutate admitted reports.
            result = self.run_guard("probe","--fixture",fixture,"--",sys.executable,"-c",
                "from pathlib import Path; import os; Path(os.environ['PXL_DISPOSABLE_OUTPUT']).joinpath('report.json').write_text('{}')")
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            report = fixture/"output/report.json"
            result = self.run_guard("edit","--",sys.executable,"-c",
                "from pathlib import Path; import sys; assert Path(sys.argv[1]).read_text() == '{}'",report)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            for blocked in [copied,fixture/"manifest.json",fixture/"output/allowed.txt"]:
                result = self.run_guard("edit","--",sys.executable,"-c",
                    "from pathlib import Path; import sys; Path(sys.argv[1]).read_bytes()",blocked)
                self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn("PermissionError",result.stderr)
            result = self.run_guard("edit","--",sys.executable,"-c",
                "from pathlib import Path; import sys; Path(sys.argv[1]).write_text('bad')",report)
            self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertEqual(report.read_text(),"{}")
            self.assertEqual(original.read_bytes(),before)

    def test_registered_original_inside_repository_is_still_protected(self):
        original = REPO/".work/safety/inside-original.mxf"
        original.write_bytes(b"synthetic source inside repository")
        result = self.run_guard("stage",original)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        result = self.run_guard("edit","--",sys.executable,"-c","from pathlib import Path; import sys; Path(sys.argv[1]).write_bytes(b'bad')",original)
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(original.read_bytes(),b"synthetic source inside repository")

    def test_ancestor_rename_cannot_relocate_protected_media(self):
        # Isolated synthetic workspace: never rename actual repository/fixtures.
        with tempfile.TemporaryDirectory(prefix="pxl-safety-") as external:
            workspace = Path(external).resolve()/"repo"
            original = workspace/".work/originals/original.mxf"
            original.parent.mkdir(parents=True)
            original.write_bytes(b"synthetic relocation decoy")
            fake_media = workspace/".work/disposable-media"
            receipt = fake_media/"fixture/manifest.json"
            receipt.parent.mkdir(parents=True)
            receipt.write_text(json.dumps({"source":str(original)}))
            spec = importlib.util.spec_from_file_location("safe_dev_test",GUARD)
            guard = importlib.util.module_from_spec(spec); spec.loader.exec_module(guard)
            guard.MEDIA = fake_media
            policy = guard.edit_policy(workspace,workspace/"temp")
            moved = workspace/".work-moved"
            result = subprocess.run([str(guard.SANDBOX),"-p",policy,sys.executable,"-c",
                "import os,sys; from pathlib import Path; os.rename(sys.argv[1],sys.argv[2]); Path(sys.argv[2]).joinpath('originals/original.mxf').write_bytes(b'bad')",
                str(workspace/".work"),str(moved)],capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertTrue(original.exists())
            self.assertEqual(original.read_bytes(),b"synthetic relocation decoy")

    def test_hard_link_escape_is_denied(self):
        with tempfile.TemporaryDirectory(prefix="pxl-safety-") as external:
            original = Path(external).resolve()/"hardlink-original.mxf"
            original.write_bytes(b"harmless decoy original")
            link = REPO/".work/safety/hardlink-escape"
            try:
                result = self.run_guard("edit","--",sys.executable,"-c","import os,sys; from pathlib import Path; os.link(sys.argv[1],sys.argv[2]); Path(sys.argv[2]).write_bytes(b'bad')",original,link)
                self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertEqual(original.read_bytes(),b"harmless decoy original")
            finally:
                if link.exists(): link.unlink()

    def test_editor_can_write_repository_output(self):
        target = REPO/".work/safety/allowed-edit.txt"
        result = self.run_guard("edit","--",sys.executable,"-c","from pathlib import Path; import sys; Path(sys.argv[1]).write_text('allowed')",target)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(target.read_text(),"allowed")

    def test_missing_sandbox_fails_closed_before_launch(self):
        spec = importlib.util.spec_from_file_location("safe_dev_missing",GUARD)
        guard = importlib.util.module_from_spec(spec); spec.loader.exec_module(guard)
        guard.SANDBOX = Path("/nonexistent/pxl-sandbox-exec")
        with self.assertRaisesRegex(RuntimeError,"refusing to run unprotected"):
            guard.launch("",["/usr/bin/true"],REPO,REPO/".work/safety/tmp")

    def test_probe_requires_receipt_and_refuses_unsafe_fixture(self):
        result = self.run_guard("probe","--fixture",REPO,"--","/usr/bin/true")
        self.assertNotEqual(result.returncode,0)

if __name__ == "__main__": unittest.main()
