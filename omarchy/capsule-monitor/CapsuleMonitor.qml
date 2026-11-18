import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Capsule System Monitor for the Omarchy bar - a port of the Cinnamon applet
// (github.com/gaborkis11/capsule-monitor). Every value sits in a slot whose
// width is fixed from font metrics, never from the current value, so the
// capsule never changes width while the numbers move.
BarWidget {
  id: root
  moduleName: "gaborkis.capsule-monitor"

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")

  // ------------------------------------------------------------- settings

  readonly property var elementIds: Model.normalizeElements(setting("elements", Model.DEFAULT_ELEMENTS))
  readonly property var cfg: ({
    thresholds: setting("thresholds", ({})),
    modes: setting("modes", ({})),
    sustainSeconds: Number(setting("sustainSeconds", 10)),
    diskMount: String(setting("diskMount", "/"))
  })
  readonly property int refreshMs: Model.clamp(Number(setting("refreshMs", 1000)) || 1000, 250, 10000)
  readonly property int gpuRefreshMs: Model.clamp(Number(setting("gpuRefreshMs", 5000)) || 5000, 1000, 60000)
  readonly property bool gpuWanted: elementIds.indexOf("gpu") >= 0 || elementIds.indexOf("gfx") >= 0
  readonly property string clickCommand: String(setting("clickCommand", "omarchy-launch-or-focus-tui btop"))
  readonly property color netUpColor: String(setting("netColorUp", "#E5484D"))
  readonly property color netDownColor: String(setting("netColorDown", "#46A758"))
  readonly property color alertColor: String(setting("alertColor", "#FF8C00"))
  readonly property int fixedWidth: Number(setting("fixedWidth", 0)) || 0

  // ------------------------------------------------------------- geometry

  readonly property int capsuleHeight: Model.clamp(barSize - 2, 18, 34)
  readonly property bool showLabels: setting("showLabels", true) !== false && capsuleHeight >= 20
  readonly property bool roomy: capsuleHeight >= 28
  readonly property int labelPx: roomy ? 8 : 7
  readonly property int valuePx: roomy ? 12 : 11
  readonly property int unitPx: roomy ? 8 : 7
  readonly property int netPx: roomy ? 10 : 9
  readonly property int netUnitPx: roomy ? 7 : 6
  readonly property string fontFamily: String(setting("fontFamily", "Noto Sans"))

  readonly property real labelCap: labelFm.tightBoundingRect("M").height
  readonly property real valueCap: valueFm.tightBoundingRect("0").height
  readonly property real netCap: netFm.tightBoundingRect("0").height
  readonly property real gap1: roomy ? 2.5 : 2
  readonly property real gap2: roomy ? 3 : 2.5
  readonly property real inset: roomy ? 3 : 2.5
  readonly property real barHeight: showLabels
    ? (roomy ? 3 : 2)
    : Math.max(3, Math.round(capsuleHeight - 2 * inset - valueCap - gap2))
  readonly property real contentHeight: (showLabels ? labelCap + gap1 : 0) + valueCap + gap2 + barHeight
  readonly property real contentTop: Math.round((capsuleHeight - contentHeight) / 2)
  readonly property real labelBaseline: contentTop + labelCap
  readonly property real valueBaseline: Math.round((showLabels ? labelBaseline + gap1 : contentTop) + valueCap)
  readonly property real barY: Math.round(valueBaseline + gap2)

  // Widest possible text of each kind, so a cell is cut once for all values.
  readonly property real pctWidth: Math.ceil(valueFm.advanceWidth("888") + unitFm.advanceWidth("%") + 1)
  readonly property real absWidth: Math.ceil(valueFm.advanceWidth("88,8") + unitFm.advanceWidth("G") + 1)
  readonly property real labelWidth: Math.ceil(labelFm.advanceWidth("MEM") * 1.15)
  readonly property int cellSpacing: 7
  readonly property int netGraphWidth: 59     // 20 columns: 19 * 3 px pitch + 2 px
  readonly property int netInnerGap: 4
  readonly property int arrowSize: 5
  readonly property real netNumbersWidth: Math.ceil(netFm.advanceWidth("88,8") + arrowSize + 2 + netUnitFm.advanceWidth("M") + 1)

  function cellWidth(id) {
    if (id === "net") return netGraphWidth + netInnerGap + netNumbersWidth
    var abs = Model.ELEMENTS[id].absFrom && cfg.modes && cfg.modes[id] === "abs"
    return Math.max(abs ? absWidth : pctWidth, showLabels ? labelWidth : 0, 26)
  }

  function tint(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  readonly property color fg: bar ? bar.barForeground : Commons.Color.foreground

  // ----------------------------------------------------------------- state

  property var values: ({})
  property var display: ({})
  property bool anyAlert: false
  property var rings: ({ cpu: [], tmp: [] })

  function sustainCapacity() {
    if (!(cfg.sustainSeconds > 0)) return 1
    return Math.max(1, Math.round(cfg.sustainSeconds * 1000 / refreshMs))
  }

  function pushRing(ring, value) {
    if (typeof value !== "number" || !isFinite(value)) return
    ring.push(value)
    var cap = sustainCapacity()
    while (ring.length > cap) ring.shift()
  }

  function ingest(line) {
    var parsed
    try { parsed = JSON.parse(line) } catch (e) { return }
    if (!parsed || typeof parsed !== "object") return
    pushRing(rings.cpu, parsed.cpu ? parsed.cpu.pct : null)
    pushRing(rings.tmp, parsed.tmp ? parsed.tmp.celsius : null)
    values = parsed
    recompute()
  }

  function recompute() {
    var next = {}
    var alert = false
    for (var i = 0; i < elementIds.length; i++) {
      var id = elementIds[i]
      var d = Model.displayFor(id, values, cfg, rings)
      next[id] = d
      if (d && d.alert) alert = true
    }
    display = next
    anyAlert = alert
    if (tooltipHovered && bar) bar.showTooltip(root, tooltipText())
  }

  function tooltipText() { return Model.tooltip(elementIds, values, cfg, rings) }

  onCfgChanged: recompute()
  onElementIdsChanged: recompute()

  // ---------------------------------------------------------------- sampler

  readonly property var samplerCommand: {
    var cmd = ["python3", "-u", pluginDir + "/sampler.py",
               "--interval", String(refreshMs),
               "--gpu-interval", String(gpuRefreshMs),
               "--mount", cfg.diskMount]
    if (!gpuWanted) cmd.push("--no-gpu")
    return cmd
  }
  onSamplerCommandChanged: {
    if (sampler.running) sampler.running = false
    else restartTimer.restart()
  }

  Process {
    id: sampler
    command: root.samplerCommand
    running: root.pluginDir !== "" && !root.vertical
    stdout: SplitParser { onRead: function(data) { root.ingest(data) } }
    onExited: restartTimer.restart()
  }

  Timer {
    id: restartTimer
    interval: 1500
    onTriggered: if (root.pluginDir !== "" && !root.vertical) sampler.running = true
  }

  // ---------------------------------------------------------------- metrics

  FontMetrics { id: labelFm; font.family: root.fontFamily; font.pixelSize: root.labelPx }
  FontMetrics { id: valueFm; font.family: root.fontFamily; font.pixelSize: root.valuePx }
  FontMetrics { id: unitFm; font.family: root.fontFamily; font.pixelSize: root.unitPx }
  FontMetrics { id: netFm; font.family: root.fontFamily; font.pixelSize: root.netPx }
  FontMetrics { id: netUnitFm; font.family: root.fontFamily; font.pixelSize: root.netUnitPx }

  // ------------------------------------------------------------------- view

  visible: !vertical
  implicitWidth: vertical ? 0 : (fixedWidth > 0 ? fixedWidth : capsule.width)
  implicitHeight: barSize

  readonly property bool tooltipHovered: visible && mouseArea.containsMouse

  Rectangle {
    id: capsule
    anchors.centerIn: parent
    height: root.capsuleHeight
    width: cells.width + 18
    radius: height / 2
    color: root.anyAlert ? root.tint(root.alertColor, 0.10) : root.tint(root.fg, 0.055)

    Row {
      id: cells
      x: 9
      height: parent.height
      spacing: root.cellSpacing

      Repeater {
        model: root.elementIds

        delegate: Item {
          id: cell
          required property string modelData
          readonly property var item: root.display[modelData] || null
          readonly property bool alert: !!(item && item.alert)
          width: root.cellWidth(modelData)
          height: cells.height

          Loader {
            anchors.fill: parent
            sourceComponent: cell.modelData === "net" ? netCell : valueCell
          }

          Component {
            id: valueCell

            Item {
              Text {
                visible: root.showLabels
                textFormat: Text.PlainText
                text: Model.ELEMENTS[cell.modelData].label
                font.family: root.fontFamily
                font.pixelSize: root.labelPx
                font.letterSpacing: root.labelPx * 0.05
                color: cell.alert ? root.tint(root.alertColor, 0.62) : root.tint(root.fg, 0.30)
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.baseline: parent.top
                anchors.baselineOffset: root.labelBaseline
              }

              Item {
                id: valueRow
                readonly property real textWidth: valueText.contentWidth + (unitText.visible ? unitText.contentWidth + 0.5 : 0)
                x: Math.round((parent.width - textWidth) / 2)
                width: textWidth
                height: parent.height

                Text {
                  id: valueText
                  textFormat: Text.PlainText
                  text: cell.item ? cell.item.text : Model.EM_DASH
                  font.family: root.fontFamily
                  font.pixelSize: root.valuePx
                  font.features: { "tnum": 1 }
                  color: cell.alert ? root.alertColor : root.tint(root.fg, 0.62)
                  anchors.baseline: parent.top
                  anchors.baselineOffset: root.valueBaseline
                }

                Text {
                  id: unitText
                  visible: !!(cell.item && cell.item.unit)
                  textFormat: Text.PlainText
                  text: cell.item ? cell.item.unit : ""
                  font.family: root.fontFamily
                  font.pixelSize: root.unitPx
                  color: cell.alert ? root.tint(root.alertColor, 0.55) : root.tint(root.fg, 0.32)
                  anchors.left: valueText.right
                  anchors.leftMargin: 0.5
                  anchors.baseline: valueText.baseline
                }
              }

              Rectangle {
                id: track
                y: root.barY
                width: parent.width
                height: root.barHeight
                radius: root.showLabels ? 1 : 3
                color: root.tint(root.fg, 0.12)

                Rectangle {
                  height: parent.height
                  radius: parent.radius
                  width: Math.round((cell.item ? cell.item.ratio : 0) * parent.width)
                  color: cell.alert ? root.alertColor : root.tint(root.fg, 0.42)
                }
              }
            }
          }

          Component {
            id: netCell

            Item {
              readonly property real mid: Math.round(height / 2)

              Canvas {
                id: graph
                x: 0
                y: Math.round(root.inset)
                width: root.netGraphWidth
                height: parent.height - 2 * Math.round(root.inset)
                readonly property var barsUp: cell.item ? cell.item.barsUp : []
                readonly property var barsDown: cell.item ? cell.item.barsDown : []
                readonly property color axis: root.tint(root.fg, 0.10)
                onBarsUpChanged: requestPaint()
                onAxisChanged: requestPaint()
                Connections {
                  target: root
                  function onNetUpColorChanged() { graph.requestPaint() }
                  function onNetDownColorChanged() { graph.requestPaint() }
                }

                onPaint: {
                  var ctx = getContext("2d")
                  ctx.reset()
                  var center = height / 2
                  var maxDeflect = Math.max(1, center - 0.5)
                  ctx.fillStyle = axis
                  ctx.fillRect(0, center - 0.5, width, 1)
                  function bars(list, color, up) {
                    ctx.fillStyle = color
                    for (var i = 0; i < 20; i++) {
                      var v = list && i < list.length ? list[i] : 0
                      if (!(v > 0)) continue
                      var h = Math.max(1, Math.round(Math.min(1, v) * maxDeflect))
                      var x = i * 3
                      var y = up ? center - 0.5 - h : center + 0.5
                      ctx.fillRect(x, y, 2, h)
                    }
                  }
                  bars(barsUp, root.netUpColor, true)
                  bars(barsDown, root.netDownColor, false)
                }
              }

              Repeater {
                model: [
                  { up: true },
                  { up: false }
                ]

                delegate: Item {
                  id: netRow
                  required property var modelData
                  readonly property bool isUp: modelData.up
                  x: root.netGraphWidth + root.netInnerGap
                  width: root.netNumbersWidth
                  height: parent.height
                  readonly property real rowBaselineY: isUp ? parent.mid - 1.5 : parent.mid + 1.5 + root.netCap

                  Text {
                    id: netUnit
                    textFormat: Text.PlainText
                    text: cell.item ? (netRow.isUp ? cell.item.upUnit : cell.item.downUnit) : ""
                    font.family: root.fontFamily
                    font.pixelSize: root.netUnitPx
                    color: root.tint(root.fg, 0.32)
                    anchors.right: parent.right
                    anchors.baseline: parent.top
                    anchors.baselineOffset: netRow.rowBaselineY
                  }

                  Canvas {
                    id: arrow
                    width: root.arrowSize
                    height: root.arrowSize
                    anchors.right: netUnit.left
                    anchors.rightMargin: 1
                    y: Math.round(netRow.rowBaselineY - root.netCap / 2 - height / 2)
                    readonly property color arrowColor: netRow.isUp ? root.netUpColor : root.netDownColor
                    onArrowColorChanged: requestPaint()
                    onPaint: {
                      var ctx = getContext("2d")
                      ctx.reset()
                      ctx.fillStyle = arrowColor
                      ctx.beginPath()
                      if (netRow.isUp) {
                        ctx.moveTo(width / 2, 0.5); ctx.lineTo(width - 0.5, height - 0.5); ctx.lineTo(0.5, height - 0.5)
                      } else {
                        ctx.moveTo(width / 2, height - 0.5); ctx.lineTo(width - 0.5, 0.5); ctx.lineTo(0.5, 0.5)
                      }
                      ctx.closePath()
                      ctx.fill()
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: cell.item ? (netRow.isUp ? cell.item.upText : cell.item.downText) : Model.EM_DASH
                    font.family: root.fontFamily
                    font.pixelSize: root.netPx
                    font.features: { "tnum": 1 }
                    color: root.tint(root.fg, 0.62)
                    anchors.right: arrow.left
                    anchors.rightMargin: 0.5
                    anchors.baseline: parent.top
                    anchors.baselineOffset: netRow.rowBaselineY
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton
    cursorShape: Qt.PointingHandCursor
    onEntered: if (root.bar) root.bar.showTooltip(root, root.tooltipText())
    onExited: if (root.bar) root.bar.hideTooltip(root)
    onClicked: if (root.bar && root.clickCommand) root.bar.run(root.clickCommand)
  }
}
