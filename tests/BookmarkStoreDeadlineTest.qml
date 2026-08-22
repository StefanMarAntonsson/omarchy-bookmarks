import QtQuick
import Quickshell
import "."

ShellRoot {
  id: root

  function fail(message) {
    console.error("BOOKMARK_STORE_DEADLINE_TEST_FAIL:", message)
    Qt.quit()
  }

  BookmarkStore {
    id: store
    storeLoadDeadlineMs: 200

    onLoadedChanged: {
      if (!loaded)
        return
      if (!recoveryRequired
          || canMutate
          || storeLoadAttemptActive
          || !error) {
        root.fail("timed-out store load did not fail closed")
        return
      }
      console.log("BOOKMARK_STORE_DEADLINE_TEST_PASS")
      Qt.quit()
    }
  }

  Timer {
    interval: 5000
    running: true
    onTriggered: root.fail("store-load deadline did not terminate the helper")
  }
}
