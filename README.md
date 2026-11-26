# Claude-Code-Widget

A fun little app that displays Claude Code usage on the desktop and in the top bar, macOS only, starring Clawd.

**Widgets** (right-click desktop → Edit Widgets → search "Claude"):
- **What Claude's Doing** (S/M): live status of your latest session: tool in use, prompt, project, model
- **Today's Usage** (S/M): tokens, output, cache, sessions, tool calls, hourly chart
- **Weekly Usage** (S/M/L): 7-day chart, active time, top projects
- **Clawd** (S): the mascot, reacting to what Claude is doing

**How it works:** the menu-bar app (Clawd icon) reads `~/.claude/projects/**/*.jsonl` every 4 s,
writes a small snapshot to the shared App Group container, and asks WidgetKit to reload.
Widgets can't read `~/.claude` themselves (sandbox), so keep the app running; tick "Launch at login".

**Build:**
```bash
xcodegen generate
xcodebuild -project ClaudeWidget.xcodeproj -scheme ClaudeWidget -configuration Release -derivedDataPath build build
ditto build/Build/Products/Release/ClaudeWidget.app /Applications/ClaudeWidget.app
```
