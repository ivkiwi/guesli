#!/usr/bin/env python3
import tempfile
import unittest
from pathlib import Path

from merge_appcast_item import merge


def appcast(version: str, url: str, delta: bool = False) -> str:
    delta_xml = '<enclosure url="delta.dmg" sparkle:deltaFrom="1" />' if delta else ""
    return f'''<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><title>Guesli</title><item>
<sparkle:version>{version}</sparkle:version><sparkle:shortVersionString>{version}</sparkle:shortVersionString>
<enclosure url="{url}" length="1" type="application/octet-stream" sparkle:edSignature="x" />{delta_xml}
</item></channel></rss>'''


class MergeAppcastTests(unittest.TestCase):
    def test_prepends_new_item_and_preserves_history(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old_url = "https://github.com/ivkiwi/guesli/releases/download/old/Guesli-old.dmg"
            new_url = "https://github.com/ivkiwi/guesli/releases/download/new/Guesli-new.dmg"
            (root / "old.xml").write_text(appcast("1", old_url), encoding="utf-8")
            (root / "new.xml").write_text(appcast("2", "file:///tmp/new.dmg", delta=True), encoding="utf-8")
            merge(root / "old.xml", root / "new.xml", "2", new_url, root / "out.xml")
            text = (root / "out.xml").read_text(encoding="utf-8")
            self.assertLess(text.index("<sparkle:version>2"), text.index("<sparkle:version>1"))
            self.assertIn(old_url, text)
            self.assertIn(new_url, text)
            self.assertNotIn("deltaFrom", text)

    def test_rejects_duplicate_version(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            url = "https://github.com/ivkiwi/guesli/releases/download/one/Guesli-one.dmg"
            (root / "old.xml").write_text(appcast("1", url), encoding="utf-8")
            (root / "new.xml").write_text(appcast("1", url), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "already contains"):
                merge(root / "old.xml", root / "new.xml", "1", url, root / "out.xml")

    def test_rejects_foreign_history(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "old.xml").write_text(appcast("1", "https://example.com/bad.dmg"), encoding="utf-8")
            (root / "new.xml").write_text(appcast("2", "file:///tmp/new.dmg"), encoding="utf-8")
            url = "https://github.com/ivkiwi/guesli/releases/download/two/Guesli-two.dmg"
            with self.assertRaisesRegex(ValueError, "non-Guesli"):
                merge(root / "old.xml", root / "new.xml", "2", url, root / "out.xml")


if __name__ == "__main__":
    unittest.main()
