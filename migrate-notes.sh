#!/bin/bash
# ============================================================
# Daily Notes Migration Script
# 每天自动把"明日保留"变成第二天的"今日任务"
#
# 安装：LaunchAgent 控制运行时间（工作日 08:00）
# 位置：~/Library/LaunchAgents/com.tully.daily-notes-migration.plist
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="/tmp/daily-notes-migration.log"
HOLIDAYS_FILE="${SCRIPT_DIR}/holidays.txt"

exec > "$LOG_FILE" 2>&1
echo "[$(date)] Starting daily notes migration..."

# ── 日期信息 ──
TODAY=$(date +%Y%m%d)
MONTH=$(date +%m)
DAY=$(date +%d)
WEEKDAY=$(date +%u)   # 1=Mon ... 7=Sun
WEEKDAY_SHORT=$(date +%a)  # Mon, Tue, Wed...

echo "Today: $TODAY ($WEEKDAY_SHORT, weekday=$WEEKDAY)"

# ── 周末跳过 ──
if [ "$WEEKDAY" -ge 6 ]; then
    echo "Weekend — skipping."
    exit 0
fi

# ── 节假日跳过 ──
if [ -f "$HOLIDAYS_FILE" ]; then
    TODAY_MMDD="${MONTH}${DAY}"
    if grep -q "^${TODAY_MMDD}$" "$HOLIDAYS_FILE" 2>/dev/null; then
        echo "Holiday ($TODAY_MMDD) — skipping."
        exit 0
    fi
fi

# ── 计算源日期（昨天/上周五） ──
if [ "$WEEKDAY" -eq 1 ]; then
    # Monday → source = last Friday
    SOURCE_MM=$(date -v-3d +%m)
    SOURCE_DD=$(date -v-3d +%d)
    echo "Monday → source last Friday"
else
    # Tue-Fri → source = yesterday
    SOURCE_MM=$(date -v-1d +%m)
    SOURCE_DD=$(date -v-1d +%d)
    echo "Weekday → source yesterday"
fi

# ── 源笔记前缀 ──
SOURCE_PREFIX="${SOURCE_MM}${SOURCE_DD}-"
echo "Source prefix: $SOURCE_PREFIX"

# ── 目标笔记名称（今天） ──
TARGET_PREFIX="${MONTH}${DAY}-"
if [ "$WEEKDAY" -eq 2 ]; then
    TARGET_NAME="${TARGET_PREFIX}Tue"
else
    TARGET_NAME="${TARGET_PREFIX}"
fi

echo "Target note: $TARGET_NAME (${WEEKDAY_SHORT})"

# ── 执行迁移 ──
/usr/bin/osascript <<ENDOSA
set accountName to "On My Mac"
set folderName to "Notes"
set sourcePrefix to "$SOURCE_PREFIX"
set targetName to "$TARGET_NAME"

on trimText(s)
    if (length of s) ≤ 1 then return s
    repeat while (length of s) > 0 and (s starts with " " or s starts with tab)
        if s starts with " " then
            set s to text 2 thru -1 of s
        else if s starts with tab then
            set s to text 2 thru -1 of s
        end if
        if (length of s) ≤ 1 then exit repeat
    end repeat
    return s
end trimText

tell application "Notes"
    -- Find Notes folder
    set targetFolder to missing value
    set folderList to folders of account accountName
    repeat with f in folderList
        if name of f is folderName then
            set targetFolder to f
            exit repeat
        end if
    end repeat

    if targetFolder is missing value then
        return "ERROR: Notes folder not found"
    end if

    -- Find all source notes matching MMDD- prefix
    set sourceNotes to {}
    set noteList to notes of targetFolder
    repeat with n in noteList
        set noteName to name of n
        if noteName starts with sourcePrefix then
            set end of sourceNotes to n
        end if
    end repeat

    if (count of sourceNotes) is 0 then
        return "ERROR: No source note found for prefix " & sourcePrefix
    end if

    -- Log all found source notes
    set sourceNames to ""
    repeat with sn in sourceNotes
        if sourceNames is "" then
            set sourceNames to name of sn
        else
            set sourceNames to sourceNames & ", " & name of sn
        end if
    end repeat
    log "Found " & (count of sourceNotes) & " source notes: " & sourceNames

    -- Concatenate plaintext from ALL source notes (skip first line = note title)
    set notePlain to ""
    set originalDelimiters to AppleScript's text item delimiters
    repeat with sn in sourceNotes
        set snText to plaintext of sn
        set AppleScript's text item delimiters to return
        set snLines to every paragraph of snText
        set AppleScript's text item delimiters to originalDelimiters
        set started to false
        set snName to name of sn
        repeat with lineNum from 2 to count of snLines
            set lineContent to item lineNum of snLines
            set trimmedLine to my trimText(lineContent)
            if not started and trimmedLine is snName then
                -- still in the title area, skip
            else if not started and trimmedLine is not "" then
                set started to true
                if notePlain is not "" then
                    set notePlain to notePlain & return
                end if
                set notePlain to notePlain & lineContent
            else if started then
                if notePlain is not "" then
                    set notePlain to notePlain & return
                end if
                set notePlain to notePlain & lineContent
            end if
        end repeat
    end repeat

    -- Parse paragraphs
    set originalDelimiters to AppleScript's text item delimiters
    set AppleScript's text item delimiters to return
    set paraList to every paragraph of notePlain
    set AppleScript's text item delimiters to originalDelimiters

    -- Only the "明日保留" section carries forward — it becomes tomorrow's "今日任务".
    -- 今日任务 / 问题修复 in the source are NOT migrated (fresh start each day).
    -- 待联系群组 no longer exists as a category.
    set currentSection to ""
    set sectionCarryForward to {}   -- content under 明日保留 in the source note

    repeat with i from 1 to count of paraList
        set p to item i of paraList
        set trimmed to my trimText(p)

        if trimmed starts with "━━━" then
            if trimmed contains "明日保留" then
                set currentSection to "carryForward"
            else
                set currentSection to ""
            end if
        else if trimmed is not "" then
            if currentSection is "carryForward" then
                if trimmed does not start with "✓" and trimmed does not start with "📋" then
                    set end of sectionCarryForward to trimmed
                end if
            end if
        end if
    end repeat

    log "Found " & (count of sectionCarryForward) & " items in 明日保留 → will become today's 今日任务"

    -- Build HTML with the 4-section template (no placeholder text, no 待联系群组)
    set htmlBody to "<div><i>📋 从 " & sourceNames & " 迁移</i></div>" & return
    set htmlBody to htmlBody & "<div><br></div>" & return

    -- Section 1: 今日任务 ← 昨天的明日保留
    set htmlBody to htmlBody & "<div><b>━━━ 今日任务 ━━━</b></div>" & return
    set htmlBody to htmlBody & "<div><br></div>" & return
    if (count of sectionCarryForward) > 0 then
        repeat with t in sectionCarryForward
            set htmlBody to htmlBody & "<div>" & t & "</div>" & return
        end repeat
        set htmlBody to htmlBody & "<div><br></div>" & return
    end if

    -- Section 2: 问题修复（每天从空开始）
    set htmlBody to htmlBody & "<div><b>━━━ 问题修复 ━━━</b></div>" & return
    set htmlBody to htmlBody & "<div><br></div>" & return
    set htmlBody to htmlBody & "<div><br></div>" & return

    -- Section 3: 明日保留（每天从空开始）
    set htmlBody to htmlBody & "<div><b>━━━ 明日保留 ━━━</b></div>" & return
    set htmlBody to htmlBody & "<div><br></div>" & return
    set htmlBody to htmlBody & "<div><br></div>" & return

    -- Section 4: 参考 & 备忘（每天从空开始）
    set htmlBody to htmlBody & "<div><b>━━━ 参考 &amp; 备忘 ━━━</b></div>" & return
    set htmlBody to htmlBody & "<div><br></div>" & return
    set htmlBody to htmlBody & "<div><br></div>" & return

    -- Check if target already exists (user may have pre-created it)
    set existingNote to missing value
    set existingFallback to missing value
    set noteList to notes of targetFolder
    repeat with n in noteList
        if name of n is targetName then
            set existingNote to n
            exit repeat
        else if name of n starts with targetName then
            if existingFallback is missing value then
                set existingFallback to n
            end if
        end if
    end repeat

    if existingNote is missing value and existingFallback is not missing value then
        set existingNote to existingFallback
    end if

    if existingNote is not missing value then
        set existingPlain to plaintext of existingNote

        if existingPlain contains "📋" and existingPlain contains targetName then
            return "OK Skipped '" & targetName & "': already has template (from previous run)"
        end if

        if (count of sectionCarryForward) is 0 then
            return "OK Skipped '" & targetName & "': no content to migrate"
        end if

        set AppleScript's text item delimiters to return
        set sourcePlain to (sectionCarryForward as string)
        set AppleScript's text item delimiters to originalDelimiters

        set contentExists to false
        if sourcePlain is not "" and existingPlain contains sourcePlain then
            set contentExists to true
        end if

        if contentExists then
            return "OK Skipped '" & targetName & "': all content already present"
        end if

        set existingBody to body of existingNote
        set newContent to "<div><br></div>" & return & "<div><hr></div>" & return & "<div><b>📋 从 " & sourceNames & " 追加迁移</b></div>" & return & "<div><br></div>" & return

        set newContent to newContent & "<div><b>━━━ 今日任务 ━━━</b></div>" & return & "<div><br></div>" & return
        repeat with t in sectionCarryForward
            set newContent to newContent & "<div>" & t & "</div>" & return
        end repeat
        set newContent to newContent & "<div><br></div>" & return

        set newContent to newContent & "<div><b>━━━ 问题修复 ━━━</b></div>" & return & "<div><br></div>" & return & "<div><br></div>" & return
        set newContent to newContent & "<div><b>━━━ 明日保留 ━━━</b></div>" & return & "<div><br></div>" & return & "<div><br></div>" & return
        set newContent to newContent & "<div><b>━━━ 参考 &amp; 备忘 ━━━</b></div>" & return & "<div><br></div>" & return & "<div><br></div>" & return

        set body of existingNote to existingBody & return & newContent
        return "OK Appended '" & targetName & "' (" & (count of sectionCarryForward) & " items from " & sourceNames & ")"
    else
        make new note at targetFolder with properties {name:targetName, body:htmlBody}
        return "OK Created '" & targetName & "' (" & (count of sectionCarryForward) & " items from " & sourceNames & ")"
    end if
end tell
ENDOSA

echo "[$(date)] Migration finished. Exit code: $?"
