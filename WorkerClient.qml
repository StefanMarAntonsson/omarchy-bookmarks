import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root
  property string launcherPath: ""
  property bool ready: false
  property string error: ""
  // The launcher found no worker installed for this plugin's exact source.
  property bool setupRequired: false
  property int nextId: 1
  property int restartAttempt: 0
  property bool stopping: false
  property bool handshakeComplete: false
  property int helloId: 0
  property string killReason: ""
  // Request ID -> deadline in milliseconds. Every request is resolved exactly
  // once: by the worker, by the watchdog, or when the worker exits.
  property var pending: ({})
  readonly property int maxLineCharacters: 256 * 1024
  readonly property int maxRequestBytes: 64 * 1024
  readonly property int requestTimeoutMs: 20000
  readonly property int libraryRequestTimeoutMs: 120000
  readonly property int maxAutomaticRestarts: 5

  signal message(var response)

  // Explicit starts (opening the overlay) also retry after startup failures
  // or repeated crashes.
  function start() {
    restartAttempt = 0
    launch()
  }

  function launch() {
    if (worker.running || !launcherPath)
      return
    stopping = false
    handshakeComplete = false
    killReason = ""
    worker.command = [launcherPath]
    worker.running = true
  }

  function utf8Length(text) {
    var bytes = 0
    for (var i = 0; i < text.length; i++) {
      var code = text.charCodeAt(i)
      if (code < 0x80) bytes += 1
      else if (code < 0x800) bytes += 2
      else if (code >= 0xd800 && code <= 0xdbff) { bytes += 4; i++ }
      else bytes += 3
    }
    return bytes
  }

  function request(body, timeoutMs) {
    // The hello request establishes protocol compatibility. Application
    // requests wait for its response so startup and automatic restarts cannot
    // race work ahead of the handshake.
    if (!worker.running || (!ready && body.type !== "hello"))
      return 0
    var id = nextId++
    body.version = 1
    body.id = id
    var encoded = JSON.stringify(body)
    if (utf8Length(encoded) > maxRequestBytes) {
      error = "Request is too large"
      return 0
    }
    var effectiveTimeout = Number(timeoutMs || requestTimeoutMs)
    if (!isFinite(effectiveTimeout) || effectiveTimeout < requestTimeoutMs)
      effectiveTimeout = requestTimeoutMs
    effectiveTimeout = Math.min(effectiveTimeout, libraryRequestTimeoutMs)
    pending[id] = Date.now() + effectiveTimeout
    watchdog.start()
    worker.write(encoded + "\n")
    return id
  }

  function abandonPending(reason) {
    var ids = Object.keys(pending)
    pending = ({})
    watchdog.stop()
    for (var i = 0; i < ids.length; i++)
      root.message({version: 1, id: Number(ids[i]), ok: false, error: reason})
  }

  function stop() {
    stopping = true
    restartTimer.stop()
    watchdog.stop()
    worker.running = false
  }

  Component.onCompleted: launch()
  Component.onDestruction: stop()
  onLauncherPathChanged: launch()

  Process {
    id: worker
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(line) {
        if (line.length > root.maxLineCharacters) {
          root.error = "Worker response exceeded the safety limit"
          return
        }
        var parsed
        try {
          parsed = JSON.parse(line)
        } catch (exception) {
          root.error = "Worker returned an invalid response"
          return
        }
        if (!parsed || parsed.version !== 1 || typeof parsed.id !== "number"
            || typeof parsed.ok !== "boolean") {
          root.error = "Worker returned an invalid response"
          return
        }
        if (parsed.id !== 0) {
          if (root.pending[parsed.id] === undefined)
            return
          delete root.pending[parsed.id]
        }
        if (parsed.id === root.helloId && parsed.ok) {
          root.handshakeComplete = true
          root.setupRequired = false
          root.ready = true
        }
        if (parsed.id === 0 && !parsed.ok) {
          root.error = String(parsed.error || "Worker failed")
          root.setupRequired = parsed.code === "worker_setup_required"
        }
        root.message(parsed)
      }
    }
    onStarted: {
      root.error = ""
      root.helloId = root.request({type: "hello"})
    }
    onExited: function(exitCode) {
      var wasRunning = root.handshakeComplete
      root.ready = false
      root.handshakeComplete = false
      if (root.killReason) root.error = root.killReason
      else if (!root.stopping && wasRunning) root.error = "Bookmark worker exited unexpectedly"
      else if (!root.stopping && !root.error) root.error = "Bookmark worker could not start"
      root.abandonPending(root.error || "Bookmark worker stopped")
      if (root.stopping)
        return
      // A worker that fails before its handshake reports why (for example a
      // missing binary or a blocked migration). Retrying cannot fix that, so
      // wait for the overlay to be reopened instead of looping.
      if (!wasRunning || root.restartAttempt >= root.maxAutomaticRestarts)
        return
      root.restartAttempt = root.restartAttempt + 1
      restartTimer.interval = Math.min(10000, 250 * Math.pow(2, root.restartAttempt - 1))
      restartTimer.restart()
    }
  }

  Timer { id: restartTimer; repeat: false; onTriggered: root.launch() }

  Timer {
    id: watchdog
    interval: 1000
    repeat: true
    onTriggered: {
      var ids = Object.keys(root.pending)
      if (!ids.length) { stop(); return }
      var now = Date.now()
      for (var i = 0; i < ids.length; i++) {
        if (root.pending[ids[i]] < now) {
          root.killReason = "Bookmark worker stopped responding"
          stop()
          worker.running = false
          return
        }
      }
    }
  }
}
