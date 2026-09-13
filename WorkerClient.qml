import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root
  property string launcherPath: ""
  property bool ready: false
  property string error: ""
  property int nextId: 1
  property int restartAttempt: 0
  property bool stopping: false
  readonly property int maxLineCharacters: 256 * 1024

  signal message(var response)

  function start() {
    if (worker.running || !launcherPath)
      return
    stopping = false
    worker.command = [launcherPath]
    worker.running = true
  }

  function request(body) {
    if (!worker.running || !ready)
      return 0
    var id = nextId++
    body.version = 1
    body.id = id
    var encoded = JSON.stringify(body)
    if (encoded.length > 64 * 1024) {
      error = "Request is too large"
      return 0
    }
    worker.write(encoded + "\n")
    return id
  }

  function stop() {
    stopping = true
    restartTimer.stop()
    worker.running = false
  }

  Component.onCompleted: start()
  Component.onDestruction: stop()
  onLauncherPathChanged: start()

  Process {
    id: worker
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(line) {
        if (line.length > root.maxLineCharacters) {
          root.error = "Worker response exceeded the safety limit"
          return
        }
        try {
          var parsed = JSON.parse(line)
          if (!parsed || parsed.version !== 1 || typeof parsed.id !== "number"
              || typeof parsed.ok !== "boolean")
            throw new Error("invalid response shape")
          if (parsed.id === 0 && !parsed.ok)
            root.error = String(parsed.error || "Worker failed")
          root.message(parsed)
        } catch (exception) {
          root.error = "Worker returned an invalid response"
        }
      }
    }
    onStarted: {
      root.ready = true
      root.error = ""
      root.restartAttempt = 0
      root.request({type: "hello"})
    }
    onExited: function(exitCode) {
      root.ready = false
      if (!root.stopping) {
        root.error = exitCode === 0 ? "Bookmark worker stopped" : "Bookmark worker exited unexpectedly"
        root.restartAttempt = Math.min(root.restartAttempt + 1, 6)
        restartTimer.interval = Math.min(10000, 250 * Math.pow(2, root.restartAttempt - 1))
        restartTimer.restart()
      }
    }
  }

  Timer { id: restartTimer; repeat: false; onTriggered: root.start() }
}
