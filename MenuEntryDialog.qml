import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  property bool opened: false
  property bool installed: false
  property bool busy: false
  property int selectedIndex: 1
  property string errorMessage: ""
  property color background: Color.background
  property color foreground: Color.foreground
  property color scrim: Util.alpha(Color.background, 0.7)
  property color selectedBackground: Util.alpha(Color.foreground, 0.08)
  property color selectedText: Color.accent
  property string fontFamily: Style.font.family
  property int cornerRadius: Style.cornerRadius

  readonly property string cancelText: installed ? "Keep" : "Not now"
  readonly property string confirmText: installed ? "Remove" : "Add entry"

  signal canceled()
  signal addRequested()
  signal removeRequested()

  function handleKey(event) {
    if (!root.opened)
      return false
    if (root.busy)
      return true

    if (event.key === Qt.Key_Escape) {
      root.canceled()
      return true
    }
    if (event.key === Qt.Key_Left
        || event.key === Qt.Key_Right
        || event.key === Qt.Key_Tab
        || event.key === Qt.Key_Backtab) {
      root.selectedIndex = root.selectedIndex === 0 ? 1 : 0
      return true
    }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (root.selectedIndex === 0)
        root.canceled()
      else if (root.installed)
        root.removeRequested()
      else
        root.addRequested()
      return true
    }
    return true
  }

  visible: opened

  Rectangle {
    anchors.fill: parent
    color: root.scrim

    MouseArea {
      anchors.fill: parent
      enabled: !root.busy
      onClicked: root.canceled()
    }

    BorderSurface {
      id: dialogCard

      width: Math.min(parent.width - Style.space(32), Style.space(430))
      height:
        contentColumn.implicitHeight
        + dialogCard.contentTopInset
        + dialogCard.contentBottomInset
      anchors.centerIn: parent
      color: root.background
      borderSpec: Border.flat(root.selectedText, Style.normalBorderWidth)
      padding: Style.space(18)
      radius: root.cornerRadius

      MouseArea {
        anchors.fill: parent
        onClicked: {}
      }

      Column {
        id: contentColumn

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: dialogCard.contentLeftInset
        anchors.rightMargin: dialogCard.contentRightInset
        anchors.topMargin: dialogCard.contentTopInset
        spacing: Style.space(14)

        Text {
          width: parent.width
          text:
            root.installed
              ? "Remove Bookmarks from the main Omarchy menu? Only the entry managed by this plugin will be removed."
              : "Add Bookmarks to the main Omarchy menu? This adds one managed entry to ~/.config/omarchy/extensions/omarchy-menu.jsonc. Existing entries and comments are preserved."
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          visible: root.busy || Boolean(root.errorMessage)
          text: root.errorMessage || "Updating main menu…"
          textFormat: Text.PlainText
          color: root.errorMessage ? Color.urgent : root.foreground
          opacity: root.errorMessage ? 1 : 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Item {
          width: parent.width
          height: Style.space(34)

          Row {
            anchors.right: parent.right
            spacing: Style.space(10)

            Repeater {
              model: [root.cancelText, root.confirmText]

              BorderSurface {
                required property int index
                required property string modelData

                readonly property bool selected:
                  root.selectedIndex === index
                readonly property bool destructive:
                  root.installed && index === 1

                width: Style.space(100)
                height: Style.space(34)
                color:
                  selected
                    ? destructive
                      ? Util.alpha(Color.urgent, 0.22)
                      : root.selectedBackground
                    : "transparent"
                borderSpec: Border.flat(
                  destructive
                    ? selected
                      ? Color.urgent
                      : Util.alpha(Color.urgent, 0.56)
                    : selected
                      ? root.selectedText
                      : Util.alpha(root.foreground, 0.38),
                  Style.normalBorderWidth
                )
                radius: 0
                opacity: root.busy ? 0.45 : 1

                Text {
                  anchors.centerIn: parent
                  text: modelData
                  textFormat: Text.PlainText
                  color:
                    parent.destructive && parent.selected
                      ? Color.urgent
                      : parent.selected
                        ? root.selectedText
                        : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  anchors.fill: parent
                  enabled: !root.busy
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.selectedIndex = index
                  onClicked: {
                    if (index === 0)
                      root.canceled()
                    else if (root.installed)
                      root.removeRequested()
                    else
                      root.addRequested()
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
