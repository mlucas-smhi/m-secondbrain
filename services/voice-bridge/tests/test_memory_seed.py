import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from bridge.memory_seed import inventory, source_kind


class MemorySeedTests(unittest.TestCase):
    def test_explicit_source_allowlist(self):
        self.assertEqual(source_kind("people/example.md"), "person")
        self.assertEqual(source_kind("projects/travel/example.md"), "project")
        for path in ("_system/personality.md", "services/.env.md", "people/.env.md",
                     "people/../security/policy.md", "people/key.pem", "/people/a.md"):
            self.assertIsNone(source_kind(path))

    def make_repo(self, root):
        def git(*args):
            return subprocess.run(["git", "-C", str(root), *args], check=True,
                                  capture_output=True).stdout.decode().strip()
        git("init")
        git("config", "user.name", "Fixture")
        git("config", "user.email", "fixture@example.invalid")
        (root / "people").mkdir()
        (root / "reference").mkdir()
        (root / "_system").mkdir()
        (root / "people/a.md").write_text("# Example\nPrivate fixture detail\nDecision A\n")
        (root / "reference/relationships.md").write_text("# Guidance\n[[a]]\n")
        (root / "_system/personality.md").write_text("Not memory")
        git("add", ".")
        git("commit", "-m", "Fixture")
        return git

    def test_immutable_preview_excludes_worktree_and_content(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            git = self.make_repo(root)
            before = inventory(root, "HEAD")
            (root / "people/a.md").write_text("Changed locally")
            (root / "people/new.md").write_text("Untracked")
            after = inventory(root, "HEAD")
            self.assertEqual(before, after)
            self.assertEqual(after["record_count"], 2)
            self.assertNotIn("Private fixture detail", json.dumps(after))
            self.assertEqual(after["source_revision"], git("rev-parse", "HEAD"))
            self.assertTrue(all(r["sensitivity_level"] == 3 for r in after["records"]))
            person = next(r for r in after["records"] if r["kind"] == "person")
            self.assertIn("contains_placeholder_text", person["warnings"])
            self.assertEqual(after["status"], "preview_only")

    def test_symlink_source_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            git = self.make_repo(root)
            (root / "people/link.md").symlink_to("../_system/personality.md")
            git("add", ".")
            git("commit", "-m", "Symlink fixture")
            with self.assertRaisesRegex(ValueError, "nonregular_knowledge_source"):
                inventory(root, "HEAD")
