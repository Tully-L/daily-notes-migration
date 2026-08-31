"""AppleScript helpers for the migrate-notes.sh test suite.

All test fixture notes live in the same "Notes" folder as real daily notes
but use a TEST9xxx- prefix that can never collide with a real MMDD- date.
"""
import subprocess


def _run_osascript(script):
    result = subprocess.run(
        ["/usr/bin/osascript", "-e", script],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"osascript failed: {result.stderr.strip()}")
    return result.stdout.rstrip("\n")


def delete_notes_with_prefix(prefix):
    # "whose name begins with" + a single `delete` on the whole filtered
    # list — deleting a manually `repeat`-collected list of note
    # references hits an AppleScript stale-reference error (-1728) in
    # Notes.app once indices shift; this filter form doesn't.
    script = f'''
    tell application "Notes"
        set targetFolder to missing value
        repeat with f in folders of account "On My Mac"
            if name of f is "Notes" then
                set targetFolder to f
                exit repeat
            end if
        end repeat
        delete (notes of targetFolder whose name begins with "{prefix}")
        return "ok"
    end tell
    '''
    return _run_osascript(script)


def create_note(name, body_html):
    escaped = body_html.replace("\\", "\\\\").replace('"', '\\"')
    script = f'''
    tell application "Notes"
        set targetFolder to missing value
        repeat with f in folders of account "On My Mac"
            if name of f is "Notes" then
                set targetFolder to f
                exit repeat
            end if
        end repeat
        make new note at targetFolder with properties {{name:"{name}", body:"{escaped}"}}
    end tell
    '''
    _run_osascript(script)


def note_exists(name):
    script = f'''
    tell application "Notes"
        set targetFolder to missing value
        repeat with f in folders of account "On My Mac"
            if name of f is "Notes" then
                set targetFolder to f
                exit repeat
            end if
        end repeat
        repeat with n in notes of targetFolder
            if name of n is "{name}" then return "yes"
        end repeat
        return "no"
    end tell
    '''
    return _run_osascript(script) == "yes"


def get_plaintext(name):
    script = f'''
    tell application "Notes"
        set targetFolder to missing value
        repeat with f in folders of account "On My Mac"
            if name of f is "Notes" then
                set targetFolder to f
                exit repeat
            end if
        end repeat
        repeat with n in notes of targetFolder
            if name of n is "{name}" then return plaintext of n
        end repeat
        return "__NOT_FOUND__"
    end tell
    '''
    return _run_osascript(script)
