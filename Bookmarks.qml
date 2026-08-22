import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false
  property string query: ""
  property int viewMode: 0
  property string tagQuery: ""
  property string keywordQuery: ""
  property int selectedIndex: 0
  property bool deleteConfirmOpen: false
  property var deleteTarget: null
  property bool fileDialogOpen: false
  property bool quickAdding: false
  property bool quickAddCanceled: false
  property string statusMessage: ""
  property string quickAddUndoId: ""
  property var browserTarget: null
  property string copyTargetTitle: ""
  property bool menuEntryDialogOpen: false
  property bool menuEntryInstalled: false
  property bool menuEntryStateReady: false
  property bool menuPromptCheckedForOpen: false
  property string menuEntryDecision: "pending"
  property string menuEntryOperation: ""

  readonly property string helperPath:
    root.localPath("bookmark_helper.py")

  readonly property string menuExtensionPath:
    Quickshell.env("HOME") + "/.config/omarchy/extensions/omarchy-menu.jsonc"

  readonly property string menuPreferencePath:
    store.dataDir + "/settings.json"

  readonly property string pluginId:
    manifest && manifest.id
      ? String(manifest.id)
      : "stefanmara.bookmarks"

  readonly property var keywordAction: root.resolveKeywordAction(root.query)

  readonly property var filteredBookmarks:
    root.bookmarksForQuery(root.query)

  readonly property var allTags:
    root.collectTags()

  readonly property var filteredTags:
    root.tagsForQuery(root.tagQuery)

  readonly property var allKeywords:
    root.collectKeywords()

  readonly property var filteredKeywords:
    root.keywordsForQuery(root.keywordQuery)

  readonly property var activeResults:
    root.viewMode === 1
      ? root.filteredTags
      : root.viewMode === 2
        ? root.filteredKeywords
        : root.filteredBookmarks

  readonly property int activeTotal:
    root.viewMode === 1
      ? root.allTags.length
      : root.viewMode === 2
        ? root.allKeywords.length
        : store.bookmarks.length

  readonly property string viewName:
    root.viewMode === 1
      ? "Tags"
      : root.viewMode === 2
        ? "Keywords"
        : "Bookmarks"

  function localPath(relativePath) {
    var value = String(Qt.resolvedUrl(relativePath))
    return value.indexOf("file://") === 0
      ? decodeURIComponent(value.substring(7))
      : value
  }

  function resolveKeywordAction(value) {
    var input = String(value || "").trim()
    var space = input.search(/\s/)
    if (space < 1)
      return null
    var keyword = input.substring(0, space).toLowerCase()
    var terms = input.substring(space).trim()
    if (!terms)
      return null
    for (var i = 0; i < store.bookmarks.length; i++) {
      var bookmark = store.bookmarks[i]
      var template = String(bookmark.url || "")
      if (String(bookmark.keyword || "").toLowerCase() === keyword
          && (template.indexOf("%s") !== -1
              || template.indexOf("%S") !== -1
              || template.indexOf("{searchTerms}") !== -1)) {
        return {bookmark: bookmark, terms: terms}
      }
    }
    return null
  }

  function resolvedUrl(bookmark) {
    if (!root.keywordAction || root.keywordAction.bookmark.id !== bookmark.id)
      return bookmark.url
    var terms = root.keywordAction.terms
    var encoded = encodeURIComponent(terms)
    return String(bookmark.url)
      .replace(/%s/g, encoded)
      .replace(/%S/g, terms)
      .replace(/\{searchTerms\}/g, encoded)
  }

  function displayTitle(bookmark) {
    var title = String(bookmark && bookmark.title || "").trim()
    if (title)
      return title
    var match = String(bookmark && bookmark.url || "").match(/^https?:\/\/([^\/?#]+)/i)
    return match ? match[1] : String(bookmark && bookmark.url || "")
  }

  function isParameterized(bookmark) {
    var url = String(bookmark && bookmark.url || "")
    return url.indexOf("%s") !== -1
      || url.indexOf("%S") !== -1
      || url.indexOf("{searchTerms}") !== -1
  }

  function collectTags() {
    var byName = {}
    var items = []

    for (var i = 0; i < store.bookmarks.length; i++) {
      var tags = store.bookmarks[i].tags || []
      var seenOnBookmark = {}
      for (var j = 0; j < tags.length; j++) {
        var name = String(tags[j] || "").trim()
        var key = name.toLowerCase()
        if (!key || seenOnBookmark[key])
          continue
        seenOnBookmark[key] = true
        if (byName[key]) {
          byName[key].count += 1
        } else {
          var item = {tag: name, count: 1}
          byName[key] = item
          items.push(item)
        }
      }
    }

    items.sort(function(first, second) {
      if (first.count !== second.count)
        return second.count - first.count
      return first.tag.toLowerCase().localeCompare(second.tag.toLowerCase())
    })
    return items
  }

  function tagsForQuery(value) {
    var search = String(value || "").trim().toLowerCase()
    if (!search)
      return root.allTags

    var prefix = []
    var substring = []
    for (var i = 0; i < root.allTags.length; i++) {
      var item = root.allTags[i]
      var tag = item.tag.toLowerCase()
      if (tag.indexOf(search) === 0)
        prefix.push(item)
      else if (tag.indexOf(search) !== -1)
        substring.push(item)
    }
    return prefix.concat(substring)
  }

  function collectKeywords() {
    var seen = {}
    var items = []

    for (var i = 0; i < store.bookmarks.length; i++) {
      var bookmark = store.bookmarks[i]
      var keyword = String(bookmark.keyword || "").trim()
      var key = keyword.toLowerCase()
      if (!key || seen[key])
        continue
      seen[key] = true
      items.push({
        keyword: keyword,
        bookmark: bookmark,
        parameterized: root.isParameterized(bookmark)
      })
    }

    items.sort(function(first, second) {
      return first.keyword.toLowerCase().localeCompare(
        second.keyword.toLowerCase()
      )
    })
    return items
  }

  function keywordsForQuery(value) {
    var search = String(value || "").trim().toLowerCase()
    if (!search)
      return root.allKeywords

    var prefix = []
    var substring = []
    for (var i = 0; i < root.allKeywords.length; i++) {
      var item = root.allKeywords[i]
      var keyword = item.keyword.toLowerCase()
      var searchable = (
        item.keyword + " "
        + root.displayTitle(item.bookmark) + " "
        + item.bookmark.url
      ).toLowerCase()
      if (keyword.indexOf(search) === 0)
        prefix.push(item)
      else if (searchable.indexOf(search) !== -1)
        substring.push(item)
    }
    return prefix.concat(substring)
  }

  function currentQuery() {
    if (root.viewMode === 1)
      return root.tagQuery
    if (root.viewMode === 2)
      return root.keywordQuery
    return root.query
  }

  function setCurrentQuery(value) {
    if (root.viewMode === 1)
      root.tagQuery = value
    else if (root.viewMode === 2)
      root.keywordQuery = value
    else
      root.query = value
  }

  function modePlaceholder() {
    if (root.viewMode === 1)
      return "Search tags…"
    if (root.viewMode === 2)
      return "Search keywords…"
    return "Search bookmarks…"
  }

  function cycleView(amount) {
    root.viewMode = ((root.viewMode + amount) % 3 + 3) % 3
    root.selectedIndex = 0
    bookmarkList.positionViewAtBeginning()
  }

  function selectedResult() {
    if (
      root.selectedIndex < 0
      || root.selectedIndex >= root.activeResults.length
    ) {
      return null
    }
    return root.activeResults[root.selectedIndex]
  }

  function applyPickerSelection(append) {
    var item = root.selectedResult()
    if (!item || root.viewMode === 0)
      return

    var token = root.viewMode === 1
      ? "#" + item.tag
      : item.keyword
    var previous = root.query.trim()
    root.query = append && previous
      ? previous + " " + token
      : token

    if (!append && root.viewMode === 2 && item.parameterized)
      root.query += " "

    if (root.viewMode === 1)
      root.tagQuery = ""
    else
      root.keywordQuery = ""
    root.viewMode = 0
    root.selectedIndex = 0
    bookmarkList.positionViewAtBeginning()
  }

  function parseSearch(value) {
    var input = String(value || "").trim().toLowerCase()
    var source = input ? input.split(/\s+/) : []
    var normalTokens = []
    var tagTokens = []
    for (var i = 0; i < source.length; i++) {
      if (source[i].charAt(0) === "#")
        tagTokens.push(source[i].substring(1))
      else
        normalTokens.push(source[i])
    }
    return {
      normalTokens: normalTokens,
      tagTokens: tagTokens,
      normalSearch: normalTokens.join(" ")
    }
  }

  function tagPrefixMatch(bookmark, prefix) {
    for (var i = 0; i < bookmark.tags.length; i++) {
      if (String(bookmark.tags[i]).toLowerCase().indexOf(prefix) === 0)
        return true
    }
    return false
  }

  function searchRelevance(bookmark, search, tokens, tagTokens) {
    var title = String(bookmark.title || "").toLowerCase()
    var keyword = String(bookmark.keyword || "").toLowerCase()
    var url = String(bookmark.url || "").toLowerCase()
    var score = 0

    if (search) {
      if (keyword === search)
        score += 500
      if (title === search)
        score += 450
      else if (title.indexOf(search) === 0)
        score += 300
      if (keyword && keyword.indexOf(search) === 0)
        score += 280
      if (url.indexOf(search) !== -1)
        score += 100
    }

    for (var i = 0; i < tokens.length; i++) {
      if (title.indexOf(tokens[i]) === 0)
        score += 30
      else if (title.indexOf(tokens[i]) !== -1)
        score += 20
      if (keyword === tokens[i])
        score += 25
    }

    for (var j = 0; j < tagTokens.length; j++) {
      if (!tagTokens[j])
        continue
      for (var k = 0; k < bookmark.tags.length; k++) {
        var tag = String(bookmark.tags[k]).toLowerCase()
        if (tag === tagTokens[j]) {
          score += 90
          break
        }
        if (tag.indexOf(tagTokens[j]) === 0) {
          score += 45
          break
        }
      }
    }
    return score
  }

  function bookmarksForQuery(value) {
    if (root.keywordAction)
      return [root.keywordAction.bookmark]

    var parsed = root.parseSearch(value)
    var search = parsed.normalSearch
    var tokens = parsed.normalTokens
    var tagTokens = parsed.tagTokens
    var now = Date.now()
    var ranked = []

    for (var i = 0; i < store.bookmarks.length; i++) {
      var bookmark = store.bookmarks[i]
      var searchable = (
        String(bookmark.title || "") + " "
        + bookmark.url + " "
        + bookmark.tags.join(" ") + " "
        + String(bookmark.keyword || "")
      ).toLowerCase()
      var matches = true

      for (var j = 0; j < tokens.length; j++) {
        if (searchable.indexOf(tokens[j]) === -1) {
          matches = false
          break
        }
      }
      for (var k = 0; matches && k < tagTokens.length; k++) {
        if (!root.tagPrefixMatch(bookmark, tagTokens[k]))
          matches = false
      }
      if (!matches)
        continue

      ranked.push({
        bookmark: bookmark,
        relevance: search || tagTokens.length
          ? root.searchRelevance(bookmark, search, tokens, tagTokens)
          : 0,
        usage: store.usageScoreAt(bookmark, now),
        originalIndex: i
      })
    }

    ranked.sort(function(first, second) {
      if (first.relevance !== second.relevance)
        return second.relevance - first.relevance
      if (Math.abs(first.usage - second.usage) > 0.0000001)
        return second.usage - first.usage
      return first.originalIndex - second.originalIndex
    })

    var results = []
    for (var resultIndex = 0; resultIndex < ranked.length; resultIndex++)
      results.push(ranked[resultIndex].bookmark)
    return results
  }

  onActiveResultsChanged: {
    root.selectedIndex = Math.max(
      0,
      Math.min(
        root.selectedIndex,
        root.activeResults.length - 1
      )
    )
  }

  function open(payloadJson) {
    root.query = ""
    root.viewMode = 0
    root.tagQuery = ""
    root.keywordQuery = ""
    root.selectedIndex = 0
    root.deleteConfirmOpen = false
    root.deleteTarget = null
    root.fileDialogOpen = false
    root.statusMessage = ""
    root.quickAddUndoId = ""
    root.quickAddCanceled = false
    root.browserTarget = null
    root.copyTargetTitle = ""
    root.menuEntryDialogOpen = false
    root.menuPromptCheckedForOpen = false
    editor.close()
    importer.close()
    browserPicker.close()
    root.opened = true

    root.maybeShowMenuConsent()
    root.refocusList()
  }

  function close() {
    if (importPickerProcess.running)
      importPickerProcess.running = false
    root.fileDialogOpen = false
    if (quickAddProcess.running) {
      root.quickAddCanceled = true
      quickAddProcess.running = false
    }
    root.quickAdding = false
    root.opened = false
    root.query = ""
    root.viewMode = 0
    root.tagQuery = ""
    root.keywordQuery = ""
    root.deleteConfirmOpen = false
    root.deleteTarget = null
    root.statusMessage = ""
    root.quickAddUndoId = ""
    root.browserTarget = null
    root.copyTargetTitle = ""
    root.menuEntryDialogOpen = false
    editor.close()
    importer.close()
    browserPicker.close()
  }

  function dismiss() {
    root.close()

    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.pluginId)
  }

  function selectedBookmark() {
    if (root.viewMode !== 0)
      return null

    if (
      root.selectedIndex < 0
      || root.selectedIndex >= root.filteredBookmarks.length
    ) {
      return null
    }

    return root.filteredBookmarks[root.selectedIndex]
  }

  function refocusList() {
    Qt.callLater(function() {
      if (
        root.opened
        && !editor.opened
        && !importer.opened
        && !browserPicker.opened
        && !root.menuEntryDialogOpen
        && !root.deleteConfirmOpen
      ) {
        keyCatcher.forceActiveFocus()
      }
    })
  }

  function selectBookmarkById(id) {
    for (var i = 0; i < root.filteredBookmarks.length; i++) {
      if (root.filteredBookmarks[i].id === id) {
        root.selectedIndex = i
        return
      }
    }

    root.selectedIndex = 0
  }

  function mutationAvailable(requireIdle) {
    if (!store.canMutate) {
      root.showStatus(
        store.error || (store.loaded
          ? "Bookmark storage is read-only"
          : "Bookmarks are still loading…")
      )
      return false
    }
    if (requireIdle && store.saving) {
      root.showStatus("Finishing the current save…")
      return false
    }
    if (requireIdle && root.quickAdding) {
      root.showStatus("Finishing the clipboard bookmark…")
      return false
    }
    return true
  }

  function beginAdd() {
    if (!root.mutationAvailable(true))
      return
    root.clearUndo()
    root.deleteConfirmOpen = false
    root.deleteTarget = null
    editor.openForCreate()
  }

  function beginEdit() {
    if (!root.mutationAvailable(true))
      return
    var bookmark = root.selectedBookmark()

    if (bookmark) {
      root.clearUndo()
      editor.openForEdit(bookmark)
    }
  }

  function saveEditor(
    bookmarkId,
    title,
    url,
    tags,
    keyword
  ) {
    if (!root.mutationAvailable(false)) {
      editor.validationError = store.error || "Bookmark storage is not writable"
      return
    }
    root.clearUndo()
    var selectedId = bookmarkId
    var saved = false

    if (bookmarkId) {
      saved = store.updateBookmark(bookmarkId, title, url, tags, keyword)
    } else {
      selectedId = store.addBookmark(title, url, tags, keyword, "")
      saved = Boolean(selectedId)
    }

    if (!saved) {
      editor.validationError = store.error || "Could not save that bookmark"
      return
    }

    editor.close()
    root.viewMode = 0
    root.query = ""
    root.selectBookmarkById(selectedId)
    root.refocusList()
  }

  function requestDelete() {
    if (!root.mutationAvailable(true))
      return
    var bookmark = root.selectedBookmark()

    if (!bookmark)
      return

    root.clearUndo()

    root.deleteTarget = bookmark
    root.deleteConfirmOpen = true
    deleteConfirm.selectedIndex = 1
  }

  function cancelDelete() {
    root.deleteConfirmOpen = false
    root.deleteTarget = null
    root.refocusList()
  }

  function confirmDelete() {
    var bookmark = root.deleteTarget

    root.deleteConfirmOpen = false
    root.deleteTarget = null

    if (bookmark && !store.removeBookmark(bookmark.id))
      root.showStatus(store.error || "Could not delete that bookmark")

    root.refocusList()
  }

  function moveSelection(amount) {
    var count = root.activeResults.length

    if (!count)
      return

    root.selectedIndex =
      ((root.selectedIndex + amount) % count + count) % count

    bookmarkList.positionViewAtIndex(
      root.selectedIndex,
      ListView.Contain
    )
  }

  function activateSelected(openInNewWindow) {
    var bookmark = root.selectedBookmark()

    if (!bookmark)
      return

    root.activateBookmark(bookmark, openInNewWindow, null)
  }

  function activateBookmark(bookmark, openInNewWindow, browser) {
    if (!bookmark)
      return

    var url = root.resolvedUrl(bookmark)
    var command

    if (browser && browser.desktopPath) {
      command = [
        "systemd-run",
        "--user",
        "--quiet",
        "--collect",
        "--unit=omarchy-bookmark-browser-" + Date.now(),
        "--property=StandardOutput=null",
        "--property=StandardError=null",
        "uwsm-app",
        "--",
        "gio",
        "launch",
        String(browser.desktopPath),
        url
      ]
    } else {
      command = ["omarchy-launch-browser"]
      if (openInNewWindow)
        command.push("--new-window")
      command.push(url)
    }

    Quickshell.execDetached(command)
    store.recordOpen(bookmark.id)

    root.dismiss()
  }

  function openBrowserPicker() {
    var bookmark = root.selectedBookmark()
    if (!bookmark)
      return
    root.browserTarget = bookmark
    browserPicker.openFor(root.displayTitle(bookmark))
  }

  function activateCurrent(openInNewWindow, append) {
    if (root.viewMode === 0)
      root.activateSelected(openInNewWindow)
    else
      root.applyPickerSelection(append)
  }

  function clearUndo() {
    root.quickAddUndoId = ""
  }

  function showStatus(message) {
    root.statusMessage = message
    statusTimer.restart()
  }

  function copySelectedUrl() {
    var bookmark = root.selectedBookmark()
    if (!bookmark || copyProcess.running)
      return
    root.copyTargetTitle = root.displayTitle(bookmark)
    copyProcess.command = [
      "python3", root.helperPath, "copy", root.resolvedUrl(bookmark)
    ]
    copyProcess.running = true
  }

  function refreshMenuEntryStatus() {
    if (!store.storageReady || menuStatusProcess.running)
      return
    menuStatusProcess.command = [
      "python3", root.helperPath,
      "menu-entry", "status",
      root.menuExtensionPath, root.menuPreferencePath
    ]
    menuStatusProcess.running = true
  }

  function maybeShowMenuConsent() {
    if (!root.opened
        || !root.menuEntryStateReady
        || root.menuPromptCheckedForOpen) {
      return
    }
    root.menuPromptCheckedForOpen = true
    if (!root.menuEntryInstalled
        && (root.menuEntryDecision === "pending"
            || root.menuEntryDecision === "installed")) {
      menuEntryDialog.errorMessage = ""
      menuEntryDialog.selectedIndex = 1
      root.menuEntryDialogOpen = true
    }
  }

  function openMenuEntryManager() {
    if (!root.menuEntryStateReady) {
      root.showStatus("Main-menu status is still loading…")
      return
    }
    menuEntryDialog.errorMessage = ""
    menuEntryDialog.selectedIndex = root.menuEntryInstalled ? 0 : 1
    root.menuEntryDialogOpen = true
  }

  function cancelMenuEntryDialog() {
    if (!root.menuEntryInstalled) {
      root.requestMenuEntryOperation("dismiss")
      return
    }
    root.menuEntryDialogOpen = false
    root.refocusList()
  }

  function requestMenuEntryOperation(operation) {
    if (menuEntryProcess.running)
      return
    root.menuEntryOperation = operation
    menuEntryDialog.errorMessage = ""
    menuEntryProcess.command = [
      "python3", root.helperPath,
      "menu-entry", operation,
      root.menuExtensionPath, root.menuPreferencePath
    ]
    menuEntryProcess.running = true
  }

  function quickAddFromClipboard() {
    if (root.quickAdding || !root.mutationAvailable(true))
      return
    root.quickAdding = true
    root.quickAddCanceled = false
    root.showStatus("Reading clipboard and fetching bookmark details…")
    quickAddProcess.command = ["python3", root.helperPath, "clipboard", store.dataPath]
    quickAddProcess.running = false
    quickAddProcess.running = true
  }

  function undoQuickAdd() {
    if (!root.quickAddUndoId)
      return
    if (!root.mutationAvailable(true)) {
      return
    }
    var id = root.quickAddUndoId
    root.quickAddUndoId = ""
    if (store.removeBookmark(id)) {
      root.viewMode = 0
      root.query = ""
      root.showStatus("Clipboard bookmark removed")
    }
  }

  function openImportPicker() {
    if (!root.mutationAvailable(true))
      return
    root.clearUndo()
    root.fileDialogOpen = true
    importPickerProcess.command = [
      "zenity",
      "--file-selection",
      "--title=Import bookmarks",
      "--filename=" + Quickshell.env("HOME") + "/",
      "--file-filter=Bookmark files | *.html *.htm *.json",
      "--file-filter=All files | *"
    ]
    importPickerProcess.running = false
    importPickerProcess.running = true
  }

  function finishImport(items) {
    root.clearUndo()
    var outcome = store.importBookmarks(items)
    if (outcome.blocked) {
      root.showStatus(store.error || "Bookmark storage is not writable")
      root.refocusList()
      return
    }
    root.viewMode = 0
    root.query = ""
    root.selectedIndex = 0
    if (outcome.added || outcome.updated) {
      root.showStatus(
        "Imported " + outcome.added + " new · updated " + outcome.updated
        + " · backup created"
      )
    } else {
      root.showStatus("Nothing changed · every URL was already saved")
    }
    root.refocusList()
  }

  Timer {
    id: statusTimer
    interval: 5000
    repeat: false
    onTriggered: root.statusMessage = ""
  }

  Process {
    id: quickAddProcess
    running: false
    command: ["true"]

    stdout: StdioCollector {
      id: quickAddOutput
      waitForEnd: true
    }

    stderr: StdioCollector {
      id: quickAddError
      waitForEnd: true
    }

    onExited: function(exitCode) {
      root.quickAdding = false
      if (root.quickAddCanceled) {
        root.quickAddCanceled = false
        return
      }
      try {
        var result = JSON.parse(String(quickAddOutput.text || ""))
        if (exitCode !== 0 || !result.ok) {
          root.showStatus(String(result.error || "Could not add clipboard bookmark"))
        } else if (result.duplicate) {
          root.viewMode = 0
          root.query = ""
          root.selectBookmarkById(result.id)
          root.showStatus("That URL is already bookmarked")
        } else {
          root.clearUndo()
          var item = result.item
          var id = store.addBookmark(
            item.title, item.url, item.tags, item.keyword, item.favicon
          )
          if (!id) {
            root.showStatus(store.error || "Could not save clipboard bookmark")
          } else {
            root.viewMode = 0
            root.query = ""
            root.selectBookmarkById(id)
            root.quickAddUndoId = id
            root.showStatus("Added " + root.displayTitle(item) + " · Ctrl+Z Undo")
          }
        }
      } catch (exception) {
        root.showStatus(String(quickAddError.text || "Could not add clipboard bookmark").trim())
      }
      root.refocusList()
    }
  }

  Process {
    id: copyProcess
    running: false
    command: ["true"]

    stdout: StdioCollector {
      id: copyOutput
      waitForEnd: true
    }

    onExited: function(exitCode) {
      var message = "Copied " + root.copyTargetTitle + " URL"
      try {
        var result = JSON.parse(String(copyOutput.text || ""))
        if (exitCode !== 0 || !result.ok)
          message = String(result.error || "Could not copy URL")
      } catch (exception) {
        message = "Could not copy URL"
      }
      root.copyTargetTitle = ""
      root.showStatus(message)
      root.refocusList()
    }
  }

  Process {
    id: menuStatusProcess
    running: false
    command: ["true"]

    stdout: StdioCollector {
      id: menuStatusOutput
      waitForEnd: true
    }

    onExited: function(exitCode) {
      try {
        var result = JSON.parse(String(menuStatusOutput.text || ""))
        if (exitCode !== 0 || !result.ok)
          throw new Error(String(result.error || "Could not inspect main-menu entry"))
        root.menuEntryInstalled = Boolean(result.installed)
        root.menuEntryDecision = String(result.decision || "pending")
        root.menuEntryStateReady = true
        root.maybeShowMenuConsent()
      } catch (exception) {
        root.menuEntryStateReady = false
        root.showStatus(String(exception.message || "Could not inspect main-menu entry"))
      }
    }
  }

  Process {
    id: menuEntryProcess
    running: false
    command: ["true"]

    stdout: StdioCollector {
      id: menuEntryOutput
      waitForEnd: true
    }

    onExited: function(exitCode) {
      try {
        var result = JSON.parse(String(menuEntryOutput.text || ""))
        if (exitCode !== 0 || !result.ok)
          throw new Error(String(result.error || "Could not update main-menu entry"))
        root.menuEntryInstalled = Boolean(result.installed)
        root.menuEntryDecision = String(result.decision || "dismissed")
        root.menuEntryDialogOpen = false
        if (root.menuEntryOperation === "install")
          root.showStatus("Added Bookmarks to the main Omarchy menu")
        else if (root.menuEntryOperation === "remove")
          root.showStatus("Removed Bookmarks from the main Omarchy menu")
      } catch (exception) {
        menuEntryDialog.errorMessage = String(
          exception.message || "Could not update main-menu entry"
        )
      }
      root.menuEntryOperation = ""
      root.refocusList()
    }
  }

  Process {
    id: importPickerProcess
    running: false
    command: ["true"]

    stdout: StdioCollector {
      id: importPickerOutput
      waitForEnd: true
    }

    stderr: StdioCollector {
      id: importPickerError
      waitForEnd: true
    }

    onExited: function(exitCode) {
      root.fileDialogOpen = false
      var path = String(importPickerOutput.text || "").trim()
      if (exitCode === 0 && path)
        importer.begin(path)
      else {
        var message = String(importPickerError.text || "").trim()
        if (message)
          root.showStatus("Could not open import picker · install Zenity")
        root.refocusList()
      }
    }
  }

  BookmarkStore {
    id: store
    onStorageReadyChanged: {
      if (storageReady)
        root.refreshMenuEntryStatus()
    }
  }

  PanelWindow {
    visible: root.opened && !root.fileDialogOpen
    color: "transparent"

    anchors {
      top: true
      bottom: true
      left: true
      right: true
    }

    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "stefanmara-bookmarks"
    WlrLayershell.keyboardFocus:
      root.opened && !root.fileDialogOpen
        ? WlrKeyboardFocus.Exclusive
        : WlrKeyboardFocus.None

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card

      width: Math.min(
        Style.space(560),
        parent.width - Style.gapsOut * 2
      )

      height: Math.min(
        parent.height * 0.8,
        parent.height - Style.gapsOut * 2
      )

      anchors.centerIn: parent

      color: Color.menu.background
      borderSpec: Border.surfaceSpec(
        "menu",
        "border",
        Color.menu.border,
        Math.max(1, Style.space(2))
      )

      radius: Style.cornerRadius
      padding: Style.spacing.panelPadding

      MouseArea {
        anchors.fill: parent
        onClicked: {}
      }

      Item {
        id: keyCatcher

        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem

        Keys.onPressed: function(event) {
          if (root.menuEntryDialogOpen) {
            if (menuEntryDialog.handleKey(event))
              event.accepted = true
            return
          }

          if (root.deleteConfirmOpen) {
            if (deleteConfirm.handleKey(event))
              event.accepted = true

            return
          }

          if (browserPicker.opened) {
            if (browserPicker.handleKey(event))
              event.accepted = true
            return
          }

          if (editor.opened || importer.opened)
            return

          if (
            event.key === Qt.Key_Tab
            && event.modifiers === Qt.ControlModifier
            && root.viewMode === 0
          ) {
            root.openBrowserPicker()
            event.accepted = true
          } else if (
            (
              event.key === Qt.Key_Tab
              && (
                event.modifiers === Qt.NoModifier
                || event.modifiers === Qt.ShiftModifier
              )
            )
            || event.key === Qt.Key_Backtab
          ) {
            root.cycleView(
              event.key === Qt.Key_Backtab
                || event.modifiers === Qt.ShiftModifier
                ? -1
                : 1
            )
            event.accepted = true
          } else if (
            event.key === Qt.Key_Z
            && event.modifiers === Qt.ControlModifier
            && root.quickAddUndoId
          ) {
            root.undoQuickAdd()
            event.accepted = true
          } else if (
            event.key === Qt.Key_C
            && event.modifiers === Qt.ControlModifier
            && root.viewMode === 0
          ) {
            root.copySelectedUrl()
            event.accepted = true
          } else if (
            event.key === Qt.Key_V
            && event.modifiers === Qt.ControlModifier
          ) {
            root.quickAddFromClipboard()
            event.accepted = true
          } else if (
            event.key === Qt.Key_I
            && event.modifiers === Qt.ControlModifier
          ) {
            root.openImportPicker()
            event.accepted = true
          } else if (
            event.key === Qt.Key_M
            && event.modifiers === Qt.ControlModifier
          ) {
            root.openMenuEntryManager()
            event.accepted = true
          } else if (
            event.key === Qt.Key_N
            && event.modifiers === Qt.ControlModifier
          ) {
            root.beginAdd()
            event.accepted = true
          } else if (
            event.key === Qt.Key_E
            && event.modifiers === Qt.ControlModifier
            && root.viewMode === 0
          ) {
            root.beginEdit()
            event.accepted = true
          } else if (
            event.key === Qt.Key_T
            && event.modifiers === Qt.ControlModifier
            && root.viewMode === 0
          ) {
            root.activateSelected(true)
            event.accepted = true
          } else if (
            event.key === Qt.Key_Delete
            && root.viewMode === 0
          ) {
            root.requestDelete()
            event.accepted = true
          } else if (event.key === Qt.Key_Escape) {
            if (root.currentQuery()) {
              root.setCurrentQuery("")
              root.selectedIndex = 0
            } else if (root.viewMode !== 0) {
              root.viewMode = 0
              root.selectedIndex = 0
            } else {
              root.dismiss()
            }

            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.moveSelection(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.moveSelection(1)
            event.accepted = true
          } else if (
            event.key === Qt.Key_Return
            || event.key === Qt.Key_Enter
          ) {
            root.activateCurrent(
              false,
              root.viewMode !== 0
                && (event.modifiers & Qt.ControlModifier) !== 0
            )
            event.accepted = true
          } else if (Util.editsFilter(event, root.currentQuery())) {
            root.setCurrentQuery(
              Util.editedFilter(event, root.currentQuery())
            )
            root.selectedIndex = 0
            event.accepted = true
          } else if (
            event.text
            && event.text.length === 1
            && event.text.charCodeAt(0) >= 32
            && event.text.charCodeAt(0) !== 127
            && (
              event.modifiers === Qt.NoModifier
              || event.modifiers === Qt.ShiftModifier
            )
          ) {
            root.setCurrentQuery(root.currentQuery() + event.text)
            root.selectedIndex = 0
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent

        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        spacing: Style.spacing.md

        Item {
          width: parent.width
          height: Style.space(42)

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.IBeamCursor
            onClicked: keyCatcher.forceActiveFocus()
          }

          Text {
            anchors.left: parent.left
            anchors.right: countText.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter

            text: root.currentQuery() || root.modePlaceholder()
            textFormat: Text.PlainText
            color: Color.menu.text
            opacity: root.currentQuery() ? 1 : 0.58

            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.heading

            elide: Text.ElideRight
          }

          Text {
            id: countText

            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            text:
              root.viewName
              + " · "
              + root.activeResults.length
              + " / "
              + root.activeTotal

            color: Color.menu.text
            opacity: 0.48

            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
          }
        }

        Item {
          width: parent.width

          height:
            parent.height
            - Style.space(42)
            - Style.space(48)
            - parent.spacing * 2

          ListView {
            id: bookmarkList

            anchors.fill: parent
            model: root.activeResults

            clip: true
            spacing: Style.spacing.xs
            boundsBehavior: Flickable.StopAtBounds

            delegate: BorderSurface {
              id: row

              required property int index
              required property var modelData

              readonly property bool selected:
                row.index === root.selectedIndex

              readonly property bool bookmarkMode:
                root.viewMode === 0

              readonly property bool tagMode:
                root.viewMode === 1

              readonly property bool keywordMode:
                root.viewMode === 2

              readonly property var bookmark:
                row.bookmarkMode
                  ? row.modelData
                  : row.keywordMode
                    ? row.modelData.bookmark
                    : null

              readonly property bool keywordResult:
                row.bookmarkMode
                  && root.keywordAction
                  && root.keywordAction.bookmark.id === row.bookmark.id

              width: ListView.view.width
              height: Style.space(62)

              radius: Style.cornerRadius

              color:
                row.selected
                  ? Color.menu.selectedBackground
                  : "transparent"

              borderSpec:
                row.selected
                  ? Border.surfaceSpec(
                      "menu",
                      "selected-border",
                      Color.menu.selectedBorder,
                      0
                    )
                  : Border.none()

              Item {
                id: bookmarkIcon

                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.md
                anchors.verticalCenter: parent.verticalCenter

                width: Style.space(30)
                height: Style.space(30)

                Image {
                  id: faviconImage
                  anchors.centerIn: parent
                  width: Style.space(24)
                  height: Style.space(24)
                  visible: row.bookmarkMode
                  source: row.bookmarkMode
                    ? String(row.bookmark.favicon || "")
                    : ""
                  sourceSize.width: 64
                  sourceSize.height: 64
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                }

                Text {
                  anchors.fill: parent
                  visible:
                    !row.bookmarkMode
                    || faviconImage.status !== Image.Ready
                  text:
                    row.tagMode
                      ? "#"
                      : row.keywordMode
                        ? "K"
                        : ""

                  color:
                    row.selected
                      ? Color.menu.selectedText
                      : Color.menu.text

                  font.family: Style.font.menuFamily
                  font.pixelSize:
                    row.bookmarkMode
                      ? Style.font.iconLarge
                      : Style.font.heading

                  horizontalAlignment: Text.AlignHCenter
                  verticalAlignment: Text.AlignVCenter
                }
              }

              Column {
                anchors.left: bookmarkIcon.right
                anchors.leftMargin: Style.spacing.sm
                anchors.right: parent.right
                anchors.rightMargin: Style.spacing.md
                anchors.verticalCenter: parent.verticalCenter

                spacing: Style.spacing.xs

                Text {
                  width: parent.width
                  text:
                    row.bookmarkMode
                      ? root.displayTitle(row.bookmark)
                      : row.tagMode
                        ? "#" + row.modelData.tag
                        : row.modelData.keyword
                  textFormat: Text.PlainText

                  color:
                    row.selected
                      ? Color.menu.selectedText
                      : Color.menu.text

                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.heading
                  font.weight: Font.Medium
                  opacity:
                    row.bookmarkMode && !row.bookmark.title
                      ? 0.68
                      : 1

                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width

                  text:
                    row.tagMode
                      ? row.modelData.count
                        + (row.modelData.count === 1 ? " bookmark" : " bookmarks")
                      : row.keywordMode
                        ? root.displayTitle(row.bookmark)
                          + (
                            row.modelData.parameterized
                              ? "  ·  accepts search terms"
                              : ""
                          )
                        : row.keywordResult
                          ? "Search for “" + root.keywordAction.terms + "”"
                          : row.bookmark.url
                            + (
                              row.bookmark.tags.length
                                ? "  ·  " + row.bookmark.tags.join(" · ")
                                : ""
                            )
                            + (
                              row.bookmark.keyword
                                ? "  ·  " + row.bookmark.keyword
                                : ""
                            )
                  textFormat: Text.PlainText

                  color: Color.menu.text
                  opacity: 0.52

                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.bodySmall

                  elide: Text.ElideRight
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor

                onEntered:
                  root.selectedIndex = row.index

                onClicked: {
                  root.selectedIndex = row.index
                  root.activateCurrent(false, false)
                }
              }
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.spacing.sm
            visible: root.activeResults.length === 0

            Text {
              width: Style.space(360)

              text:
                store.error
                  ? ""
                  : root.viewMode === 1
                    ? "#"
                    : root.viewMode === 2
                      ? "K"
                      : ""
              color:
                store.error
                  ? Color.urgent
                  : Color.menu.selectedText

              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              width: Style.space(360)

              text:
                store.error
                  ? store.error
                  : root.currentQuery()
                    ? "No matching " + root.viewName.toLowerCase()
                    : root.viewMode === 1
                      ? "No tags yet"
                      : root.viewMode === 2
                        ? "No keywords yet"
                        : "No bookmarks yet"
              textFormat: Text.PlainText

              color: Color.menu.text
              opacity: 0.7

              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.title

              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }
          }
        }

        Text {
          width: parent.width
          height: Style.space(48)

          text:
            store.error
              ? store.error
              : store.saving
                ? "Saving…"
                : root.statusMessage
                  ? root.statusMessage
                  : root.viewMode === 1
                    ? "Enter Set  Ctrl+Enter Append  ↑↓ Select\nTab Keywords  Shift+Tab Bookmarks"
                    : root.viewMode === 2
                      ? "Enter Set  Ctrl+Enter Append  ↑↓ Select\nTab Bookmarks  Shift+Tab Tags"
                      : "Enter Open  Ctrl+C Copy  Ctrl+T Window  Ctrl+Tab Browser\nTab Tags  Ctrl+V Paste  Ctrl+I Import  Ctrl+N Add  Ctrl+E Edit  Delete"
          textFormat: Text.PlainText

          color: store.error ? Color.urgent : Color.menu.text
          opacity: store.error ? 1 : 0.48

          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
          lineHeight: 1.35

          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
        }
      }

      BookmarkEditor {
        id: editor

        z: 10

        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        urlValidator: function(value) {
          return store.normalizeUrl(value)
        }

        onSubmitted: function(
          bookmarkId,
          title,
          url,
          tags,
          keyword
        ) {
          root.saveEditor(bookmarkId, title, url, tags, keyword)
        }

        onCanceled: root.refocusList()
      }

      BookmarkImport {
        id: importer

        z: 15
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        helperPath: root.helperPath
        dataPath: store.dataPath

        onConfirmed: function(items) {
          root.finishImport(items)
        }

        onCanceled: root.refocusList()
      }

      BrowserPicker {
        id: browserPicker

        z: 18
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        helperPath: root.helperPath

        onSelected: function(browser) {
          var bookmark = root.browserTarget
          root.browserTarget = null
          root.activateBookmark(bookmark, false, browser)
        }

        onCanceled: {
          root.browserTarget = null
          root.refocusList()
        }
      }

      ConfirmDialog {
        id: deleteConfirm

        z: 20
        anchors.fill: parent

        opened: root.deleteConfirmOpen
        message:
          root.deleteTarget
            ? "Delete “" + root.displayTitle(root.deleteTarget) + "”?"
            : "Delete this bookmark?"

        cancelText: "Cancel"
        confirmText: "Delete"

        background: Color.menu.background
        foreground: Color.menu.text
        scrim: Util.alpha(Color.menu.background, 0.76)
        selectedBackground: Color.menu.selectedBackground
        selectedText: Color.menu.selectedText
        fontFamily: Style.font.menuFamily

        onCanceled: root.cancelDelete()
        onConfirmed: root.confirmDelete()
      }

      MenuEntryDialog {
        id: menuEntryDialog

        z: 25
        anchors.fill: parent
        opened: root.menuEntryDialogOpen
        installed: root.menuEntryInstalled
        busy: menuEntryProcess.running
        background: Color.menu.background
        foreground: Color.menu.text
        scrim: Util.alpha(Color.menu.background, 0.76)
        selectedBackground: Color.menu.selectedBackground
        selectedText: Color.menu.selectedText
        fontFamily: Style.font.menuFamily

        onCanceled: root.cancelMenuEntryDialog()
        onAddRequested: root.requestMenuEntryOperation("install")
        onRemoveRequested: root.requestMenuEntryOperation("remove")
      }
    }
  }
}
