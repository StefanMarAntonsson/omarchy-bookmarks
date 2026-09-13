import QtQuick
import QtQuick.Controls as Controls
import QtQml.Models
import Quickshell
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
  property int resultCount: 5
  property bool openInNewWindow: false
  property bool fetchPageDetails: false
  property string draftSearchScope: "all"
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
  property bool previewingSelection: false
  property bool editingPreviewUrl: false
  property int openUrlRequestId: 0
  property int addUrlRequestId: 0
  property string pendingAddUrl: ""
  property string mode: "search"
  property var editingBookmark: null
  property string statusMessage: ""
  property int metadataRequestId: 0
  property bool titleEdited: false
  property bool descriptionEdited: false
  property bool applyingMetadata: false
  property var suggestedTags: []
  property bool controlHeld: false
  property bool altHeld: false
  property var browsers: []
  property int browsersRequestId: 0
  property bool browsersLoading: false
  property string browsersError: ""
  readonly property var alternateBrowsers: root.browsers.filter(function(browser) { return !browser.isDefault }).slice(0, 9)
  readonly property real menuCornerRadius: Math.max(Style.cornerRadius, Style.space(12))
  readonly property real contentCornerRadius: Math.max(1, root.menuCornerRadius - Math.max(1, Style.space(4)))
  readonly property real resultWindowHeight: Style.space(58) * root.resultCount + Style.spacing.xs * (root.resultCount - 1)
  readonly property real resultCountButtonWidth: Style.space(58)
  readonly property int maximumResultCount: Math.min(10, Math.max(3, 2 + Math.floor((contentColumn.width + Style.spacing.sm) / (root.resultCountButtonWidth + Style.spacing.sm))))
  readonly property string pluginId: (manifest && manifest.id) || "stefanmara.bookmarks"
  readonly property string workerLauncher: localPath("worker-launcher.sh")

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
  function open(payloadJson) {
    query = ""; searchField.text = ""; results = []; defaultResults = []; selectedIndex = -1; latestSearchId = 0; searchLoading = false; searchHasMore = false; noResultsState = false; pendingSelectionIndex = -1
    previewingSelection = false; editingPreviewUrl = false; openUrlRequestId = 0; addUrlRequestId = 0; pendingAddUrl = ""
    mode = "search"; searchScope = defaultSearchScope; editingBookmark = null; statusMessage = ""; controlHeld = false; altHeld = false; browsersError = ""; opened = true
    worker.start()
    requestSettings()
    performSearch()
    requestBrowsers()
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }
  function close() { opened = false; query = ""; searchField.text = ""; results = []; defaultResults = []; selectedIndex = -1; pendingSelectionIndex = -1; noResultsState = false; previewingSelection = false; editingPreviewUrl = false; openUrlRequestId = 0; addUrlRequestId = 0; pendingAddUrl = ""; mode = "search"; searchScope = defaultSearchScope; editingBookmark = null; statusMessage = ""; controlHeld = false; altHeld = false }
  function dismiss() { close(); if (shell && typeof shell.hide === "function") shell.hide(pluginId) }
  function performSearch() {
    if (!query.trim()) { noResultsState = false; results = defaultResults }
    selectedIndex = -1; pendingSelectionIndex = -1; searchHasMore = false; searchLoading = true
    latestSearchId = worker.request({type: "search", query: query, scope: searchScope, limit: resultCount, offset: 0})
  }
  function loadNextSearchPage() {
    if (!query.trim() || searchLoading || !searchHasMore) return
    searchLoading = true
    latestSearchId = worker.request({type: "search", query: query, scope: searchScope, limit: resultCount, offset: loadedBookmarkCount()})
  }
  function requestSettings() {
    var requestId = worker.request({type: "get_settings"})
    if (requestId) settingsRequestId = requestId
  }
  function applySettings(settings) {
    if (!settings) return
    defaultSearchScope = settings.defaultSearchScope === "tags" ? "tags" : "all"
    resultCount = Math.max(3, Math.min(10, Number(settings.resultCount || 5)))
    openInNewWindow = settings.openInNewWindow === true
    fetchPageDetails = settings.fetchPageDetails === true
  }
  function beginSettings() {
    draftSearchScope = defaultSearchScope
    draftResultCount = resultCount
    draftOpenInNewWindow = openInNewWindow
    draftFetchPageDetails = fetchPageDetails
    statusMessage = ""
    mode = "settings"
    Qt.callLater(function() { settingsKeyCatcher.forceActiveFocus() })
  }
  function saveSettings() {
    statusMessage = "Saving settings…"
    settingsSaveRequestId = worker.request({
      type: "save_settings",
      settings: {
        defaultSearchScope: draftSearchScope,
        resultCount: draftResultCount,
        openInNewWindow: draftOpenInNewWindow,
        fetchPageDetails: draftFetchPageDetails
      }
    })
    if (!settingsSaveRequestId) statusMessage = worker.error || "Worker is unavailable"
  }
  function requestBrowsers() {
    var requestId = worker.request({type: "browsers"})
    if (!requestId) return
    browsersRequestId = requestId
    browsersLoading = true
    browsersError = ""
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
  function activateIndex(index) {
    if (index < 0 || index >= results.length) return
    previewingSelection = false; editingPreviewUrl = false; selectedIndex = index; activateCurrent(false)
  }
  function requestOpenUrl(url, invertOpeningPreference, browserId) {
    if (openUrlRequestId) return
    statusMessage = ""
    var useNewWindow = invertOpeningPreference ? !openInNewWindow : openInNewWindow
    openUrlRequestId = worker.request({type: "open_url", url: String(url || "").trim(), new_window: browserId ? false : useNewWindow, browser_id: browserId ? String(browserId) : null})
    if (!openUrlRequestId) statusMessage = worker.error || "Worker is unavailable"
  }
  function activateCurrent(invertOpeningPreference) {
    if (editingPreviewUrl) { requestOpenUrl(searchField.text, invertOpeningPreference, null); return }
    var item = selectedResult()
    if (item) {
      if (item.action === "open_url") requestOpenUrl(item.url, invertOpeningPreference, null)
      else activateSelected(invertOpeningPreference)
      return
    }
    if (looksLikeWebUrl(searchField.text)) requestOpenUrl(searchField.text, invertOpeningPreference, null)
  }
  function activateSelected(invertOpeningPreference) {
    var item = selectedResult(); if (!item) return
    if (item.action === "open_url") { requestOpenUrl(item.url, invertOpeningPreference, null); return }
    var useNewWindow = invertOpeningPreference ? !openInNewWindow : openInNewWindow
    worker.request({type: "open", bookmark_id: item.id, new_window: useNewWindow}); dismiss()
  }
  function activateCurrentInBrowser(browserId) {
    if (editingPreviewUrl) { requestOpenUrl(searchField.text, false, browserId); return }
    var item = selectedResult()
    if (!item) {
      if (looksLikeWebUrl(searchField.text)) requestOpenUrl(searchField.text, false, browserId)
      return
    }
    if (item.action === "open_url") { requestOpenUrl(item.url, false, browserId); return }
    if (item.action) return
    worker.request({type: "open", bookmark_id: item.id, new_window: false, browser_id: String(browserId)}); dismiss()
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
    editingBookmark = null; mode = "form"; applyingMetadata = true
    urlField.text = url || ""; titleField.text = ""; descriptionField.text = ""; tagsField.text = ""
    applyingMetadata = false; titleEdited = false; descriptionEdited = false; suggestedTags = []; statusMessage = ""
    Qt.callLater(function() { (url ? titleField : urlField).forceActiveFocus() })
    if (url && fetchPageDetails) { metadataRequestId++; worker.request({type: "fetch_metadata", url: url, metadata_request_id: metadataRequestId}) }
  }
  function beginEdit() {
    var item = selectedResult(); if (!item || item.action) return
    editingBookmark = item; mode = "form"; applyingMetadata = true
    urlField.text = item.originalUrl; titleField.text = item.title; descriptionField.text = item.description || ""
    tagsField.text = (item.tags || []).join(", "); applyingMetadata = false
    titleEdited = true; descriptionEdited = true; suggestedTags = []; statusMessage = ""
    Qt.callLater(function() { titleField.forceActiveFocus(); titleField.selectAll() })
  }
  function saveForm() {
    var tags = tagsField.text.split(",").map(function(value) { return value.trim() }).filter(Boolean)
    var bookmark = {id: editingBookmark ? editingBookmark.id : "", url: urlField.text, title: titleField.text,
      description: descriptionField.text, tags: tags, keyword: editingBookmark ? (editingBookmark.keyword || "") : ""}
    if (!worker.request({type: editingBookmark ? "edit" : "add", bookmark: bookmark})) statusMessage = worker.error || "Worker is unavailable"
  }
  function cancelSecondary() { mode = "search"; editingBookmark = null; statusMessage = ""; Qt.callLater(function() { searchField.forceActiveFocus() }) }
  function requestDelete() { var item = selectedResult(); if (item && !item.action) { editingBookmark = item; mode = "delete"; Qt.callLater(function(){ deleteKeyCatcher.forceActiveFocus() }) } }
  function domain(url) { var match = String(url || "").match(/^https?:\/\/([^/]+)(\/.*)?$/i); return match ? match[1] + ((match[2] && match[2] !== "/") ? match[2] : "") : String(url || "") }
  function handleMessage(response) {
    if (!response.ok) {
      if (openUrlRequestId && response.id === openUrlRequestId) { openUrlRequestId = 0; statusMessage = String(response.error || "Could not open URL"); return }
      if (addUrlRequestId && response.id === addUrlRequestId) { addUrlRequestId = 0; pendingAddUrl = ""; statusMessage = String(response.error || "Enter a valid HTTP or HTTPS URL"); return }
      if (response.id === settingsRequestId || response.id === settingsSaveRequestId) { statusMessage = String(response.error || "Could not load settings"); return }
      if (response.id === browsersRequestId) { browsersLoading = false; browsersError = String(response.error || "Could not find browsers"); return }
      if (response.id === latestSearchId) { searchLoading = false; results = []; noResultsState = false }
      statusMessage = String(response.error || "Bookmark operation failed"); return
    }
    var result = response.result || {}
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
      applySettings(result.settings)
      if (mode === "settings") {
        draftSearchScope = defaultSearchScope
        draftResultCount = resultCount
        draftOpenInNewWindow = openInNewWindow
        draftFetchPageDetails = fetchPageDetails
      }
      if (mode === "search") {
        searchScope = defaultSearchScope
        if (previousScope !== searchScope || previousCount !== resultCount) performSearch()
      }
      return
    }
    if (response.id === settingsSaveRequestId) {
      applySettings(result.settings)
      searchScope = defaultSearchScope
      mode = "search"
      statusMessage = ""
      restoreSearchQuery()
      performSearch()
      Qt.callLater(function() { searchField.forceActiveFocus() })
      return
    }
    if (response.id === browsersRequestId) {
      browsers = Array.isArray(result.browsers) ? result.browsers : []
      browsersLoading = false; browsersError = ""; return
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
    if (result.metadataRequestId !== undefined) {
      if (Number(result.metadataRequestId) !== metadataRequestId || mode !== "form") return
      applyingMetadata = true
      if (!titleEdited && result.metadata && result.metadata.title) titleField.text = result.metadata.title
      if (!descriptionEdited && result.metadata && result.metadata.description) descriptionField.text = result.metadata.description
      applyingMetadata = false; worker.request({type: "suggest_tags", text: titleField.text + " " + descriptionField.text}); return
    }
    if (Array.isArray(result.tags) && mode === "form") { suggestedTags = result.tags.slice(0, 4); return }
    if (result.bookmark && mode === "form") { previewingSelection = false; editingPreviewUrl = false; cancelSecondary(); query = result.bookmark.title || result.bookmark.originalUrl; searchField.text = query; searchDebounce.restart(); return }
    if (result.deleted) { mode = "search"; editingBookmark = null; restoreSearchQuery(); performSearch() }
  }

  component ResultShortcutContent: Item {
    property var controller

    Row {
      id: bookmarkActions
      visible: !controller.altHeld
      anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.md

      Repeater {
        model: [
          {key: "Ctrl+T", label: controller.openInNewWindow ? "Open in new tab" : "Open in new window"},
          {key: "Ctrl+C", label: "Copy URL"},
          {key: "Ctrl+E", label: "Edit"}
        ]
        delegate: Column {
          required property var modelData
          width: (bookmarkActions.width - bookmarkActions.spacing * 2) / 3
          spacing: Style.spacing.xs
          Text {
            width: parent.width; text: modelData.key; color: Color.menu.selectedText
            font.family: Style.font.menuFamily; font.pixelSize: Style.font.heading; font.weight: Font.Medium
            elide: Text.ElideRight
          }
          Text {
            width: parent.width; text: modelData.label; color: Color.menu.selectedText; opacity: 0.72
            font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }

    Row {
      id: browserActions
      visible: controller.altHeld && controller.alternateBrowsers.length > 0
      anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.md

      Repeater {
        model: controller.alternateBrowsers
        delegate: Column {
          required property int index
          required property var modelData
          width: (browserActions.width - browserActions.spacing * (controller.alternateBrowsers.length - 1)) / controller.alternateBrowsers.length
          spacing: Style.spacing.xs
          Text {
            width: parent.width; text: "Ctrl+Alt+" + (index + 1); color: Color.menu.selectedText
            font.family: Style.font.menuFamily; font.pixelSize: Style.font.heading; font.weight: Font.Medium
            elide: Text.ElideRight
          }
          Text {
            width: parent.width; text: modelData.name; textFormat: Text.PlainText
            color: Color.menu.selectedText; opacity: 0.72
            font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }

    Text {
      visible: controller.altHeld && controller.alternateBrowsers.length === 0
      anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
      text: controller.browsersLoading ? "Finding alternate browsers…" : controller.browsersError ? controller.browsersError : "No alternate browsers configured"
      color: controller.browsersError ? Color.urgent : Color.menu.selectedText
      opacity: controller.browsersError ? 1 : 0.72
      font.family: Style.font.menuFamily; font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }

  component HighlightedText: Item {
    id: highlightedText
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
    Row {
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

  WorkerClient {
    id: worker
    launcherPath: root.workerLauncher
    onReadyChanged: if (ready && root.opened) { root.requestSettings(); root.performSearch(); root.requestBrowsers() }
    onMessage: function(response) { root.handleMessage(response) }
  }
  Timer { id: searchDebounce; interval: 35; repeat: false; onTriggered: root.performSearch() }

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

      Instantiator {
        model: root.alternateBrowsers
        delegate: Shortcut {
          required property int index
          required property var modelData
          sequence: "Ctrl+Alt+" + String(index + 1)
          enabled: root.opened && root.mode === "search" && index < 9
          autoRepeat: false
          onActivated: root.activateCurrentInBrowser(modelData.id)
        }
      }

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
          placeholderText: root.controlHeld && !root.altHeld && text.length === 0 ? "" : root.searchScope === "tags" ? "Search tags" : "Search bookmarks"; font.family: Style.font.menuFamily; font.pixelSize: Style.font.heading
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
            visible: root.controlHeld && !root.altHeld && searchField.text.length === 0
            anchors.centerIn: parent
            text: "Ctrl+N   Add bookmark     Ctrl+S   Settings"
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
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.activateCurrent(false); event.accepted = true }
            else if (event.modifiers === Qt.ControlModifier && directSlot >= 0 && directSlot < root.resultCount) { root.activateIndex(root.shortcutIndex(directSlot)); event.accepted = true }
            else if (event.key === Qt.Key_N && event.modifiers === Qt.ControlModifier) { root.requestAddCurrentUrl(); event.accepted = true }
            else if (event.key === Qt.Key_S && event.modifiers === Qt.ControlModifier) { root.beginSettings(); event.accepted = true }
            else if (event.key === Qt.Key_E && event.modifiers === Qt.ControlModifier) { root.beginEdit(); event.accepted = true }
            else if (event.key === Qt.Key_T && event.modifiers === Qt.ControlModifier) { root.activateCurrent(true); event.accepted = true }
            else if (event.key === Qt.Key_C && event.modifiers === Qt.ControlModifier && !root.editingPreviewUrl && root.selectedResult() && !root.selectedResult().action) { worker.request({type:"copy",bookmark_id:root.selectedResult().id}); event.accepted=true }
            else if (event.key === Qt.Key_D && event.modifiers === Qt.ControlModifier) { root.requestDelete(); event.accepted = true }
          }
          Keys.onReleased: function(event) { root.updateModifierState(event, false) }
        }
        Column {
          id: topBookmarks
          visible: root.mode === "search" && root.query.trim().length === 0
          width: parent.width; height: root.resultWindowHeight; spacing: Style.spacing.xs
          Repeater {
            model: root.results
            delegate: Rectangle {
              required property int index; required property var modelData
              readonly property bool showingShortcuts: root.controlHeld && index === root.selectedIndex && !modelData.action
              width: topBookmarks.width; height: Style.space(58); radius: root.contentCornerRadius
              color: index === root.selectedIndex ? Color.menu.selectedBackground : "transparent"
              MouseArea { anchors.fill: parent; hoverEnabled: true; onEntered: root.selectedIndex = index; onClicked: root.activateIndex(index) }
              Text { id: topShortcutHint; anchors.right: parent.right; anchors.rightMargin: Style.spacing.md; anchors.verticalCenter: parent.verticalCenter; visible: root.controlHeld; text: "Ctrl+" + root.resultShortcutKey(index); color: index === root.selectedIndex ? Color.menu.selectedText : Color.menu.text; opacity: 0.55; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
              Column {
                visible: !parent.showingShortcuts
                anchors.left: parent.left; anchors.right: topShortcutHint.visible ? topShortcutHint.left : parent.right; anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.spacing.md; anchors.rightMargin: Style.spacing.md; spacing: Style.spacing.xs
                Text { width: parent.width; text: modelData.title || root.domain(modelData.originalUrl); textFormat: Text.PlainText; elide: Text.ElideRight; color: index === root.selectedIndex ? Color.menu.selectedText : Color.menu.text; font.family: Style.font.menuFamily; font.pixelSize: Style.font.heading; font.weight: Font.Medium }
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
          visible: root.mode === "search" && root.query.trim().length > 0; width: parent.width; spacing: Style.spacing.xs
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
              MouseArea { anchors.fill: parent; hoverEnabled: true; onEntered: if (!root.editingPreviewUrl) root.previewSelection(index); onClicked: root.activateIndex(index) }
              Text { id: shortcutHint; anchors.right: parent.right; anchors.rightMargin: Style.spacing.md; anchors.verticalCenter: parent.verticalCenter; visible: root.controlHeld && index >= searchResults.visibleStartIndex && index < searchResults.visibleStartIndex + root.resultCount; text: "Ctrl+" + root.resultShortcutKey(index - searchResults.visibleStartIndex); color: index === root.selectedIndex ? Color.menu.selectedText : Color.menu.text; opacity: 0.55; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
              Column {
                visible: !parent.showingShortcuts
                anchors.left: parent.left; anchors.right: shortcutHint.visible ? shortcutHint.left : parent.right; anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.spacing.md; anchors.rightMargin: Style.spacing.md; spacing: Style.spacing.xs
                HighlightedText {
                  width: parent.width
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
          Text { visible: root.noResultsState && !worker.error; width: parent.width; height: Style.space(44); text: "No matching bookmarks"; color: Color.menu.text; opacity: 0.55; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.family: Style.font.menuFamily }
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
          Row { visible: root.suggestedTags.length > 0; spacing: Style.spacing.xs; Repeater { model: root.suggestedTags; delegate: Controls.Button { required property string modelData; text: "+ " + modelData; onClicked: { var values=tagsField.text.split(",").map(function(v){return v.trim()}).filter(Boolean); if(values.indexOf(modelData)<0) values.push(modelData); tagsField.text=values.join(", ") } } } }
          Item {
            width: parent.width; height: Style.space(38)
            Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "Enter to save"; color: Color.menu.text; opacity: 0.45; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
            Row {
              anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; spacing: Style.spacing.sm
              Button { width: Style.space(88); height: Style.space(34); text: "Cancel"; bordered: true; focusable: true; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.cancelSecondary() }
              Button { width: Style.space(88); height: Style.space(34); text: root.editingBookmark ? "Save" : "Add"; bordered: true; selected: true; focusable: true; enabled: urlField.text.trim().length > 0; opacity: enabled ? 1 : 0.42; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.saveForm() }
            }
          }
        }
        Column {
          visible: root.mode === "settings"; width: parent.width; spacing: Style.spacing.md
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) { root.cancelSecondary(); event.accepted = true }
            else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && event.modifiers === Qt.ControlModifier) { root.saveSettings(); event.accepted = true }
          }

          Text {
            width: parent.width; text: "Settings"; color: Color.menu.text
            font.family: Style.font.menuFamily; font.pixelSize: Style.font.title; font.weight: Font.DemiBold
          }

          Column {
            width: parent.width; spacing: Style.spacing.xs
            Text { text: "Default search"; color: Color.menu.text; opacity: 0.72; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
            Row {
              spacing: Style.spacing.sm
              Button { id: settingsKeyCatcher; width: Style.space(150); height: Style.space(34); text: "Bookmarks & tags"; bordered: true; selected: root.draftSearchScope === "all"; focusable: true; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.draftSearchScope = "all" }
              Button { width: Style.space(110); height: Style.space(34); text: "Tags only"; bordered: true; selected: root.draftSearchScope === "tags"; focusable: true; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.draftSearchScope = "tags" }
            }
          }

          Column {
            width: parent.width; spacing: Style.spacing.xs
            Text { text: "Visible results"; color: Color.menu.text; opacity: 0.72; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
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
            Text { text: "Open bookmarks"; color: Color.menu.text; opacity: 0.72; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
            Row {
              spacing: Style.spacing.sm
              Button { width: Style.space(150); height: Style.space(34); text: "In a new tab"; bordered: true; selected: !root.draftOpenInNewWindow; focusable: true; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.draftOpenInNewWindow = false }
              Button { width: Style.space(150); height: Style.space(34); text: "In a new window"; bordered: true; selected: root.draftOpenInNewWindow; focusable: true; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.draftOpenInNewWindow = true }
            }
          }

          Column {
            width: parent.width; spacing: Style.spacing.xs
            Text { text: "Details for pasted URLs"; color: Color.menu.text; opacity: 0.72; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
            Row {
              spacing: Style.spacing.sm
              Button { width: Style.space(150); height: Style.space(34); text: "Fetch automatically"; bordered: true; selected: root.draftFetchPageDetails; focusable: true; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.draftFetchPageDetails = true }
              Button { width: Style.space(150); height: Style.space(34); text: "Never fetch"; bordered: true; selected: !root.draftFetchPageDetails; focusable: true; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.draftFetchPageDetails = false }
            }
            Text { width: parent.width; text: "Fetching contacts the website and reveals your IP address and requested URL."; color: Color.menu.text; opacity: 0.45; wrapMode: Text.Wrap; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
          }

          Item {
            width: parent.width; height: Style.space(38)
            Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "Ctrl+Enter to save · Escape to cancel"; color: Color.menu.text; opacity: 0.45; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
            Row {
              anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; spacing: Style.spacing.sm
              Button { width: Style.space(88); height: Style.space(34); text: "Cancel"; bordered: true; focusable: true; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.cancelSecondary() }
              Button { width: Style.space(88); height: Style.space(34); text: "Save"; bordered: true; selected: true; focusable: true; foreground: Color.menu.text; accent: Color.menu.selectedText; onClicked: root.saveSettings() }
            }
          }
        }
        Column {
          visible: root.mode === "delete"; width: parent.width; spacing: Style.spacing.md
          Text { width: parent.width; text: "Delete “" + (root.editingBookmark ? (root.editingBookmark.title || root.domain(root.editingBookmark.originalUrl)) : "") + "”?"; color: Color.menu.text; wrapMode: Text.Wrap; font.family: Style.font.menuFamily; font.pixelSize: Style.font.heading }
          Text { width: parent.width; text: "Enter confirms · Escape cancels"; color: Color.menu.text; opacity: 0.5; font.family: Style.font.menuFamily }
          Item { id: deleteKeyCatcher; width: 1; height: 1; Keys.onPressed: function(e){if(e.key===Qt.Key_Escape){root.cancelSecondary();e.accepted=true}else if(e.key===Qt.Key_Return||e.key===Qt.Key_Enter){worker.request({type:"delete",bookmark_id:root.editingBookmark.id});e.accepted=true}} }
        }
        Text { visible: Boolean(root.statusMessage || worker.error); width: parent.width; text: root.statusMessage || worker.error; color: Color.urgent; wrapMode: Text.Wrap; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption }
      }

    }
  }
}
