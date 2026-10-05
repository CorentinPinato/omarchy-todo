// Pure task math for the todo widget and its panel.
// Everything here is locale- and Qt-free so it can be unit tested under node;
// the QML owns date rendering through Qt.formatDateTime().
//
// An item is { id, text, done, createdAt, updatedAt }. Timestamps are epoch
// milliseconds. Tasks toggle between active and completed forever — there is
// no delete path, so every item stays in the list.

function finiteMs(value) {
  var n = Number(value)
  if (!isFinite(n) || n < 0) return Date.now()
  return Math.round(n)
}

function cleanText(value) {
  return String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
}

// Drop anything that is not a well-formed item (e.g. hand-edited config),
// so a corrupt shell.json entry renders an empty list instead of crashing
// the Repeater.
function coerceItems(value) {
  if (!Array.isArray(value)) return []
  var out = []
  for (var i = 0; i < value.length; i++) {
    var raw = value[i]
    if (!raw || typeof raw !== "object") continue
    var text = cleanText(raw.text)
    if (text === "") continue
    out.push({
      id: String(raw.id === undefined || raw.id === null ? "" : raw.id),
      text: text,
      done: raw.done === true,
      createdAt: finiteMs(raw.createdAt),
      updatedAt: finiteMs(raw.updatedAt)
    })
  }
  return out
}

function createItem(text, now) {
  var clean = cleanText(text)
  if (clean === "") return null
  var ts = finiteMs(now)
  return {
    id: "todo-" + String(ts) + "-" + String(Math.floor(Math.random() * 1000000)),
    text: clean,
    done: false,
    createdAt: ts,
    updatedAt: ts
  }
}

// New tasks go at the end, in the order they were added.
function addItem(items, text, now) {
  var list = coerceItems(items)
  var item = createItem(text, now)
  if (!item) return list
  list.push(item)
  return list
}

// Flip done and stamp the change. Unknown ids leave the list untouched.
function toggleItem(items, id, now) {
  var list = coerceItems(items)
  var ts = finiteMs(now)
  for (var i = 0; i < list.length; i++) {
    if (list[i].id === String(id)) {
      list[i] = {
        id: list[i].id,
        text: list[i].text,
        done: !list[i].done,
        createdAt: list[i].createdAt,
        updatedAt: ts
      }
    }
  }
  return list
}

// Replace the text, stamping the change. Empty or unchanged text leaves
// the list untouched.
function updateItemText(items, id, text, now) {
  var clean = cleanText(text)
  if (clean === "") return coerceItems(items)
  var list = coerceItems(items)
  var ts = finiteMs(now)
  for (var i = 0; i < list.length; i++) {
    if (list[i].id === String(id)) {
      if (list[i].text === clean) return list
      list[i] = {
        id: list[i].id,
        text: clean,
        done: list[i].done,
        createdAt: list[i].createdAt,
        updatedAt: ts
      }
    }
  }
  return list
}

// Drop the item. Unknown ids leave the list untouched.
function removeItem(items, id) {
  var list = coerceItems(items)
  var out = []
  for (var i = 0; i < list.length; i++) {
    if (list[i].id !== String(id)) out.push(list[i])
  }
  return out
}

// On-disk envelope. The version leaves room for future migrations;
// a bare array is tolerated so hand-written files keep working.
var STORE_VERSION = 1

function serializeStore(items) {
  return JSON.stringify({ version: STORE_VERSION, items: coerceItems(items) }, null, 2) + "\n"
}

// Never throws: corrupt input yields an error string plus an empty list,
// so the panel renders empty instead of crashing.
function parseStore(raw) {
  var text = String(raw === undefined || raw === null ? "" : raw)
  if (text.replace(/^\s+|\s+$/g, "") === "") return { error: "", items: [] }
  var data
  try {
    data = JSON.parse(text)
  } catch (e) {
    return { error: "invalid JSON", items: [] }
  }
  if (Array.isArray(data)) return { error: "", items: coerceItems(data) }
  if (!data || typeof data !== "object") return { error: "not an object", items: [] }
  return { error: "", items: coerceItems(data.items) }
}

// Filter is "todo" or "done"; anything else shows the active tasks.
function visibleItems(items, filter) {
  var list = coerceItems(items)
  var wantDone = String(filter) === "done"
  var out = []
  for (var i = 0; i < list.length; i++) {
    if ((list[i].done === true) === wantDone) out.push(list[i])
  }
  return out
}

function openCount(items) {
  return visibleItems(items, "todo").length
}

if (typeof module !== "undefined") {
  module.exports = {
    coerceItems: coerceItems,
    createItem: createItem,
    addItem: addItem,
    toggleItem: toggleItem,
    updateItemText: updateItemText,
    removeItem: removeItem,
    serializeStore: serializeStore,
    parseStore: parseStore,
    visibleItems: visibleItems,
    openCount: openCount
  }
}
