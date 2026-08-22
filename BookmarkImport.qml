import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

Item {
  id: root

  property bool opened: false
  property bool loading: false
  property string helperPath: ""
  property string dataPath: ""
  property string sourcePath: ""
  property string error: ""
  property var result: null
  property bool responseReceived: false

  readonly property int maxImportOutputCharacters: 128 * 1024 * 1024
  readonly property int maxBookmarks: 50000

  signal confirmed(var items)
  signal canceled()

  function begin(source) {
    root.sourcePath = String(source || "")
    root.error = ""
    root.result = null
    root.loading = true
    root.opened = true
    importProcess.command = ["python3", root.helperPath, "import", root.sourcePath, root.dataPath]
    importProcess.running = false
    importProcess.running = true
    root.forceActiveFocus()
  }

  function close() {
    if (importProcess.running)
      importProcess.running = false
    root.opened = false
    root.loading = false
    root.sourcePath = ""
    root.error = ""
    root.result = null
    root.responseReceived = false
  }

  function handleResponse(data) {
    root.responseReceived = true
    try {
      var output = String(data || "")
      if (output.length > root.maxImportOutputCharacters)
        throw new Error("Bookmark import returned too much data")
      var parsed = JSON.parse(output)
      if (parsed.ok
          && Array.isArray(parsed.items)
          && parsed.items.length <= root.maxBookmarks) {
        root.result = parsed
        root.error = ""
      } else {
        root.error = String(parsed.error || "Could not read that bookmark file")
      }
    } catch (exception) {
      root.result = null
      root.error = String(
        exception.message || "Could not read that bookmark file"
      ).trim()
    }
  }

  function cancel() {
    root.close()
    root.canceled()
  }

  function accept() {
    if (!root.result || !root.result.items)
      return
    var items = root.result.items
    root.close()
    root.confirmed(items)
  }

  visible: opened
  enabled: opened
  focus: opened

  Keys.priority: Keys.BeforeItem
  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Escape) {
      root.cancel()
      event.accepted = true
    } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
               && root.result && root.result.items) {
      root.accept()
      event.accepted = true
    }
  }

  Process {
    id: importProcess
    running: false
    command: ["true"]

    onStarted: root.responseReceived = false

    stdout: SplitParser {
      onRead: function(data) {
        if (root.opened)
          root.handleResponse(data)
      }
    }

    onExited: function() {
      if (!root.opened)
        return
      root.loading = false
      if (!root.responseReceived)
        root.error = "Could not read that bookmark file"
      root.forceActiveFocus()
    }

    onRunningChanged: {
      if (!running && root.loading) {
        root.loading = false
        root.error = "Could not start the bookmark import helper"
        root.forceActiveFocus()
      }
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

      Text {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: "Import bookmarks"
        color: Color.menu.text
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.title
        font.weight: Font.DemiBold
      }

      Text {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: "Esc Cancel"
        color: Color.menu.text
        opacity: 0.48
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.caption
      }
    }

    Column {
      width: parent.width
      spacing: Style.spacing.sm

      Text {
        width: parent.width
        text: root.loading
          ? "Reading and validating bookmarks…"
          : root.error
            ? root.error
            : root.result
              ? root.result.stats.ready + " unique URL bookmarks are ready"
              : "Choose an exported bookmarks file"
        textFormat: Text.PlainText
        color: root.error ? Color.urgent : Color.menu.text
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.heading
        font.weight: Font.Medium
        wrapMode: Text.WordWrap
      }

      Text {
        width: parent.width
        visible: root.result !== null
        text: root.result
          ? root.result.stats.new + " new  ·  "
            + root.result.stats.duplicatesExisting + " already saved  ·  "
            + root.result.stats.duplicatesInFile + " duplicate entries"
          : ""
        color: Color.menu.text
        opacity: 0.68
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      Text {
        width: parent.width
        visible: root.result !== null
        text: root.result
          ? root.result.stats.favicons + " favicons  ·  "
            + root.result.stats.untitled + " untitled  ·  "
            + root.result.stats.rejected + " rejected non-URL entries"
          : ""
        color: Color.menu.text
        opacity: 0.52
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }
    }

    Rectangle {
      width: parent.width
      height: Style.space(244)
      color: Color.menu.selectedBackground
      opacity: root.result ? 1 : 0.35
      radius: Style.cornerRadius

      ListView {
        anchors.fill: parent
        anchors.margins: Style.spacing.md
        interactive: false
        spacing: Style.spacing.sm
        model: root.result && root.result.items ? root.result.items.slice(0, 5) : []

        delegate: Column {
          required property var modelData
          width: ListView.view.width
          spacing: Style.spacing.xs

          Text {
            width: parent.width
            text: modelData.title || modelData.url
            textFormat: Text.PlainText
            color: Color.menu.selectedText
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            text: modelData.url
            textFormat: Text.PlainText
            color: Color.menu.selectedText
            opacity: 0.56
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }

      Text {
        anchors.centerIn: parent
        visible: !root.result
        text: root.loading ? "" : ""
        color: Color.menu.text
        opacity: 0.5
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.displayLarge
      }
    }

    Item {
      width: parent.width
      height: Style.space(42)

      Text {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: root.result ? "A timestamped backup will be created" : "HTML and plugin JSON files"
        color: Color.menu.text
        opacity: 0.48
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.caption
      }

      Row {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.sm

        Button {
          width: Style.space(88)
          height: Style.space(34)
          text: "Cancel"
          bordered: true
          focusable: true
          foreground: Color.menu.text
          accent: Color.menu.selectedText
          onClicked: root.cancel()
        }

        Button {
          width: Style.space(88)
          height: Style.space(34)
          text: "Import"
          bordered: true
          selected: true
          focusable: true
          enabled: root.result !== null && !root.loading
          opacity: enabled ? 1 : 0.42
          foreground: Color.menu.text
          accent: Color.menu.selectedText
          onClicked: root.accept()
        }
      }
    }
  }
}
