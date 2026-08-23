#!/usr/bin/env python3
import argparse
import os
import tempfile
from pathlib import Path
from urllib.parse import urlparse
from xml.dom import Node, minidom


SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ALLOWED_DOWNLOAD_PREFIX = "https://github.com/ivkiwi/guesli/releases/download/"


def items(document: minidom.Document) -> list[minidom.Element]:
    return [node for node in document.getElementsByTagName("item") if node.nodeType == Node.ELEMENT_NODE]


def item_version(item: minidom.Element) -> str:
    nodes = item.getElementsByTagNameNS(SPARKLE_NAMESPACE, "version")
    if len(nodes) != 1 or nodes[0].firstChild is None:
        raise ValueError("appcast item must contain exactly one sparkle:version")
    return nodes[0].firstChild.nodeValue.strip()


def full_enclosure(item: minidom.Element) -> minidom.Element:
    enclosures = [
        node
        for node in item.getElementsByTagName("enclosure")
        if not node.hasAttributeNS(SPARKLE_NAMESPACE, "deltaFrom")
    ]
    if len(enclosures) != 1:
        raise ValueError("appcast item must contain exactly one full enclosure")
    return enclosures[0]


def validate_download_url(url: str) -> None:
    parsed = urlparse(url)
    if not url.startswith(ALLOWED_DOWNLOAD_PREFIX) or parsed.scheme != "https" or not parsed.path.endswith(".dmg"):
        raise ValueError(f"non-Guesli release URL in appcast: {url}")


def merge(existing_path: Path, generated_path: Path, version: str, download_url: str, output_path: Path) -> None:
    validate_download_url(download_url)
    existing = minidom.parse(str(existing_path))
    generated = minidom.parse(str(generated_path))

    existing_items = items(existing)
    versions = [item_version(item) for item in existing_items]
    if len(versions) != len(set(versions)):
        raise ValueError("existing appcast contains duplicate sparkle:version entries")
    if version in versions:
        raise ValueError(f"existing appcast already contains version {version}")
    for item in existing_items:
        validate_download_url(full_enclosure(item).getAttribute("url"))

    matches = [item for item in items(generated) if item_version(item) == version]
    if len(matches) != 1:
        raise ValueError(f"generated appcast must contain exactly one item for {version}")
    generated_item = matches[0]
    for enclosure in list(generated_item.getElementsByTagName("enclosure")):
        if enclosure.hasAttributeNS(SPARKLE_NAMESPACE, "deltaFrom"):
            enclosure.parentNode.removeChild(enclosure)
    full_enclosure(generated_item).setAttribute("url", download_url)

    channels = existing.getElementsByTagName("channel")
    if len(channels) != 1:
        raise ValueError("existing appcast must contain exactly one channel")
    channel = channels[0]
    imported = existing.importNode(generated_item, deep=True)
    first = next((node for node in channel.childNodes if node.nodeType == Node.ELEMENT_NODE and node.tagName == "item"), None)
    channel.insertBefore(imported, first) if first is not None else channel.appendChild(imported)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=output_path.parent, delete=False) as handle:
        existing.writexml(handle, encoding=None)
        temporary = Path(handle.name)
    os.replace(temporary, output_path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--existing", required=True, type=Path)
    parser.add_argument("--generated", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        merge(args.existing, args.generated, args.version, args.download_url, args.output)
    except (OSError, ValueError) as error:
        raise SystemExit(f"ERROR: {error}") from error
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
