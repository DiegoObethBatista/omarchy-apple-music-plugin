import QtQuick
import Quickshell
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: "diegohades.apple-music"

  readonly property var am: bar && bar.shell ? bar.shell.serviceFor("diegohades.apple-music") : null
  readonly property bool running: am ? am.running : false
  readonly property bool hasTrack: am ? am.hasTrack : false
  readonly property bool playing: am ? am.playing : false
  readonly property string title: am ? am.title : ""
  readonly property string artist: am ? am.artist : ""
  readonly property bool showTitle: setting("showTitle", true)
  readonly property real maxLabelWidth: setting("maxLabelWidth", 180)

  // Apple "music note" glyph when idle, play/pause state while a track is loaded.
  readonly property string glyphText: !hasTrack ? "󰎆" : (playing ? "󰏤" : "󰐊")

  property bool popupOpen: false
  readonly property bool opened: popupOpen
  function open() { popupOpen = true }
  function close() { popupOpen = false }

  function fmt(sec) {
    sec = Math.max(0, Math.floor(sec || 0))
    var m = Math.floor(sec / 60), s = sec % 60
    return m + ":" + (s < 10 ? "0" : "") + s
  }

  visible: true
  implicitWidth: row.implicitWidth + Style.space(14)
  implicitHeight: barSize

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(6)

    Text {
      id: glyph
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: root.glyphText
      color: root.playing || !root.hasTrack ? root.bar.barForeground : Qt.darker(root.bar.barForeground, 1.5)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
    }

    Item {
      id: scrollClip
      width: Math.min(root.maxLabelWidth, labelText.implicitWidth)
      height: glyph.height
      clip: true
      anchors.verticalCenter: parent.verticalCenter
      visible: root.showTitle && !root.vertical && root.hasTrack

      Text {
        id: labelText
        textFormat: Text.PlainText
        text: root.title + (root.artist ? "  ·  " + root.artist : "")
        color: root.bar.barForeground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
        property bool needsScroll: implicitWidth > scrollClip.width

        NumberAnimation on x {
          running: labelText.needsScroll && !root.popupOpen && scrollClip.visible
          loops: Animation.Infinite
          duration: Math.max(6000, labelText.implicitWidth * 25)
          from: scrollClip.width
          to: -labelText.implicitWidth
        }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    onClicked: function(mouse) {
      if (!root.am) return
      if (mouse.button === Qt.RightButton) { root.popupOpen = !root.popupOpen; return }
      if (!root.running) { root.am.launch(); return }
      if (mouse.button === Qt.MiddleButton) root.am.next()
      else if (root.hasTrack) root.am.playPause()
      else root.am.raise()
    }
    onWheel: function(wheel) {
      if (!root.am || !root.hasTrack) return
      if (wheel.angleDelta.y > 0) root.am.previous()
      else if (wheel.angleDelta.y < 0) root.am.next()
    }
    onEntered: if (root.bar) root.bar.showTooltip(root,
      !root.running ? "Apple Music — click to open"
      : root.hasTrack ? (root.title + (root.artist ? " — " + root.artist : ""))
      : "Apple Music — nothing playing")
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(340))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
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
            source: root.am ? root.am.artUrl : ""
            visible: source != ""
          }
          Text {
            anchors.centerIn: parent
            visible: !root.am || !root.am.artUrl
            text: "󰎆"
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
            text: root.fmt(seek.dragging ? seek.liveValue : (root.am ? root.am.position : 0))
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            anchors.right: parent.right
            text: root.fmt(root.am ? root.am.length : 0)
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(6)
        visible: root.running

        Button {
          iconText: "󰒮"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: root.am && root.am.player && root.am.player.canGoPrevious
          opacity: enabled ? 1.0 : 0.4
          onClicked: root.am.previous()
        }
        Button {
          iconText: root.playing ? "󰏤" : "󰐊"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.panelGap
          verticalPadding: Style.spacing.controlPaddingY
          iconSize: Style.font.iconLarge
          enabled: root.am && root.am.player !== null
          opacity: enabled ? 1.0 : 0.4
          onClicked: root.am.playPause()
        }
        Button {
          iconText: "󰒭"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: root.am && root.am.player && root.am.player.canGoNext
          opacity: enabled ? 1.0 : 0.4
          onClicked: root.am.next()
        }
      }

      PanelSeparator {
        foreground: root.bar.foreground
        visible: queueSection.visible
      }

      // Previous / Up next, from the MusicKit queue via the bridge extension.
      Column {
        id: queueSection
        width: parent.width
        spacing: Style.space(4)
        visible: root.am !== null && root.am.hasQueue

        Text {
          textFormat: Text.PlainText
          text: "Previous"
          visible: root.am && root.am.previousTrack !== null
          color: Qt.darker(root.bar.foreground, 1.6)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        QueueRow {
          width: parent.width
          bar: root.bar
          track: root.am ? root.am.previousTrack : null
          glyph: "󰒮"
          visible: track !== null
          onActivated: root.am.previous()
        }

        Text {
          textFormat: Text.PlainText
          text: "Up next"
          visible: root.am && root.am.upcoming.length > 0
          color: Qt.darker(root.bar.foreground, 1.6)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          topPadding: Style.space(4)
        }

        Repeater {
          model: root.am ? root.am.upcoming : []
          QueueRow {
            required property var modelData
            required property int index
            width: queueSection.width
            bar: root.bar
            track: modelData
            glyph: index === 0 ? "󰒭" : ""
            // Autoplay entries without a queue index: first one = just skip ahead.
            onActivated: modelData.index >= 0 ? root.am.playQueueIndex(modelData.index)
                                              : (index === 0 ? root.am.next() : null)
          }
        }
      }

      PanelSeparator { foreground: root.bar.foreground }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(6)

        Button {
          text: root.running ? "Show window" : "Open Apple Music"
          foreground: root.bar.foreground
          bordered: true
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: { root.am.raise(); root.popupOpen = false }
        }
        Button {
          text: "Quit"
          visible: root.running
          foreground: root.bar.foreground
          bordered: true
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: { root.am.quit(); root.popupOpen = false }
        }
      }
    }
  }
}
