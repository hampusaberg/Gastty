#!/usr/bin/env python3
"""
Append a new release entry to docs/appcast.xml — used by the release
workflow after a tag push to publish a newly-built DMG to Sparkle's
update feed.

The new <item> is inserted at the top of the channel (newest-first
ordering) so the feed reads cleanly when humans look at it.

Usage:
    append-appcast-entry.py \\
        --version 0.7.0 \\
        --build 10 \\
        --pub-date "Thu, 22 May 2026 12:00:00 +0000" \\
        --url https://github.com/.../Gastty-v0.7.0.dmg \\
        --sig-attrs 'sparkle:edSignature="ABC..." length="12345"' \\
        --release-url https://github.com/.../releases/tag/v0.7.0 \\
        docs/appcast.xml

The `--sig-attrs` value is the raw stdout of `sign_update` — Sparkle's
CLI prints exactly the two attributes we need to embed.
"""

import argparse
import re
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
# Register before parse + write so element names come out with the
# `sparkle:` prefix rather than ElementTree's default `ns0:`.
ET.register_namespace("sparkle", SPARKLE_NS)


def parse_sign_update_output(raw: str) -> tuple[str, str]:
    sig = re.search(r'sparkle:edSignature="([^"]+)"', raw)
    length = re.search(r'length="([^"]+)"', raw)
    if not sig or not length:
        raise ValueError(
            f"Could not parse sign_update output. Expected "
            f'`sparkle:edSignature="..." length="..."`, got: {raw!r}'
        )
    return sig.group(1), length.group(1)


def make_item(args: argparse.Namespace, signature: str, length: str) -> ET.Element:
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Version {args.version}"
    ET.SubElement(item, "pubDate").text = args.pub_date
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = args.build
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = args.version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = "13.0"
    if args.release_url:
        # Optional: link to the GitHub release page so Sparkle's update
        # sheet can offer a "What's new" web link.
        ET.SubElement(
            item, f"{{{SPARKLE_NS}}}releaseNotesLink"
        ).text = args.release_url
    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", args.url)
    enclosure.set("length", length)
    enclosure.set("type", "application/octet-stream")
    enclosure.set(f"{{{SPARKLE_NS}}}edSignature", signature)
    return item


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="Marketing version, e.g. 0.7.0")
    parser.add_argument("--build", required=True, help="CFBundleVersion, e.g. 10")
    parser.add_argument("--pub-date", required=True, help="RFC 822 timestamp")
    parser.add_argument("--url", required=True, help="Direct DMG download URL")
    parser.add_argument(
        "--sig-attrs",
        required=True,
        help='Raw stdout from `sign_update`: sparkle:edSignature="..." length="..."',
    )
    parser.add_argument(
        "--release-url",
        default=None,
        help="Optional: GitHub release page URL for the What's New link",
    )
    parser.add_argument("appcast_file")
    args = parser.parse_args()

    signature, length = parse_sign_update_output(args.sig_attrs)

    tree = ET.parse(args.appcast_file)
    root = tree.getroot()
    channel = root.find("channel")
    if channel is None:
        raise SystemExit("appcast.xml is missing the <channel> element.")

    item = make_item(args, signature, length)

    # Skip if this version is already in the appcast — avoids
    # duplicate entries if the release workflow re-runs.
    for existing in channel.findall("item"):
        v = existing.find(f"{{{SPARKLE_NS}}}shortVersionString")
        if v is not None and v.text == args.version:
            print(f"appcast already contains version {args.version}; skipping.")
            return

    # Insert at the start of the items list so newest is on top.
    children = list(channel)
    first_item_idx = next(
        (i for i, child in enumerate(children) if child.tag == "item"),
        len(children),
    )
    channel.insert(first_item_idx, item)

    ET.indent(tree, space="  ")
    tree.write(args.appcast_file, encoding="utf-8", xml_declaration=True)
    # ET.write doesn't add a trailing newline; do that ourselves so the
    # file stays human-friendly in diffs.
    with open(args.appcast_file, "ab") as f:
        f.write(b"\n")


if __name__ == "__main__":
    main()
