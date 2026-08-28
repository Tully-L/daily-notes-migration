#!/usr/bin/env python3
"""
Parses Notes.app note body HTML into ordered paragraph units, preserving
each unit's original HTML (bold, font, bullet lists) instead of flattening
to plaintext. Used by migrate-notes.sh to carry formatting across the daily
migration instead of losing it.

Note: checkbox checked/unchecked state is NOT recoverable via AppleScript's
`body` property (Notes doesn't expose it there at all) — that limitation is
unrelated to this script and is worked around separately via the
@@@FINISHED@@@ divider line in the source bash script.
"""
import html
import json
import re
import sys

TAG_RE = re.compile(r"<[^>]+>")


def strip_tags(fragment):
    text = TAG_RE.sub("", fragment)
    return html.unescape(text).strip()


def parse_units(body_html):
    """Returns an ordered list of {html, text} paragraph units.

    A unit is either a top-level <div>...</div> line, or an individual
    <li>...</li> line (list wrapper tags themselves are not emitted as
    units — they get re-wrapped around kept <li> units later).
    Nested <ul>/<ol> collapse to a single flat list on reconstruction;
    that's an accepted simplification since the only nested lists in
    practice are unrecoverable checklists that live below @@@FINISHED@@@.
    """
    units = []
    for line in body_html.splitlines():
        line = line.strip()
        if not line:
            continue
        if line in ("<ul>", "<ol>", "</ul>", "</ol>"):
            continue
        if line.startswith("<li>") or line.startswith("<li "):
            units.append({"html": line, "text": strip_tags(line), "kind": "li"})
        elif line.startswith("<div>") or line.startswith("<div "):
            units.append({"html": line, "text": strip_tags(line), "kind": "div"})
        else:
            # stray line (shouldn't normally happen) — keep as-is, treat as div
            units.append({"html": line, "text": strip_tags(line), "kind": "div"})
    return units


def skip_title(units, note_name):
    i = 0
    while i < len(units) and units[i]["text"] == note_name:
        i += 1
    return units[i:]


def extract(note_name, body_html):
    units = skip_title(parse_units(body_html), note_name)

    current_section = None
    in_done_zone = False
    today_units = []
    tomorrow_units = []

    for u in units:
        t = u["text"]
        if t.startswith("━━━"):  # ━━━
            if "今日任务" in t or "Today" in t:
                current_section = "tasks"
                in_done_zone = False
            elif "明日保留" in t or "Tomorrow" in t:
                current_section = "carryForward"
                in_done_zone = False
            else:
                current_section = None
                in_done_zone = False
            continue
        if not t and "<img" not in u["html"]:
            continue
        if current_section == "tasks" and not in_done_zone and t == "@@@FINISHED@@@":
            in_done_zone = True
            continue
        if current_section == "tasks" and not in_done_zone:
            today_units.append(u)
        elif current_section == "carryForward":
            if not t.startswith("\U0001f4cb"):  # 📋
                tomorrow_units.append(u)

    return today_units, tomorrow_units


def render(units):
    """Re-wrap kept units into HTML: consecutive <li> units get re-wrapped
    in <ul>...</ul>; <div> units pass through as their own lines."""
    out = []
    li_run = []

    def flush():
        if li_run:
            out.append("<ul>")
            out.extend(li_run)
            out.append("</ul>")
            li_run.clear()

    for u in units:
        if u["kind"] == "li":
            li_run.append(u["html"])
        else:
            flush()
            out.append(u["html"])
    flush()
    return "\n".join(out)


def main():
    manifest = json.load(sys.stdin)
    all_today = []
    all_tomorrow = []
    for src in manifest["sources"]:
        with open(src["bodyFile"], encoding="utf-8") as f:
            body_html = f.read()
        today_units, tomorrow_units = extract(src["name"], body_html)
        all_today.extend(today_units)
        all_tomorrow.extend(tomorrow_units)

    with open(manifest["todayOut"], "w", encoding="utf-8") as f:
        f.write(render(all_today))
    with open(manifest["tomorrowOut"], "w", encoding="utf-8") as f:
        f.write(render(all_tomorrow))
    with open(manifest["todayPlainOut"], "w", encoding="utf-8") as f:
        f.write("\n".join(u["text"] for u in all_today))
    with open(manifest["tomorrowPlainOut"], "w", encoding="utf-8") as f:
        f.write("\n".join(u["text"] for u in all_tomorrow))

    print(json.dumps({"todayCount": len(all_today), "tomorrowCount": len(all_tomorrow)}))


if __name__ == "__main__":
    main()
