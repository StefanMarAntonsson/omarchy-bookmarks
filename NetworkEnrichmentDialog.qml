import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  property bool opened: false
  property bool webEnabled: false
  property bool busy: false
  property int selectedIndex: 0
  property string errorMessage: ""
  property color background: Color.background
  property color foreground: Color.foreground
  property color scrim: Util.alpha(Color.background, 0.7)
  property color selectedBackground: Util.alpha(Color.foreground, 0.08)
  property color selectedText: Color.accent
  property string fontFamily: Style.font.family
  property int cornerRadius: Style.cornerRadius

  signal canceled()
  signal settingRequested(bool enabled)

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
      else
        root.settingRequested(!root.webEnabled)
      return true
    }
    return true
  }

  onOpenedChanged: {
    if (opened)
      Qt.callLater(root.forceActiveFocus)
  }

  visible: opened
  focus: opened

  Keys.priority: Keys.BeforeItem
  Keys.onPressed: function(event) {
    if (root.handleKey(event))
      event.accepted = true
  }

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

      width: Math.min(parent.width - Style.space(32), Style.space(460))
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
          text: root.webEnabled ? "Web details are enabled" : "Enable web details for pasted URLs?"
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.weight: Font.DemiBold
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          text: root.webEnabled
            ? "Pasting a URL currently contacts that website to download its title and favicon. Turn this off to guarantee that paste never performs a network request."
            : "This is off by default. If enabled, pasting a new URL contacts that website and up to three public redirect destinations, reveals your IP address and each requested URL, and downloads page and favicon data for local processing. Requests are restricted to public HTTP(S) destinations, but fetching untrusted content is never risk-free."
          textFormat: Text.PlainText
          color: root.foreground
          opacity: 0.76
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          visible: root.busy || Boolean(root.errorMessage)
          text: root.errorMessage || "Saving preference…"
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
              model: root.webEnabled
                ? ["Keep enabled", "Turn off"]
                : ["Keep off", "Enable anyway"]

              BorderSurface {
                required property int index
                required property string modelData

                readonly property bool selected: root.selectedIndex === index

                width: Style.space(126)
                height: Style.space(34)
                color: selected ? root.selectedBackground : "transparent"
                borderSpec: Border.flat(
                  selected ? root.selectedText : Util.alpha(root.foreground, 0.38),
                  Style.normalBorderWidth
                )
                radius: 0
                opacity: root.busy ? 0.45 : 1

                Text {
                  anchors.centerIn: parent
                  text: modelData
                  textFormat: Text.PlainText
                  color: parent.selected ? root.selectedText : root.foreground
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
                    else
                      root.settingRequested(!root.webEnabled)
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
