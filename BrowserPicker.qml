import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

Item {
  id: root

  property bool opened: false
  property bool loading: false
  property string helperPath: ""
  property string bookmarkTitle: ""
  property string error: ""
  property var browsers: []
  property int selectedIndex: 0

  signal selected(var browser)
  signal canceled()

  function openFor(title) {
    root.bookmarkTitle = String(title || "")
    root.error = ""
    root.browsers = []
    root.selectedIndex = 0
    root.loading = true
    root.opened = true
    browserProcess.command = ["python3", root.helperPath, "browsers"]
    browserProcess.running = false
    browserProcess.running = true
    root.forceActiveFocus()
  }

  function close() {
    if (browserProcess.running)
      browserProcess.running = false
    root.opened = false
    root.loading = false
    root.error = ""
  }

  function cancel() {
    root.close()
    root.canceled()
  }

  function moveSelection(amount) {
    if (!root.browsers.length)
      return
    root.selectedIndex =
      ((root.selectedIndex + amount) % root.browsers.length
        + root.browsers.length) % root.browsers.length
    browserList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function choose(index) {
    if (index < 0 || index >= root.browsers.length)
      return
    var browser = root.browsers[index]
    root.close()
    root.selected(browser)
  }

  function handleKey(event) {
    if (!root.opened)
      return false
    if (event.key === Qt.Key_Escape
        || (event.key === Qt.Key_Tab
            && event.modifiers === Qt.ControlModifier)) {
      root.cancel()
      return true
    }
    if (event.key === Qt.Key_Up) {
      root.moveSelection(-1)
      return true
    }
    if (event.key === Qt.Key_Down) {
      root.moveSelection(1)
      return true
    }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.choose(root.selectedIndex)
      return true
    }
    return true
  }

  visible: opened
  enabled: opened
  focus: opened

  Keys.priority: Keys.BeforeItem
  Keys.onPressed: function(event) {
    if (root.handleKey(event))
      event.accepted = true
  }

  Process {
    id: browserProcess
    running: false
    command: ["true"]

    stdout: StdioCollector {
      id: browserOutput
      waitForEnd: true
    }

    stderr: StdioCollector {
      id: browserError
      waitForEnd: true
    }

    onExited: function(exitCode) {
      if (!root.opened)
        return
      root.loading = false
      try {
        var result = JSON.parse(String(browserOutput.text || ""))
        if (exitCode !== 0 || !result.ok)
          throw new Error(String(result.error || "Could not find installed browsers"))
        root.browsers = Array.isArray(result.browsers) ? result.browsers : []
        root.selectedIndex = 0
        if (!root.browsers.length)
          root.error = "No registered HTTPS browsers found"
      } catch (exception) {
        root.error = String(
          browserError.text || exception.message || "Could not find installed browsers"
        ).trim()
      }
      root.forceActiveFocus()
    }
  }

  Rectangle {
    anchors.fill: parent
    color: Color.menu.background

    MouseArea {
      anchors.fill: parent
      onClicked: {}
    }
  }

  Column {
    anchors.fill: parent
    spacing: Style.spacing.md

    Item {
      width: parent.width
      height: Style.space(42)

      Column {
        anchors.left: parent.left
        anchors.right: countText.left
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xs

        Text {
          width: parent.width
          text: "Open with…"
          color: Color.menu.text
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.title
          font.weight: Font.DemiBold
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: root.bookmarkTitle
          color: Color.menu.text
          opacity: 0.52
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        id: countText
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: root.loading ? "…" : String(root.browsers.length)
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
        - Style.space(34)
        - parent.spacing * 2

      ListView {
        id: browserList
        anchors.fill: parent
        model: root.browsers
        clip: true
        spacing: Style.spacing.xs
        boundsBehavior: Flickable.StopAtBounds

        delegate: BorderSurface {
          id: browserRow

          required property int index
          required property var modelData

          readonly property bool isSelected:
            browserRow.index === root.selectedIndex

          width: ListView.view.width
          height: Style.space(58)
          radius: Style.cornerRadius
          color:
            browserRow.isSelected
              ? Color.menu.selectedBackground
              : "transparent"
          borderSpec:
            browserRow.isSelected
              ? Border.surfaceSpec(
                  "menu",
                  "selected-border",
                  Color.menu.selectedBorder,
                  0
                )
              : Border.none()

          Text {
            id: browserIcon
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(30)
            text: ""
            color:
              browserRow.isSelected
                ? Color.menu.selectedText
                : Color.menu.text
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.iconLarge
            horizontalAlignment: Text.AlignHCenter
          }

          Column {
            anchors.left: browserIcon.right
            anchors.leftMargin: Style.spacing.sm
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xs

            Text {
              width: parent.width
              text:
                browserRow.modelData.name
                + (browserRow.modelData.isDefault ? "  ·  Default" : "")
              color:
                browserRow.isSelected
                  ? Color.menu.selectedText
                  : Color.menu.text
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.heading
              font.weight: Font.Medium
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: browserRow.modelData.id
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
            onEntered: root.selectedIndex = browserRow.index
            onClicked: root.choose(browserRow.index)
          }
        }
      }

      Text {
        anchors.centerIn: parent
        width: Style.space(360)
        visible: root.loading || root.error
        text: root.loading ? "Finding installed browsers…" : root.error
        color: root.error ? Color.urgent : Color.menu.text
        opacity: root.error ? 1 : 0.7
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.title
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
      }
    }

    Text {
      width: parent.width
      height: Style.space(34)
      text: "Enter Open  ↑↓ Select  Ctrl+Tab / Esc Back"
      color: Color.menu.text
      opacity: 0.48
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
    }
  }
}
