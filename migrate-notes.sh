#!/bin/bash
# ============================================================
# Daily Notes Migration Script
# 每天自动把"明日保留"变成第二天的"今日任务"
#
# 安装：LaunchAgent 控制运行时间（工作日 08:00）
# 位置：~/Library/LaunchAgents/com.tully.daily-notes-migration.plist
#
# 格式保留：carried-over 内容不再靠 plaintext 重建（会丢加粗/列表/图片），
# 改成解析源笔记 body 的原始 HTML 段落，逐段保留格式后再拼进新笔记。
# 勾选框的选中状态本身 AppleScript 读写两头都摸不到（Notes 完全不导出这
# 个标记），继续靠 @@@FINISHED@@@ 分割线的"位置"判断要不要迁移。
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="/tmp/daily-notes-migration.log"
HOLIDAYS_FILE="${SCRIPT_DIR}/holidays.txt"
TRANSFORM_PY="${SCRIPT_DIR}/transform.py"
MAX_BODY_BYTES=5000000  # 5MB — 超过这个量提示可能含大图，见 feedback_applescript_notes_write_size_limit

TMP_DIR="$(mktemp -d /tmp/daily-notes-migration-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

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

# ── 第一步：把源笔记的原始 body HTML 逐个导出到临时文件 ──
MANIFEST=$(/usr/bin/osascript <<ENDOSA
set sourcePrefix to "$SOURCE_PREFIX"
set tmpDir to "$TMP_DIR"

tell application "Notes"
    set targetFolder to missing value
    set folderList to folders of account "On My Mac"
    repeat with f in folderList
        if name of f is "Notes" then
            set targetFolder to f
            exit repeat
        end if
    end repeat
    if targetFolder is missing value then return "ERROR: Notes folder not found"

    set sourceNotes to {}
    set noteList to notes of targetFolder
    repeat with n in noteList
        if (name of n) starts with sourcePrefix then set end of sourceNotes to n
    end repeat
    if (count of sourceNotes) is 0 then return "ERROR: No source note found for prefix " & sourcePrefix

    set manifestLines to {}
    set idx to 0
    repeat with sn in sourceNotes
        set idx to idx + 1
        set bodyFile to tmpDir & "/source_" & idx & ".html"
        set bodyText to body of sn
        set fh to open for access POSIX file bodyFile with write permission
        set eof of fh to 0
        write bodyText to fh as «class utf8»
        close access fh
        set end of manifestLines to (name of sn) & tab & bodyFile
    end repeat

    set AppleScript's text item delimiters to linefeed
    set manifestText to manifestLines as string
    set AppleScript's text item delimiters to ""
    return manifestText
end tell
ENDOSA
)

if [[ "$MANIFEST" == ERROR:* ]]; then
    echo "$MANIFEST"
    exit 1
fi

echo "Source notes dumped:"
echo "$MANIFEST"

# ── 第二步：manifest 转成 JSON，跑 transform.py 解析+重组 HTML ──
# (manifest 走临时文件传给 python，不走 stdin —— heredoc 已经占用了 python 脚本本身的 stdin，
#  和 <<< herestring 叠在同一个命令上时后者会被静默吃掉，之前在这里踩过一次坑)
echo "$MANIFEST" > "$TMP_DIR/manifest_raw.txt"

python3 - "$TMP_DIR" <<'ENDPY'
import json, sys
tmp_dir = sys.argv[1]
sources = []
names = []
with open(f"{tmp_dir}/manifest_raw.txt", encoding="utf-8") as f:
    for line in f.read().splitlines():
        if not line.strip():
            continue
        name, body_file = line.split("\t", 1)
        sources.append({"name": name, "bodyFile": body_file})
        names.append(name)
manifest = {
    "sources": sources,
    "todayOut": f"{tmp_dir}/today_frag.html",
    "tomorrowOut": f"{tmp_dir}/tomorrow_frag.html",
    "todayPlainOut": f"{tmp_dir}/today_plain.txt",
    "tomorrowPlainOut": f"{tmp_dir}/tomorrow_plain.txt",
}
with open(f"{tmp_dir}/manifest.json", "w", encoding="utf-8") as f:
    json.dump(manifest, f)
with open(f"{tmp_dir}/source_names.txt", "w", encoding="utf-8") as f:
    f.write(", ".join(names))
ENDPY

SOURCE_NAMES=$(cat "$TMP_DIR/source_names.txt")
echo "Source names: $SOURCE_NAMES"

TRANSFORM_RESULT=$(python3 "$TRANSFORM_PY" < "$TMP_DIR/manifest.json")
echo "Transform result: $TRANSFORM_RESULT"

TODAY_FRAG_FILE="$TMP_DIR/today_frag.html"
TOMORROW_FRAG_FILE="$TMP_DIR/tomorrow_frag.html"
TODAY_PLAIN_FILE="$TMP_DIR/today_plain.txt"
TOMORROW_PLAIN_FILE="$TMP_DIR/tomorrow_plain.txt"

TODAY_COUNT=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['todayCount'])" "$TRANSFORM_RESULT")
TOMORROW_COUNT=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['tomorrowCount'])" "$TRANSFORM_RESULT")

# ── 体积安全检查（大图内嵌截图写入会静默截断，见 feedback_applescript_notes_write_size_limit）──
TOTAL_BYTES=$(( $(wc -c < "$TODAY_FRAG_FILE") + $(wc -c < "$TOMORROW_FRAG_FILE") ))
if [ "$TOTAL_BYTES" -gt "$MAX_BODY_BYTES" ]; then
    echo "WARNING: carried-over content is ${TOTAL_BYTES} bytes (>${MAX_BODY_BYTES}) — likely contains large embedded images. Notes.app may silently truncate on write. Check '$TARGET_NAME' manually after this run."
fi

# ── 第三步：写入/追加目标笔记（保格式）──
RESULT=$(/usr/bin/osascript <<ENDOSA
set targetName to "$TARGET_NAME"
set sourceNames to "$SOURCE_NAMES"
set todayFrag to ""
set tomorrowFrag to ""
try
    set todayFrag to (read (POSIX file "$TODAY_FRAG_FILE") as «class utf8»)
end try
try
    set tomorrowFrag to (read (POSIX file "$TOMORROW_FRAG_FILE") as «class utf8»)
end try
set todayCount to $TODAY_COUNT
set tomorrowCount to $TOMORROW_COUNT

tell application "Notes"
    set targetFolder to missing value
    set folderList to folders of account "On My Mac"
    repeat with f in folderList
        if name of f is "Notes" then
            set targetFolder to f
            exit repeat
        end if
    end repeat

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

        if todayCount is 0 and tomorrowCount is 0 then
            return "OK Skipped '" & targetName & "': no content to migrate"
        end if

        if todayFrag is not "" and existingPlain contains todayFrag then
            return "OK Skipped '" & targetName & "': all content already present"
        end if

        set existingBody to body of existingNote
        set newContent to "<div><br></div>" & return & "<div><hr></div>" & return & "<div><b>📋 Appended from " & sourceNames & "</b></div>" & return & "<div><br></div>" & return

        set newContent to newContent & "<div><b>━━━ Today ━━━</b></div>" & return & "<div><br></div>" & return
        if todayFrag is not "" then set newContent to newContent & todayFrag & return
        if tomorrowFrag is not "" then set newContent to newContent & tomorrowFrag & return
        set newContent to newContent & "<div><br></div>" & return
        set newContent to newContent & "<div>@@@FINISHED@@@</div>" & return
        set newContent to newContent & "<div><br></div>" & return

        set newContent to newContent & "<div><b>━━━ Tomorrow ━━━</b></div>" & return & "<div><br></div>" & return & "<div><br></div>" & return
        set newContent to newContent & "<div><b>━━━ Reference ━━━</b></div>" & return & "<div><br></div>" & return & "<div><br></div>" & return

        set body of existingNote to existingBody & return & newContent
        return "OK Appended '" & targetName & "' (" & todayCount & " tasks + " & tomorrowCount & " carry-forward from " & sourceNames & ")"
    else
        set htmlBody to "<div><i>📋 Migrated from " & sourceNames & "</i></div>" & return
        set htmlBody to htmlBody & "<div><br></div>" & return
        set htmlBody to htmlBody & "<div><b>━━━ Today ━━━</b></div>" & return & "<div><br></div>" & return
        if todayFrag is not "" then set htmlBody to htmlBody & todayFrag & return
        if tomorrowFrag is not "" then set htmlBody to htmlBody & tomorrowFrag & return
        set htmlBody to htmlBody & "<div><br></div>" & return
        set htmlBody to htmlBody & "<div>@@@FINISHED@@@</div>" & return
        set htmlBody to htmlBody & "<div><br></div>" & return

        set htmlBody to htmlBody & "<div><b>━━━ Tomorrow ━━━</b></div>" & return & "<div><br></div>" & return & "<div><br></div>" & return

        set htmlBody to htmlBody & "<div><b>━━━ Reference ━━━</b></div>" & return & "<div><br></div>" & return & "<div><br></div>" & return

        make new note at targetFolder with properties {name:targetName, body:htmlBody}
        return "OK Created '" & targetName & "' (" & todayCount & " tasks + " & tomorrowCount & " carry-forward from " & sourceNames & ")"
    end if
end tell
ENDOSA
)

echo "$RESULT"
echo "[$(date)] Migration finished."
