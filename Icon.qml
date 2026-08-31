import QtQuick
import qs.Commons

// The bar wordmark: OMADOKU laid out as one row of a sudoku grid.
//
// Drawn rather than set in a font because no icon font carries this, and
// because the obvious alternative does not survive contact with a 26px bar: a
// 3x3 grid of nine characters gives each glyph about five pixels and reads as
// noise. Seven cells in a single row gives each letter the full height of the
// icon, which reads cleanly.
Item {
  id: root

  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property int barSize: Style.bar.sizeHorizontal
  property string letters: "OMADOKU"

  // Hairlines stay at one physical pixel: a 2px rule around an 18px box eats
  // the cell it is supposed to be dividing.
  readonly property real line: 1
  readonly property real cellHeight: Math.max(14, Math.round(barSize * 0.70))
  readonly property real cellWidth: Math.max(7, Math.round(cellHeight * 0.50))
  readonly property int cells: letters.length

  function shade(alpha) {
    return Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, alpha)
  }

  implicitWidth: cellWidth * cells + line
  implicitHeight: cellHeight

  // The board edge.
  Rectangle {
    anchors.fill: parent
    color: "transparent"
    border.width: root.line
    border.color: root.shade(0.55)
  }

  // Cell divisions, dimmer than the edge. Brightness rather than thickness
  // separates them, for the same reason the hairline stays at 1px.
  Repeater {
    model: root.cells - 1

    Rectangle {
      required property int index
      x: Math.round(root.line + (index + 1) * root.cellWidth - root.line / 2)
      y: root.line
      width: root.line
      height: root.height - root.line * 2
      color: root.shade(0.32)
    }
  }

  Repeater {
    model: root.cells

    Text {
      required property int index
      x: root.line + index * root.cellWidth
      width: root.cellWidth
      height: root.height
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      textFormat: Text.PlainText
      text: root.letters.charAt(index)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Math.max(7, Math.round(root.cellHeight * 0.50))
      font.bold: true
      // Hinted rendering, because at this size antialiased stems turn to fog.
      renderType: Text.NativeRendering
    }
  }
}
