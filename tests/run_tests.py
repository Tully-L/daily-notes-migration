#!/usr/bin/env python3
"""Regression test suite for migrate-notes.sh — see ../TDD.md.

Exercises the script against real Notes.app using TEST9xxx- prefixed
fixture notes (never collide with real MMDD- daily notes), then deletes
them. Exit code 0 = all pass, 1 = at least one failure.
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))
import notes_helpers as nh

SCRIPT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MIGRATE_SH = os.path.join(SCRIPT_DIR, "migrate-notes.sh")
LOG_FILE = "/tmp/daily-notes-migration.log"

results = []


def run_migration(source_prefix, target_name):
    env = os.environ.copy()
    env["TEST_SOURCE_PREFIX"] = source_prefix
    env["TEST_TARGET_NAME"] = target_name
    proc = subprocess.run(["/bin/bash", MIGRATE_SH], env=env, capture_output=True, text=True)
    log = ""
    if os.path.exists(LOG_FILE):
        with open(LOG_FILE, encoding="utf-8") as f:
            log = f.read()
    return proc.returncode, log


def check(name, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    results.append((name, status, detail))
    print(f"  [{status}] {name}" + (f" — {detail}" if detail and status == "FAIL" else ""))
    return condition


def section(text):
    print(f"\n=== {text} ===")


def source_note_body(title, today_above, today_below, tomorrow_items):
    lines = [f"<div>{title}</div>", "<div><br></div>",
             "<div><b>━━━ Today ━━━</b></div>", "<div><br></div>"]
    for t in today_above:
        lines.append(f"<div>{t}</div>")
    lines += ["<div><br></div>", "<div>@@@FINISHED@@@</div>", "<div><br></div>"]
    for t in today_below:
        lines.append(f"<div>{t}</div>")
    lines += ["<div><br></div>", "<div><b>━━━ Tomorrow ━━━</b></div>", "<div><br></div>"]
    for t in tomorrow_items:
        lines.append(f"<div>{t}</div>")
    lines += ["<div><br></div>", "<div><b>━━━ Reference ━━━</b></div>", "<div><br></div>"]
    return "\n".join(lines)


def assert_carried_correctly(plain, today_item, tomorrow_items, done_item, case_label):
    ok = True
    ok &= check(f"{case_label}: today-carry item present", today_item in plain, plain)
    for t in tomorrow_items:
        ok &= check(f"{case_label}: tomorrow item '{t}' carried", t in plain, plain)
    ok &= check(f"{case_label}: done item NOT carried (below @@@FINISHED@@@)", done_item not in plain, plain)

    if "@@@FINISHED@@@" not in plain:
        return check(f"{case_label}: has @@@FINISHED@@@ marker", False, "marker missing entirely")

    finished_idx = plain.index("@@@FINISHED@@@")
    for t in tomorrow_items:
        idx = plain.find(t)
        ok &= check(f"{case_label}: '{t}' sits above @@@FINISHED@@@ (in Today, not Tomorrow)",
                     idx != -1 and idx < finished_idx)

    # Everything strictly between the (last) "Tomorrow" header and the
    # (last) "Reference" header must be empty of the carried items —
    # this is exactly the bug that shipped on 2026-08-28.
    tomorrow_header_idx = plain.rfind("Tomorrow")
    reference_header_idx = plain.rfind("Reference")
    if tomorrow_header_idx == -1 or reference_header_idx == -1 or reference_header_idx < tomorrow_header_idx:
        return check(f"{case_label}: has Tomorrow/Reference headers in order", False,
                      f"tomorrow_idx={tomorrow_header_idx} reference_idx={reference_header_idx}")
    tomorrow_section = plain[tomorrow_header_idx:reference_header_idx]
    for t in tomorrow_items:
        ok &= check(f"{case_label}: '{t}' NOT stuck in the new Tomorrow section", t not in tomorrow_section)
    return ok


def test_a_create_new_note():
    section("Test A — target note does NOT exist yet (create-new path)")
    src, tgt = "TEST9001-", "TEST9002-"
    nh.delete_notes_with_prefix(src)
    nh.delete_notes_with_prefix(tgt)
    nh.create_note(src, source_note_body(src, ["TodayCarryItem"], ["TodayDoneItem"],
                                          ["TomorrowItemA", "TomorrowItemB"]))
    rc, log = run_migration(src, tgt)
    if not check("Test A: script exits 0", rc == 0, log):
        return False
    if not check("Test A: target note was created", nh.note_exists(tgt), log):
        return False
    plain = nh.get_plaintext(tgt)
    return assert_carried_correctly(plain, "TodayCarryItem", ["TomorrowItemA", "TomorrowItemB"],
                                     "TodayDoneItem", "Test A")


def test_b_append_existing_note():
    section("Test B — target note already exists (append path)")
    src, tgt = "TEST9003-", "TEST9004-"
    nh.delete_notes_with_prefix(src)
    nh.delete_notes_with_prefix(tgt)
    nh.create_note(src, source_note_body(src, ["TodayCarryItem2"], ["TodayDoneItem2"],
                                          ["TomorrowItemC", "TomorrowItemD"]))
    # Pre-existing target note — deliberately no "📋" so the idempotency
    # skip-guard in migrate-notes.sh doesn't fire.
    nh.create_note(tgt, f"<div>{tgt}</div>\n<div><br></div>\n<div>pre-existing unrelated line</div>")
    rc, log = run_migration(src, tgt)
    if not check("Test B: script exits 0", rc == 0, log):
        return False
    plain = nh.get_plaintext(tgt)
    if not check("Test B: pre-existing content preserved", "pre-existing unrelated line" in plain, plain):
        return False
    return assert_carried_correctly(plain, "TodayCarryItem2", ["TomorrowItemC", "TomorrowItemD"],
                                     "TodayDoneItem2", "Test B")


def main():
    ok_a = test_a_create_new_note()
    ok_b = test_b_append_existing_note()

    section("Cleanup")
    for prefix in ("TEST9001-", "TEST9002-", "TEST9003-", "TEST9004-"):
        nh.delete_notes_with_prefix(prefix)
    print("  test fixture notes deleted")

    section("Summary")
    passed = sum(1 for _, s, _ in results if s == "PASS")
    failed = sum(1 for _, s, _ in results if s == "FAIL")
    print(f"  {passed} passed, {failed} failed")
    if failed:
        print("\nFAILED CHECKS:")
        for name, status, detail in results:
            if status == "FAIL":
                print(f"  - {name}")
    sys.exit(0 if (ok_a and ok_b and failed == 0) else 1)


if __name__ == "__main__":
    main()
