# corentin.todo

A todo-list bar widget for the Omarchy shell: a checkmark icon on the
right of the bar that opens a task panel beneath it.

## Usage

- **Open/close:** click the checkmark, or press `SUPER + CTRL + T`.
- **Add a task:** type in the box (multi-line), then Add or `Ctrl+⏎`.
- **Filter:** To do / Completed switch — one list is always showing.
- **Complete / reopen:** the left button on each row (checkmark ↔ undo arrow).
- **Edit:** pencil button at the right end of active tasks; inline editor
  with Update. Enter is a newline there too.
- **Delete:** trash button (under the pencil on active tasks, alone on
  completed ones), with confirmation.
- Every task shows `Created … · Updated …` stamps. Tasks toggle between
  the lists forever — nothing archives or expires.

Tasks live in `~/.local/state/omarchy/todo.json`, outside the shell config,
so bar/layout operations can never take them down.

## Shortcuts

| Where | Keys | Action |
|---|---|---|
| Bar | `SUPER + CTRL + T` | Toggle the panel |
| Add / edit field | `Ctrl+⏎` | Submit |
| Add / edit field | `Shift+⏎` (or `⏎`) | Newline |
| Add field | `Esc` | Close panel |
| Edit field | `Esc` | Cancel edit |
| Delete dialog | `← →` | Move selection |
| Delete dialog | `⏎` / `Space` | Confirm selection |
| Delete dialog | `Ctrl+⏎` | Delete immediately |
| Delete dialog | `Esc` | Cancel |

## Files

| File | Role |
|---|---|
| `BarWidget.qml` (~90 lines) | Checkmark bar button, panel host, `corentin.todo` IPC target |
| `Panel.qml` (~900 lines) | Panel: header, textareas, filter, list, edit, delete + confirm, file store |
| `Model.js` (~165 lines) | Pure task math + store envelope; Qt-free, node-testable |
| `manifest.json` | Standalone plugin metadata (`corentin.todo`) |

## Maintainer notes

Conventions from the design grill — don't relitigate without new evidence:

- **Store:** `{version, items}` JSON via `FileView` (atomic writes,
  debounced 200ms saves). `shell.json` carries layout only — config never
  contains tasks. Reads go through `Model.coerceItems` / `parseStore`;
  corrupt input renders empty, never crashes.
- **First load is gated** on the bar's settings injection (`settingsSeen`):
  never strip-or-adopt what you haven't observed.
- **Session-only:** filter tab, edit mode, delete-pending. Restoring
  anything else would need store schema that doesn't exist.
- **Edits abandon totally** on toggle / filter switch / close — no
  sometimes-preserved drafts.
- **Bar widget stays stateless** (no count badge); the panel owns state.
- **IPC is toggle-only.** The JSON file is the query API (`jq` it).
- Hints sit centered; the delete dialog preselects Cancel.

Verifying changes:

```bash
node -e 'const M = require("./Model.js"); ...'   # model probes
/usr/lib/qt6/bin/qmllint BarWidget.qml Panel.qml # NOT /usr/bin/qmllint (Qt5 chokes on `: void`)
omarchy restart shell                             # hot-reload can't be trusted for this plugin
journalctl --user -u omarchy-shell --since "2 minutes ago" | grep -iE "todo|error|fail"
```
