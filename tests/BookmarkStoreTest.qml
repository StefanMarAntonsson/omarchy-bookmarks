import QtQuick
import Quickshell
import "."

ShellRoot {
  id: root

  property bool started: false
  property int reloadStressCycles: 0

  function fail(message) {
    console.error("BOOKMARK_STORE_TEST_FAIL:", message)
    Qt.quit()
  }

  function check(condition, message) {
    if (!condition) {
      root.fail(message)
      return false
    }
    return true
  }

  function waitUntil(condition, callback) {
    pollTimer.condition = condition
    pollTimer.callback = callback
    pollTimer.attempts = 0
    pollTimer.restart()
  }

  function runSynchronousChecks() {
    if (!root.check(store.storageReady, "storage did not initialize")
        || !root.check(store.canMutate, "new store is not writable")) {
      return
    }

    var invalidUrls = [
      "https://:",
      "https://example.com:99999",
      "https://[broken",
      "https://[::::]",
      "https://999.999.999.999",
      "https://-invalid.example"
    ]
    for (var index = 0; index < invalidUrls.length; index++) {
      if (!root.check(
        store.normalizeUrl(invalidUrls[index]) === "",
        "accepted malformed URL " + invalidUrls[index]
      )) {
        return
      }
    }
    if (!root.check(
      store.normalizeUrl("example.com") === "https://example.com",
      "did not add the HTTPS scheme"
    ) || !root.check(
      store.normalizeUrl("https://[::1]:8443/path")
        === "https://[::1]:8443/path",
      "rejected a valid IPv6 URL"
    )) {
      return
    }

    if (!root.check(
      store.utf8ByteLength("Aé😀", 0) === 7,
      "UTF-8 byte accounting is incorrect"
    ) || !root.check(
      store.normalizedBookmark({
        id: "oversized-title",
        title: "x".repeat(store.maxTitleLength + 1),
        url: "https://example.com"
      }, true) === null,
      "accepted an oversized bookmark title"
    ) || !root.check(
      store.normalizedBookmark({
        id: "oversized-url",
        url: "https://example.com/" + "x".repeat(store.maxUrlLength)
      }, true) === null,
      "accepted an oversized bookmark URL"
    )) {
      return
    }

    store.parse('{not-json')
    if (!root.check(store.recoveryRequired, "invalid JSON did not enter recovery mode")
        || !root.check(!store.canMutate, "invalid JSON remained writable")
        || !root.check(
          store.addBookmark("Unsafe", "https://example.com", [], "", "") === "",
          "invalid JSON allowed a write"
        )) {
      return
    }

    store.parse(JSON.stringify({
      version: 3,
      bookmarks: [
        {id: "valid", url: "https://example.com"},
        {id: "invalid", url: "https://:"}
      ]
    }))
    if (!root.check(store.bookmarks.length === 1, "valid recovery entry was hidden")
        || !root.check(store.recoveryRequired, "invalid entry did not enter recovery mode")
        || !root.check(!store.canMutate, "partially invalid store remained writable")) {
      return
    }

    store.parse('{"version":3,"bookmarks":[]}')
    var firstId = store.addBookmark("First", "https://first.example", [], "", "")
    var secondId = store.addBookmark("Second", "https://second.example", [], "", "")
    if (!root.check(Boolean(firstId), "first queued add failed")
        || !root.check(Boolean(secondId), "second queued add failed")
        || !root.check(
          store.updateBookmark(firstId, "Updated", "https://first.example", [], ""),
          "queued update failed"
        )) {
      return
    }
    root.waitUntil(function() { return !store.saving }, root.checkQueuedSaves)
  }

  function checkQueuedSaves() {
    if (!root.check(store.bookmarks.length === 2, "queued save lost a bookmark")
        || !root.check(store.saveQueue.length === 0, "save queue did not drain")
        || !root.check(store.activeSave === null, "active save did not finish")) {
      return
    }

    store.bookmarks = []
    store.reload()
    root.waitUntil(
      function() { return store.bookmarks.length === 2 },
      root.checkPersistedQueue
    )
  }

  function checkPersistedQueue() {
    var first = store.findByUrl("https://first.example")
    if (!root.check(first && first.title === "Updated", "disk lost latest queued state"))
      return

    var favicon = "data:image/png;base64,AAAA"
    store.parse(JSON.stringify({
      version: 3,
      bookmarks: [{
        id: "one",
        title: "One",
        url: "https://example.com/old",
        favicon: favicon
      }]
    }))
    if (!root.check(
      store.updateBookmark("one", "One", "https://example.com/new", [], ""),
      "same-origin update failed"
    ) || !root.check(store.bookmarks[0].favicon === favicon, "same-origin favicon was cleared")) {
      return
    }
    root.waitUntil(function() { return !store.saving }, root.checkCrossOriginFavicon)
  }

  function checkCrossOriginFavicon() {
    if (!root.check(
      store.updateBookmark("one", "One", "https://other.example/new", [], ""),
      "cross-origin update failed"
    ) || !root.check(store.bookmarks[0].favicon === "", "stale cross-origin favicon remained")) {
      return
    }
    root.waitUntil(function() { return !store.saving }, root.checkImportMerge)
  }

  function checkImportMerge() {
    store.parse(JSON.stringify({
      version: 3,
      bookmarks: [{id: "one", title: "", url: "https://example.com"}]
    }))
    var outcome = store.importBookmarks([
      {title: "Example", url: "https://example.com", tags: []}
    ])
    if (!root.check(outcome.updated === 1, "import did not update an untitled bookmark")
        || !root.check(store.bookmarks[0].title === "Example", "import title was not merged")) {
      return
    }
    root.waitUntil(function() { return !store.saving }, root.finishTests)
  }

  function finishTests() {
    if (!root.check(store.canMutate, "store was blocked after successful saves"))
      return
    var bookmark = store.bookmarks[0]
    if (!root.check(store.recordOpen(bookmark.id), "usage recording failed")
        || !root.check(store.pendingUsageOpens === 1, "usage open was not batched")
        || !root.check(!store.saving, "single usage open caused an immediate full write")
        || !root.check(store.flushUsage(), "usage flush failed")) {
      return
    }
    root.waitUntil(function() { return !store.saving }, root.startReloadStress)
  }

  function startReloadStress() {
    if (!root.check(store.pendingUsageOpens === 0, "usage batch did not flush"))
      return

    var items = []
    var title = "Resident reload ".concat("x".repeat(512))
    for (var index = 0; index < 2000; index++) {
      items.push({
        id: "stress-" + index,
        title: title,
        url: "https://stress-" + index + ".example/path",
        tags: ["stress"],
        keyword: "",
        favicon: "",
        usageScore: 0,
        lastOpenedAt: 0
      })
    }
    if (!root.check(store.save(items, false), "could not prepare reload stress store"))
      return
    root.waitUntil(function() { return !store.saving }, root.runReloadStressCycle)
  }

  function runReloadStressCycle() {
    if (root.reloadStressCycles >= 12) {
      root.passTests()
      return
    }
    store.reload()
    root.waitUntil(
      function() {
        return !store.storeLoadAttemptActive && store.bookmarks.length === 2000
      },
      function() {
        root.reloadStressCycles++
        root.runReloadStressCycle()
      }
    )
  }

  function passTests() {
    console.log("BOOKMARK_STORE_TEST_PASS")
    Qt.quit()
  }

  BookmarkStore {
    id: store

    onLoadedChanged: {
      if (loaded && !root.started) {
        root.started = true
        Qt.callLater(root.runSynchronousChecks)
      }
    }
  }

  Timer {
    id: pollTimer
    property var condition: null
    property var callback: null
    property int attempts: 0
    interval: 25
    repeat: true
    onTriggered: {
      attempts++
      if (condition && condition()) {
        stop()
        Qt.callLater(callback)
      } else if (attempts >= 200) {
        stop()
        root.fail("timed out waiting for persistence")
      }
    }
  }

  Timer {
    interval: 25000
    running: true
    onTriggered: root.fail("overall test timeout")
  }
}
