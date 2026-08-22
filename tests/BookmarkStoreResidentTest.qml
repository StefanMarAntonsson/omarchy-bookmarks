import QtQuick
import Quickshell
import "."

ShellRoot {
  id: root

  property bool loadedOnce: false
  readonly property int expectedBookmarks:
    Number(Quickshell.env("BOOKMARK_TEST_EXPECTED") || "2000")
  readonly property bool expectInitializationFailure:
    Quickshell.env("BOOKMARK_TEST_EXPECT_INIT_FAILURE") === "1"

  function fail(message) {
    console.error("BOOKMARK_STORE_RESIDENT_TEST_FAIL:", message)
    Qt.quit()
  }

  BookmarkStore {
    id: store

    onLoadedChanged: {
      if (!loaded || root.loadedOnce)
        return
      root.loadedOnce = true
      if (root.expectInitializationFailure) {
        if (storageReady || !recoveryRequired) {
          root.fail("failed initializer did not enter recovery mode")
          return
        }
        settleTimer.start()
        return
      }
      if (bookmarks.length !== root.expectedBookmarks) {
        root.fail("persisted stress store did not load")
        return
      }
      settleTimer.start()
    }
  }

  Timer {
    id: settleTimer
    interval: 1000
    repeat: false
    onTriggered: {
      gc()
      console.log("BOOKMARK_STORE_RESIDENT_TEST_PASS")
      Qt.quit()
    }
  }

  Timer {
    interval: 10000
    running: true
    onTriggered: root.fail("resident load test timed out")
  }
}
