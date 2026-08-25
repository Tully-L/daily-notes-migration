# daily-notes-migration

这是仓库所有者本人每天实际在用的每日笔记迁移工具。项目基于 Shell 脚本 + AppleScript，通过 macOS 系统的 `osascript` 操作原生 Notes.app（备忘录），自动把当天笔记中"今日任务"里未完成的事项和"明日保留"的内容，搬运成第二天笔记的"今日任务"，从而实现每日待办的自动接力，不需要手动复制粘贴。脚本内置工作日判断和节假日跳过逻辑（周末自动跳过，节假日名单维护在 `holidays.txt`），并通过 LaunchAgent 定时在工作日早上自动触发。

## 文件说明

- `migrate-notes.sh`：核心迁移脚本，负责计算源笔记/目标笔记的日期前缀、跳过周末与节假日、解析笔记正文并调用 AppleScript 操作 Notes.app 完成任务迁移。
- `holidays.txt`：节假日名单（`MMDD` 格式），迁移脚本运行前会检查当天是否在此名单中，命中则跳过。
