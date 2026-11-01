import tempfile
import unittest
from pathlib import Path

import update_hercules_readme as update


COMMIT_A = "a" * 40
COMMIT_B = "b" * 40
URL_A = update.RAW_PREFIX + COMMIT_A.encode() + b"/" + update.IMAGE_PATH
URL_B = update.RAW_PREFIX + COMMIT_B.encode() + b"/" + update.IMAGE_PATH


class HerculesReadmeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.readme = Path(self.directory.name) / "README.md"

    def test_preserves_every_byte_except_the_image_url(self):
        original = (
            b"# My later README additions\r\n\r\n"
            b"![My custom chart](assets/hercules-history.png \"title\")\r\n"
            b"\r\nUser edits: \xc3\xa9 and `assets/hercules-history.png` in prose.\r\n"
        )
        self.readme.write_bytes(original)
        self.assertTrue(update.update_readme(self.readme, COMMIT_A))
        expected = original.replace(b"assets/hercules-history.png \"title\"", URL_A + b' "title"', 1)
        self.assertEqual(self.readme.read_bytes(), expected)
        self.assertFalse(update.update_readme(self.readme, COMMIT_A))
        self.assertEqual(self.readme.read_bytes(), expected)
        self.assertTrue(update.update_readme(self.readme, COMMIT_B))
        self.assertEqual(self.readme.read_bytes(), expected.replace(URL_A, URL_B))

    def test_supports_a_user_edited_html_image(self):
        original = b'<p>Text</p>\n<img width="800" src="assets/hercules-history.png" alt="custom">\n'
        self.readme.write_bytes(original)
        self.assertTrue(update.update_readme(self.readme, COMMIT_A))
        self.assertEqual(self.readme.read_bytes(), original.replace(update.IMAGE_PATH, URL_A))

    def test_missing_or_ambiguous_image_does_not_change_readme(self):
        for original in (b"# User removed the image\n", b"![a](assets/hercules-history.png)\n![b](assets/hercules-history.png)\n"):
            with self.subTest(original=original):
                self.readme.write_bytes(original)
                with self.assertRaises(ValueError):
                    update.update_readme(self.readme, COMMIT_A)
                self.assertEqual(self.readme.read_bytes(), original)

    def test_refuses_a_symlinked_readme(self):
        target = Path(self.directory.name) / "other.md"
        original = b"![chart](assets/hercules-history.png)\n"
        target.write_bytes(original)
        self.readme.symlink_to(target)
        with self.assertRaises(ValueError):
            update.update_readme(self.readme, COMMIT_A)
        self.assertEqual(target.read_bytes(), original)

    def test_invalid_commit_does_not_change_readme(self):
        original = b"![chart](assets/hercules-history.png)\n"
        self.readme.write_bytes(original)
        for commit in ("main", "a" * 7, "Z" * 40):
            with self.subTest(commit=commit), self.assertRaises(ValueError):
                update.update_readme(self.readme, commit)
            self.assertEqual(self.readme.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
