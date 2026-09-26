import QtQuick
import Quickshell
import qs.Ui
import qs.Commons
import "Logic.js" as Logic

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

  readonly property string glyphText: !hasTrack ? Logic.G.note : (playing ? Logic.G.pause : Logic.G.play)

  property bool popupOpen: false
  readonly property bool opened: popupOpen
  function open() { popupOpen = true }
  function close() { popupOpen = false }

  // Search view state (inside the popup).
  property bool searchMode: false
  property int searchCursor: -1
  readonly property var searchFlat: am ? Logic.flatten(am.searchResults) : []
  function openSearch() {
    root.searchMode = true
    root.searchCursor = -1
    Qt.callLater(function() { searchField.forceActiveFocus(); searchField.selectAll() })
  }
  function closeSearch() {
    root.searchMode = false
    searchField.text = ""
    if (root.am) root.am.clearSearch()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  function playResult(r, mode) {
    if (!r || !root.am) return
    root.am.playItem(r.kind, r.id, mode)
    if (mode === "now") root.closeSearch()
  }
  onPopupOpenChanged: if (!popupOpen && searchMode) closeSearch()

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

  // KeyboardPanel (not PopupCard) so the search field can take typing.
  KeyboardPanel {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(360))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus
      onCloseRequested: root.searchMode ? root.closeSearch() : root.close()
      onTextKey: function(t) {
        if (!root.am) return
        if (t === "/" || t === "s") root.openSearch()
        else if (t === "p") root.am.playPause()
        else if (t === "n") root.am.next()
        else if (t === "b") root.am.previous()
        else if (t === "r") root.am.cycleRepeat()
        else if (t === "f") root.am.toggleLike()
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(10)

        // ---- search bar (always visible; typing switches to results) ----
        Row {
          width: parent.width
          spacing: Style.space(6)
          visible: root.running

          TextField {
            id: searchField
            width: parent.width - (root.searchMode ? closeSearchButton.width + Style.space(6) : 0)
            placeholderText: Logic.G.search + "  Search Apple Music"
            foreground: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            verticalPadding: Style.space(4)
            enabled: root.am !== null && root.am.bridged
            onActiveFocusChanged: if (activeFocus && !root.searchMode) root.searchMode = true
            onTextChanged: if (root.searchMode) debounce.restart()
            Keys.onPressed: function(event) {
              var n = root.searchFlat.length
              if (event.key === Qt.Key_Escape) {
                root.closeSearch(); event.accepted = true
              } else if (event.key === Qt.Key_Down) {
                root.searchCursor = Logic.clampIndex(root.searchCursor + 1, n); event.accepted = true
              } else if (event.key === Qt.Key_Up) {
                root.searchCursor = Logic.clampIndex(root.searchCursor - 1, n); event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                debounce.stop()
                if (root.searchCursor >= 0 && root.searchCursor < n) {
                  var mode = (event.modifiers & Qt.ShiftModifier) ? "next" : ((event.modifiers & Qt.ControlModifier) ? "later" : "now")
                  root.playResult(root.searchFlat[root.searchCursor], mode)
                } else if (root.am) {
                  root.am.search(text)
                }
                event.accepted = true
              }
            }
            Timer {
              id: debounce
              interval: 350
              onTriggered: { root.searchCursor = -1; if (root.am) root.am.search(searchField.text) }
            }
          }
          Button {
            id: closeSearchButton
            visible: root.searchMode
            iconText: Logic.G.close
            tooltipText: "Close search (Esc)"
            foreground: root.bar.foreground
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.closeSearch()
          }
        }

        // ---- search results ----
        Column {
          id: searchView
          width: parent.width
          spacing: Style.space(4)
          visible: root.searchMode

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: text !== ""
            text: !root.am ? ""
                : root.am.searching ? "Searching…"
                : root.am.searchFailed ? "Search failed. Is Apple Music signed in?"
                : (root.am.searchTerm.length >= 2 && root.searchFlat.length === 0) ? "No results"
                : root.am.searchTerm.length < 2 ? "Type to search. ↑↓ select · Enter play · Shift+Enter play next · Ctrl+Enter add to queue"
                : ""
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.am ? root.am.searchResults : []
            Column {
              id: section
              required property var modelData
              required property int index
              readonly property int offset: {
                var o = 0
                for (var i = 0; i < index; i++) o += root.am.searchResults[i].items.length
                return o
              }
              width: searchView.width
              spacing: Style.space(2)
              Text {
                textFormat: Text.PlainText
                text: section.modelData.title
                color: Qt.darker(root.bar.foreground, 1.6)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                topPadding: section.index > 0 ? Style.space(4) : 0
              }
              Repeater {
                model: section.modelData.items
                SearchRow {
                  required property var modelData
                  required property int index
                  width: searchView.width
                  bar: root.bar
                  result: modelData
                  selected: root.searchCursor === section.offset + index
                  onPlay: function(mode) { root.playResult(modelData, mode) }
                }
              }
            }
          }
        }

        // ---- now playing ----
        Row {
          spacing: Style.space(10)
          width: parent.width
          visible: !root.searchMode

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
          visible: !root.searchMode && root.hasTrack && root.am && root.am.length > 0

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
          visible: root.running && !root.searchMode

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
          visible: root.running && !root.searchMode

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

        PanelSeparator {
          foreground: root.bar.foreground
          visible: queueSection.visible
        }

        // Previous / Up next, from the MusicKit queue via the bridge extension.
        Column {
          id: queueSection
          width: parent.width
          spacing: Style.space(4)
          visible: !root.searchMode && root.am !== null && root.am.hasQueue

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
            glyph: Logic.G.prev
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
              glyph: index === 0 ? Logic.G.next : ""
              onActivated: modelData.index >= 0 ? root.am.playQueueIndex(modelData.index)
                                                : (index === 0 ? root.am.next() : null)
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground; visible: !root.searchMode }

        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(6)
          visible: !root.searchMode

          Button {
            text: !root.running ? "Open Apple Music" : (root.am && root.am.windowHidden ? "Show window" : "Hide window")
            iconText: !root.running ? "" : (root.am && root.am.windowHidden ? Logic.G.eye : Logic.G.eyeOff)
            tooltipText: root.running ? "Hidden windows keep playing" : ""
            foreground: root.bar.foreground
            bordered: true
            onClicked: {
              if (!root.running) { root.am.launch(); root.popupOpen = false }
              else if (root.am.windowHidden) { root.am.showWindow(); root.popupOpen = false }
              else root.am.hideWindow()
            }
          }
          Button {
            text: "Quit"
            visible: root.running
            foreground: root.bar.foreground
            bordered: true
            onClicked: { root.am.quit(); root.popupOpen = false }
          }
        }
      }
    }
  }
}
