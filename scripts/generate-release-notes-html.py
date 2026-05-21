#!/usr/bin/env python3
"""
Generate `docs/releases/<tag>.html` from a GitHub release's markdown body.

The release-notes workflow calls this on every `release: [published,
edited]` event so the page Sparkle's update dialog loads always
reflects the latest notes — including typo fixes. The HTML is wrapped
in a minimal Apple-style template that respects `prefers-color-scheme`
so it looks at home inside Sparkle's WebView.

Uses GitHub's own `/markdown` endpoint via `urllib` for rendering so
emoji shortcodes (`:sparkles:`), task lists, mentions, etc. all match
exactly what GitHub shows on the release page. Requires a token in
`GH_TOKEN` or `GITHUB_TOKEN` (the workflow provides this).

Usage:
    generate-release-notes-html.py \\
        --tag v0.7.1 \\
        --body-file /tmp/release-body.md \\
        --output-dir docs/releases/
"""

import argparse
import json
import os
import sys
import urllib.request
from pathlib import Path


HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Gastty {{TAG}}</title>
  <style>
    :root {
      color-scheme: light dark;
      --bg: #ffffff;
      --text: #1d1d1f;
      --secondary: #6e6e73;
      --code-bg: #f0f0f0;
      --pre-bg: #f5f5f7;
      --link: #0066cc;
      --rule: #e5e5ea;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #1c1c1e;
        --text: #f2f2f7;
        --secondary: #98989d;
        --code-bg: #2c2c2e;
        --pre-bg: #2c2c2e;
        --link: #6ea3ff;
        --rule: #38383a;
      }
    }
    html, body { margin: 0; padding: 0; background: var(--bg); color: var(--text); }
    body {
      font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      padding: 18px 22px;
    }
    .tag-header { color: var(--secondary); font-size: 0.85em; margin-bottom: 0.4em; }
    h1, h2, h3 { font-weight: 600; line-height: 1.25; margin: 1.2em 0 0.35em; }
    h1 { font-size: 1.4em; margin-top: 0; }
    h2 { font-size: 1.15em; }
    h3 { font-size: 1.05em; }
    p { margin: 0.5em 0; }
    ul, ol { margin: 0.3em 0 0.7em 1.4em; padding: 0; }
    li { margin: 0.15em 0; }
    a { color: var(--link); text-decoration: none; }
    a:hover { text-decoration: underline; }
    code {
      font: 0.9em ui-monospace, SFMono-Regular, Menlo, monospace;
      background: var(--code-bg);
      padding: 0.1em 0.35em;
      border-radius: 3px;
    }
    pre {
      background: var(--pre-bg);
      padding: 0.7em 0.9em;
      border-radius: 6px;
      overflow-x: auto;
      margin: 0.7em 0;
    }
    pre code { background: transparent; padding: 0; font-size: 0.85em; }
    blockquote {
      margin: 0.5em 0;
      padding: 0 0.8em;
      border-left: 3px solid var(--rule);
      color: var(--secondary);
    }
    hr { border: none; border-top: 1px solid var(--rule); margin: 1em 0; }
    table { border-collapse: collapse; margin: 0.7em 0; }
    th, td { padding: 0.35em 0.7em; border: 1px solid var(--rule); }
    img { max-width: 100%; }
  </style>
</head>
<body>
  <div class="tag-header">Gastty {{TAG}}</div>
  {{CONTENT}}
</body>
</html>
"""


def render_markdown(body: str, token: str) -> str:
    """Render markdown to HTML via GitHub's `/markdown` endpoint (GFM mode)."""
    payload = json.dumps({"text": body, "mode": "gfm"}).encode("utf-8")
    req = urllib.request.Request(
        "https://api.github.com/markdown",
        data=payload,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "User-Agent": "gastty-release-notes-script",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read().decode("utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True,
                        help="Release tag (e.g. v0.7.1). Used as the page title + filename.")
    parser.add_argument("--body-file", required=True,
                        help="File containing the release-body markdown.")
    parser.add_argument("--output-dir", required=True,
                        help="Where to write <tag>.html. Created if missing.")
    args = parser.parse_args()

    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        sys.exit("Set GH_TOKEN or GITHUB_TOKEN in the environment.")

    body = Path(args.body_file).read_text(encoding="utf-8")

    if body.strip():
        rendered = render_markdown(body, token)
    else:
        # GitHub auto-generates release notes when `generate_release_notes`
        # is true on the create call; but if a release is published with
        # an empty body and then edited later, we want to handle the
        # transient empty state gracefully.
        rendered = "<p><em>No release notes available yet.</em></p>"

    html = HTML_TEMPLATE.replace("{{TAG}}", args.tag).replace("{{CONTENT}}", rendered)

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / f"{args.tag}.html"
    output_path.write_text(html, encoding="utf-8")
    print(f"Wrote {output_path} ({len(html)} bytes)")


if __name__ == "__main__":
    main()
