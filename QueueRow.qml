import QtQuick
import qs.Ui
import qs.Commons
import "Logic.js" as Logic

// One track in the Previous / Up next list: artwork, title, artist, duration.
BorderSurface {
  id: row

  property QtObject bar: null
  property var track: null
  property string glyph: ""
  signal activated()

  readonly property bool hovered: mouse.containsMouse

  height: inner.implicitHeight + Style.space(8)
  radius: Style.spacing.labelGap
  color: hovered ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"
  borderSpec: Border.none()

  function fmt(sec) {
    sec = Math.max(0, Math.floor(sec || 0))
    var m = Math.floor(sec / 60), s = sec % 60
    return m + ":" + (s < 10 ? "0" : "") + s
  }

  Row {
    id: inner
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(6)
    anchors.rightMargin: Style.space(6)
    spacing: Style.space(8)

    Item {
      width: Style.space(32)
      height: Style.space(32)
      anchors.verticalCenter: parent.verticalCenter

      Image {
        id: cover
        anchors.fill: parent
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        source: row.track ? Logic.safeArt(row.track.art) : ""
        visible: status === Image.Ready
      }
      Text {
        anchors.centerIn: parent
        visible: !cover.visible
        text: "󰎆"
        color: row.bar.foreground
        font.family: row.bar.fontFamily
        font.pixelSize: Style.font.body
      }
    }

    Column {
      width: parent.width - Style.space(32) - durationText.width - glyphText.width - Style.space(24)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        text: row.track ? row.track.title : ""
        color: row.bar.foreground
        font.family: row.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
        width: parent.width
      }
      Text {
        textFormat: Text.PlainText
        text: row.track ? row.track.artist : ""
        color: Qt.darker(row.bar.foreground, 1.5)
        font.family: row.bar.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        width: parent.width
        visible: text !== ""
      }
    }

    Text {
      id: durationText
      anchors.verticalCenter: parent.verticalCenter
      text: row.track && row.track.duration ? row.fmt(row.track.duration) : ""
      color: Qt.darker(row.bar.foreground, 1.6)
      font.family: row.bar.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      id: glyphText
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(14)
      text: row.glyph
      color: Qt.darker(row.bar.foreground, 1.3)
      font.family: row.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: row.activated()
  }
}
