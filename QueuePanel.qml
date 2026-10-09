import QtQuick
import qs.Ui
import qs.Commons
import "Logic.js" as Logic

// Previous / Up next, from the MusicKit queue via the bridge extension.
Column {
  id: queueSection

  property var am: null
  property QtObject bar: null

  spacing: Style.space(4)

  Text {
    textFormat: Text.PlainText
    text: "Previous"
    visible: queueSection.am && queueSection.am.previousTrack !== null
    color: Qt.darker(queueSection.bar.foreground, 1.6)
    font.family: queueSection.bar.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }

  QueueRow {
    width: parent.width
    bar: queueSection.bar
    track: queueSection.am ? queueSection.am.previousTrack : null
    glyph: Logic.G.prev
    visible: track !== null
    onActivated: queueSection.am.previous()
  }

  Text {
    textFormat: Text.PlainText
    text: "Up next"
    visible: queueSection.am && queueSection.am.upcoming.length > 0
    color: Qt.darker(queueSection.bar.foreground, 1.6)
    font.family: queueSection.bar.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    topPadding: Style.space(4)
  }

  Repeater {
    model: queueSection.am ? queueSection.am.upcoming : []
    QueueRow {
      required property var modelData
      required property int index
      width: queueSection.width
      bar: queueSection.bar
      track: modelData
      glyph: index === 0 ? Logic.G.next : ""
      onActivated: modelData.index >= 0 ? queueSection.am.playQueueIndex(modelData.index)
                                        : (index === 0 ? queueSection.am.next() : null)
    }
  }
}
