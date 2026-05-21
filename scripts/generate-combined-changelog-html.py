#!/usr/bin/env python3
"""
Generate `docs/releases/index.html` — a single page that lists every
shipped release's notes, newest-first.

Sparkle's update dialog uses the channel-level
`<sparkle:fullReleaseNotesLink>` in `docs/appcast.xml` whenever a user
is more than one version behind, so they see notes for every version
they're skipping instead of just the latest one.

We fetch the release list via `gh api`, render each body through the
same GitHub `/markdown` GFM endpoint we already use for per-version
pages, then stitch them into one HTML document. Styling matches
`generate-release-notes-html.py` so the combined page feels like a
natural extension of the per-version pages, not a separate artifact.

Usage:
    generate-combined-changelog-html.py \\
        --repo hampusaberg/Gastty \\
        --output docs/releases/index.html

Requires:
    - `gh` CLI authenticated (the workflow injects GITHUB_TOKEN via
      `GH_TOKEN` env var which `gh` picks up automatically).
    - `GH_TOKEN` or `GITHUB_TOKEN` env var for the `/markdown` endpoint.
"""

import argparse
import json
import os
import subprocess
import sys
import urllib.request
from pathlib import Path


HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Gastty — All Releases</title>
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
      --section-rule: #d2d2d7;
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
        --section-rule: #48484a;
      }
    }
    html, body { margin: 0; padding: 0; background: var(--bg); color: var(--text); }
    body {
      font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      padding: 18px 22px;
    }
    .page-header { color: var(--secondary); font-size: 0.85em; margin-bottom: 1.2em; }
    .release { padding-top: 1.4em; margin-top: 1.4em; border-top: 1px solid var(--section-rule); }
    .release:first-of-type { border-top: none; padding-top: 0; margin-top: 0; }
    .release-tag {
      display: inline-block;
      font: 600 0.78em/1 ui-monospace, SFMono-Regular, Menlo, monospace;
      color: var(--secondary);
      letter-spacing: 0.03em;
      text-transform: uppercase;
      margin-bottom: 0.5em;
    }
    .release-tag .pub-date { font-weight: 400; margin-left: 0.6em; }
    h1, h2, h3 { font-weight: 600; line-height: 1.25; margin: 1.2em 0 0.35em; }
    h1.release-title { font-size: 1.5em; margin: 0 0 0.4em; }
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
  <div class="page-header">Gastty — All Releases</div>
{{SECTIONS}}
</body>
</html>
"""


SECTION_TEMPLATE = """  <section class="release" id="{anchor}">
    <div class="release-tag">{tag}<span class="pub-date">{pub_date}</span></div>
    <h1 class="release-title">{name}</h1>
    {body_html}
  </section>"""


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
            "User-Agent": "gastty-combined-changelog-script",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read().decode("utf-8")


def fetch_releases(repo: str) -> list[dict]:
    """Fetch every published release via `gh api --paginate`.

    Filters out drafts and prereleases — those shouldn't surface in the
    user-visible "all changes" page. Sorts newest-first by published_at.
    """
    cmd = [
        "gh", "api",
        f"/repos/{repo}/releases",
        "--paginate",
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    # `gh api --paginate` concatenates JSON arrays back-to-back as `][`
    # rather than producing one valid array. Normalise that.
    stdout = result.stdout.strip()
    if "][" in stdout:
        stdout = stdout.replace("][", ",")
    releases = json.loads(stdout)
    releases = [r for r in releases if not r.get("draft") and not r.get("prerelease")]
    releases.sort(key=lambda r: r.get("published_at") or "", reverse=True)
    return releases


def format_pub_date(iso: str | None) -> str:
    """ISO 8601 → 'Thu, 21 May 2026'. Empty string if unparseable."""
    if not iso:
        return ""
    try:
        from datetime import datetime
        # GitHub's published_at is e.g. "2026-05-21T13:18:00Z"
        dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
        return dt.strftime("%a, %d %b %Y")
    except Exception:
        return ""


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True,
                        help="owner/name, e.g. hampusaberg/Gastty")
    parser.add_argument("--output", required=True,
                        help="Output HTML path, e.g. docs/releases/index.html")
    args = parser.parse_args()

    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        sys.exit("Set GH_TOKEN or GITHUB_TOKEN in the environment.")

    releases = fetch_releases(args.repo)
    if not releases:
        sys.exit("No published releases found — nothing to write.")

    sections = []
    for rel in releases:
        tag = rel.get("tag_name") or "(untagged)"
        name = rel.get("name") or tag
        body = rel.get("body") or ""
        body_html = render_markdown(body, token) if body.strip() \
            else "<p><em>No release notes available for this version.</em></p>"
        sections.append(SECTION_TEMPLATE.format(
            anchor=tag.lstrip("v").replace(".", "-") or "release",
            tag=tag,
            pub_date=format_pub_date(rel.get("published_at")),
            name=name,
            body_html=body_html,
        ))

    html = HTML_TEMPLATE.replace("{{SECTIONS}}", "\n".join(sections))

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(html, encoding="utf-8")
    print(f"Wrote {output_path} ({len(html)} bytes, {len(releases)} releases)")


if __name__ == "__main__":
    main()
