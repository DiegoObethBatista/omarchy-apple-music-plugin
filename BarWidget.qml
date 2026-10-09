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
        SearchResults {
          width: parent.width
          visible: root.searchMode
          am: root.am
          bar: root.bar
          flat: root.searchFlat
          cursor: root.searchCursor
          onPlayRequested: function(result, mode) { root.playResult(result, mode) }
        }

        // ---- now playing: artwork, seek, transport, song actions ----
        NowPlaying {
          width: parent.width
          visible: !root.searchMode
          am: root.am
          bar: root.bar
        }

        PanelSeparator {
          foreground: root.bar.foreground
          visible: queuePanel.visible
        }

        QueuePanel {
          id: queuePanel
          width: parent.width
          visible: !root.searchMode && root.am !== null && root.am.hasQueue
          am: root.am
          bar: root.bar
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
