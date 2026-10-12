"""Regression checks for accidental report and pack publication."""
from pathlib import Path
import hashlib
import json
import tempfile
import unittest

from check_public_inputs import verify


class PublicInputTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.report = self.root / "tools/benchmark/leaderboard.json"
        self.report.parent.mkdir(parents=True)
        self.report.write_text('{"models":[]}')
        pack = self.root / "packs/example/manifest.json"
        pack.parent.mkdir(parents=True)
        pack.write_text('{"title":"Synthetic example"}')
        registry = {"sha256": {
            p.relative_to(self.root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (self.report, pack)
        }}
        (self.root / "tools/public-release-inputs.json").write_text(json.dumps(registry))

    def test_reviewed_snapshot_passes(self):
        verify(self.root, {})

    def test_changed_report_is_rejected_even_with_same_schema(self):
        self.report.write_text('{"models":[{"id":"unreviewed"}]}')
        with self.assertRaisesRegex(ValueError, "Unreviewed"):
            verify(self.root, {})

    def test_additional_pack_is_rejected(self):
        path = self.root / "packs/extra/manifest.json"
        path.parent.mkdir()
        path.write_text("{}")
        with self.assertRaisesRegex(ValueError, "inventory changed"):
            verify(self.root, {})

    def test_symlink_is_rejected_even_with_approved_bytes(self):
        original = self.root / "report.json"
        self.report.rename(original)
        self.report.symlink_to(original)
        with self.assertRaisesRegex(ValueError, "linked"):
            verify(self.root, {})

    def test_arbitrary_report_override_is_rejected(self):
        for name in ("GRIDPONDER_LEADERBOARD_DATA", "GRIDPONDER_STUDY_DATA"):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "not supported"):
                verify(self.root, {name: "/tmp/report.json"})

    def test_submodule_and_study_artifacts_are_rejected(self):
        for rel in (".gitmodules", "tools/benchmark/study-leaderboard.json"):
            path = self.root / rel
            path.write_text("{}")
            with self.subTest(path=rel), self.assertRaises(ValueError):
                verify(self.root, {})
            path.unlink()


if __name__ == "__main__":
    unittest.main()
