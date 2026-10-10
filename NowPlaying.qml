import QtQuick
import qs.Ui
import qs.Commons
import "Logic.js" as Logic

// Now-playing view: artwork + title/artist/album, seek bar, transport
// (shuffle · prev · play/pause · next · repeat) and song actions
// (love · suggest less · add to library · library mix).
Column {
  id: root

  property var am: null
  property QtObject bar: null

  readonly property bool running: am ? am.running : false
  readonly property bool hasTrack: am ? am.hasTrack : false
  readonly property bool playing: am ? am.playing : false
  readonly property string title: am ? am.title : ""
  readonly property string artist: am ? am.artist : ""

  spacing: Style.space(10)

  Row {
    spacing: Style.space(10)
    width: parent.width

    BorderSurface {
      width: Style.space(72)
      height: Style.space(72)
      radius: Style.spacing.labelGap
      color: Style.normalFillFor(root.bar.foreground, Color.accent)
      borderSpec: Border.controlSpec("normal", root.bar.foreground, Color.accent)

      Image {
        anchors.fill: parent
        anchors.margins: Style.space(2)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        source: root.am ? root.am.artUrl : ""   // filtered by Logic.nowArt in Service
        visible: source != ""
      }
      Text {
        anchors.centerIn: parent
        visible: !root.am || !root.am.artUrl
        text: Logic.G.note
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.displayLarge
      }
    }

    Column {
      spacing: Style.space(4)
      width: parent.width - Style.space(82)
      anchors.verticalCenter: parent.verticalCenter

      Text {
        textFormat: Text.PlainText
        text: !root.running ? "Apple Music" : (root.title || "Nothing playing")
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
        elide: Text.ElideRight
        width: parent.width
      }
      Text {
        textFormat: Text.PlainText
        text: !root.running ? "Not running" : root.artist
        color: Qt.darker(root.bar.foreground, 1.3)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
        width: parent.width
        visible: text !== ""
      }
      Text {
        textFormat: Text.PlainText
        text: root.am ? root.am.album : ""
        color: Qt.darker(root.bar.foreground, 1.6)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        width: parent.width
        visible: text !== ""
      }
    }
  }

  // Seek bar
  Column {
    width: parent.width
    spacing: Style.space(2)
    visible: root.hasTrack && root.am && root.am.length > 0

    PanelSlider {
      id: seek
      bar: root.bar
      width: parent.width
      minimum: 0
      maximum: root.am ? Math.max(1, root.am.length) : 1
      value: root.am ? root.am.position : 0
      onReleased: function(v) { if (root.am) root.am.seekTo(v) }
    }
    Item {
      width: parent.width
      height: posText.implicitHeight
      Text {
        id: posText
        anchors.left: parent.left
        text: Logic.fmtTime(seek.dragging ? seek.liveValue : (root.am ? root.am.position : 0))
        color: Qt.darker(root.bar.foreground, 1.5)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
      }
      Text {
        anchors.right: parent.right
        text: Logic.fmtTime(root.am ? root.am.length : 0)
        color: Qt.darker(root.bar.foreground, 1.5)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // Transport: shuffle · prev · play/pause · next · repeat
  Row {
    anchors.horizontalCenter: parent.horizontalCenter
    spacing: Style.space(6)
    visible: root.running

    Button {
      iconText: Logic.G.shuffle
      tooltipText: root.am && root.am.shuffle ? "Shuffle on" : "Shuffle off"
      foreground: root.am && root.am.shuffle ? Color.accent : root.bar.foreground
      enabled: root.am !== null && root.am.bridged
      opacity: !enabled ? 0.4 : (root.am.shuffle ? 1.0 : 0.6)
      onClicked: root.am.toggleShuffle()
    }
    Button {
      iconText: Logic.G.prev
      foreground: root.bar.foreground
      enabled: root.am && root.am.player && root.am.player.canGoPrevious
      opacity: enabled ? 1.0 : 0.4
      onClicked: root.am.previous()
    }
    Button {
      iconText: root.playing ? Logic.G.pause : Logic.G.play
      foreground: root.bar.foreground
      horizontalPadding: Style.spacing.panelGap
      iconSize: Style.font.iconLarge
      enabled: root.am && root.am.player !== null
      opacity: enabled ? 1.0 : 0.4
      onClicked: root.am.playPause()
    }
    Button {
      iconText: Logic.G.next
      foreground: root.bar.foreground
      enabled: root.am && root.am.player && root.am.player.canGoNext
      opacity: enabled ? 1.0 : 0.4
      onClicked: root.am.next()
    }
    Button {
      iconText: Logic.repeatIcon(root.am ? root.am.repeatMode : 0)
      tooltipText: Logic.repeatLabel(root.am ? root.am.repeatMode : 0)
      foreground: root.am && root.am.repeatMode !== 0 ? Color.accent : root.bar.foreground
      enabled: root.am !== null && root.am.bridged
      opacity: !enabled ? 0.4 : (root.am.repeatMode !== 0 ? 1.0 : 0.6)
      onClicked: root.am.cycleRepeat()
    }
  }

  // Song actions: like · dislike · add to library · library mix
  Row {
    anchors.horizontalCenter: parent.horizontalCenter
    spacing: Style.space(6)
    visible: root.running

    Button {
      iconText: root.am && root.am.rating === 1 ? Logic.G.heart : Logic.G.heartOutline
      tooltipText: root.am && root.am.rating === 1 ? "Loved (click to undo)" : "Love"
      foreground: root.am && root.am.rating === 1 ? Color.accent : root.bar.foreground
      enabled: root.am !== null && root.am.canRate
      opacity: enabled ? 1.0 : 0.35
      onClicked: root.am.toggleLike()
    }
    Button {
      iconText: root.am && root.am.rating === -1 ? Logic.G.thumbDown : Logic.G.thumbDownOutline
      tooltipText: root.am && root.am.rating === -1 ? "Suggesting less (click to undo)" : "Suggest less"
      foreground: root.am && root.am.rating === -1 ? Color.accent : root.bar.foreground
      enabled: root.am !== null && root.am.canRate
      opacity: enabled ? 1.0 : 0.35
      onClicked: root.am.toggleDislike()
    }
    Button {
      iconText: root.am && root.am.inLibrary === true ? Logic.G.libraryCheck : Logic.G.libraryAdd
      tooltipText: root.am && root.am.inLibrary === true ? "In your library" : "Add to library"
      foreground: root.am && root.am.inLibrary === true ? Color.accent : root.bar.foreground
      enabled: root.am !== null && root.am.canRate && root.am.inLibrary !== true
      opacity: root.am && root.am.inLibrary === true ? 1.0 : (enabled ? 1.0 : 0.35)
      onClicked: root.am.addToLibrary()
    }
    Button {
      iconText: Logic.G.mix
      tooltipText: "Random mix from your whole library"
      foreground: root.bar.foreground
      enabled: root.running
      opacity: enabled ? 0.85 : 0.4
      onClicked: root.am.shuffleLibrary()
    }
  }
}
