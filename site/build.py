#!/usr/bin/env python3
"""Builds agneta.dahlbom.io.

The landing page is site/src/index.html. Its lists and tables, and every documentation page, are rendered from the
repository's own Markdown (README.md, docs/, CHANGELOG.md, packaging/release-page.md) at build time, so the site
can't drift from the docs. Standard library only. A link to a file or heading that doesn't exist fails the build.

    python3 site/build.py [--out site/_build] [--release release.json] [--commit <sha>]

--release is GitHub's JSON for the latest release (`gh api repos/olofd/agneta/releases/latest`). With it, the page
names the version and links each DMG directly; without it, it links the releases page.
"""

import argparse
import html
import json
import os
import posixpath
import re
import shutil
import sys
from datetime import date

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "site", "src")
REPO = "https://github.com/olofd/agneta"
SITE = "https://agneta.dahlbom.io"

# The documentation pages: (source, its section in README.md or None, path on the site, title in the navigation).
# A source's first heading is the page's title; README's section is cut out between its heading and the next of
# the same level.
GROUPS = [
    ("For app developers", [
        ("README.md", "For app developers", "docs/apps", "Developer guide"),
        ("clients/typescript/README.md", None, "docs/typescript-client", "TypeScript client"),
        ("docs/APP_PROTOCOL.md", None, "docs/app-protocol", "App protocol"),
        ("docs/DIAGNOSTICS.md", None, "docs/diagnostics", "Diagnostics"),
    ]),
    ("How Agneta works", [
        ("docs/ARCHITECTURE.md", None, "docs/architecture", "Architecture"),
        ("docs/ENGINES.md", None, "docs/engines", "Engines"),
        ("docs/CONTAINMENT.md", None, "docs/containment", "Containment"),
    ]),
    ("Privacy and terms", [
        ("docs/PRIVACY.md", None, "docs/privacy", "Privacy and threat model"),
        ("docs/TERMS.md", None, "docs/terms", "Accounts, terms and trademarks"),
    ]),
]
CHANGELOG = ("CHANGELOG.md", None, "changelog", "Changelog")
DEMO, DEMO_POSTER = "docs/images/demo.mp4", "docs/images/demo-poster.png"
PAGES = [page for _, pages in GROUPS for page in pages] + [CHANGELOG]
WHOLE_FILES = {source: path for source, section, path, _ in PAGES if section is None}


class BuildError(Exception):
    pass


def read(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as f:
        return f.read()


def esc(text):
    return html.escape(text, quote=True)


def slugify(text):
    """GitHub's heading anchors: lower case, punctuation dropped, spaces to hyphens."""
    text = re.sub(r"[^\w\- ]", "", text.strip().lower())
    return text.replace(" ", "-")


def plain(markdown):
    """A heading's text, as GitHub slugs it: without code ticks, emphasis or link targets."""
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", markdown)
    return re.sub(r"[`*]", "", text)


def section(markdown, title):
    """The lines of one section: from its heading to the next heading of the same or a higher level."""
    lines = markdown.split("\n")
    for i, line in enumerate(lines):
        m = re.match(r"^(#+) (.*)$", line)
        if m and m.group(2).strip() == title:
            level = len(m.group(1))
            end = next((j for j in range(i + 1, len(lines))
                        if re.match(r"^#{1,%d} " % level, lines[j])), len(lines))
            return lines[i:end], level
    raise BuildError(f"no section {title!r}")


def all_anchors(markdown):
    seen, ids = {}, set()
    in_code = False
    for line in markdown.split("\n"):
        if line.startswith("```"):
            in_code = not in_code
        m = None if in_code else re.match(r"^#{1,6} +(.*?) *$", line)
        if m:
            base = slugify(plain(m.group(1)))
            n = seen.get(base, 0)
            seen[base] = n + 1
            ids.add(base if n == 0 else f"{base}-{n}")
    return ids


LIST_ITEM = re.compile(r"^( *)([-*]|\d+\.) +(.*)$")
FENCE = re.compile(r"^ *```")


def l_is_fence(line):
    return bool(FENCE.match(line))


class Markdown:
    """The Markdown the repository's docs use: headings, paragraphs, nested lists, tables, fenced code, block
    quotes, and inline code, links and emphasis. Anything else, raw HTML or images among it, stops the build, so
    a construct this doesn't know is noticed rather than mangled."""

    def __init__(self, site, source, path, shift=0):
        self.site, self.source, self.path, self.shift = site, source, path, shift
        self.ids, self.slug_counts, self.toc = set(), {}, []
        self.title = None

    # Blocks

    def render(self, text):
        return self.blocks(text.split("\n"))

    def starts_block(self, line):
        return bool(FENCE.match(line) or re.match(r"^#{1,6} ", line) or line.startswith("|")
                    or line.startswith(">") or LIST_ITEM.match(line))

    def blocks(self, lines, tight=False):
        out, i = [], 0
        while i < len(lines):
            line = lines[i]
            if not line.strip():
                i += 1
            elif FENCE.match(line):
                indent = len(line) - len(line.lstrip())
                lang = line.strip()[3:].strip()
                j = i + 1
                while j < len(lines) and not FENCE.match(lines[j]):
                    j += 1
                if j == len(lines):
                    raise BuildError(f"{self.source}: an unclosed code block")
                out.append(self.code([l[indent:] for l in lines[i + 1:j]], lang))
                i = j + 1
            elif re.match(r"^#{1,6} ", line):
                m = re.match(r"^(#{1,6}) +(.*?) *$", line)
                out.append(self.heading(len(m.group(1)), m.group(2)))
                i += 1
            elif line.startswith("|") and i + 1 < len(lines) and re.match(r"^\|[\s:|-]+$", lines[i + 1]):
                j = i + 2
                while j < len(lines) and lines[j].startswith("|"):
                    j += 1
                out.append(self.table(lines[i], lines[i + 2:j]))
                i = j
            elif line.startswith(">"):
                j, quoted = i, []
                while j < len(lines) and lines[j].startswith(">"):
                    quoted.append(re.sub(r"^> ?", "", lines[j]))
                    j += 1
                out.append(f"<blockquote>{self.blocks(quoted)}</blockquote>")
                i = j
            elif LIST_ITEM.match(line):
                i = self.list(lines, i, out)
            elif re.match(r"^\s*(<|!\[)", line):
                raise BuildError(f"{self.source}: raw HTML or an image, which the site doesn't render: {line.strip()[:60]}")
            else:
                j, text = i, []
                while j < len(lines) and lines[j].strip() and not self.starts_block(lines[j]):
                    text.append(lines[j].strip())
                    j += 1
                joined = " ".join(text)
                step = None if tight else re.match(r"^\*\*(\d+)\. (.+?)\*\*", joined)
                body = self.inline(joined)
                if step:  # "**2. Pair, once.** …": a numbered step, which the contents list shows under its section
                    anchor = self.anchor(f"step {step.group(1)} {plain(step.group(2))}")
                    self.toc.append((3, anchor, esc(f"{step.group(1)}. {plain(step.group(2)).rstrip('.')}")))
                    out.append(f'<p class="step" id="{anchor}">{body}</p>')
                else:
                    out.append(body if tight else f"<p>{body}</p>")
                i = j
        return "\n".join(out)

    def list(self, lines, i, out):
        first = LIST_ITEM.match(lines[i])
        base, ordered = len(first.group(1)), first.group(2)[0].isdigit()
        items, loose = [], False
        while i < len(lines):
            m = LIST_ITEM.match(lines[i])
            if not m or len(m.group(1)) != base or m.group(2)[0].isdigit() != ordered:
                break
            column = m.start(3)
            body = [m.group(3)]
            i += 1
            while i < len(lines):
                line = lines[i]
                if not line.strip():
                    k = i
                    while k < len(lines) and not lines[k].strip():
                        k += 1
                    if k < len(lines) and len(lines[k]) - len(lines[k].lstrip()) >= column:
                        body.extend([""] * (k - i))
                        loose = True
                        i = k
                        continue
                    break
                if len(line) - len(line.lstrip()) >= column:
                    body.append(line[column:])
                elif not self.starts_block(line.lstrip()):
                    body.append(line.strip())  # a lazy continuation of the item's paragraph
                else:
                    break
                i += 1
            items.append(body)
            if i < len(lines) and not lines[i].strip():
                k = i
                while k < len(lines) and not lines[k].strip():
                    k += 1
                nxt = LIST_ITEM.match(lines[k]) if k < len(lines) else None
                if nxt and len(nxt.group(1)) == base and nxt.group(2)[0].isdigit() == ordered:
                    loose = True
                    i = k
                    continue
                break
        tag = "ol" if ordered else "ul"
        start = int(first.group(2)[:-1]) if ordered else 1
        attrs = f' start="{start}"' if start != 1 else ""
        rendered = "".join(f"<li>{self.blocks(body, tight=not loose)}</li>" for body in items)
        out.append(f"<{tag}{attrs}>{rendered}</{tag}>")
        return i

    def heading(self, level, text):
        level = min(level - self.shift, 6) if level > 1 else level
        anchor = self.anchor(plain(text))
        body = self.inline(text)
        if level == 1:
            if self.title is None:
                self.title = re.sub(r"<[^>]+>", "", body)
            return f'<h1 id="{anchor}">{body}</h1>'
        if level in (2, 3):
            self.toc.append((level, anchor, re.sub(r"<[^>]+>", "", body)))
        return (f'<h{level} id="{anchor}">{body}'
                f'<a class="anchor" href="#{anchor}" aria-label="Link to this section"></a></h{level}>')

    def anchor(self, text):
        """A heading's id as GitHub makes it, numbered when it repeats."""
        base = slugify(text)
        n = self.slug_counts.get(base, 0)
        self.slug_counts[base] = n + 1
        anchor = base if n == 0 else f"{base}-{n}"
        self.ids.add(anchor)
        return anchor

    def table(self, head, rows):
        def cells(row):
            out, cell, code, k = [], "", False, 0
            row = row.strip()
            row = row[1:] if row.startswith("|") else row
            row = row[:-1] if row.endswith("|") and not row.endswith("\\|") else row
            while k < len(row):
                c = row[k]
                if c == "\\" and k + 1 < len(row) and row[k + 1] == "|":
                    cell += "|"
                    k += 2
                    continue
                if c == "`":
                    code = not code
                if c == "|" and not code:
                    out.append(cell.strip())
                    cell = ""
                else:
                    cell += c
                k += 1
            out.append(cell.strip())
            return out

        header = cells(head)
        label = ", ".join(plain(h) for h in header if h) or "Table"
        thead = "".join(f'<th scope="col">{self.inline(c)}</th>' for c in header)
        labels = [esc(plain(h)) for h in header] + [""] * 8
        body = "".join("<tr>" + "".join(f'<td data-label="{labels[k]}">{self.inline(c)}</td>'
                                        for k, c in enumerate(cells(r))) + "</tr>" for r in rows)
        return (f'<div class="table" role="region" aria-label="{esc(label)}" tabindex="0">'
                f"<table><thead><tr>{thead}</tr></thead><tbody>{body}</tbody></table></div>")

    def code(self, lines, lang):
        text = esc("\n".join(lines))
        if lang in ("bash", "sh"):
            # Comments, dimmed: a # at the start of a line, or after whitespace.
            text = re.sub(r"(^|\s)(#[^\n]*)", r'\1<span class="c">\2</span>', text, flags=re.M)
        elif lang == "json":
            # Arrows (who sends it), keys, strings and numbers.
            text = re.sub(r"^(\s*)(→|←)", r'\1<span class="a">\2</span>', text, flags=re.M)
            text = re.sub(r"(&quot;(?:(?!&quot;)[^\n])*?&quot;)(\s*:)?|(?<![\w.])(-?\d+(?:\.\d+)?|true|false|null)(?![\w.])",
                          lambda m: (f'<span class="k">{m.group(1)}</span>{m.group(2)}' if m.group(2) else
                                     f'<span class="s">{m.group(1)}</span>' if m.group(1) else f'<span class="n">{m.group(3)}</span>'),
                          text)
        copy = ' data-copy' if lang in ("bash", "sh") else ""
        label = f' data-lang="{esc(lang)}"' if lang and lang != "text" else ""
        return f'<pre{copy}{label}><code>{text}</code></pre>'

    # Inline

    def inline(self, text):
        held = []

        def hold(fragment):
            held.append(fragment)
            return f"\x00{len(held) - 1}\x00"

        text = re.sub(r"\\([\\`*_{}\[\]()#+\-.!|<>])", lambda m: hold(esc(m.group(1))), text)
        text = re.sub(r"(`+)(.+?)\1", lambda m: hold(f"<code>{esc(m.group(2).strip())}</code>"), text)
        text = esc(text).replace("&#x27;", "'").replace("&quot;", '"')

        def link(m):
            label, href = m.group(1), html.unescape(m.group(2))
            url, title = self.site.resolve(self, href)
            shown = re.sub(r"\x00\d+\x00", lambda h: held[int(h.group()[1:-1])], label)
            target = href.split("#")[0]
            if title and target and shown.replace("<code>", "").replace("</code>", "") in (
                    esc(target), esc(posixpath.basename(target))):
                label = esc(title)  # "ENGINES.md" or "docs/TERMS.md" reads as the page's title on the site
            external = ' rel="noopener"' if url.startswith("http") and not url.startswith(SITE) else ""
            return hold(f'<a href="{esc(url)}"{external}>') + label + hold("</a>")

        text = re.sub(r"\[((?:[^\[\]]|\[[^\]]*\])+)\]\(([^)\s]+)\)", link, text)
        # Typographer's quotes in prose; code and URLs are held aside above.
        text = re.sub(r"(?<=\w)'(?=\w)|(?<=s)'(?=\s)", "\u2019", text)
        text = re.sub(r'"([^"\x00]*)"', "\u201c\\1\u201d", text)
        text = text.replace("...", "\u2026")
        text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
        text = re.sub(r"(?<![\w*])\*(?![\s*])(.+?)(?<![\s*])\*(?![\w*])", r"<em>\1</em>", text)
        if re.search(r"\]\(|!\[", text):
            raise BuildError(f"{self.source}: a link the site can't read: {text[:80]}")
        while "\x00" in text:
            text = re.sub(r"\x00(\d+)\x00", lambda m: held[int(m.group(1))], text)
        return text


class Site:
    def __init__(self, release, commit):
        self.release, self.commit = release, commit
        self.checks = []  # (where, page path, fragment)
        self.page_ids = {}
        self.readme = read("README.md")
        self.readme_ids = all_anchors(self.readme)
        dev_lines, _ = section(self.readme, "For app developers")
        self.dev_ids = all_anchors("\n".join(dev_lines))

    def page(self, path):
        return next(p for p in PAGES if p[2] == path)

    def resolve(self, md, href):
        """A link in Markdown, as a URL on the site and that page's title if it's one of the site's pages."""
        if re.match(r"^[a-z][a-z0-9+.-]*:", href):
            # The changelog links each document as it was at that release; it keeps the link, and the page's name.
            pinned = re.match(re.escape(REPO) + r"/blob/[^/]+/([^#]+)", href)
            if pinned and pinned.group(1) in WHOLE_FILES:
                return href, self.page(WHOLE_FILES[pinned.group(1)])[3]
            return href, None
        target, _, fragment = href.partition("#")
        if not target:
            self.checks.append((md.source, md.path, fragment))
            return f"#{fragment}", None
        target = posixpath.normpath(posixpath.join(posixpath.dirname(md.source), target))
        hash_ = f"#{fragment}" if fragment else ""
        if target == "README.md" and fragment in self.dev_ids:
            return f"/docs/apps/{hash_}", "Developer guide"
        if target in WHOLE_FILES:
            path = WHOLE_FILES[target]
            if fragment:
                self.checks.append((md.source, path, fragment))
            return f"/{path}/{hash_}", self.page(path)[3]
        full = os.path.join(ROOT, target)
        if not os.path.exists(full):
            raise BuildError(f"{md.source}: a link to {target}, which doesn't exist")
        if target == "README.md" and fragment and fragment not in self.readme_ids:
            raise BuildError(f"{md.source}: a link to README.md#{fragment}, which doesn't exist")
        kind = "tree" if os.path.isdir(full) else "blob"
        return f"{REPO}/{kind}/main/{target}{hash_}", None

    def markdown(self, source, path, text, shift=0):
        md = Markdown(self, source, path, shift)
        body = md.render(text)
        self.page_ids.setdefault(path, set()).update(md.ids)
        return md, body

    def check_links(self):
        broken = [f"{where}: #{fragment} on /{path}/" for where, path, fragment in self.checks
                  if fragment not in self.page_ids.get(path, set())]
        if broken:
            raise BuildError("links to headings that don't exist:\n  " + "\n  ".join(broken))

    # Release

    def asset(self, arch):
        for a in (self.release or {}).get("assets", []):
            if re.fullmatch(r"Agneta-[\d.]+-%s\.dmg" % arch, a["name"]):
                return a
        return None

    def version(self):
        tag = (self.release or {}).get("tag_name", "")
        return tag[1:] if tag.startswith("v") else tag


def megabytes(size):
    return f"{round(size / 1_000_000)} MB"


def long_date(iso):
    d = date.fromisoformat(iso[:10])
    return f"{d.day} {d.strftime('%B')} {d.year}"


def layout(site, *, title, description, path, body, page_class, head_extra=""):
    template = read("site/src/layout.html")
    canonical = f"{SITE}/{path}/" if path else f"{SITE}/"
    full_title = title if title == "Agneta" else f"{title} · Agneta"
    nav_current = lambda p: ' aria-current="page"' if (path or "").startswith(p) else ""
    values = {
        "title": esc(full_title),
        "og_title": esc(title),
        "description": esc(description),
        "canonical": canonical,
        "head_extra": head_extra,
        "body": body,
        "page_class": page_class,
        "nav_docs": nav_current("docs"),
        "nav_changelog": nav_current("changelog"),
        "commit": esc(site.commit[:7]) if site.commit else "local",
        "commit_url": f"{REPO}/commit/{site.commit}" if site.commit else REPO,
        "year": str(date.today().year),
    }
    return fill(template, values, "layout.html")


def fill(template, values, name):
    def sub(m):
        if m.group(1) not in values:
            raise BuildError(f"{name}: no value for {{{{{m.group(1)}}}}}")
        return values[m.group(1)]
    return re.sub(r"\{\{(\w+)\}\}", sub, template)


def docs_nav(current):
    groups = []
    for name, pages in GROUPS + [("", [CHANGELOG])]:
        current_attr = lambda p: ' aria-current="page"' if p == current else ""
        items = "".join(f'<li><a href="/{p}/"{current_attr(p)}>{esc(t)}</a></li>' for _, _, p, t in pages)
        heading = f"<h2>{esc(name)}</h2>" if name else ""
        groups.append(f"<div>{heading}<ul>{items}</ul></div>")
    return "".join(groups)


def contents(entries):
    """The page's contents: its sections, each with its subsections and numbered steps; none for a short page."""
    if len(entries) < 3:
        return ""
    items, open_sub = [], False
    for level, anchor, text in entries:
        if level == 2:
            if open_sub:
                items.append("</ul></li>")
            elif items:
                items.append("</li>")
            items.append(f'<li><a href="#{anchor}">{text}</a>')
            open_sub = False
        else:
            if not open_sub:
                items.append('<ul>' if items else '<li><ul>')
                open_sub = True
            items.append(f'<li><a href="#{anchor}">{text}</a></li>')
    items.append("</ul></li>" if open_sub else "</li>")
    return (f'<nav class="toc" aria-labelledby="toc-title"><h2 id="toc-title">On this page</h2>'
            f'<ul>{"".join(items)}</ul></nav>')


def pager(path):
    """Links to the previous and next page, in the order of the documentation's navigation."""
    order = [p for _, pages in GROUPS for _, _, p, _ in pages] + [CHANGELOG[2]]
    titles = {p: t for _, pages in GROUPS + [("", [CHANGELOG])] for _, _, p, t in pages}
    i = order.index(path)
    links = []
    if i > 0:
        links.append(f'<a class="prev" href="/{order[i - 1]}/"><span>Previous</span>{esc(titles[order[i - 1]])}</a>')
    if i + 1 < len(order):
        links.append(f'<a class="next" href="/{order[i + 1]}/"><span>Next</span>{esc(titles[order[i + 1]])}</a>')
    return f'<nav class="pager" aria-label="More documentation">{"".join(links)}</nav>'


def doc_page(site, source, sect, path, nav_title):
    if sect:
        lines, level = section(read(source), sect)
        lines[0] = "# " + lines[0].lstrip("#").strip()
        md, body = site.markdown(source, path, "\n".join(lines), shift=level - 1)
        source_url = f"{REPO}/blob/main/{source}#{slugify(sect)}"
        source_label = f"{source}, “{sect}”"
    else:
        md, body = site.markdown(source, path, read(source))
        source_url = f"{REPO}/blob/main/{source}"
        source_label = source
    title = md.title or nav_title
    first_p = re.search(r"<p>(.*?)</p>", body, re.S)
    if sect:  # README's section opens with the example, not with what the page is
        first_p = re.search(r"<p>(Your app is an ACP .*?)</p>", body, re.S) or first_p
    description = re.sub(r"<[^>]+>", "", first_p.group(1)) if first_p else title
    description = re.sub(r"\s+", " ", html.unescape(description)).strip()
    if len(description) > 200:
        description = description[:197].rsplit(" ", 1)[0] + "…"
    toc_html = contents(md.toc)
    nav = docs_nav(path)
    page = fill(read("site/src/doc.html"), {
        "nav": nav,
        "current": esc(nav_title),
        "article": body,
        "toc": toc_html,
        "docs_class": "docs" if toc_html else "docs docs-no-toc",
        "pager": pager(path),
        "source_url": source_url,
        "history_url": f"{REPO}/commits/main/{source}",
        "source_label": esc(source_label),
    }, "doc.html")
    return md, layout(site, title=title, description=description, path=path, body=page, page_class="doc")


def docs_index(site):
    """The documentation index, from README's own table of documents, for those the site publishes."""
    lines, _ = section(site.readme, "Documentation")
    rows = [l for l in lines if l.startswith("| [")]
    described = {}
    for row in rows:
        m = re.match(r"^\| \[[^\]]+\]\(([^)]+)\)[^|]*\| (.+?) \|$", row)
        if m:
            described[m.group(1)] = m.group(2)
    md = Markdown(site, "README.md", "docs")
    groups = []
    for name, pages in GROUPS:
        cards = []
        for source, sect, p, t in pages:
            what = described.get(source)
            if sect:
                what = "Connecting, pairing, a session and its stream, step by step"
            if what is None:
                raise BuildError(f"README's Documentation table doesn't describe {source}")
            cards.append(f'<li><a href="/{p}/"><span class="name">{esc(t)}</span>'
                         f'<span class="what">{md.inline(what)}</span></a></li>')
        groups.append(f'<section><h2>{esc(name)}</h2><ul class="cards">{"".join(cards)}</ul></section>')
    body = fill(read("site/src/docs.html"), {"groups": "".join(groups)}, "docs.html")
    return layout(site, title="Documentation", description="How to integrate an app with Agneta, how it works "
                  "inside, and what stays private on your Mac.", path="docs", body=body, page_class="index")


def install_steps(site):
    """The numbered install steps of packaging/release-page.md, rendered."""
    lines, _ = section(read("packaging/release-page.md"), "Install")
    steps = [l for l in lines if re.match(r"^\d+\. ", l)]
    return Markdown(site, "packaging/release-page.md", "").render("\n".join(steps))


def downloads(site):
    """Both DMGs, linked directly from the latest release (or the releases page without one). `data-arch` lets the
    install page put the one the app named in its fragment first."""
    out = []
    for arch, label, hint in (("arm64", "Apple silicon", "M1 or later"), ("x86_64", "Intel", "Intel processor")):
        a = site.asset(arch)
        url = a["browser_download_url"] if a else f"{REPO}/releases/latest"
        size = f" · {megabytes(a['size'])}" if a else ""
        file = f'<span class="file">{esc(a["name"])}</span>' if a else ""
        out.append(f'<a class="download" data-arch="{arch}" href="{esc(url)}"><img src="/assets/icon-64.png" width="44" height="44" alt="">'
                   f'<span class="arch">{label}</span><span class="detail">{hint}{size}</span>{file}</a>')
    return "".join(out)


def release_line(site):
    version = site.version()
    if not version:
        return f'<a href="{REPO}/releases/latest">Latest release</a>'
    published = site.release.get("published_at") or ""
    when = f", {long_date(published)}" if published else ""
    return f'<a href="{REPO}/releases/tag/v{esc(version)}">Version {esc(version)}</a>{when}'


def get_page(site):
    """/get/: the install page apps open (docs/APP_PROTOCOL.md, Getting Agneta). Its address is a promise: it stays."""
    body = fill(read("site/src/get.html"), {
        "release_line": release_line(site),
        "downloads": downloads(site),
        "install_steps": install_steps(site),
    }, "get.html")
    return layout(site, title="Get Agneta", description="Download Agneta for your Mac, Apple silicon or Intel, or "
                  "install it with Homebrew. Free and open source; signed and notarized.", path="get", body=body,
                  page_class="get")


# What a page may load, and what the site's script may read: the install page is opened by apps, so it must send
# nothing anywhere and read nothing of its address but the fragment (docs/APP_PROTOCOL.md, Getting Agneta).
LOADS = re.compile(r'<(?:script|img|iframe|video|audio|source|embed|track)\b[^>]*?\s(?:src|srcset|poster)="([^"]*)"'
                   r'|<link\b[^>]*?\shref="([^"]*)"|<object\b[^>]*?\sdata="([^"]*)"|url\(\s*["\']?(https?:|//)', re.I)
READS = re.compile(r"location\.(?:search|href)|document\.(?:URL|referrer|cookie)|URLSearchParams|\bfetch\s*\(|"
                   r"XMLHttpRequest|sendBeacon|WebSocket|EventSource|localStorage|sessionStorage|indexedDB")


def check_loads(name, page):
    """Fails on anything a page would load from elsewhere: every script, style, image and frame comes from the site."""
    for m in LOADS.finditer(page):
        url = next((g for g in m.groups() if g is not None), "")
        if url.startswith(("http:", "https:", "//")) and not url.startswith(SITE + "/"):
            raise BuildError(f"{name}: loads {url} from elsewhere; the site serves everything itself")


def check_script(text):
    found = READS.search(text)
    if found:
        raise BuildError(f"site.js: uses {found.group()}; the site's script reads nothing of the address but its "
                         f"fragment and sends nothing anywhere")


def check_get(page):
    """The install page has what an app promises its user: both downloads, Homebrew, and Open Agneta."""
    for needed in ('data-arch="arm64"', 'data-arch="x86_64"', 'href="agneta://open"', "brew install olofd/tap/agneta",
                   "data-downloads", 'src="/site.js"'):
        if needed not in page:
            raise BuildError(f"get/: the install page lacks {needed}")


def landing(site):
    readme = site.readme

    def part(title, kind, after=None):
        """One block of a README section, rendered: its first list or table, or a paragraph starting with `after`."""
        lines, _ = section(readme, title)
        body = lines[1:]
        if kind == "list":
            start = next(i for i, l in enumerate(body) if LIST_ITEM.match(l))
            end = next((i for i in range(start, len(body)) if not body[i].strip()), len(body))
            body = body[start:end]
        elif kind == "table":
            start = next(i for i, l in enumerate(body) if l.startswith("|"))
            end = next((i for i in range(start, len(body)) if not body[i].startswith("|")), len(body))
            body = body[start:end]
        elif kind == "paragraph":
            body = [next(l for l in body if l.startswith(after))]
        return Markdown(site, "README.md", "").render("\n".join(body))

    def status_quote():
        quote = [re.sub(r"^> ?", "", l) for l in readme.split("\n") if l.startswith(">")]
        if not quote or not quote[0].startswith("**Status"):
            raise BuildError("README.md: the status note isn't its first block quote")
        return Markdown(site, "README.md", "").render("\n".join(quote))

    def dev_snippet():
        # The developer guide's first example: a few lines on the TypeScript client.
        lines, _ = section(readme, "For app developers")
        start = next(i for i, l in enumerate(lines) if l.startswith("```js"))
        end = next(i for i in range(start + 1, len(lines)) if l_is_fence(lines[i]))
        return Markdown(site, "README.md", "").render("\n".join(lines[start:end + 1]))

    # The demo video, once there is one: its own section under the screenshots, which stay.
    demo = ""
    if os.path.exists(os.path.join(ROOT, DEMO)):
        poster = ' poster="/images/demo-poster.png"' if os.path.exists(os.path.join(ROOT, DEMO_POSTER)) else ""
        demo = (f'<section class="demo-section wrap" aria-label="Demo"><figure class="demo"><video src="/images/demo.mp4"{poster} controls muted playsinline '
                'preload="metadata" aria-describedby="demo-caption"></video>'
                '<figcaption id="demo-caption">An app pairs with Agneta, its task runs in the menu bar panel, '
                'and Stop ends it.</figcaption></figure></section>')

    body = fill(read("site/src/index.html"), {
        "demo": demo,
        "release_line": release_line(site),
        "downloads": downloads(site),
        "how_steps": part("How it works", "list"),
        "providers_table": part("Providers and engines", "table"),
        "without_native": part("Providers and engines", "paragraph", "**Without Claude Code or Codex,**"),
        "not_list": part("What it is not", "list"),
        "status_quote": status_quote(),
        "dev_snippet": dev_snippet(),
        "install_steps": install_steps(site),
    }, "index.html")
    head = ('<link rel="preload" as="image" href="/images/panel.png" media="(prefers-color-scheme: light)">'
            '<link rel="preload" as="image" href="/images/panel-dark.png" media="(prefers-color-scheme: dark)">')
    return layout(site, title="Agneta", description="Agneta is an open-source macOS menu bar app that lets the "
                  "apps you allow use your own ChatGPT or Claude plan, or API key, for agent tasks: on your Mac, "
                  "sandboxed, with every task in view.", path="", body=body, page_class="home", head_extra=head)


def build(out, release, commit):
    site = Site(release, commit)
    if os.path.exists(out):
        shutil.rmtree(out)
    os.makedirs(out)

    def write(rel, text):
        full = os.path.join(out, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as f:
            f.write(text)

    for source, sect, path, nav_title in PAGES:
        _, text = doc_page(site, source, sect, path, nav_title)
        write(f"{path}/index.html", text)
    write("docs/index.html", docs_index(site))
    write("index.html", landing(site))
    get = get_page(site)
    check_get(get)
    write("get/index.html", get)
    write("404.html", layout(site, title="Not found", description="This page doesn't exist.", path="404",
                             body=read("site/src/404.html"), page_class="missing"))
    site.check_links()
    for root, _, files in os.walk(out):
        for name in files:
            if name.endswith(".html"):
                with open(os.path.join(root, name), encoding="utf-8") as f:
                    check_loads(os.path.relpath(os.path.join(root, name), out), f.read())
    check_script(read("site/src/site.js"))

    for name in ("style.css", "site.js"):
        shutil.copy(os.path.join(SRC, name), os.path.join(out, name))
    shutil.copytree(os.path.join(SRC, "assets"), os.path.join(out, "assets"))
    shutil.copy(os.path.join(SRC, "assets", "favicon.ico"), os.path.join(out, "favicon.ico"))
    os.makedirs(os.path.join(out, "images"))
    for name in ("panel.png", "panel-dark.png", "approval.png", "approval-dark.png", "social-preview.png"):
        shutil.copy(os.path.join(ROOT, "docs", "images", name), os.path.join(out, "images", name))
    for optional in (DEMO, DEMO_POSTER):
        if os.path.exists(os.path.join(ROOT, optional)):
            shutil.copy(os.path.join(ROOT, optional), os.path.join(out, "images", os.path.basename(optional)))
    shutil.copy(os.path.join(ROOT, "examples", "project-chat", "preview.png"),
                os.path.join(out, "images", "project-chat.png"))
    urls = [""] + ["get", "docs"] + [p for _, _, p, _ in PAGES]
    write("sitemap.xml", '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
          + "".join(f"  <url><loc>{SITE}/{u + '/' if u else ''}</loc></url>\n" for u in urls) + "</urlset>\n")
    write("robots.txt", f"Sitemap: {SITE}/sitemap.xml\n")


def main():
    parser = argparse.ArgumentParser(description="Build agneta.dahlbom.io from the repository.")
    parser.add_argument("--out", default=os.path.join(ROOT, "site", "_build"))
    parser.add_argument("--release", help="GitHub's JSON for the latest release")
    parser.add_argument("--commit", default="", help="the commit the site is built from")
    args = parser.parse_args()
    release = None
    if args.release and os.path.getsize(args.release) > 0:
        with open(args.release, encoding="utf-8") as f:
            release = json.load(f)
        if "tag_name" not in release:
            release = None
    try:
        build(args.out, release, args.commit)
    except BuildError as e:
        print(f"build: {e}", file=sys.stderr)
        sys.exit(1)
    print(f"Built {args.out}" + (f" for {release['tag_name']}" if release else " (no release given)"))


if __name__ == "__main__":
    main()
