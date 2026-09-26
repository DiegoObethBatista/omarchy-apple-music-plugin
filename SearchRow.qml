import QtQuick
import qs.Ui
import qs.Commons
import "Logic.js" as Logic

// One search result: artwork, title, subtitle, and play-now / play-next /
// add-to-queue actions. Click the row = play now.
BorderSurface {
  id: row

  property QtObject bar: null
  property var result: null
  property bool selected: false
  signal play(string mode)

  readonly property bool hot: mouse.containsMouse || selected
  readonly property bool isSong: result && String(result.kind).indexOf("songs") !== -1

  height: Style.space(44)
  radius: Style.spacing.labelGap
  color: hot ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"
  borderSpec: Border.none()

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: row.play("now")
  }

  Row {
    anchors.fill: parent
    anchors.leftMargin: Style.space(6)
    anchors.rightMargin: Style.space(4)
    spacing: Style.space(8)

    Item {
      width: Style.space(34)
      height: Style.space(34)
      anchors.verticalCenter: parent.verticalCenter
      Image {
        id: cover
        anchors.fill: parent
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        source: row.result ? Logic.safeArt(row.result.art) : ""
        visible: status === Image.Ready
      }
      Text {
        anchors.centerIn: parent
        visible: !cover.visible
        text: Logic.G.note
        color: row.bar.foreground
        font.family: row.bar.fontFamily
        font.pixelSize: Style.font.body
      }
    }

    Column {
      width: parent.width - Style.space(34) - actions.width - Style.space(16)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)
      Text {
        textFormat: Text.PlainText
        text: row.result ? row.result.title : ""
        color: row.bar.foreground
        font.family: row.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
        width: parent.width
      }
      Text {
        textFormat: Text.PlainText
        text: row.result ? row.result.subtitle + (row.isSong && row.result.duration ? "  ·  " + Logic.fmtTime(row.result.duration) : "") : ""
        color: Qt.darker(row.bar.foreground, 1.5)
        font.family: row.bar.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        width: parent.width
        visible: text !== ""
      }
    }

    Row {
      id: actions
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)
      opacity: row.hot ? 1.0 : 0.0
      Button {
        iconText: Logic.G.next
        tooltipText: "Play next"
        foreground: row.bar.foreground
        horizontalPadding: Style.space(4)
        verticalPadding: Style.space(2)
        iconSize: Style.font.bodySmall
        onClicked: row.play("next")
      }
      Button {
        iconText: "+"
        tooltipText: "Add to queue"
        foreground: row.bar.foreground
        horizontalPadding: Style.space(4)
        verticalPadding: Style.space(2)
        onClicked: row.play("later")
      }
    }
  }
}
