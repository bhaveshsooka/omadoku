import QtQuick
import qs.Commons

// The compact bar mark: a 3x3 sudoku grid with four cells written in.
//
// The wordmark in Icon.qml is 64px of art before padding, which is more bar
// than a game deserves sitting next to the clock. This says the same thing in
// 16px, and unlike the wordmark it is square, so it fits a vertical bar too.
//
// Dots rather than filled cells. Solid blocks at this size read as a
// checkerboard rather than a sudoku board, and they leave no empty ground for
// the solved fill to show against - the mark would gain a state it could not
// display. Dots read as entries written into cells, which is the idea.
Item {
  id: root

  property color foreground: Color.foreground
  property int barSize: Style.bar.sizeHorizontal

  // Lit up on a win exactly as the wordmark is: the box fills and its edge
  // brightens. Not a colour change, because the bar's palette has an urgent
  // colour and no success one, and accent is not a safe substitute - some
  // themes set it equal to foreground.
  property bool solved: false

  // Hairlines stay at one physical pixel; a 2px rule around a 4px cell eats
  // the cell it is meant to divide.
  readonly property real line: 1

  // Derived so the box always divides into exactly three cells and two
  // dividers. Sizing it from the wordmark's cellHeight instead gives cells of
  // 4/5/4 and visibly uneven dots, at the one scale where evenness is all the
  // mark has to work with.
  readonly property int cell: Math.max(3, Math.round((barSize * 0.62 - 4) / 3))
  readonly property int box: cell * 3 + 4
  readonly property int dot: Math.max(2, cell - 2)

  // Which cells are written in. Asymmetric on purpose: a symmetric pattern
  // reads as decoration, this reads as a board part of the way through.
  readonly property var written: [[0, 0], [1, 1], [1, 2], [2, 0]]

  function shade(alpha) {
    return Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, alpha)
  }

  implicitWidth: box
  implicitHeight: box

  Rectangle {
    anchors.fill: parent
    color: root.solved ? root.shade(0.22) : "transparent"
    border.width: root.line
    border.color: root.shade(root.solved ? 0.85 : 0.55)

    // Wins arrive, they do not blink into place.
    Behavior on color { ColorAnimation { duration: 220 } }
    Behavior on border.color { ColorAnimation { duration: 220 } }
  }

  // Box divisions, dimmer than the edge. Brightness separates them rather than
  // thickness, for the same reason the hairline stays at 1px.
  Repeater {
    model: 2

    Rectangle {
      required property int index
      x: root.line + (index + 1) * (root.cell + root.line) - root.line
      y: root.line
      width: root.line
      height: root.box - root.line * 2
      color: root.shade(0.32)
    }
  }

  Repeater {
    model: 2

    Rectangle {
      required property int index
      x: root.line
      y: root.line + (index + 1) * (root.cell + root.line) - root.line
      width: root.box - root.line * 2
      height: root.line
      color: root.shade(0.32)
    }
  }

  Repeater {
    model: root.written

    Rectangle {
      required property var modelData
      readonly property real pad: (root.cell - root.dot) / 2
      x: root.line + modelData[1] * (root.cell + root.line) + pad
      y: root.line + modelData[0] * (root.cell + root.line) + pad
      width: root.dot
      height: root.dot
      color: root.shade(0.85)
    }
  }
}
