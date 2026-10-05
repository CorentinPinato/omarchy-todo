import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The todo panel: an input row to add tasks, a To do / Completed filter,
// and the task list for the active filter. Tasks toggle between the two
// lists forever — there is no delete path.
//
// BarWidget.qml owns the bar button and hands this panel the button to
// anchor against.
Panel {
  id: root
  moduleName: "corentin.todo"
  ipcTarget: "corentin.todo"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel. Everything the bar identifies a panel by has to be that
  // widget: the popout coordinator (and with it the open-panel dot under the
  // pill) compares against `slot.activeItem`, and switchPanelFrom looks the
  // slot up the same way.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // Tasks live in a dedicated state file, not in shell.json: layout
  // entries get rewritten by bar tooling, which used to take the tasks
  // down with them. XDG state dir, following the shell's own services —
  // persistent user state, not regeneratable cache.
  readonly property string storeDir: Quickshell.env("HOME") + "/.local/state/omarchy/"
  readonly property string storePath: storeDir + "todo.json"

  // File-backed task list. Empty until the store loads so the panel never
  // flashes stale settings data; saves are blocked until then too.
  // settingsSeen tracks the bar's injection: the entry must be observed
  // before any strip-or-adopt decision, otherwise an early load would
  // wipe tasks it hasn't seen yet.
  property var fileItems: []
  property bool storeLoaded: false
  property bool settingsSeen: false
  readonly property var items: storeLoaded ? fileItems : []
  readonly property var visibleItems: Model.visibleItems(items, filter)

  onSettingsChanged: {
    root.settingsSeen = true
    if (!root.storeLoaded) storeFile.reload()
  }

  // Session-only: which list is on screen. One of the two is always active.
  property string filter: "todo"

  // Session-only: id of the task being rewritten inline. At most one row
  // is in edit mode at a time; "" means no row is.
  property string editingId: ""

  // Session-only: id of the task awaiting delete confirmation; "" means
  // no confirmation dialog is open.
  property string pendingDeleteId: ""
  readonly property string pendingDeleteText: {
    var full = ""
    for (var i = 0; i < items.length; i++)
      if (items[i] && String(items[i].id) === pendingDeleteId) full = String(items[i].text)
    var line = full.split("\n")[0]
    return line.length > 80 ? line.slice(0, 80) + "…" : line
  }

  // Guarded so the widget renders before the bar is injected (the bar-widget
  // contract instantiates it bare).
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  // Multi-line task input styled like Ui/TextField. Enter inserts a newline;
  // commit via accepted() (Ctrl+Enter or the row button), abort via
  // cancelled() (Escape).
  component TodoTextArea: Item {
    id: fieldRoot

    property alias text: area.text
    property alias placeholderText: area.placeholderText
    property color foreground: Color.foreground
    property color accent: Color.accent
    property color selectionTint: Style.selectionFillFor(foreground, accent)
    property string fontFamily: Style.font.family
    property real fontSize: Style.font.body
    property int visibleRows: 3

    signal accepted()
    signal cancelled()

    function selectAll() { area.selectAll() }

    activeFocusOnTab: true
    onActiveFocusChanged: if (activeFocus) area.forceActiveFocus()

    implicitHeight: Math.max(1, Math.round(fontSize * 1.4 * visibleRows) + Border.top(_borderSpec) + Border.bottom(_borderSpec))

    readonly property var _borderSpec: Border.controlSpec(area.activeFocus ? "focus" : (area.hovered ? "hover-cursor" : "normal"), foreground, accent)

    // BeforeItem so Ctrl+Enter/Escape are caught before the area itself
    // sees them; a plain Enter is left alone and inserts a newline.
    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Escape) {
        fieldRoot.cancelled()
        event.accepted = true
      } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
        fieldRoot.accepted()
        event.accepted = true
      }
    }

    BorderSurface {
      anchors.fill: parent
      color: Style.controlFill(area.activeFocus, area.hovered, fieldRoot.foreground, fieldRoot.accent)
      borderSpec: fieldRoot._borderSpec
      radius: Style.cornerRadius
    }

    Flickable {
      anchors.fill: parent
      anchors.leftMargin: Border.left(fieldRoot._borderSpec)
      anchors.rightMargin: Border.right(fieldRoot._borderSpec)
      anchors.topMargin: Border.top(fieldRoot._borderSpec)
      anchors.bottomMargin: Border.bottom(fieldRoot._borderSpec)
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick

      TextArea.flickable: TextArea {
        id: area
        wrapMode: Text.Wrap
        selectByMouse: true
        hoverEnabled: true
        font.family: fieldRoot.fontFamily
        font.pixelSize: fieldRoot.fontSize
        color: fieldRoot.foreground
        selectionColor: fieldRoot.selectionTint
        selectedTextColor: fieldRoot.foreground
        placeholderTextColor: Qt.darker(fieldRoot.foreground, 1.6)

        // The wrapper owns all chrome; the inner field paints text only.
        background: Rectangle {
          color: "transparent"
          border.width: 0
        }
      }
    }
  }

  function open() {
    root.controller.show()
  }

  function close() {
    if (root.editingId !== "") root.editingId = ""
    if (root.pendingDeleteId !== "") root.pendingDeleteId = ""
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // The shell.json entry carries layout only. "items" is deliberately
  // dropped so a stale task list can never linger in config now that the
  // state file is the source of truth.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id" && existing !== "items") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // ---- File store. Pattern lifted from the shell's own services:
  //      mkdir on start, FileView load, debounced atomic saves.

  function loadStore(raw) {
    var parsed = Model.parseStore(raw)
    if (parsed.error !== "") console.warn("todo: store parse failed:", parsed.error)

    // Live file change — our own debounced save or another monitor's.
    // Refresh the list, but never touch shell.json here; the one-time
    // strip below already happened. The serialize round-trip skips
    // no-op rebuilds from our own saves.
    if (root.storeLoaded) {
      if (Model.serializeStore(fileItems) !== String(raw)) root.fileItems = parsed.items
      return
    }

    // A populated file wins outright, no settings needed.
    if (parsed.items.length > 0) {
      root.fileItems = parsed.items
      root.storeLoaded = true
      root.persistSettings({})
      return
    }

    // File empty and the bar hasn't wired settings up yet: wait for the
    // onSettingsChanged retry. Stripping now would destroy tasks sitting
    // in an entry we haven't observed — unrecoverable.
    if (!root.settingsSeen) return

    // Genuine first run, or one-time migration from the old shell.json
    // entry. persistSettings drops "items" from the entry going forward.
    var next = Model.coerceItems(setting("items", []))
    root.fileItems = next
    root.storeLoaded = true
    root.persistSettings({})
    if (next.length > 0) root.scheduleSave()
  }

  function scheduleSave() {
    if (!root.storeLoaded) return
    storeSaveTimer.restart()
  }

  function flushStore() {
    storeFile.setText(Model.serializeStore(fileItems))
  }

  function addItem() {
    if (newItemField.text.trim() === "") return
    root.fileItems = Model.addItem(items, newItemField.text, Date.now())
    root.scheduleSave()
    root.persistSettings({})
    newItemField.text = ""
  }

  function toggleItem(id) {
    if (root.editingId !== "") root.editingId = ""
    root.fileItems = Model.toggleItem(items, id, Date.now())
    root.scheduleSave()
    root.persistSettings({})
  }

  function setFilter(value) {
    if (value !== "todo" && value !== "done") return
    if (root.editingId !== "") root.editingId = ""
    if (root.pendingDeleteId !== "") root.pendingDeleteId = ""
    root.filter = value
  }

  function startEdit(id) {
    root.editingId = String(id)
  }

  // Empty or unchanged rewrites are dropped silently; anything else
  // replaces the text and stamps the change.
  function commitEdit(id, text) {
    var clean = String(text === undefined || text === null ? "" : text).trim()
    var current = ""
    for (var i = 0; i < items.length; i++)
      if (items[i] && String(items[i].id) === String(id)) current = String(items[i].text)
    if (clean === "" || clean === current) {
      root.editingId = ""
      newItemField.forceActiveFocus()
      return
    }
    root.fileItems = Model.updateItemText(items, id, clean, Date.now())
    root.scheduleSave()
    root.persistSettings({})
    root.editingId = ""
    newItemField.forceActiveFocus()
  }

  function cancelEdit() {
    root.editingId = ""
    newItemField.forceActiveFocus()
  }

  function askDelete(id) {
    root.pendingDeleteId = String(id)
    dialogScope.selectedIndex = 0
    dialogScope.forceActiveFocus()
  }

  function cancelDelete() {
    root.pendingDeleteId = ""
    newItemField.forceActiveFocus()
  }

  function removeItem(id) {
    root.fileItems = Model.removeItem(items, id)
    root.scheduleSave()
    root.persistSettings({})
    if (root.editingId === String(id)) root.editingId = ""
    root.pendingDeleteId = ""
    newItemField.forceActiveFocus()
  }

  // Short local stamp for the creation / update lines. Items always carry
  // epoch milliseconds, so this only guards hand-edited config.
  function stamp(ts) {
    var n = Number(ts)
    if (!isFinite(n) || n <= 0) return "—"
    return Qt.formatDateTime(new Date(Math.round(n)), "d MMM HH:mm")
  }

  FileView {
    id: storeFile
    path: root.storePath
    // Watch so every per-monitor instance refreshes off the same file.
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadStore(storeFile.text())
    // First run: the file doesn't exist yet. Without this branch the
    // store would stay unloaded forever and nothing would ever save.
    onLoadFailed: root.loadStore("")
  }

  Timer {
    id: storeSaveTimer
    interval: 200
    repeat: false
    onTriggered: root.flushStore()
  }

  Process {
    id: ensureStoreDirProc
    command: ["mkdir", "-p", root.storeDir]
  }

  Component.onCompleted: {
    ensureStoreDirProc.running = true
    // Once mkdir has had a tick, load the existing store file. FileView
    // surfaces an empty string when the file doesn't exist; loadStore
    // handles that path, including the shell.json migration.
    Qt.callLater(function() { storeFile.reload() })
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: newItemField
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(headerBlock.implicitHeight + Style.space(12) + listColumn.implicitHeight)

    // Fixed header (title, input, filter) plus a task list that scrolls
    // internally once the panel reaches the screen cap.
    Item {
      anchors.fill: parent

      Column {
        id: headerBlock
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(12)

        PanelSectionHeader {
          text: "TODO LIST"
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
          fontSize: Style.font.title
        }

        // ---- New-task row: text area with the Add button right-aligned
        //      beneath it.
        Column {
          id: inputRow
          width: parent.width
          spacing: Style.space(8)

          TodoTextArea {
            id: newItemField
            width: parent.width
            placeholderText: "New task"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onAccepted: root.addItem()
            onCancelled: root.close()
          }

          Item {
            width: parent.width
            height: addButton.height + Style.space(4) + addHintRow.height

            Button {
              id: addButton
              anchors.right: parent.right
              anchors.top: parent.top
              text: "Add"
              bordered: true
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onClicked: root.addItem()
            }

            Row {
              id: addHintRow
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.bottom: parent.bottom
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "[Esc]"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "close"
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "·"
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "[Ctrl+⏎]"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "add"
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "·"
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "[Shift+⏎]"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "newline"
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        // ---- List filter. ButtonGroup is mutually exclusive by design,
        //      so one of the two lists is on screen at all times.
        ButtonGroup {
          id: filterGroup
          anchors.left: parent.left
          options: [
            { value: "todo", label: "To do" },
            { value: "done", label: "Completed" }
          ]
          value: root.filter
          focusable: false
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
          onChanged: function(v) { root.setFilter(v) }
        }
      }

      Flickable {
        id: listScroll
        anchors.top: headerBlock.bottom
        anchors.topMargin: Style.space(12)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        contentWidth: listColumn.width
        contentHeight: listColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: listColumn
          width: listScroll.width
          spacing: Style.space(12)

        // ---- Task list for the active filter. The action sits on the
        //      left, before the text: a checkmark completes a task, a
        //      return glyph reopens a completed one.
        Repeater {
          model: root.visibleItems

          Column {
            required property var modelData

            width: listColumn.width
            readonly property bool editing: root.editingId === String(modelData.id)

            // View mode: toggle on the left, text in the middle, actions
            // stacked at the right end — edit above delete on active
            // tasks, delete alone on completed ones.
            Row {
              visible: !parent.editing
              width: parent.width
              spacing: Style.space(8)

              PanelActionButton {
                id: toggleButton
                anchors.verticalCenter: parent.verticalCenter
                iconText: modelData.done ? "󰕌" : "󰄬"
                tooltipText: modelData.done ? "Back to To do" : "Mark completed"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.toggleItem(modelData.id)
              }

              Column {
                width: parent.width - toggleButton.width - actionsColumn.width - parent.spacing * 2
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: modelData.text
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  font.strikeout: modelData.done === true
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: "Created " + root.stamp(modelData.createdAt) + " · Updated " + root.stamp(modelData.updatedAt)
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Column {
                id: actionsColumn
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)

                PanelActionButton {
                  id: editButton
                  visible: modelData.done !== true
                  anchors.horizontalCenter: parent.horizontalCenter
                  iconText: "󰏫"
                  tooltipText: "Edit task"
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  onClicked: root.startEdit(modelData.id)
                }

                PanelActionButton {
                  id: deleteButton
                  anchors.horizontalCenter: parent.horizontalCenter
                  iconText: "󰩹"
                  tooltipText: "Delete task"
                  foreground: root.contentForeground
                  hoverColor: Color.urgent
                  fontFamily: root.contentFontFamily
                  onClicked: root.askDelete(modelData.id)
                }
              }
            }

            // Edit mode: text area with the Update button right-aligned
            // beneath it.
            Column {
              visible: parent.editing
              width: parent.width
              spacing: Style.space(8)

              TodoTextArea {
                id: editField
                width: parent.width
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onAccepted: root.commitEdit(modelData.id, text)
                onCancelled: root.cancelEdit()
                onVisibleChanged: {
                  if (visible) {
                    text = modelData.text
                    forceActiveFocus()
                    selectAll()
                  }
                }
              }

              Item {
                width: parent.width
                height: updateButton.height + Style.space(4) + updateHintRow.height

                Button {
                  id: updateButton
                  anchors.right: parent.right
                  anchors.top: parent.top
                  text: "Update"
                  bordered: true
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  onClicked: root.commitEdit(modelData.id, editField.text)
                }

                Row {
                  id: updateHintRow
                  anchors.horizontalCenter: parent.horizontalCenter
                  anchors.bottom: parent.bottom
                  spacing: Style.space(6)

                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: "[Esc]"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                  }
                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: "cancel"
                    color: Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: "·"
                    color: Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: "[Ctrl+⏎]"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                  }
                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: "save"
                    color: Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: "·"
                    color: Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: "[Shift+⏎]"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                  }
                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: "newline"
                    color: Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }
        }

        Text {
          visible: root.visibleItems.length === 0
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: root.filter === "done" ? "No completed tasks" : "No tasks yet — add one above"
          color: Qt.darker(root.contentForeground, 1.5)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
        }
        }
      }
    }

    // Delete confirmation, overlaying the panel while open. A bespoke
    // card (rather than Ui/ConfirmDialog) so the title paints urgent red
    // while the body and Cancel stay neutral. Focus moves here so
    // arrows/Enter/Escape drive the dialog instead of the text areas
    // behind it. Cancel is preselected — the safe choice stays primary.
    Item {
      id: dialogScope
      anchors.fill: parent
      visible: root.pendingDeleteId !== ""
      property int selectedIndex: 0

      Keys.onPressed: function(event) {
        if (!dialogScope.visible) return
        if (event.key === Qt.Key_Escape) {
          root.cancelDelete()
          event.accepted = true
        } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
          root.removeItem(root.pendingDeleteId)
          event.accepted = true
        } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right || event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
          dialogScope.selectedIndex = dialogScope.selectedIndex === 0 ? 1 : 0
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
          if (dialogScope.selectedIndex === 0) root.cancelDelete()
          else root.removeItem(root.pendingDeleteId)
          event.accepted = true
        }
      }

      Rectangle {
        anchors.fill: parent
        color: Util.alpha(Color.background, 0.7)

        MouseArea { anchors.fill: parent; onClicked: root.cancelDelete() }

        BorderSurface {
          id: deleteCard
          width: Math.min(parent.width - Style.space(32), Style.space(370))
          height: deleteCard.contentTopInset + deleteCard.contentBottomInset + cardColumn.implicitHeight
          anchors.centerIn: parent
          color: Color.background
          borderSpec: Border.flat(Color.urgent, Style.normalBorderWidth)
          padding: Style.space(18)
          bottomPadding: Style.space(4)
          radius: Style.cornerRadius

          MouseArea { anchors.fill: parent; onClicked: {} }

          Item {
            anchors.fill: parent
            anchors.topMargin: deleteCard.contentTopInset
            anchors.rightMargin: deleteCard.contentRightInset
            anchors.bottomMargin: deleteCard.contentBottomInset
            anchors.leftMargin: deleteCard.contentLeftInset

            Column {
              id: cardColumn
              anchors.fill: parent
              spacing: Style.space(6)

              Text {
                id: titleText
                textFormat: Text.PlainText
                width: parent.width
                text: "Delete this task ?"
                color: Color.urgent
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                id: previewText
                textFormat: Text.PlainText
                width: parent.width
                maximumLineCount: 2
                elide: Text.ElideRight
                wrapMode: Text.WordWrap
                text: root.pendingDeleteText
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Item {
                width: parent.width
                height: Style.space(10)
              }

              Item {
                width: parent.width
                height: dialogButtons.height

                Row {
                  id: dialogButtons
                  anchors.right: parent.right
                  spacing: Style.space(10)
              Button {
                text: "Cancel"
                bordered: true
                foreground: Qt.darker(root.contentForeground, 1.5)
                hasCursor: dialogScope.selectedIndex === 0
                fontFamily: root.contentFontFamily
                onClicked: root.cancelDelete()
              }

              Button {
                text: "Delete"
                bordered: true
                foreground: Color.urgent
                hasCursor: dialogScope.selectedIndex === 1
                fontFamily: root.contentFontFamily
                onClicked: root.removeItem(root.pendingDeleteId)
              }
            }
          }

          Item {
            width: parent.width
            height: dialogHintRow.height

            Row {
              id: dialogHintRow
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "[Esc]"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "cancel"
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "·"
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "[Ctrl+⏎]"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "delete"
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }
    }
  }
}
  }
}
