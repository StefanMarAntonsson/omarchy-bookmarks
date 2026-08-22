import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  property bool opened: false
  property bool editing: false
  property string bookmarkId: ""
  property string validationError: ""
  property var urlValidator: null

  readonly property bool canSubmit:
    urlField.text.trim().length > 0

  signal submitted(
    string bookmarkId,
    string title,
    string url,
    string tags,
    string keyword
  )

  signal canceled()

  function openForCreate() {
    root.editing = false
    root.bookmarkId = ""
    root.validationError = ""
    titleField.text = ""
    urlField.text = ""
    tagsField.text = ""
    keywordField.text = ""
    root.opened = true

    Qt.callLater(function() {
      titleField.forceActiveFocus()
    })
  }

  function openForEdit(bookmark) {
    if (!bookmark)
      return

    root.editing = true
    root.bookmarkId = String(bookmark.id || "")
    root.validationError = ""
    titleField.text = String(bookmark.title || "")
    urlField.text = String(bookmark.url || "")
    tagsField.text = Array.isArray(bookmark.tags)
      ? bookmark.tags.join(", ")
      : ""
    keywordField.text = String(bookmark.keyword || "")
    root.opened = true

    Qt.callLater(function() {
      titleField.forceActiveFocus()
      titleField.selectAll()
    })
  }

  function close() {
    root.opened = false
    root.validationError = ""
  }

  function cancel() {
    root.close()
    root.canceled()
  }

  function submit() {
    var title = titleField.text.trim()
    var url = urlField.text.trim()

    if (!url) {
      root.validationError = "Enter a URL"
      urlField.forceActiveFocus()
      return
    }

    if (/\s/.test(url) || (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(url) && !/^https?:\/\//i.test(url))) {
      root.validationError = "Use an HTTP(S) URL"
      urlField.forceActiveFocus()
      return
    }

    if (typeof root.urlValidator === "function" && !root.urlValidator(url)) {
      root.validationError = "Enter a valid HTTP(S) URL"
      urlField.forceActiveFocus()
      return
    }

    if (/\s/.test(keywordField.text.trim())) {
      root.validationError = "Keyword cannot contain spaces"
      keywordField.forceActiveFocus()
      return
    }

    root.validationError = ""
    root.submitted(
      root.bookmarkId,
      title,
      url,
      tagsField.text,
      keywordField.text
    )
  }

  visible: opened
  enabled: opened

  Keys.priority: Keys.BeforeItem

  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Escape) {
      root.cancel()
      event.accepted = true
    } else if (
      (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
      && event.modifiers === Qt.ControlModifier
    ) {
      root.submit()
      event.accepted = true
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

        text: root.editing ? "Edit bookmark" : "Add bookmark"
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
      spacing: Style.spacing.xs

      Text {
        text: "Title (optional)"
        color: Color.menu.text
        opacity: 0.72
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.caption
      }

      TextField {
        id: titleField

        width: parent.width
        placeholderText: "Bookmark name"
        foreground: Color.menu.text
        accent: Color.menu.selectedText

        onTextChanged: root.validationError = ""
        onAccepted: urlField.forceActiveFocus()
      }
    }

    Column {
      width: parent.width
      spacing: Style.spacing.xs

      Text {
        text: "URL"
        color: Color.menu.text
        opacity: 0.72
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.caption
      }

      TextField {
        id: urlField

        width: parent.width
        placeholderText: "https://example.com"
        foreground: Color.menu.text
        accent: Color.menu.selectedText

        onTextChanged: root.validationError = ""
        onAccepted: tagsField.forceActiveFocus()
      }
    }

    Column {
      width: parent.width
      spacing: Style.spacing.xs

      Text {
        text: "Tags"
        color: Color.menu.text
        opacity: 0.72
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.caption
      }

      TextField {
        id: tagsField

        width: parent.width
        placeholderText: "tag-one, tag-two"
        foreground: Color.menu.text
        accent: Color.menu.selectedText

        onTextChanged: root.validationError = ""
        onAccepted: keywordField.forceActiveFocus()
      }
    }

    Column {
      width: parent.width
      spacing: Style.spacing.xs

      Text {
        text: "Keyword (optional)"
        color: Color.menu.text
        opacity: 0.72
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.caption
      }

      TextField {
        id: keywordField

        width: parent.width
        placeholderText: "alias"
        foreground: Color.menu.text
        accent: Color.menu.selectedText

        onTextChanged: root.validationError = ""
        onAccepted: root.submit()
      }
    }

    Item {
      width: parent.width
      height: Style.space(32)

      Text {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter

        text: root.validationError
        visible: text !== ""
        color: Color.urgent
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Item {
      width: parent.width
      height: Style.space(42)

      Text {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter

        text: "Enter Next field    Ctrl+Enter Save"
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
          text: root.editing ? "Save" : "Add"
          bordered: true
          selected: true
          focusable: true
          enabled: root.canSubmit
          opacity: enabled ? 1 : 0.42
          foreground: Color.menu.text
          accent: Color.menu.selectedText

          onClicked: root.submit()
        }
      }
    }
  }
}
