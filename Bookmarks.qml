import QtQuick
import QtQuick.Controls as Controls
import QtQml.Models
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

Item {
  id: root
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property bool opened: false
  property string query: ""
  property string searchScope: "all"
  property string defaultSearchScope: "all"
  property string defaultResultOrder: "mostUsed"
  property int resultCount: 5
  property bool openInNewWindow: false
  property bool fetchPageDetails: false
  property string draftSearchScope: "all"
  property string draftDefaultResultOrder: "mostUsed"
  property int draftResultCount: 5
  property bool draftOpenInNewWindow: false
  property bool draftFetchPageDetails: false
  property int settingsRequestId: 0
  property int settingsSaveRequestId: 0
  property var results: []
  property var defaultResults: []
  property int selectedIndex: -1
  property int latestSearchId: 0
  property bool searchLoading: false
  property bool searchHasMore: false
  property bool noResultsState: false
  property int pendingSelectionIndex: -1
  property bool pointerPlacementPending: false
  property bool pointerPlacementScheduled: false
  property int pointerPlacementSettingsId: 0
  property int pointerPlacementSearchId: 0
  property real lastPointerEventX: NaN
  property real lastPointerEventY: NaN
  property bool previewingSelection: false
  property bool editingPreviewUrl: false
  property int openUrlRequestId: 0
  property int addUrlRequestId: 0
  property string pendingAddUrl: ""
  property string mode: "search"
  property var editingBookmark: null
  property string statusMessage: ""
  property int formSaveRequestId: 0
  property int deleteRequestId: 0
  property int metadataRequestId: 0
  property var metadataRequests: ({})
  property var suggestionRequests: ({})
  property bool titleEdited: false
  property bool descriptionEdited: false
  property bool applyingMetadata: false
  property var suggestedTags: []
  property bool controlHeld: false
  property bool altHeld: false
  // Library screens (import, restore, confirmations) share one request slot.
  property string noticeMessage: ""
  property bool libraryBusy: false
  property int libraryRequestId: 0
  property var libraryItems: []
  property int libraryIndex: 0
  property var importPreview: null
  property var pendingLibraryAction: null
  readonly property real menuCornerRadius: Math.max(Style.cornerRadius, Style.space(12))
  readonly property real contentCornerRadius: Math.max(1, root.menuCornerRadius - Math.max(1, Style.space(4)))
  readonly property real resultWindowHeight: Style.space(58) * root.resultCount + Style.spacing.xs * (root.resultCount - 1)
  readonly property real resultCountButtonWidth: Style.space(58)
  readonly property int maximumResultCount: Math.min(10, Math.max(3, 2 + Math.floor((contentColumn.width + Style.spacing.sm) / (root.resultCountButtonWidth + Style.spacing.sm))))
  readonly property string pluginId: (manifest && manifest.id) || "stefanmara.bookmarks"
  readonly property string workerLauncher: localPath("worker-launcher.sh")
  readonly property string workerInstaller: localPath("scripts/install-worker.sh")

  function isControlKey(event) {
    var nativeKey = Number(event.nativeVirtualKey)
    var scanCode = Number(event.nativeScanCode)
    return event.key === Qt.Key_Control
      || nativeKey === 0xffe3 || nativeKey === 0xffe4
      || (event.key === Qt.Key_unknown
        && (scanCode === 29 || scanCode === 37 || scanCode === 97 || scanCode === 105))
  }
  function isAltKey(event) {
    var nativeKey = Number(event.nativeVirtualKey)
    var scanCode = Number(event.nativeScanCode)
    return event.key === Qt.Key_Alt
      || nativeKey === 0xffe9 || nativeKey === 0xffea
      || (event.key === Qt.Key_unknown
        && (scanCode === 56 || scanCode === 64 || scanCode === 100 || scanCode === 108))
  }
  function updateModifierState(event, pressed) {
    if (isControlKey(event)) controlHeld = pressed
    else if (event.modifiers & Qt.ControlModifier) controlHeld = true
    else if (!pressed) controlHeld = false
    if (isAltKey(event)) altHeld = pressed
    else if (event.modifiers & Qt.AltModifier) altHeld = true
    else if (!pressed) altHeld = false
  }
  function localPath(relativePath) {
    var resolved = String(Qt.resolvedUrl(relativePath))
    if (resolved.indexOf("file://") === 0) resolved = resolved.slice(7)
    try { return decodeURIComponent(resolved) } catch (_) { return resolved }
  }
  function maybePlacePointerOverSearchField() {
    if (!pointerPlacementPending || pointerPlacementScheduled || !opened || mode !== "search"
        || pointerPlacementSettingsId || pointerPlacementSearchId) return
    pointerPlacementScheduled = true
    Qt.callLater(function() {
      root.pointerPlacementScheduled = false
      if (!root.pointerPlacementPending || !root.opened || root.mode !== "search"
          || root.pointerPlacementSettingsId || root.pointerPlacementSearchId) return
      var target = searchField.mapToGlobal(searchField.width / 2, searchField.height / 2)
      var x = Math.round(target.x)
      var y = Math.round(target.y)
      Hyprland.dispatch(Hyprland.usingLua
        ? "hl.dsp.cursor.move({ x = " + x + ", y = " + y + " })"
        : "movecursor " + x + " " + y)
      pointerPlacementGuard.restart()
    })
  }
  function pointerMotionIsIntentional(area, event) {
    var point = area.mapToGlobal(event.x, event.y)
    if (!isFinite(lastPointerEventX) || !isFinite(lastPointerEventY)) {
      lastPointerEventX = point.x
      lastPointerEventY = point.y
      return false
    }
    if (Math.abs(point.x - lastPointerEventX) < 4
        && Math.abs(point.y - lastPointerEventY) < 4) return false
    lastPointerEventX = point.x
    lastPointerEventY = point.y
    return true
  }
  function settlePointerPlacementRequest(requestId) {
    if (requestId === pointerPlacementSettingsId) pointerPlacementSettingsId = 0
    if (requestId === pointerPlacementSearchId) pointerPlacementSearchId = 0
    maybePlacePointerOverSearchField()
  }
  function open(payloadJson) {
    noticeMessage = ""
    query = ""; searchField.text = ""; results = []; defaultResults = []; selectedIndex = -1; latestSearchId = 0; searchLoading = false; searchHasMore = false; noResultsState = false; pendingSelectionIndex = -1
    pointerPlacementGuard.stop(); pointerPlacementPending = true; pointerPlacementScheduled = false; pointerPlacementSettingsId = 0; pointerPlacementSearchId = 0; lastPointerEventX = NaN; lastPointerEventY = NaN
    previewingSelection = false; editingPreviewUrl = false; openUrlRequestId = 0; addUrlRequestId = 0; pendingAddUrl = ""
    mode = "search"; searchScope = defaultSearchScope; editingBookmark = null; statusMessage = ""; controlHeld = false; altHeld = false; opened = true
    worker.start()
    requestSettings()
    performSearch()
    Qt.callLater(function() { searchField.forceActiveFocus(); root.maybePlacePointerOverSearchField() })
  }
  function close() { opened = false; query = ""; searchField.text = ""; results = []; defaultResults = []; selectedIndex = -1; pendingSelectionIndex = -1; noResultsState = false; pointerPlacementGuard.stop(); pointerPlacementPending = false; pointerPlacementScheduled = false; pointerPlacementSettingsId = 0; pointerPlacementSearchId = 0; lastPointerEventX = NaN; lastPointerEventY = NaN; previewingSelection = false; editingPreviewUrl = false; openUrlRequestId = 0; addUrlRequestId = 0; pendingAddUrl = ""; mode = "search"; searchScope = defaultSearchScope; editingBookmark = null; statusMessage = ""; controlHeld = false; altHeld = false; noticeMessage = ""; importPreview = null; pendingLibraryAction = null; if (!libraryBusy) libraryItems = [] }
  // Setup runs in a visible terminal so its verification result can be read.
  // Once that terminal closes, return to the overlay and either start the
  // installed worker or show the setup error again.
  function startWorkerSetup() {
    if (!worker.setupRequired || workerSetup.running) return
    workerSetup.running = true
    dismiss()
  }
  function dismiss() { close(); if (shell && typeof shell.hide === "function") shell.hide(pluginId) }
  function performSearch() {
    if (!query.trim()) { noResultsState = false; results = defaultResults }
    selectedIndex = -1; pendingSelectionIndex = -1; searchHasMore = false; searchLoading = true
    latestSearchId = worker.request({type: "search", query: query, scope: searchScope, limit: resultCount, offset: 0})
    if (pointerPlacementPending) pointerPlacementSearchId = latestSearchId
    maybePlacePointerOverSearchField()
  }
  function loadNextSearchPage() {
    if (!query.trim() || searchLoading || !searchHasMore) return
    searchLoading = true
    latestSearchId = worker.request({type: "search", query: query, scope: searchScope, limit: resultCount, offset: loadedBookmarkCount()})
  }
  function requestSettings() {
    var requestId = worker.request({type: "get_settings"})
    if (requestId) settingsRequestId = requestId
    if (pointerPlacementPending) pointerPlacementSettingsId = requestId
    maybePlacePointerOverSearchField()
  }
  function applySettings(settings) {
    if (!settings) return
    defaultSearchScope = settings.defaultSearchScope === "tags" ? "tags" : "all"
    defaultResultOrder = settings.defaultResultOrder === "recentlyUsed" ? "recentlyUsed" : "mostUsed"
    resultCount = Math.max(3, Math.min(10, Number(settings.resultCount || 5)))
    openInNewWindow = settings.openInNewWindow === true
    fetchPageDetails = settings.fetchPageDetails === true
  }
  function beginSettings() {
    draftSearchScope = defaultSearchScope
    draftDefaultResultOrder = defaultResultOrder
    draftResultCount = resultCount
    draftOpenInNewWindow = openInNewWindow
    draftFetchPageDetails = fetchPageDetails
    statusMessage = ""
    mode = "settings"
    Qt.callLater(function() { settingsKeyCatcher.forceActiveFocus() })
  }
  function saveSettings() {
    if (settingsSaveRequestId) return
    statusMessage = "Saving settings…"
    settingsSaveRequestId = worker.request({
      type: "save_settings",
      settings: {
        defaultSearchScope: draftSearchScope,
        defaultResultOrder: draftDefaultResultOrder,
        resultCount: draftResultCount,
        openInNewWindow: draftOpenInNewWindow,
        fetchPageDetails: draftFetchPageDetails
      }
    })
    if (!settingsSaveRequestId) statusMessage = worker.error || "Worker is unavailable"
  }
  function settingsFocusRows() {
    var controls = []
    function collect(item) {
      if (!item) return
      if (item !== settingsPanel && item.focusable === true && item.visible && item.enabled) {
        var position = item.mapToItem(settingsPanel, 0, 0)
        controls.push({
          item: item,
          left: position.x,
          right: position.x + item.width,
          top: position.y,
          bottom: position.y + item.height,
          centerX: position.x + item.width / 2
        })
      }
      var childItems = item.children
      for (var i = 0; i < childItems.length; ++i) collect(childItems[i])
    }
    collect(settingsPanel)
    controls.sort(function(a, b) {
      if (a.top !== b.top) return a.top - b.top
      return a.left - b.left
    })

    var rows = []
    for (var controlIndex = 0; controlIndex < controls.length; ++controlIndex) {
      var control = controls[controlIndex]
      var row = rows.length ? rows[rows.length - 1] : null
      if (!row || control.top >= row.bottom - 1 || control.bottom <= row.top + 1) {
        row = {top: control.top, bottom: control.bottom, controls: []}
        rows.push(row)
      } else {
        row.top = Math.min(row.top, control.top)
        row.bottom = Math.max(row.bottom, control.bottom)
      }
      row.controls.push(control)
    }
    for (var rowIndex = 0; rowIndex < rows.length; ++rowIndex) {
      rows[rowIndex].controls.sort(function(a, b) { return a.left - b.left })
    }
    return rows
  }
  function moveSettingsFocus(horizontalDelta, verticalDelta) {
    var rows = settingsFocusRows()
    if (!rows.length) return
    var currentRow = -1
    var currentColumn = -1
    for (var rowIndex = 0; rowIndex < rows.length; ++rowIndex) {
      for (var columnIndex = 0; columnIndex < rows[rowIndex].controls.length; ++columnIndex) {
        if (rows[rowIndex].controls[columnIndex].item.activeFocus) {
          currentRow = rowIndex
          currentColumn = columnIndex
          break
        }
      }
      if (currentRow >= 0) break
    }
    if (currentRow < 0) {
      rows[0].controls[0].item.forceActiveFocus()
      return
    }

    var target
    if (horizontalDelta !== 0) {
      var currentControls = rows[currentRow].controls
      var wrappedColumn = (currentColumn + horizontalDelta + currentControls.length) % currentControls.length
      target = currentControls[wrappedColumn]
    } else {
      var targetRow = currentRow + verticalDelta
      if (targetRow < 0 || targetRow >= rows.length) return
      var sourceX = rows[currentRow].controls[currentColumn].centerX
      var targetControls = rows[targetRow].controls
      target = targetControls[0]
      for (var targetIndex = 1; targetIndex < targetControls.length; ++targetIndex) {
        if (Math.abs(targetControls[targetIndex].centerX - sourceX) < Math.abs(target.centerX - sourceX)) {
          target = targetControls[targetIndex]
        }
      }
    }
    target.item.forceActiveFocus()
  }
  function shortcutIndex(slot) {
    return query.trim() ? searchResults.visibleStartIndex + slot : slot
  }
  function resultShortcutSlot(key) {
    if (key >= Qt.Key_1 && key <= Qt.Key_9) return key - Qt.Key_1
    return key === Qt.Key_0 ? 9 : -1
  }
  function resultShortcutKey(slot) { return slot === 9 ? "0" : String(slot + 1) }
  function toggleSearchScope() {
    restoreSearchQuery()
    searchScope = searchScope === "all" ? "tags" : "all"
    selectedIndex = -1; performSearch()
  }
  function selectedResult() { return selectedIndex >= 0 && selectedIndex < results.length ? results[selectedIndex] : null }
  function loadedBookmarkCount() {
    return results.reduce(function(count, item) { return count + (item.action ? 0 : 1) }, 0)
  }
  function looksLikeWebUrl(value) { return /^https?:\/\//i.test(String(value || "").trim()) }
  function restoreSearchQuery() {
    previewingSelection = false; editingPreviewUrl = false; selectedIndex = -1; pendingSelectionIndex = -1; addUrlRequestId = 0; pendingAddUrl = ""; statusMessage = ""
    searchField.text = query
    searchField.cursorPosition = searchField.text.length
  }
  function previewSelection(index) {
    if (index < 0 || index >= results.length) return
    selectedIndex = index
    var item = results[index]
    searchField.text = String(item.originalUrl || item.url || "")
    var matchIndex = searchField.text.toLowerCase().indexOf(query.trim().toLowerCase())
    if (!item.action && query.trim().length && matchIndex >= 0) searchField.select(matchIndex, matchIndex + query.trim().length)
    else searchField.cursorPosition = searchField.text.length
    previewingSelection = !item.action
    editingPreviewUrl = false
    statusMessage = ""
  }
  function moveSelection(delta) {
    if (!results.length) return
    if (delta > 0 && selectedIndex === results.length - 1 && searchHasMore) {
      pendingSelectionIndex = results.length
      loadNextSearchPage()
      return
    }
    var next = selectedIndex < 0 ? 0 : Math.max(0, Math.min(selectedIndex + delta, results.length - 1))
    previewSelection(next)
    searchResults.positionViewAtIndex(next, ListView.Contain)
  }
  function moveTopSelection(delta) {
    if (!results.length) return
    selectedIndex = selectedIndex < 0
      ? (delta > 0 ? 0 : results.length - 1)
      : ((selectedIndex + delta) % results.length + results.length) % results.length
  }
  function activateIndex(index, invertOpeningPreference) {
    if (index < 0 || index >= results.length) return
    previewingSelection = false; editingPreviewUrl = false; selectedIndex = index; activateCurrent(Boolean(invertOpeningPreference))
  }
  function requestOpen(body) {
    if (openUrlRequestId) return
    statusMessage = ""
    openUrlRequestId = worker.request(body)
    if (!openUrlRequestId) statusMessage = worker.error || "Worker is unavailable"
  }
  function requestOpenUrl(url, invertOpeningPreference) {
    var useNewWindow = invertOpeningPreference ? !openInNewWindow : openInNewWindow
    requestOpen({type: "open_url", url: String(url || "").trim(), new_window: useNewWindow})
  }
  function activateCurrent(invertOpeningPreference) {
    if (editingPreviewUrl) { requestOpenUrl(searchField.text, invertOpeningPreference); return }
    var item = selectedResult()
    if (!item && query.trim() && !searchLoading && results.length) {
      selectedIndex = 0
      item = selectedResult()
    }
    if (item) {
      if (item.action === "open_url") requestOpenUrl(item.url, invertOpeningPreference)
      else activateSelected(invertOpeningPreference)
      return
    }
    if (looksLikeWebUrl(searchField.text)) requestOpenUrl(searchField.text, invertOpeningPreference)
  }
  function activateSelected(invertOpeningPreference) {
    var item = selectedResult(); if (!item) return
    if (item.action === "open_url") { requestOpenUrl(item.url, invertOpeningPreference); return }
    var useNewWindow = invertOpeningPreference ? !openInNewWindow : openInNewWindow
    requestOpen({type: "open", bookmark_id: item.id, new_window: useNewWindow})
  }
  function requestAddCurrentUrl() {
    if (addUrlRequestId) return
    var candidate = String(searchField.text || "").trim()
    if (!editingPreviewUrl && !looksLikeWebUrl(candidate)) { beginAdd(""); return }
    pendingAddUrl = candidate
    addUrlRequestId = worker.request({type: "duplicate", url: candidate})
    if (!addUrlRequestId) statusMessage = worker.error || "Worker is unavailable"
  }
  function beginAdd(url) {
    metadataRequestId++
    editingBookmark = null; mode = "form"; applyingMetadata = true
    urlField.text = url || ""; titleField.text = ""; descriptionField.text = ""; tagsField.text = ""
    applyingMetadata = false; titleEdited = false; descriptionEdited = false; suggestedTags = []; statusMessage = ""
    Qt.callLater(function() { (url ? titleField : urlField).forceActiveFocus() })
    if (url && fetchPageDetails) {
      var requestId = worker.request({type: "fetch_metadata", url: url, metadata_request_id: metadataRequestId})
      if (requestId) metadataRequests[requestId] = metadataRequestId
    }
  }
  function beginEdit() {
    var item = selectedResult(); if (!item || item.action) return
    metadataRequestId++
    editingBookmark = item; mode = "form"; applyingMetadata = true
    urlField.text = item.originalUrl; titleField.text = item.title; descriptionField.text = item.description || ""
    tagsField.text = (item.tags || []).join(", "); applyingMetadata = false
    titleEdited = true; descriptionEdited = true; suggestedTags = []; statusMessage = ""
    Qt.callLater(function() { titleField.forceActiveFocus(); titleField.selectAll() })
  }
  function saveForm() {
    if (formSaveRequestId) return
    var tags = tagsField.text.split(",").map(function(value) { return value.trim() }).filter(Boolean)
    var bookmark = {id: editingBookmark ? editingBookmark.id : "", url: urlField.text, title: titleField.text,
      description: descriptionField.text, tags: tags, keyword: editingBookmark ? (editingBookmark.keyword || "") : ""}
    statusMessage = "Saving bookmark…"
    formSaveRequestId = worker.request({type: editingBookmark ? "edit" : "add", bookmark: bookmark})
    if (!formSaveRequestId) statusMessage = worker.error || "Worker is unavailable"
  }
  function returnToSettings() {
    mode = "settings"; importPreview = null; pendingLibraryAction = null
    Qt.callLater(function() { settingsKeyCatcher.forceActiveFocus() })
  }
  function focusLibrary() { Qt.callLater(function() { libraryKeyCatcher.forceActiveFocus() }) }
  function libraryRequest(body) {
    if (libraryBusy) return
    statusMessage = ""; noticeMessage = ""
    libraryRequestId = worker.request(body, worker.libraryRequestTimeoutMs)
    libraryBusy = libraryRequestId !== 0
    if (!libraryRequestId) statusMessage = worker.error || "Worker is unavailable"
  }
  function beginImport() {
    if (libraryBusy) return
    mode = "import"; libraryItems = []; libraryIndex = 0; importPreview = null
    libraryRequest({type: "import_sources"}); focusLibrary()
  }
  function beginRestore() {
    if (libraryBusy) return
    mode = "restore"; libraryItems = []; libraryIndex = 0
    libraryRequest({type: "backups_list"}); focusLibrary()
  }
  function beginLibraryConfirm(action) {
    if (libraryBusy) return
    statusMessage = ""; noticeMessage = ""
    pendingLibraryAction = action; mode = "confirmLibrary"; focusLibrary()
  }
  function confirmLoadExamples() {
    beginLibraryConfirm({title: "Replace your bookmarks with example bookmarks?", detail: "Your current library is backed up first and can be brought back with Restore backup.", confirmLabel: "Load examples", request: {type: "library_load_examples"}})
  }
  function confirmClearLibrary() {
    beginLibraryConfirm({title: "Delete all bookmarks?", detail: "Your current library is backed up first and can be brought back with Restore backup.", confirmLabel: "Clear all", request: {type: "library_clear"}})
  }
  function moveLibrarySelection(delta) {
    if (!libraryItems.length) return
    libraryIndex = Math.max(0, Math.min(libraryIndex + delta, libraryItems.length - 1))
    libraryList.positionViewAtIndex(libraryIndex, ListView.Contain)
  }
  function activateLibrary() {
    if (libraryBusy) return
    if (mode === "import") {
      if (importPreview) {
        if (importPreview.counts.new > 0) libraryRequest({type: "import_bookmarks", source_id: importPreview.sourceId})
        else returnToSettings()
        return
      }
      var source = libraryItems[libraryIndex]
      if (source) libraryRequest({type: "import_preview", source_id: source.id})
    } else if (mode === "restore") {
      var backup = libraryItems[libraryIndex]
      if (!backup) return
      beginLibraryConfirm({title: "Restore the backup from " + formatBackupTime(backup.createdAt) + "?", detail: bookmarkCount(backup.bookmarks) + ". Your current library is backed up first. Settings are kept.", confirmLabel: "Restore", request: {type: "backup_restore", name: backup.name}, returnMode: "restore"})
    } else if (mode === "confirmLibrary" && pendingLibraryAction) {
      libraryRequest(pendingLibraryAction.request)
    }
  }
  function libraryBack() {
    if (libraryBusy) return
    statusMessage = ""
    if (mode === "import" && importPreview) { importPreview = null; return }
    if (mode === "confirmLibrary" && pendingLibraryAction && pendingLibraryAction.returnMode === "restore") { pendingLibraryAction = null; mode = "restore"; return }
    returnToSettings()
  }
  function finishLibrary(message) {
    noticeMessage = message
    importPreview = null; pendingLibraryAction = null; libraryItems = []
    mode = "search"
    restoreSearchQuery()
    performSearch()
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }
  function bookmarkCount(count) { return Number(count) === 1 ? "1 bookmark" : Number(count) + " bookmarks" }
  function backupNote(name) { return name ? " Your previous library was backed up." : "" }
  function formatBackupTime(millis) { return Qt.formatDateTime(new Date(Number(millis)), "yyyy-MM-dd hh:mm") }
  function backupReasonLabel(reason) {
    return ({"manual": "Manual backup", "before-import": "Before import", "before-restore": "Before restore", "before-clear": "Before clearing", "before-examples": "Before loading examples"})[reason] || "Backup"
  }
  function handleLibraryResult(result) {
    if (Array.isArray(result.importSources)) { libraryItems = result.importSources; libraryIndex = 0; return }
    if (result.importPreview) { importPreview = result.importPreview; return }
    if (Array.isArray(result.backups)) { libraryItems = result.backups; libraryIndex = 0; return }
    if (result.backupCreated) { noticeMessage = "Backup saved with " + bookmarkCount(result.backupCreated.bookmarks) + "."; return }
    if (result.imported) {
      var imported = result.imported
      finishLibrary(imported.added ? "Imported " + bookmarkCount(imported.added) + "." + backupNote(imported.backup) : "Nothing new to import.")
      return
    }
    if (result.restored) { finishLibrary("Restored " + bookmarkCount(result.restored.bookmarks) + "." + backupNote(result.restored.backup)); return }
    if (result.cleared) { finishLibrary("Removed " + bookmarkCount(result.cleared.removed) + "." + backupNote(result.cleared.backup)); return }
    if (result.examplesLoaded) { finishLibrary("Loaded " + bookmarkCount(result.examplesLoaded.added) + " of examples." + backupNote(result.examplesLoaded.backup)); return }
  }
  function libraryTitle() {
    if (mode === "confirmLibrary") return pendingLibraryAction ? pendingLibraryAction.title : ""
    if (mode === "import") {
      if (importPreview) return "Import from " + importPreview.browser + " (" + importPreview.profile + ")?"
      if (libraryItems.length) return "Import bookmarks from a browser"
      return libraryBusy ? "Finding browsers…" : "No browser bookmarks found"
    }
    if (libraryItems.length) return "Restore a backup"
    return libraryBusy ? "Loading backups…" : "No backups yet"
  }
  function libraryDetail() {
    if (mode === "confirmLibrary") return pendingLibraryAction ? pendingLibraryAction.detail : ""
    if (mode === "import") {
      if (importPreview) {
        var counts = importPreview.counts
        if (!counts.new) return "Everything in this profile is already saved."
        return bookmarkCount(counts.new) + " will be added. " + counts.alreadySaved + " already saved, " + counts.skipped + " skipped (not web pages or repeated). Your library is backed up first."
      }
      return "Bookmarks are read from Firefox, Zen, LibreWolf, Chrome, Chromium, Brave, Vivaldi, Edge, and similar browsers. Existing bookmarks are not changed."
    }
    return libraryItems.length ? "Your current library is backed up before restoring. Settings are kept." : "Back up now from Settings, or make a change that backs up automatically."
  }
  function libraryPrimaryLabel() {
    if (mode === "confirmLibrary") return pendingLibraryAction ? pendingLibraryAction.confirmLabel : ""
    if (mode === "import") return importPreview ? (importPreview.counts.new ? "Import" : "Done") : "Preview"
    return "Restore…"
  }
  function cancelSecondary() {
    if ((mode === "form" && formSaveRequestId) || (mode === "settings" && settingsSaveRequestId) || (mode === "delete" && deleteRequestId)) return
    metadataRequestId++
    mode = "search"; editingBookmark = null; statusMessage = ""
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }
  function requestDelete() { var item = selectedResult(); if (item && !item.action) { editingBookmark = item; mode = "delete"; Qt.callLater(function(){ deleteKeyCatcher.forceActiveFocus() }) } }
  function confirmDelete() {
    if (deleteRequestId || !editingBookmark) return
    deleteRequestId = worker.request({type: "delete", bookmark_id: editingBookmark.id})
    if (!deleteRequestId) statusMessage = worker.error || "Worker is unavailable"
  }
  function domain(url) { var match = String(url || "").match(/^https?:\/\/([^/]+)(\/.*)?$/i); return match ? match[1] + ((match[2] && match[2] !== "/") ? match[2] : "") : String(url || "") }
  function handleMessage(response) {
    settlePointerPlacementRequest(response.id)
    var metadataGeneration = metadataRequests[response.id]
    var suggestionGeneration = suggestionRequests[response.id]
    if (!response.ok) {
      if (metadataGeneration !== undefined) {
        delete metadataRequests[response.id]
        if (Number(metadataGeneration) === metadataRequestId && mode === "form") statusMessage = String(response.error || "Could not fetch page details")
        return
      }
      if (suggestionGeneration !== undefined) { delete suggestionRequests[response.id]; return }
      if (libraryRequestId && response.id === libraryRequestId) { libraryRequestId = 0; libraryBusy = false; statusMessage = String(response.error || "Library operation failed"); return }
      if (openUrlRequestId && response.id === openUrlRequestId) { openUrlRequestId = 0; statusMessage = String(response.error || "Could not open URL"); return }
      if (addUrlRequestId && response.id === addUrlRequestId) { addUrlRequestId = 0; pendingAddUrl = ""; statusMessage = String(response.error || "Enter a valid HTTP or HTTPS URL"); return }
      if (formSaveRequestId && response.id === formSaveRequestId) { formSaveRequestId = 0; statusMessage = String(response.error || "Could not save bookmark"); return }
      if (deleteRequestId && response.id === deleteRequestId) { deleteRequestId = 0; statusMessage = String(response.error || "Could not delete bookmark"); return }
      if (response.id === settingsRequestId) { statusMessage = String(response.error || "Could not load settings"); return }
      if (settingsSaveRequestId && response.id === settingsSaveRequestId) { settingsSaveRequestId = 0; statusMessage = String(response.error || "Could not save settings"); return }
      if (response.id === latestSearchId) { searchLoading = false; results = []; noResultsState = false }
      statusMessage = String(response.error || "Bookmark operation failed"); return
    }
    var result = response.result || {}
    if (libraryRequestId && response.id === libraryRequestId) { libraryRequestId = 0; libraryBusy = false; handleLibraryResult(result); return }
    if (openUrlRequestId && response.id === openUrlRequestId) { openUrlRequestId = 0; dismiss(); return }
    if (addUrlRequestId && response.id === addUrlRequestId) {
      var urlToAdd = pendingAddUrl
      addUrlRequestId = 0; pendingAddUrl = ""
      if (result.bookmark) { statusMessage = "Already bookmarked"; return }
      restoreSearchQuery()
      beginAdd(urlToAdd); return
    }
    if (response.id === settingsRequestId) {
      var previousScope = searchScope
      var previousCount = resultCount
      var previousOrder = defaultResultOrder
      applySettings(result.settings)
      if (mode === "settings") {
        draftSearchScope = defaultSearchScope
        draftDefaultResultOrder = defaultResultOrder
        draftResultCount = resultCount
        draftOpenInNewWindow = openInNewWindow
        draftFetchPageDetails = fetchPageDetails
      }
      if (mode === "search") {
        searchScope = defaultSearchScope
        if (previousScope !== searchScope || previousCount !== resultCount || previousOrder !== defaultResultOrder) performSearch()
      }
      return
    }
    if (response.id === settingsSaveRequestId) {
      settingsSaveRequestId = 0
      applySettings(result.settings)
      searchScope = defaultSearchScope
      mode = "search"
      statusMessage = ""
      restoreSearchQuery()
      performSearch()
      Qt.callLater(function() { searchField.forceActiveFocus() })
      return
    }
    if (response.id === latestSearchId) {
      if (String(result.query || "") !== query || String(result.scope || "all") !== searchScope) return
      var offset = Number(result.offset || 0)
      var next = Array.isArray(result.items) ? result.items : []
      var displacedBookmark = false
      if (result.isUrl && !result.exactMatch && offset === 0) {
        next.unshift({action: "open_url", title: "Open URL", originalUrl: query, url: query, tags: []})
        if (next.length > resultCount) { next.pop(); displacedBookmark = true }
      }
      if (offset === 0) {
        noResultsState = query.trim().length > 0 && next.length === 0
      }
      results = offset === 0 ? next : results.concat(next); searchHasMore = Boolean(result.hasMore) || displacedBookmark; searchLoading = false
      if (offset === 0 && !query.trim()) defaultResults = next
      if (offset === 0) selectedIndex = result.isUrl && next.length ? 0 : -1
      if (pendingSelectionIndex >= 0) {
        var pending = Math.min(pendingSelectionIndex, results.length - 1)
        pendingSelectionIndex = -1
        if (pending >= 0) {
          previewSelection(pending)
          Qt.callLater(function() { searchResults.positionViewAtIndex(pending, ListView.Contain) })
        }
      }
      return
    }
    if (metadataGeneration !== undefined) {
      delete metadataRequests[response.id]
      if (Number(metadataGeneration) !== metadataRequestId || Number(result.metadataRequestId) !== metadataRequestId || mode !== "form") return
      applyingMetadata = true
      if (!titleEdited && result.metadata && result.metadata.title) titleField.text = result.metadata.title
      if (!descriptionEdited && result.metadata && result.metadata.description) descriptionField.text = result.metadata.description
      applyingMetadata = false
      var suggestionId = worker.request({type: "suggest_tags", text: titleField.text + " " + descriptionField.text})
      if (suggestionId) suggestionRequests[suggestionId] = metadataRequestId
      return
    }
    if (suggestionGeneration !== undefined) {
      delete suggestionRequests[response.id]
      if (Number(suggestionGeneration) === metadataRequestId && mode === "form" && Array.isArray(result.tags)) suggestedTags = result.tags.slice(0, 4)
      return
    }
    if (formSaveRequestId && response.id === formSaveRequestId) {
      formSaveRequestId = 0
      if (result.bookmark && mode === "form") { previewingSelection = false; editingPreviewUrl = false; cancelSecondary(); query = result.bookmark.title || result.bookmark.originalUrl; searchField.text = query; searchDebounce.restart() }
      return
    }
    if (deleteRequestId && response.id === deleteRequestId) {
      deleteRequestId = 0
      if (result.deleted) { mode = "search"; editingBookmark = null; restoreSearchQuery(); performSearch() }
      else statusMessage = "Bookmark no longer exists"
    }
  }

  component ResultShortcutContent: Item {
    property var controller

    Row {
      id: bookmarkActions
      anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.md

      Repeater {
        model: [
          {key: "Ctrl+Enter", label: controller.openInNewWindow ? "Open in new tab" : "Open in new window"},
          {key: "Ctrl+C", label: "Copy URL"},
          {key: "Ctrl+E", label: "Edit"}
        ]
        delegate: Column {
          required property var modelData
          width: (bookmarkActions.width - bookmarkActions.spacing * 2) / 3
          spacing: Style.spacing.xs
          Text {
            textFormat: Text.PlainText
            width: parent.width; text: modelData.key; color: Color.menu.selectedText
            font.family: Style.font.menuFamily; font.pixelSize: Style.font.heading; font.weight: Font.Medium
            elide: Text.ElideRight
          }
          Text {
            textFormat: Text.PlainText
            width: parent.width; text: modelData.label; color: Color.menu.selectedText; opacity: 0.72
            font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }

  }

  // Clips its content and, while active, scrolls overflowing content horizontally:
  // hold for 1s, scroll to the end, hold for 1s, snap back to the start, and repeat.
  component ScrollingClip: Item {
    id: scrollingClip
    property bool active: false
    property real contentWidth: 0
    property real offset: 0
    readonly property real overflow: Math.max(0, contentWidth - width)
    readonly property bool scrolling: active && overflow > 0
    default property alias content: track.data
    clip: true
    onScrollingChanged: offset = 0

    Item { id: track; x: -scrollingClip.offset; width: scrollingClip.contentWidth; height: parent.height }
    SequentialAnimation {
      running: scrollingClip.scrolling
      loops: Animation.Infinite
      PropertyAction { target: scrollingClip; property: "offset"; value: 0 }
      PauseAnimation { duration: 1000 }
      NumberAnimation { target: scrollingClip; property: "offset"; from: 0; to: scrollingClip.overflow; duration: Math.max(1, scrollingClip.overflow / Style.space(50) * 1000) }
      PauseAnimation { duration: 1000 }
    }
  }

  component HighlightedText: Item {
    id: highlightedText
    property bool scrollActive: false
    property string value: ""
    property string needle: ""
    property color foreground: Color.menu.text
    property color matchedForeground: Color.menu.selectedText
    property color matchedBackground: Util.alpha(Color.menu.selectedText, 0.2)
    property string fontFamily: Style.font.menuFamily
    property int fontPixelSize: Style.font.bodySmall
    property int fontWeight: Font.Normal
    readonly property string trimmedNeedle: needle.trim()
    readonly property var segments: splitMatches(value, trimmedNeedle)
    implicitHeight: textMetrics.implicitHeight
    clip: true

    function splitMatches(sourceValue, searchValue) {
      var source = String(sourceValue || "")
      var search = String(searchValue || "")
      if (!search.length) return [{value: source, matched: false}]
      var sourceLower = source.toLowerCase()
      var searchLower = search.toLowerCase()
      var parts = []
      var cursor = 0
      var matchIndex = sourceLower.indexOf(searchLower, cursor)
      while (matchIndex >= 0) {
        if (matchIndex > cursor) appendPart(parts, source.slice(cursor, matchIndex), false)
        appendPart(parts, source.slice(matchIndex, matchIndex + search.length), true)
        cursor = matchIndex + search.length
        matchIndex = sourceLower.indexOf(searchLower, cursor)
      }
      if (cursor < source.length) appendPart(parts, source.slice(cursor), false)
      return parts.length ? parts : [{value: source, matched: false}]
    }
    function appendPart(parts, partValue, matched) {
      if (!partValue.length) return
      var previous = parts.length ? parts[parts.length - 1] : null
      if (previous && previous.matched === matched) previous.value += partValue
      else parts.push({value: partValue, matched: matched})
    }

    Text {
      id: textMetrics
      visible: false; text: "M"; textFormat: Text.PlainText
      font.family: highlightedText.fontFamily; font.pixelSize: highlightedText.fontPixelSize; font.weight: highlightedText.fontWeight
    }
    ScrollingClip {
      anchors.fill: parent
      active: highlightedText.scrollActive
      contentWidth: segmentRow.implicitWidth
      Row {
        id: segmentRow
        anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
        Repeater {
          model: highlightedText.segments
          delegate: Rectangle {
            required property var modelData
            width: segmentText.implicitWidth; height: parent.height
            radius: modelData.matched ? Math.max(1, Style.space(2)) : 0
            color: modelData.matched ? highlightedText.matchedBackground : "transparent"
            Text {
              id: segmentText
              anchors.centerIn: parent
              text: modelData.value; textFormat: Text.PlainText
              color: modelData.matched ? highlightedText.matchedForeground : highlightedText.foreground
              font.family: highlightedText.fontFamily; font.pixelSize: highlightedText.fontPixelSize; font.weight: highlightedText.fontWeight
            }
          }
        }
      }
    }
  }

  WorkerClient {
    id: worker
    launcherPath: root.workerLauncher
    onReadyChanged: if (ready && root.opened) { root.requestSettings(); root.performSearch() }
    onMessage: function(response) { root.handleMessage(response) }
  }
  Timer { id: searchDebounce; interval: 35; repeat: false; onTriggered: root.performSearch() }
  // Keep result rows inert until Hyprland has processed the initial cursor
  // move; otherwise the cursor passes over them on its way to the field.
  Timer { id: pointerPlacementGuard; interval: 150; repeat: false; onTriggered: root.pointerPlacementPending = false }
  Process {
    id: workerSetup
    command: ["omarchy-launch-tui", "--app-id=TUI.float", root.workerInstaller, "--pause"]
    onExited: function() {
      if (root.shell && typeof root.shell.summon === "function")
        Qt.callLater(function() { root.shell.summon(root.pluginId, "{}") })
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "stefanmara-bookmarks"
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    Rectangle { anchors.fill: parent; color: Color.menu.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: Math.min(Style.space(620), panel.width - Style.gapsOut * 2)
      height: contentColumn.implicitHeight + Style.spacing.panelPadding * 2
      // Pin the top where the collapsed card is centred so results grow downward only.
      readonly property real collapsedHeight: searchField.height + Style.spacing.panelPadding * 2
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: Math.round(Math.max(Style.gapsOut, Math.min((panel.height - collapsedHeight) / 2, panel.height - height - Style.gapsOut)))
      color: Color.menu.background; radius: root.menuCornerRadius; padding: Style.spacing.panelPadding
      borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(1)))
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) { root.updateModifierState(event, true) }
      Keys.onReleased: function(event) { root.updateModifierState(event, false) }
      MouseArea { anchors.fill: parent; onClicked: {} }

      Shortcut {
        sequence: "Ctrl+S"
        enabled: root.opened && root.mode === "search"
        autoRepeat: false
        onActivated: root.beginSettings()
      }

      Shortcut {
        sequence: "Ctrl+Return"
        enabled: root.opened && root.mode === "settings"
        autoRepeat: false
        onActivated: root.saveSettings()
      }

      Column {
        id: contentColumn
        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
        anchors.leftMargin: card.contentLeftInset; anchors.rightMargin: card.contentRightInset; anchors.topMargin: card.contentTopInset
        spacing: Style.spacing.xs
        Controls.TextField {
          id: searchField
          visible: root.mode === "search"; width: parent.width; height: Style.space(46); text: root.query
          leftPadding: Style.spacing.md; rightPadding: Style.spacing.md
          cursorVisible: !root.controlHeld
          placeholderText: root.controlHeld && text.length === 0 ? "" : root.searchScope === "tags" ? "Search tags" : "Search bookmarks"; font.family: Style.font.menuFamily; font.pixelSize: Style.font.heading
          color: Color.menu.text; selectionColor: Util.alpha(Color.menu.selectedText, 0.24); selectedTextColor: Color.menu.text; selectByMouse: true
          background: Rectangle {
            color: Util.alpha(Color.menu.text, 0.035); radius: root.contentCornerRadius
            border.color: root.searchScope === "tags" ? Util.alpha(Color.menu.selectedText, 0.62) : Util.alpha(Color.menu.text, 0.12)
            Rectangle {
              visible: root.searchScope === "tags"
              anchors.fill: parent; anchors.margins: Style.space(3)
              color: "transparent"; radius: Math.max(1, parent.radius - Style.space(3))
              border.color: Util.alpha(Color.menu.selectedText, 0.42)
            }
          }
          Text {
            textFormat: Text.PlainText
            visible: root.controlHeld && searchField.text.length === 0
            anchors.centerIn: parent
            text: root.altHeld
              ? "Ctrl+Alt+number   " + (root.openInNewWindow ? "Open in new tab" : "Open in new window")
              : "Ctrl+N   Add bookmark     Ctrl+V   Paste     Ctrl+S   Settings"
            color: Color.menu.text
            opacity: 0.72
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.bodySmall
          }
          Rectangle {
            visible: root.previewingSelection || root.editingPreviewUrl
            anchors.left: parent.left; anchors.leftMargin: Style.spacing.sm
            anchors.top: parent.top; anchors.topMargin: -height / 2
            width: escapeHint.implicitWidth + Style.space(8); height: escapeHint.implicitHeight
            color: Color.menu.background; z: 2
            Text {
              id: escapeHint
              textFormat: Text.PlainText
              anchors.centerIn: parent
              text: "esc"
              color: Color.menu.text; opacity: 0.62
              font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption
            }
          }
          onTextEdited: {
            if (root.previewingSelection || root.editingPreviewUrl) {
              root.previewingSelection = false; root.editingPreviewUrl = true; root.selectedIndex = -1; root.pendingSelectionIndex = -1; root.statusMessage = ""
              return
            }
            root.noticeMessage = ""
            root.query = text; root.selectedIndex = -1; root.pendingSelectionIndex = -1; root.statusMessage = ""
            root.searchHasMore = false; root.searchLoading = true
            if (!root.query.trim()) { root.results = root.defaultResults; root.noResultsState = false }
            searchDebounce.restart()
          }
          Keys.onPressed: function(event) {
            var directSlot = root.resultShortcutSlot(event.key)
            root.updateModifierState(event, true)
            if (event.key === Qt.Key_Escape && (root.previewingSelection || root.editingPreviewUrl)) { root.restoreSearchQuery(); event.accepted = true }
            else if (event.key === Qt.Key_Escape) { root.dismiss(); event.accepted = true }
            else if (event.key === Qt.Key_Tab && event.modifiers === Qt.NoModifier) { root.toggleSearchScope(); event.accepted = true }
            else if (!root.query.trim() && event.key === Qt.Key_Up) { root.moveTopSelection(-1); event.accepted = true }
            else if (!root.query.trim() && event.key === Qt.Key_Down) { root.moveTopSelection(1); event.accepted = true }
            else if (root.query.trim() && event.key === Qt.Key_Up) { root.moveSelection(-1); event.accepted = true }
            else if (root.query.trim() && event.key === Qt.Key_Down) { root.moveSelection(1); event.accepted = true }
            else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && worker.setupRequired) { root.startWorkerSetup(); event.accepted = true }
            else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && event.modifiers === Qt.ControlModifier) { root.activateCurrent(true); event.accepted = true }
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.activateCurrent(false); event.accepted = true }
            else if (event.modifiers === (Qt.ControlModifier | Qt.AltModifier) && directSlot >= 0 && directSlot < root.resultCount) { root.activateIndex(root.shortcutIndex(directSlot), true); event.accepted = true }
            else if (event.modifiers === Qt.ControlModifier && directSlot >= 0 && directSlot < root.resultCount) { root.activateIndex(root.shortcutIndex(directSlot), false); event.accepted = true }
            else if (event.key === Qt.Key_N && event.modifiers === Qt.ControlModifier) { root.requestAddCurrentUrl(); event.accepted = true }
            else if (event.key === Qt.Key_S && event.modifiers === Qt.ControlModifier) { root.beginSettings(); event.accepted = true }
            else if (event.key === Qt.Key_E && event.modifiers === Qt.ControlModifier) { root.beginEdit(); event.accepted = true }
            else if (event.key === Qt.Key_C && event.modifiers === Qt.ControlModifier && !root.editingPreviewUrl && root.selectedResult() && !root.selectedResult().action) { worker.request({type:"copy",bookmark_id:root.selectedResult().id}); event.accepted=true }
            else if (event.key === Qt.Key_D && event.modifiers === Qt.ControlModifier) { root.requestDelete(); event.accepted = true }
          }
          Keys.onReleased: function(event) { root.updateModifierState(event, false) }
        }
        Column {
          id: emptyLibraryPrompt
          visible: root.mode === "search" && root.query.trim().length === 0
            && !worker.setupRequired && worker.ready && !root.searchLoading
            && root.results.length === 0
          width: parent.width; spacing: Style.spacing.sm
          topPadding: Style.spacing.sm; bottomPadding: Style.spacing.sm
          Text {
            width: parent.width; textFormat: Text.PlainText
            text: "Your bookmark library is empty"
            color: Color.menu.text; font.family: Style.font.menuFamily; font.pixelSize: Style.font.heading
          }
          Text {
            width: parent.width; textFormat: Text.PlainText; wrapMode: Text.Wrap
            text: "Add your first bookmark, import from an installed browser, or load examples to explore Bookmarks."
            color: Color.menu.text; opacity: 0.6; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption
          }
          Flow {
            width: parent.width; spacing: Style.spacing.sm
            Button { width: Style.space(140); height: Style.space(34); text: "Add bookmark"; bordered: true; selected: true; focusable: true; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.beginAdd("") }
            Button { width: Style.space(170); height: Style.space(34); text: "Import from browser"; bordered: true; focusable: true; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.beginImport() }
            Button { width: Style.space(140); height: Style.space(34); text: "Load examples"; bordered: true; focusable: true; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.confirmLoadExamples() }
          }
          Text {
            width: parent.width; textFormat: Text.PlainText
            text: "Keyboard: Ctrl+N adds · Ctrl+S opens settings and library tools"
            color: Color.menu.text; opacity: 0.45; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption
          }
        }
        Column {
          id: topBookmarks
          visible: root.mode === "search" && root.query.trim().length === 0
            && !worker.setupRequired && root.results.length > 0
          width: parent.width; height: root.resultWindowHeight; spacing: Style.spacing.xs
          Repeater {
            model: root.results
            delegate: Rectangle {
              required property int index; required property var modelData
              readonly property bool showingShortcuts: root.controlHeld && index === root.selectedIndex && !modelData.action
              width: topBookmarks.width; height: Style.space(58); radius: root.contentCornerRadius
              color: index === root.selectedIndex ? Color.menu.selectedBackground : "transparent"
              MouseArea {
                id: topPointerArea
                anchors.fill: parent; hoverEnabled: true
                onPositionChanged: function(event) {
                  if (!root.pointerPlacementPending && index !== root.selectedIndex
                      && root.pointerMotionIsIntentional(topPointerArea, event)) root.selectedIndex = index
                }
                onClicked: root.activateIndex(index)
              }
              Text { id: topShortcutHint; textFormat: Text.PlainText; anchors.right: parent.right; anchors.rightMargin: Style.spacing.md; anchors.verticalCenter: parent.verticalCenter; visible: root.controlHeld; text: (root.altHeld ? "Ctrl+Alt+" : "Ctrl+") + root.resultShortcutKey(index); color: index === root.selectedIndex ? Color.menu.selectedText : Color.menu.text; opacity: 0.55; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
              Column {
                visible: !parent.showingShortcuts
                anchors.left: parent.left; anchors.right: topShortcutHint.visible ? topShortcutHint.left : parent.right; anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.spacing.md; anchors.rightMargin: Style.spacing.md; spacing: Style.spacing.xs
                ScrollingClip {
                  id: topTitle
                  width: parent.width; height: topTitleText.implicitHeight
                  active: index === root.selectedIndex && parent.visible
                  contentWidth: topTitleText.implicitWidth
                  // Elide while at rest; show the full title once it starts moving.
                  Text { id: topTitleText; width: topTitle.offset > 0 ? implicitWidth : topTitle.width; text: modelData.title || root.domain(modelData.originalUrl); textFormat: Text.PlainText; elide: Text.ElideRight; color: index === root.selectedIndex ? Color.menu.selectedText : Color.menu.text; font.family: Style.font.menuFamily; font.pixelSize: Style.font.heading; font.weight: Font.Medium }
                }
                Text { width: parent.width; text: root.domain(modelData.originalUrl) + ((modelData.tags || []).length ? "  ·  " + modelData.tags.slice(0, 3).join(" · ") : ""); textFormat: Text.PlainText; elide: Text.ElideRight; color: Color.menu.text; opacity: 0.52; font.family: Style.font.menuFamily; font.pixelSize: Style.font.bodySmall }
              }
              ResultShortcutContent {
                visible: parent.showingShortcuts
                anchors.left: parent.left; anchors.right: topShortcutHint.left; anchors.top: parent.top; anchors.bottom: parent.bottom
                anchors.leftMargin: Style.spacing.md; anchors.rightMargin: Style.spacing.md
                controller: root
              }
            }
          }
        }
        ListView {
          id: searchResults
          visible: root.mode === "search" && root.query.trim().length > 0 && !worker.setupRequired; width: parent.width; spacing: Style.spacing.xs
          height: root.noResultsState ? Style.space(44) : root.resultWindowHeight
          clip: true; model: root.results; boundsBehavior: Flickable.StopAtBounds; snapMode: ListView.SnapToItem
          Controls.ScrollBar.vertical: Controls.ScrollBar {}
          property int visibleStartIndex: 0
          onContentYChanged: {
            var found = indexAt(width / 2, contentY + 1)
            if (found >= 0) visibleStartIndex = found
          }
          onAtYEndChanged: if (atYEnd && root.searchHasMore) root.loadNextSearchPage()
          footer: Item { width: searchResults.width; height: root.searchHasMore ? Style.space(24) : 0 }
          delegate: Rectangle {
              required property int index; required property var modelData
              readonly property bool showingShortcuts: root.controlHeld && index === root.selectedIndex && !modelData.action
              width: contentColumn.width; height: Style.space(58); radius: root.contentCornerRadius
              color: index === root.selectedIndex ? Color.menu.selectedBackground : "transparent"
              MouseArea {
                id: resultPointerArea
                anchors.fill: parent; hoverEnabled: true
                onPositionChanged: function(event) {
                  if (!root.pointerPlacementPending && !root.editingPreviewUrl && index !== root.selectedIndex
                      && root.pointerMotionIsIntentional(resultPointerArea, event)) root.previewSelection(index)
                }
                onClicked: root.activateIndex(index)
              }
              Text { id: shortcutHint; textFormat: Text.PlainText; anchors.right: parent.right; anchors.rightMargin: Style.spacing.md; anchors.verticalCenter: parent.verticalCenter; visible: root.controlHeld && index >= searchResults.visibleStartIndex && index < searchResults.visibleStartIndex + root.resultCount; text: (root.altHeld ? "Ctrl+Alt+" : "Ctrl+") + root.resultShortcutKey(index - searchResults.visibleStartIndex); color: index === root.selectedIndex ? Color.menu.selectedText : Color.menu.text; opacity: 0.55; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
              Column {
                visible: !parent.showingShortcuts
                anchors.left: parent.left; anchors.right: shortcutHint.visible ? shortcutHint.left : parent.right; anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.spacing.md; anchors.rightMargin: Style.spacing.md; spacing: Style.spacing.xs
                HighlightedText {
                  width: parent.width
                  scrollActive: index === root.selectedIndex && parent.visible
                  value: modelData.title || root.domain(modelData.originalUrl)
                  needle: root.query
                  foreground: index === root.selectedIndex ? Color.menu.selectedText : Color.menu.text
                  fontPixelSize: Style.font.heading; fontWeight: Font.Medium
                }
                HighlightedText {
                  width: parent.width
                  value: modelData.action === "open_url" ? modelData.originalUrl + "  ·  Ctrl+N to add bookmark" : root.domain(modelData.originalUrl) + ((modelData.tags || []).length ? "  ·  " + modelData.tags.slice(0, 3).join(" · ") : "")
                  needle: root.query
                  foreground: Util.alpha(Color.menu.text, 0.52)
                  matchedForeground: Color.menu.selectedText
                  fontPixelSize: Style.font.bodySmall
                }
              }
              ResultShortcutContent {
                visible: parent.showingShortcuts
                anchors.left: parent.left; anchors.right: shortcutHint.left; anchors.top: parent.top; anchors.bottom: parent.bottom
                anchors.leftMargin: Style.spacing.md; anchors.rightMargin: Style.spacing.md
                controller: root
              }
          }
          Text { textFormat: Text.PlainText; visible: root.noResultsState && !worker.error; width: parent.width; height: Style.space(44); text: "No matching bookmarks"; color: Color.menu.text; opacity: 0.55; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.family: Style.font.menuFamily }
        }
        Column {
          id: workerSetupPrompt
          visible: root.mode === "search" && worker.setupRequired
          width: parent.width; spacing: Style.spacing.sm
          topPadding: Style.spacing.sm; bottomPadding: Style.spacing.sm
          Text {
            width: parent.width; textFormat: Text.PlainText; wrapMode: Text.Wrap
            text: worker.error || "The bookmark worker needs to be set up."
            color: Color.menu.text; font.family: Style.font.menuFamily; font.pixelSize: Style.font.heading
          }
          Text {
            width: parent.width; textFormat: Text.PlainText; wrapMode: Text.Wrap
            text: "Setup opens a terminal. It installs the worker release pinned by this plugin after checking its SHA-256, or builds the plugin's own source with cargo when no release matches. Bookmarks returns when the terminal closes."
            color: Color.menu.text; opacity: 0.6; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption
          }
          Item {
            width: parent.width; height: Style.space(38)
            Text { textFormat: Text.PlainText; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "Enter to set up · Escape to close"; color: Color.menu.text; opacity: 0.45; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
            Button { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; width: Style.space(120); height: Style.space(34); text: "Set up worker"; bordered: true; selected: true; focusable: true; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.startWorkerSetup() }
          }
        }
        Column {
          visible: root.mode === "form"; width: parent.width; spacing: Style.spacing.sm
          Controls.TextField { id: urlField; width: parent.width; placeholderText: "URL"; selectByMouse: true; font.family: Style.font.menuFamily; onAccepted: root.saveForm(); Keys.onPressed: function(e){if(e.key===Qt.Key_Escape){root.cancelSecondary();e.accepted=true}} }
          Controls.TextField { id: titleField; width: parent.width; placeholderText: "Title"; selectByMouse: true; font.family: Style.font.menuFamily; onTextEdited: if(!root.applyingMetadata) root.titleEdited=true; onAccepted: root.saveForm(); Keys.onPressed: function(e){if(e.key===Qt.Key_Escape){root.cancelSecondary();e.accepted=true}} }
          Controls.TextArea {
            id: descriptionField
            width: parent.width; height: Style.space(70); placeholderText: "Description"
            wrapMode: TextEdit.Wrap; selectByMouse: true; font.family: Style.font.menuFamily
            onTextChanged: if(activeFocus&&!root.applyingMetadata) root.descriptionEdited=true
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(e) {
              if (e.key === Qt.Key_Tab && e.modifiers === Qt.NoModifier) {
                tagsField.forceActiveFocus(); e.accepted = true
              } else if (e.key === Qt.Key_Backtab || (e.key === Qt.Key_Tab && e.modifiers === Qt.ShiftModifier)) {
                titleField.forceActiveFocus(); e.accepted = true
              } else if (e.key === Qt.Key_Escape) {
                root.cancelSecondary(); e.accepted = true
              } else if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && (e.modifiers & Qt.ControlModifier)) {
                root.saveForm(); e.accepted = true
              }
            }
          }
          Controls.TextField { id: tagsField; width: parent.width; placeholderText: "Tags, comma separated"; selectByMouse: true; font.family: Style.font.menuFamily; onAccepted: root.saveForm(); Keys.onPressed: function(e){if(e.key===Qt.Key_Escape){root.cancelSecondary();e.accepted=true}} }
          Row { visible: root.suggestedTags.length > 0; spacing: Style.spacing.xs; Repeater { model: root.suggestedTags; delegate: Button { required property string modelData; height: Style.space(30); text: "+ " + modelData; bordered: true; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: { var values=tagsField.text.split(",").map(function(v){return v.trim()}).filter(Boolean); if(values.indexOf(modelData)<0) values.push(modelData); tagsField.text=values.join(", ") } } } }
          Item {
            width: parent.width; height: Style.space(38)
            Text { textFormat: Text.PlainText; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "Enter to save"; color: Color.menu.text; opacity: 0.45; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
            Row {
              anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; spacing: Style.spacing.sm
              Button { width: Style.space(88); height: Style.space(34); text: "Cancel"; bordered: true; focusable: true; enabled: !root.formSaveRequestId; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.cancelSecondary() }
              Button { width: Style.space(88); height: Style.space(34); text: root.formSaveRequestId ? "Saving…" : root.editingBookmark ? "Save" : "Add"; bordered: true; selected: true; focusable: true; enabled: !root.formSaveRequestId && urlField.text.trim().length > 0; opacity: enabled ? 1 : 0.42; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.saveForm() }
            }
          }
        }
        Column {
          id: settingsPanel
          visible: root.mode === "settings"; width: parent.width; spacing: Style.spacing.md
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) { root.cancelSecondary(); event.accepted = true }
            else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && event.modifiers === Qt.ControlModifier) { root.saveSettings(); event.accepted = true }
            else if (event.modifiers === Qt.NoModifier && event.key === Qt.Key_Left) { root.moveSettingsFocus(-1, 0); event.accepted = true }
            else if (event.modifiers === Qt.NoModifier && event.key === Qt.Key_Right) { root.moveSettingsFocus(1, 0); event.accepted = true }
            else if (event.modifiers === Qt.NoModifier && event.key === Qt.Key_Up) { root.moveSettingsFocus(0, -1); event.accepted = true }
            else if (event.modifiers === Qt.NoModifier && event.key === Qt.Key_Down) { root.moveSettingsFocus(0, 1); event.accepted = true }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width; text: "Settings"; color: Color.menu.text
            font.family: Style.font.menuFamily; font.pixelSize: Style.font.title; font.weight: Font.DemiBold
          }

          Column {
            width: parent.width; spacing: Style.spacing.xs
            Text { textFormat: Text.PlainText; text: "Default search"; color: Color.menu.text; opacity: 0.72; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
            Row {
              spacing: Style.spacing.sm
              Button { id: settingsKeyCatcher; width: Style.space(150); height: Style.space(34); text: "Bookmarks & tags"; bordered: true; selected: root.draftSearchScope === "all"; focusable: true; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.draftSearchScope = "all" }
              Button { width: Style.space(110); height: Style.space(34); text: "Tags only"; bordered: true; selected: root.draftSearchScope === "tags"; focusable: true; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.draftSearchScope = "tags" }
            }
          }

          Column {
            width: parent.width; spacing: Style.spacing.xs
            Text { textFormat: Text.PlainText; text: "Visible results"; color: Color.menu.text; opacity: 0.72; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
            Row {
              width: parent.width
              spacing: Style.spacing.sm
              Repeater {
                model: root.maximumResultCount - 2
                delegate: Button {
                  required property int index
                  readonly property int count: index + 3
                  width: root.resultCountButtonWidth; height: Style.space(34); text: String(count); bordered: true
                  selected: root.draftResultCount === count; focusable: true
                  foreground: Color.menu.text; accent: Color.menu.selectedText
                  onClicked: root.draftResultCount = count
                }
              }
            }
          }

          Column {
            width: parent.width; spacing: Style.spacing.xs
            Text { textFormat: Text.PlainText; text: "Empty search shows"; color: Color.menu.text; opacity: 0.72; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
            Row {
              spacing: Style.spacing.sm
              Button { width: Style.space(150); height: Style.space(34); text: "Most used"; bordered: true; selected: root.draftDefaultResultOrder === "mostUsed"; focusable: true; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.draftDefaultResultOrder = "mostUsed" }
              Button { width: Style.space(150); height: Style.space(34); text: "Recently used"; bordered: true; selected: root.draftDefaultResultOrder === "recentlyUsed"; focusable: true; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.draftDefaultResultOrder = "recentlyUsed" }
            }
          }

          Column {
            width: parent.width; spacing: Style.spacing.xs
            Text { textFormat: Text.PlainText; text: "Open bookmarks"; color: Color.menu.text; opacity: 0.72; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
            Row {
              spacing: Style.spacing.sm
              Button { width: Style.space(150); height: Style.space(34); text: "In a new tab"; bordered: true; selected: !root.draftOpenInNewWindow; focusable: true; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.draftOpenInNewWindow = false }
              Button { width: Style.space(150); height: Style.space(34); text: "In a new window"; bordered: true; selected: root.draftOpenInNewWindow; focusable: true; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.draftOpenInNewWindow = true }
            }
          }

          Column {
            width: parent.width; spacing: Style.spacing.xs
            Text { textFormat: Text.PlainText; text: "Details for pasted URLs"; color: Color.menu.text; opacity: 0.72; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
            Row {
              spacing: Style.spacing.sm
              Button { width: Style.space(150); height: Style.space(34); text: "Fetch automatically"; bordered: true; selected: root.draftFetchPageDetails; focusable: true; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.draftFetchPageDetails = true }
              Button { width: Style.space(150); height: Style.space(34); text: "Never fetch"; bordered: true; selected: !root.draftFetchPageDetails; focusable: true; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.draftFetchPageDetails = false }
            }
            Text { textFormat: Text.PlainText; width: parent.width; text: "Fetching contacts the website and reveals your IP address and requested URL."; color: Color.menu.text; opacity: 0.45; wrapMode: Text.Wrap; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
          }

          Column {
            width: parent.width; spacing: Style.spacing.xs
            Text { textFormat: Text.PlainText; text: "Library"; color: Color.menu.text; opacity: 0.72; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
            Flow {
              width: parent.width; spacing: Style.spacing.sm
              Button { width: Style.space(170); height: Style.space(34); text: "Import from browser"; bordered: true; focusable: true; enabled: !root.libraryBusy; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.beginImport() }
              Button { width: Style.space(130); height: Style.space(34); text: root.libraryBusy ? "Working…" : "Back up now"; bordered: true; focusable: true; enabled: !root.libraryBusy; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.libraryRequest({type: "backup_create"}) }
              Button { width: Style.space(140); height: Style.space(34); text: "Restore backup"; bordered: true; focusable: true; enabled: !root.libraryBusy; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.beginRestore() }
              Button { width: Style.space(140); height: Style.space(34); text: "Load examples"; bordered: true; focusable: true; enabled: !root.libraryBusy; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.confirmLoadExamples() }
              Button { width: Style.space(110); height: Style.space(34); text: "Clear all"; bordered: true; focusable: true; enabled: !root.libraryBusy; foreground: Color.urgent; accent: Color.urgent; onClicked: root.confirmClearLibrary() }
            }
            Text { textFormat: Text.PlainText; width: parent.width; text: "Import, restore, clear, and examples back up your library first. Settings changes above still need Save."; color: Color.menu.text; opacity: 0.45; wrapMode: Text.Wrap; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
          }

          Item {
            width: parent.width; height: Style.space(38)
            Text { textFormat: Text.PlainText; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "Ctrl+Enter to save · Escape to cancel"; color: Color.menu.text; opacity: 0.45; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
            Row {
              anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; spacing: Style.spacing.sm
              Button { width: Style.space(88); height: Style.space(34); text: "Cancel"; bordered: true; focusable: true; enabled: !root.settingsSaveRequestId; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.cancelSecondary() }
              Button { width: Style.space(88); height: Style.space(34); text: root.settingsSaveRequestId ? "Saving…" : "Save"; bordered: true; selected: true; focusable: true; enabled: !root.settingsSaveRequestId; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.saveSettings() }
            }
          }
        }
        Column {
          id: libraryPanel
          visible: root.mode === "import" || root.mode === "restore" || root.mode === "confirmLibrary"
          width: parent.width; spacing: Style.spacing.sm
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) { root.libraryBack(); event.accepted = true }
            else if (event.key === Qt.Key_Up) { root.moveLibrarySelection(-1); event.accepted = true }
            else if (event.key === Qt.Key_Down) { root.moveLibrarySelection(1); event.accepted = true }
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.activateLibrary(); event.accepted = true }
          }
          Text {
            width: parent.width; textFormat: Text.PlainText; wrapMode: Text.Wrap
            text: root.libraryTitle()
            color: Color.menu.text; font.family: Style.font.menuFamily; font.pixelSize: Style.font.heading
          }
          Text {
            width: parent.width; textFormat: Text.PlainText; wrapMode: Text.Wrap
            text: root.libraryDetail()
            color: Color.menu.text; opacity: 0.6; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption
          }
          ListView {
            id: libraryList
            readonly property real rowHeight: Style.space(52)
            visible: (root.mode === "import" && !root.importPreview) || root.mode === "restore"
            width: parent.width; spacing: Style.spacing.xs; clip: true
            height: Math.min(count, 6) * (rowHeight + spacing)
            model: root.libraryItems; boundsBehavior: Flickable.StopAtBounds
            Controls.ScrollBar.vertical: Controls.ScrollBar {}
            delegate: Rectangle {
              required property int index; required property var modelData
              width: libraryList.width; height: libraryList.rowHeight; radius: root.contentCornerRadius
              color: index === root.libraryIndex ? Color.menu.selectedBackground : "transparent"
              MouseArea { anchors.fill: parent; hoverEnabled: true; onEntered: root.libraryIndex = index; onClicked: { root.libraryIndex = index; root.activateLibrary() } }
              Column {
                anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.spacing.md; anchors.rightMargin: Style.spacing.md; spacing: Style.spacing.xs
                Text {
                  width: parent.width; textFormat: Text.PlainText; elide: Text.ElideRight
                  text: root.mode === "import"
                    ? String(modelData.browser || "")
                    : root.formatBackupTime(Number(modelData.createdAt || 0)) + "  ·  " + root.backupReasonLabel(String(modelData.reason || ""))
                  color: index === root.libraryIndex ? Color.menu.selectedText : Color.menu.text
                  font.family: Style.font.menuFamily; font.pixelSize: Style.font.heading; font.weight: Font.Medium
                }
                Text {
                  width: parent.width; textFormat: Text.PlainText; elide: Text.ElideRight
                  text: root.mode === "import" ? String(modelData.profile || "") : root.bookmarkCount(Number(modelData.bookmarks || 0))
                  color: Color.menu.text; opacity: 0.52; font.family: Style.font.menuFamily; font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }
          Item {
            width: parent.width; height: Style.space(38)
            Text { textFormat: Text.PlainText; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: root.libraryBusy ? "Working…" : "Enter to continue · Escape to go back"; color: Color.menu.text; opacity: 0.45; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
            Row {
              anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; spacing: Style.spacing.sm
              Button { width: Style.space(88); height: Style.space(34); text: "Back"; bordered: true; focusable: true; enabled: !root.libraryBusy; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.libraryBack() }
              Button {
                visible: root.mode === "confirmLibrary" || Boolean(root.importPreview) || root.libraryItems.length > 0
                width: Style.space(120); height: Style.space(34); text: root.libraryPrimaryLabel(); bordered: true; selected: true; focusable: true
                enabled: !root.libraryBusy; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.activateLibrary()
              }
            }
          }
          Item { id: libraryKeyCatcher; width: 1; height: 1 }
        }
        Column {
          visible: root.mode === "delete"; width: parent.width; spacing: Style.spacing.md
          Text { textFormat: Text.PlainText; width: parent.width; text: "Delete “" + (root.editingBookmark ? (root.editingBookmark.title || root.domain(root.editingBookmark.originalUrl)) : "") + "”?"; color: Color.menu.text; wrapMode: Text.Wrap; font.family: Style.font.menuFamily; font.pixelSize: Style.font.heading }
          Text { textFormat: Text.PlainText; width: parent.width; text: "Enter confirms · Escape cancels"; color: Color.menu.text; opacity: 0.5; font.family: Style.font.menuFamily }
          Item { id: deleteKeyCatcher; width: 1; height: 1; Keys.onPressed: function(e){if(e.key===Qt.Key_Escape){root.cancelSecondary();e.accepted=true}else if(e.key===Qt.Key_Return||e.key===Qt.Key_Enter){root.confirmDelete();e.accepted=true}} }
        }
        Text { textFormat: Text.PlainText; visible: Boolean(root.noticeMessage) && !root.statusMessage; width: parent.width; text: root.noticeMessage; color: Color.menu.text; opacity: 0.72; wrapMode: Text.Wrap; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
        Text { textFormat: Text.PlainText; visible: Boolean(root.statusMessage || (worker.error && !worker.setupRequired)); width: parent.width; text: root.statusMessage || worker.error; color: Color.urgent; wrapMode: Text.Wrap; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
      }

    }
  }
}
