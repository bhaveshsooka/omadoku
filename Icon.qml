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

  // Lit up on a win: the cells fill and the edge brightens.
  //
  // Signalled by fill rather than by colour because the bar's palette has an
  // urgent colour and no success one, and the obvious substitute does not hold
  // - in Kanagawa, among others, accent and foreground are the same value, so
  // an accent-coloured win is no win at all. Filling reads in every theme.
  property bool solved: false

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

  // The board edge, and the fill behind it that carries the solved state.
  Rectangle {
    anchors.fill: parent
    color: root.solved ? root.shade(0.20) : "transparent"
    border.width: root.line
    border.color: root.shade(root.solved ? 0.85 : 0.55)

    // Wins arrive, they do not blink into place.
    Behavior on color { ColorAnimation { duration: 220 } }
    Behavior on border.color { ColorAnimation { duration: 220 } }
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
