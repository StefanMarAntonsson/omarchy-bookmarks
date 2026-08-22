import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  readonly property string dataHome: {
    var configured = String(Quickshell.env("XDG_DATA_HOME") || "")
    return configured.charAt(0) === "/"
      ? configured
      : Quickshell.env("HOME") + "/.local/share"
  }
  readonly property string dataDir:
    root.dataHome + "/stefanmara.bookmarks"
  readonly property string dataPath:
    root.dataDir + "/bookmarks.json"
  readonly property string menuExtensionPath:
    Quickshell.env("HOME") + "/.config/omarchy/extensions/omarchy-menu.jsonc"
  readonly property string initializerPath:
    root.localPath("bookmark_store_init.sh")
  readonly property real usageHalfLifeDays: 30
  readonly property int usageBatchSize: 5
  readonly property int maxStoreBytes: 64 * 1024 * 1024
  readonly property int maxStoreResponseCharacters: maxStoreBytes * 2 + 1024 * 1024
  readonly property int maxBookmarks: 50000
  readonly property int maxTitleLength: 2048
  readonly property int maxUrlLength: 8192
  readonly property int maxIdLength: 256
  readonly property int maxTags: 64
  readonly property int maxTagLength: 128
  readonly property int maxKeywordLength: 128

  property var bookmarks: []
  property bool loaded: false
  property bool saving: false
  property bool storageReady: false
  property bool recoveryRequired: false
  property bool persistenceBlocked: false
  property string error: ""
  property var saveQueue: []
  property var activeSave: null
  property int pendingUsageOpens: 0
  property bool storeLoadResponseReceived: false
  property bool reloadPending: false
  property bool initializePending: false
  property bool storeLoadAttemptActive: false
  property bool storeSaveAttemptActive: false
  property bool backupAttemptActive: false
  property string initializeFailureDetail: ""
  property var storeSaveResponse: null
  property var backupResponse: null

  readonly property bool canMutate:
    root.storageReady
    && root.loaded
    && !root.recoveryRequired
    && !root.persistenceBlocked

  signal saveFinished(bool backupCreated)

  function localPath(relativePath) {
    var value = String(Qt.resolvedUrl(relativePath))
    return value.indexOf("file://") === 0
      ? decodeURIComponent(value.substring(7))
      : value
  }

  function validIpv4Address(value) {
    var parts = String(value || "").split(".")
    if (parts.length !== 4)
      return false
    for (var index = 0; index < parts.length; index++) {
      if (!parts[index] || !/^\d+$/.test(parts[index]))
        return false
      var number = Number(parts[index])
      if (!isFinite(number) || number < 0 || number > 255)
        return false
    }
    return true
  }

  function validIpv6Address(value) {
    var address = String(value || "")
    var zoneIndex = address.indexOf("%")
    if (zoneIndex !== -1) {
      var zone = address.substring(zoneIndex + 1)
      if (!zone || !/^[A-Za-z0-9._~-]+$/.test(zone))
        return false
      address = address.substring(0, zoneIndex)
    }
    if (!address || address.indexOf(":::") !== -1)
      return false

    var dottedIndex = address.lastIndexOf(":")
    if (address.indexOf(".") !== -1) {
      if (dottedIndex < 0
          || !root.validIpv4Address(address.substring(dottedIndex + 1))) {
        return false
      }
      address = address.substring(0, dottedIndex) + ":0:0"
    }

    var compressionIndex = address.indexOf("::")
    if (compressionIndex !== -1
        && address.indexOf("::", compressionIndex + 2) !== -1) {
      return false
    }
    if ((address.charAt(0) === ":" && address.indexOf("::") !== 0)
        || (address.charAt(address.length - 1) === ":"
            && address.lastIndexOf("::") !== address.length - 2)) {
      return false
    }

    var groups = address.split(":")
    var groupCount = 0
    for (var index = 0; index < groups.length; index++) {
      if (!groups[index])
        continue
      if (!/^[0-9A-Fa-f]{1,4}$/.test(groups[index]))
        return false
      groupCount++
    }
    return compressionIndex !== -1 ? groupCount < 8 : groupCount === 8
  }

  function normalizeUrl(value) {
    var url = String(value || "").trim()
    if (url.length > root.maxUrlLength)
      return ""
    if (url && !/^[A-Za-z][A-Za-z0-9+.-]*:/.test(url))
      url = "https://" + url
    if (url.length > root.maxUrlLength)
      return ""
    var match = url.match(/^(https?):\/\/([^\/?#\s]+)([\s\S]*)$/i)
    if (!match || match[2].indexOf("@") !== -1 || /\s/.test(url))
      return ""

    var authority = match[2]
    var host = authority
    var port = ""
    if (authority.charAt(0) === "[") {
      var closeBracket = authority.indexOf("]")
      if (closeBracket < 2)
        return ""
      host = authority.substring(1, closeBracket)
      var suffix = authority.substring(closeBracket + 1)
      if (!root.validIpv6Address(host))
        return ""
      if (suffix) {
        if (suffix.charAt(0) !== ":")
          return ""
        port = suffix.substring(1)
      }
    } else {
      if (authority.indexOf("[") !== -1 || authority.indexOf("]") !== -1)
        return ""
      var colon = authority.lastIndexOf(":")
      if (colon !== -1) {
        if (authority.indexOf(":") !== colon)
          return ""
        host = authority.substring(0, colon)
        port = authority.substring(colon + 1)
      }
      var comparableHost = host.charAt(host.length - 1) === "."
        ? host.substring(0, host.length - 1)
        : host
      if (!comparableHost
          || comparableHost.length > 253
          || comparableHost.indexOf("..") !== -1
          || /[\[\]<>\\^`{|}]/.test(comparableHost)) {
        return ""
      }
      if (/^[0-9.]+$/.test(comparableHost) && comparableHost.indexOf(".") !== -1) {
        if (!root.validIpv4Address(comparableHost))
          return ""
      }
      var labels = comparableHost.split(".")
      for (var labelIndex = 0; labelIndex < labels.length; labelIndex++) {
        if (!labels[labelIndex]
            || labels[labelIndex].length > 63
            || labels[labelIndex].charAt(0) === "-"
            || labels[labelIndex].charAt(labels[labelIndex].length - 1) === "-") {
          return ""
        }
      }
    }
    if (port) {
      if (!/^\d+$/.test(port))
        return ""
      var portNumber = Number(port)
      if (!isFinite(portNumber) || portNumber < 0 || portNumber > 65535)
        return ""
    } else if (authority.charAt(authority.length - 1) === ":") {
      return ""
    }
    return url
  }

  function canonicalUrl(value) {
    var url = root.normalizeUrl(value)
    var match = url.match(/^(https?):\/\/([^\/?#]+)([\s\S]*)$/i)
    if (!match)
      return ""
    var scheme = match[1].toLowerCase()
    var authority = match[2].toLowerCase()
    var rest = match[3]
    if ((scheme === "http" && /:80$/.test(authority))
        || (scheme === "https" && /:443$/.test(authority)))
      authority = authority.replace(/:(80|443)$/, "")
    if (!rest || rest.charAt(0) === "?" || rest.charAt(0) === "#")
      rest = "/" + rest
    return scheme + "://" + authority + rest
  }

  function urlOrigin(value) {
    var url = root.normalizeUrl(value)
    var match = url.match(/^(https?):\/\/([^\/?#]+)/i)
    if (!match)
      return ""
    var scheme = match[1].toLowerCase()
    var authority = match[2].toLowerCase()
    if ((scheme === "http" && /:80$/.test(authority))
        || (scheme === "https" && /:443$/.test(authority))) {
      authority = authority.replace(/:(80|443)$/, "")
    }
    return scheme + "://" + authority
  }

  function normalizeTags(value) {
    var source = Array.isArray(value) ? value : String(value || "").split(",")
    var tags = []
    var seen = ({})
    for (var i = 0; i < source.length && tags.length < root.maxTags; i++) {
      var tag = String(source[i]).trim()
      var key = "tag:" + tag.toLowerCase()
      if (tag && tag.length <= root.maxTagLength && !seen[key]) {
        tags.push(tag)
        seen[key] = true
      }
    }
    return tags
  }

  function mergeTags(first, second) {
    return root.normalizeTags(root.normalizeTags(first).concat(root.normalizeTags(second)))
  }

  function normalizeKeyword(value) {
    var keyword = String(value || "").trim()
    return keyword
      && keyword.length <= root.maxKeywordLength
      && !/\s/.test(keyword)
        ? keyword
        : ""
  }

  function normalizeFavicon(value) {
    var favicon = String(value || "")
    if (favicon.length > 140000 || !/^data:image\/png;base64,[A-Za-z0-9+/]+=*$/.test(favicon))
      return ""
    return favicon
  }

  function normalizeUsageScore(value) {
    var score = Number(value || 0)
    return isFinite(score) && score >= 0 ? score : 0
  }

  function normalizeLastOpenedAt(value) {
    var timestamp = Math.floor(Number(value || 0))
    return isFinite(timestamp) && timestamp > 0 ? timestamp : 0
  }

  function usageScoreAt(bookmark, timestamp) {
    var score = root.normalizeUsageScore(bookmark && bookmark.usageScore)
    var lastOpenedAt = root.normalizeLastOpenedAt(bookmark && bookmark.lastOpenedAt)
    var now = root.normalizeLastOpenedAt(timestamp) || Date.now()
    if (!score || !lastOpenedAt || now <= lastOpenedAt)
      return score
    var elapsedDays = (now - lastOpenedAt) / 86400000
    return score * Math.pow(0.5, elapsedDays / root.usageHalfLifeDays)
  }

  function normalizedBookmark(item, keepId) {
    if (!item || typeof item !== "object")
      return null
    var identifier = String(item.id || "")
    var title = String(item.title || "").trim()
    var keyword = String(item.keyword || "").trim()
    var rawTags = Array.isArray(item.tags)
      ? item.tags
      : String(item.tags || "").split(",")
    if ((keepId && (!identifier || identifier.length > root.maxIdLength))
        || title.length > root.maxTitleLength
        || keyword.length > root.maxKeywordLength
        || rawTags.length > root.maxTags) {
      return null
    }
    for (var tagIndex = 0; tagIndex < rawTags.length; tagIndex++) {
      if (String(rawTags[tagIndex]).trim().length > root.maxTagLength)
        return null
    }
    var url = root.normalizeUrl(item.url)
    if (!url)
      return null
    return {
      id: keepId ? identifier : root.newId(),
      title: title,
      url: url,
      tags: root.normalizeTags(item.tags),
      keyword: root.normalizeKeyword(item.keyword),
      favicon: root.normalizeFavicon(item.favicon),
      usageScore: root.normalizeUsageScore(item.usageScore),
      lastOpenedAt: root.normalizeLastOpenedAt(item.lastOpenedAt)
    }
  }

  function newId() {
    return Date.now().toString(36) + "-" + Math.floor(Math.random() * 16777216).toString(36)
  }

  function utf8ByteLength(value, stopAfter) {
    var text = String(value || "")
    var bytes = 0
    for (var index = 0; index < text.length; index++) {
      var code = text.charCodeAt(index)
      if (code < 0x80) {
        bytes++
      } else if (code < 0x800) {
        bytes += 2
      } else if (code >= 0xD800 && code <= 0xDBFF
                 && index + 1 < text.length
                 && text.charCodeAt(index + 1) >= 0xDC00
                 && text.charCodeAt(index + 1) <= 0xDFFF) {
        bytes += 4
        index++
      } else {
        bytes += 3
      }
      if (stopAfter && bytes > stopAfter)
        return bytes
    }
    return bytes
  }

  function applyParsedData(data, preliminaryInvalid) {
    var source
    if (Array.isArray(data)) {
      source = data
    } else if (data && typeof data === "object" && Array.isArray(data.bookmarks)) {
      source = data.bookmarks
      if (Number(data.version || 0) > 3)
        throw new Error("bookmarks.json uses a newer data format")
    } else {
      throw new Error("bookmarks.json must contain a bookmarks array")
    }
    if (source.length > root.maxBookmarks)
      throw new Error("bookmarks.json contains too many entries")

    var result = []
    var invalid = Math.max(0, Number(preliminaryInvalid || 0))
    var seenIds = ({})
    for (var i = 0; i < source.length; i++) {
      var item = root.normalizedBookmark(source[i], true)
      if (!item) {
        invalid++
        continue
      }
      var idKey = "id:" + item.id
      if (seenIds[idKey]) {
        invalid++
        continue
      }
      seenIds[idKey] = true
      result.push(item)
    }
    root.bookmarks = result
    root.persistenceBlocked = false
    if (invalid) {
      root.recoveryRequired = true
      root.error = "bookmarks.json contains " + invalid
        + " invalid or duplicate " + (invalid === 1 ? "entry" : "entries")
        + " · writes are disabled to protect the file"
    } else {
      root.recoveryRequired = false
      root.error = ""
    }
    root.loaded = true
  }

  function failLoad(exception) {
    root.bookmarks = []
    root.recoveryRequired = true
    root.persistenceBlocked = false
    root.error = "Could not read bookmarks.json · writes are disabled to protect the file"
    root.loaded = true
    console.warn("Bookmarks:", exception)
  }

  function parse(raw) {
    usageSaveTimer.stop()
    root.pendingUsageOpens = 0
    try {
      var text = String(raw || "")
      if (root.utf8ByteLength(text, root.maxStoreBytes) > root.maxStoreBytes)
        throw new Error("bookmarks.json is too large")
      root.applyParsedData(JSON.parse(text), 0)
    } catch (exception) {
      root.failLoad(exception)
    }
  }

  function reload() {
    if (!root.storageReady)
      return
    if (storeLoadProcess.running) {
      root.reloadPending = true
      return
    }
    root.reloadPending = false
    storeLoadProcess.command = [
      "python3", root.localPath("bookmark_helper.py"),
      "store-load", root.dataPath
    ]
    root.storeLoadResponseReceived = false
    root.storeLoadAttemptActive = true
    storeLoadProcess.running = true
  }

  function requestReload() {
    reloadDebounce.restart()
  }

  function parseSmallHelperResponse(data) {
    var output = String(data || "")
    if (output.length > 64 * 1024)
      throw new Error("Helper returned too much data")
    return JSON.parse(output)
  }

  function handleStoreLoadResponse(data) {
    root.storeLoadResponseReceived = true
    usageSaveTimer.stop()
    root.pendingUsageOpens = 0
    try {
      var output = String(data || "")
      if (output.length > root.maxStoreResponseCharacters)
        throw new Error("Bounded store reader returned too much data")
      var result = JSON.parse(output)
      if (!result.ok || !result.data)
        throw new Error(String(result.error || "Could not read bookmarks.json"))
      root.applyParsedData(result.data, result.invalid)
    } catch (exception) {
      root.failLoad(exception)
    }
  }

  function finishStoreLoadAttempt() {
    if (!root.storeLoadAttemptActive)
      return
    root.storeLoadAttemptActive = false
    if (!root.storeLoadResponseReceived)
      root.failLoad("Bounded store reader did not return a response")
    if (root.reloadPending) {
      root.reloadPending = false
      reloadDebounce.restart()
    }
  }

  function save(next, createBackup) {
    if (!root.canMutate)
      return false

    usageSaveTimer.stop()
    root.pendingUsageOpens = 0
    if (!Array.isArray(next) || next.length > root.maxBookmarks)
      return false
    var contents = JSON.stringify({version: 3, bookmarks: next}, null, 2) + "\n"
    if (root.utf8ByteLength(contents, root.maxStoreBytes) > root.maxStoreBytes) {
      root.error = "Bookmark data is too large to save"
      return false
    }
    root.bookmarks = next
    root.error = ""
    var request = {
      contents: contents,
      createBackup: Boolean(createBackup)
    }
    var queue = root.saveQueue.slice()
    if (!request.createBackup
        && queue.length
        && !queue[queue.length - 1].createBackup) {
      queue[queue.length - 1] = request
    } else {
      queue.push(request)
    }
    root.saveQueue = queue
    root.saving = true
    root.startNextSave()
    return true
  }

  function startNextSave() {
    if (root.activeSave !== null)
      return
    if (!root.saveQueue.length) {
      root.saving = false
      return
    }

    var queue = root.saveQueue.slice()
    root.activeSave = queue.shift()
    root.saveQueue = queue
    if (root.activeSave.createBackup) {
      backupProcess.command = [
        "python3", root.localPath("bookmark_helper.py"),
        "backup", root.dataPath
      ]
      root.backupAttemptActive = true
      backupProcess.running = true
    } else {
      root.writeActiveSave()
    }
  }

  function writeActiveSave() {
    if (root.activeSave === null)
      return
    storeSaveProcess.stdinEnabled = true
    storeSaveProcess.command = [
      "python3", root.localPath("bookmark_helper.py"),
      "store-save", root.dataPath
    ]
    root.storeSaveAttemptActive = true
    storeSaveProcess.running = true
  }

  function finishActiveSave(success, message) {
    if (root.activeSave === null)
      return
    var completed = root.activeSave
    root.activeSave = null
    if (!success) {
      root.saveQueue = []
      root.saving = false
      root.persistenceBlocked = true
      root.error = message || "Could not save bookmarks.json · writes are disabled"
      return
    }
    root.saveFinished(Boolean(completed.createBackup))
    root.startNextSave()
  }

  function addBookmark(title, url, tags, keyword, favicon) {
    if (!root.canMutate)
      return ""
    var item = root.normalizedBookmark({
      title: title, url: url, tags: tags, keyword: keyword, favicon: favicon
    }, false)
    if (!item)
      return ""
    var next = root.bookmarks.slice()
    next.unshift(item)
    return root.save(next, false) ? item.id : ""
  }

  function updateBookmark(id, title, url, tags, keyword) {
    if (!root.canMutate)
      return false
    var next = []
    var updated = false
    for (var i = 0; i < root.bookmarks.length; i++) {
      var current = root.bookmarks[i]
      if (current.id === id) {
        var item = root.normalizedBookmark({
          id: current.id, title: title, url: url, tags: tags,
          keyword: keyword,
          favicon: root.urlOrigin(current.url) === root.urlOrigin(url)
            ? current.favicon
            : "",
          usageScore: current.usageScore,
          lastOpenedAt: current.lastOpenedAt
        }, true)
        if (!item)
          return false
        next.push(item)
        updated = true
      } else {
        next.push(current)
      }
    }
    return updated ? root.save(next, false) : false
  }

  function removeBookmark(id) {
    if (!root.canMutate)
      return false
    var next = []
    var removed = false
    for (var i = 0; i < root.bookmarks.length; i++) {
      if (root.bookmarks[i].id !== id)
        next.push(root.bookmarks[i])
      else
        removed = true
    }
    return removed ? root.save(next, false) : false
  }

  function findByUrl(url) {
    var key = root.canonicalUrl(url)
    for (var i = 0; i < root.bookmarks.length; i++) {
      if (root.canonicalUrl(root.bookmarks[i].url) === key)
        return root.bookmarks[i]
    }
    return null
  }

  function recordOpen(id) {
    if (!root.canMutate)
      return false
    var now = Date.now()
    var next = []
    var recorded = false
    for (var i = 0; i < root.bookmarks.length; i++) {
      var current = root.bookmarks[i]
      if (current.id === id) {
        next.push({
          id: current.id,
          title: current.title,
          url: current.url,
          tags: current.tags,
          keyword: current.keyword,
          favicon: current.favicon,
          usageScore: root.usageScoreAt(current, now) + 1,
          lastOpenedAt: now
        })
        recorded = true
      } else {
        next.push(current)
      }
    }
    if (!recorded)
      return false

    root.bookmarks = next
    root.pendingUsageOpens++
    if (root.pendingUsageOpens >= root.usageBatchSize)
      return root.save(next, false)
    if (!usageSaveTimer.running)
      usageSaveTimer.start()
    return true
  }

  function flushUsage() {
    if (!root.pendingUsageOpens)
      return true
    return root.save(root.bookmarks, false)
  }

  function importBookmarks(items) {
    if (!root.canMutate || !Array.isArray(items) || items.length > root.maxBookmarks)
      return {added: 0, updated: 0, unchanged: 0, blocked: true}
    var next = root.bookmarks.slice()
    var positions = ({})
    var added = 0
    var updated = 0
    var unchanged = 0
    for (var i = 0; i < next.length; i++)
      positions["url:" + root.canonicalUrl(next[i].url)] = i

    for (var j = 0; j < items.length; j++) {
      var incoming = root.normalizedBookmark(items[j], false)
      if (!incoming)
        continue
      var key = "url:" + root.canonicalUrl(incoming.url)
      var position = positions[key]
      if (position === undefined) {
        positions[key] = next.length
        next.push(incoming)
        added++
        continue
      }
      var current = next[position]
      var mergedTitle = current.title || incoming.title
      var mergedTags = root.mergeTags(current.tags, incoming.tags)
      var mergedKeyword = current.keyword || incoming.keyword
      var mergedFavicon = current.favicon || incoming.favicon
      if (mergedTitle !== current.title
          || JSON.stringify(mergedTags) !== JSON.stringify(current.tags)
          || mergedKeyword !== current.keyword
          || mergedFavicon !== current.favicon) {
        next[position] = {
          id: current.id, title: mergedTitle, url: current.url,
          tags: mergedTags, keyword: mergedKeyword, favicon: mergedFavicon,
          usageScore: current.usageScore,
          lastOpenedAt: current.lastOpenedAt
        }
        updated++
      } else {
        unchanged++
      }
    }
    if (added || updated) {
      if (!root.save(next, true))
        return {added: 0, updated: 0, unchanged: 0, blocked: true}
    }
    return {added: added, updated: updated, unchanged: unchanged, blocked: false}
  }

  Process {
    id: initializeProcess
    running: false
    command: [
      "sh", root.initializerPath,
      root.dataDir, root.dataPath
    ]

    onStarted: root.initializeFailureDetail = ""

    stdout: SplitParser {
      onRead: function() {}
    }

    stderr: SplitParser {
      onRead: function(data) {
        root.initializeFailureDetail = String(data || "").substring(0, 4096)
      }
    }

    onExited: function(exitCode) {
      root.initializePending = false
      if (exitCode !== 0) {
        root.recoveryRequired = true
        root.error = root.initializeFailureDetail
          || "Could not initialize bookmark storage"
        root.initializeFailureDetail = ""
        root.loaded = true
        return
      }

      root.initializeFailureDetail = ""
      root.storageReady = true
      Qt.callLater(root.reload)
    }

    onRunningChanged: {
      if (!running && root.initializePending) {
        root.initializePending = false
        root.initializeFailureDetail = ""
        root.recoveryRequired = true
        root.error = "Could not start bookmark storage initialization"
        root.loaded = true
      }
    }
  }

  Process {
    id: storeLoadProcess
    running: false
    command: ["true"]

    onStarted: root.storeLoadResponseReceived = false

    stdout: SplitParser {
      onRead: function(data) {
        root.handleStoreLoadResponse(data)
      }
    }

    onExited: root.finishStoreLoadAttempt()

    onRunningChanged: {
      if (!running)
        root.finishStoreLoadAttempt()
    }
  }

  Process {
    id: storeSaveProcess
    running: false
    command: ["true"]
    stdinEnabled: true

    stdout: SplitParser {
      onRead: function(data) {
        try {
          root.storeSaveResponse = root.parseSmallHelperResponse(data)
        } catch (exception) {
          root.storeSaveResponse = {ok: false, error: "Invalid writer response"}
        }
      }
    }

    onStarted: {
      root.storeSaveResponse = null
      if (root.activeSave !== null)
        write(root.activeSave.contents)
      stdinEnabled = false
    }

    onExited: function(exitCode) {
      root.storeSaveAttemptActive = false
      var message = "Could not save bookmarks.json · writes are disabled"
      var result = root.storeSaveResponse
      root.storeSaveResponse = null
      if (!result || exitCode !== 0 || !result.ok) {
        if (result && result.error)
          message += " · " + result.error
        root.finishActiveSave(false, message)
        return
      }
      root.finishActiveSave(true, "")
    }

    onRunningChanged: {
      if (!running && root.storeSaveAttemptActive) {
        root.storeSaveAttemptActive = false
        root.storeSaveResponse = null
        root.finishActiveSave(
          false,
          "Could not start the bookmark storage writer · writes are disabled"
        )
      }
    }
  }

  Component.onCompleted: {
    root.initializePending = true
    initializeProcess.running = true
  }

  Component.onDestruction: Quickshell.execDetached([
    "python3", root.localPath("bookmark_helper.py"),
    "menu-entry", "cleanup", root.menuExtensionPath
  ])

  Timer {
    id: usageSaveTimer
    interval: 300000
    repeat: false
    onTriggered: root.flushUsage()
  }

  Timer {
    id: reloadDebounce
    interval: 100
    repeat: false
    onTriggered: root.reload()
  }

  Process {
    id: backupProcess
    running: false
    command: ["true"]

    onStarted: root.backupResponse = null

    stdout: SplitParser {
      onRead: function(data) {
        try {
          root.backupResponse = root.parseSmallHelperResponse(data)
        } catch (exception) {
          root.backupResponse = {ok: false, error: "Invalid backup response"}
        }
      }
    }

    onExited: function(exitCode) {
      root.backupAttemptActive = false
      var result = root.backupResponse
      root.backupResponse = null
      if (exitCode !== 0) {
        var message = "Could not create an import backup · no changes were written"
        if (result && result.error)
          message += " · " + result.error
        root.finishActiveSave(false, message)
      } else {
        root.writeActiveSave()
      }
    }

    onRunningChanged: {
      if (!running && root.backupAttemptActive) {
        root.backupAttemptActive = false
        root.backupResponse = null
        root.finishActiveSave(
          false,
          "Could not start the import backup helper · no changes were written"
        )
      }
    }
  }

  FileView {
    id: dataFile
    path: root.storageReady ? root.dataPath : ""
    preload: false
    watchChanges: true
    printErrors: false
    onFileChanged: {
      if (!root.saving && !root.pendingUsageOpens)
        root.requestReload()
    }
  }
}
