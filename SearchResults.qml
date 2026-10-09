import QtQuick
import qs.Ui
import qs.Commons
import "Logic.js" as Logic

// Search results view: status line plus one section per result kind
// (songs / albums / playlists, library first). Rows are SearchRow.
Column {
  id: searchView

  property var am: null
  property QtObject bar: null
  property var flat: []          // Logic.flatten(am.searchResults), for the cursor
  property int cursor: -1
  signal playRequested(var result, string mode)

  spacing: Style.space(4)

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: text !== ""
    text: !searchView.am ? ""
        : searchView.am.searching ? "Searching…"
        : searchView.am.searchFailed ? "Search failed. Is Apple Music signed in?"
        : (searchView.am.searchTerm.length >= 2 && searchView.flat.length === 0) ? "No results"
        : searchView.am.searchTerm.length < 2 ? "Type to search. ↑↓ select · Enter play · Shift+Enter play next · Ctrl+Enter add to queue"
        : ""
    color: Qt.darker(searchView.bar.foreground, 1.5)
    font.family: searchView.bar.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Repeater {
    model: searchView.am ? searchView.am.searchResults : []
    Column {
      id: section
      required property var modelData
      required property int index
      readonly property int offset: {
        var o = 0
        for (var i = 0; i < index; i++) o += searchView.am.searchResults[i].items.length
        return o
      }
      width: searchView.width
      spacing: Style.space(2)
      Text {
        textFormat: Text.PlainText
        text: section.modelData.title
        color: Qt.darker(searchView.bar.foreground, 1.6)
        font.family: searchView.bar.fontFamily
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
          bar: searchView.bar
          result: modelData
          selected: searchView.cursor === section.offset + index
          onPlay: function(mode) { searchView.playRequested(modelData, mode) }
        }
      }
    }
  }
}
