import os
import unittest
from pathlib import Path
from unittest.mock import patch

from verifier.app import Settings, classify, enrollment_filename


VALID_ENV = {
    "SPEAKER_VERIFIER_API_KEY": "test-secret",
    "SPEAKER_ENROLLMENT_DIR": "/tmp/test-enrollments",
}


class SettingsTests(unittest.TestCase):
    def test_requires_private_runtime_configuration(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "SPEAKER_VERIFIER_API_KEY"):
                Settings.from_env()

    def test_thresholds_must_have_gray_zone(self) -> None:
        env = VALID_ENV | {
            "SPEAKER_MATCH_THRESHOLD": "0.2",
            "SPEAKER_NO_MATCH_THRESHOLD": "0.3",
        }
        with patch.dict(os.environ, env, clear=True):
            with self.assertRaisesRegex(RuntimeError, "thresholds"):
                Settings.from_env()


class ClassificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.settings = Settings("key", Path("/tmp/enrollments"))

    def test_match(self) -> None:
        self.assertEqual(classify(0.8, self.settings)[0], "MATCH")

    def test_no_match(self) -> None:
        self.assertEqual(classify(0.1, self.settings)[0], "NO_MATCH")

    def test_gray_zone_is_inconclusive(self) -> None:
        self.assertEqual(classify(0.3, self.settings)[0], "INCONCLUSIVE")

    def test_actor_reference_is_not_used_as_a_path(self) -> None:
        name = enrollment_filename("../../person:m")
        self.assertNotIn("/", name)
        self.assertTrue(name.endswith(".wav"))


if __name__ == "__main__":
    unittest.main()
