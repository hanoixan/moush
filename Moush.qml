pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

// Moush: drive the pointer from the keyboard.
//
// The mode is a grid of keys under one hand. Mashing across them rolls the
// pointer like a trackball; a key struck alone steps in its own direction with
// acceleration, edge snapping and a double-tap skitter behind it; holding the
// wheel key turns the whole thing into a scroll wheel.
//
// Everything about which key does what, and where each key sits in space, lives
// in bindings.lua. This file knows actions and coordinates, never keysyms —
// except where it must ask the compositor whether a key is still down, and even
// then the spelling comes from there.
//
// Three facts about Hyprland shape most of what follows:
//
//  1. An overlay cannot take keyboard focus. Exclusive focus makes Hyprland
//     swallow every pointer event, and OnDemand delivers one key and then stops.
//     So keys arrive as global shortcuts dispatched from binds inside a submap.
//
//  2. There is no key release. A `release = true` bind fires only with exec_cmd,
//     and once two bound keys are held Hyprland delivers neither key's release.
//     Anything that needs to know a key is still down asks hl.is_key_down.
//
//  3. Key repeat stops as soon as a second bound key is held, so a repeat-driven
//     ramp dies the moment a modifier key joins it. Those repeats are generated
//     here instead.
Item {
  id: root

  // Injected by omarchy-shell when the overlay loads.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  function log(msg) { if (root.debug) console.warn("[moush] " + msg) }
  readonly property bool debug: false

  // ---- actions ---------------------------------------------------------------
  // Grid keys are actions named by index, so bindings.lua can place them at any
  // coordinates it likes without this file knowing them in advance. The pool is
  // fixed because GlobalShortcut objects are declared, not created on demand.
  readonly property int maxKeys: 48
  readonly property var gridActions: {
    var out = []
    for (var i = 0; i < root.maxKeys; i++) out.push("k" + i)
    return out
  }
  readonly property var actions: ["up", "down", "left", "right",
                                  "upleft", "upright", "downleft", "downright",
                                  "lmb", "mmb", "rmb",
                                  "wheel", "fine", "cycle", "debug", "strategy",
                                  "noop"].concat(root.gridActions)

  // Diagonals are normalised, so one press covers the same ground as a cardinal
  // press rather than 1.41 times as much.
  readonly property real diag: 0.70710678
  readonly property var actionDirs: ({ "up": [0, -1], "down": [0, 1],
                                       "left": [-1, 0], "right": [1, 0],
                                       "upleft": [-root.diag, -root.diag],
                                       "upright": [root.diag, -root.diag],
                                       "downleft": [-root.diag, root.diag],
                                       "downright": [root.diag, root.diag] })

  // ---- tuning ----------------------------------------------------------------
  readonly property real baseStep: 8          // pixels a single press moves
  readonly property real finePx: 1            // ...with the fine key held
  readonly property real edgeEpsilon: 0.5     // an edge this close counts as reached
  readonly property int repeatGapMs: 55       // longer gap than this: the key is up
  readonly property int holdChainMs: 400      // same key again within this: same hold
  readonly property int takeoverGraceMs: 320  // bridges a new key's repeat delay
  readonly property int sweepMs: 1500         // hold this long to cross one screen
  readonly property int motionTickMs: 16
  readonly property int resyncMs: 130         // wait for a focus warp, then refresh
  readonly property int landMs: 60            // ...then for the geometry to arrive
  readonly property int armPollMs: 60         // chord release, while arming
  readonly property int longPressMs: 500      // chord held this long latches
  readonly property int idleMs: 2000          // unlatched session dies after this
  readonly property int hintMs: 900           // mode name shown this long
  readonly property real markerSize: 28
  readonly property int keysArmMs: 25         // ask before a hold would lapse
  readonly property int keysPollMs: 60        // ...and keep asking while held
  readonly property int keysGraceMs: 60       // each "still down" is good for this
  readonly property int wheelPollMs: 70       // wheel and fine keys, while held
  readonly property int scrollEndDetents: 120 // a double-tap runs to the view's end
  readonly property real mashScrollPx: 90     // ball travel per detent, while scrolling
  readonly property int mashClusterMs: 200    // a longer gap starts a new gesture
  readonly property real mashFriction: 3.0    // e-folds/s of rolling decay
  readonly property int scrollStartMs: 250    // before the first scroll repeat
  readonly property int btnMaxMs: 15000       // a lost release must not pin a button

  // ---- settings, from bindings.lua -------------------------------------------
  // A mode may override any of these by naming it; the merge happens in Lua so it
  // is written once. Hyprland keeps its globals across config loads, so a
  // hyprctl reload is enough to apply a change: they are re-read every session.
  property int fastTapMs: 135
  property int carryMs: 175
  property real mashGain: 20
  property real mashVMax: 1000
  property int mashSamples: 4
  property string mashStrategy: "lsq"
  property var mashStrategies: ["lsq"]
  property var mashDebugStrategies: ["lsq"]
  property real scrollRepeatScaleMin: 1
  property real scrollRepeatScaleMax: 10
  property real scrollRepeatScaleUltra: 100
  property real scrollIncreaseDelay: 1.5      // seconds, as the name says
  property real scrollIncreaseTime: 5         // seconds
  property int scrollRepeatMs: 60

  // The grid, as bindings.lua describes it: index -> label and position. The
  // coordinate space is whatever the config chose; only mashGain relates it to
  // pixels. x grows rightward and y downward, matching the screen.
  property var mashLabels: ({})               // index -> key name, for the overlay
  property var mashPos: ({})                  // index -> {x, y}
  property var mashDirs: ({})                 // index -> direction, for lone presses
  property var modeKeys: ({})                 // lmb/mmb/rmb/wheel/fine -> key name

  property string mode: "mash"
  property var modeNames: ["mash"]
  readonly property string statePath: Quickshell.statePath("moush.json")

  // The saved mode is taken on trust here, because the list of real modes does not
  // exist yet -- it arrives with the first settings fetch. Validating against it at
  // this point silently discarded every mode but the default. The check still
  // happens, just later, once there is something to check against.
  function loadState(text) {
    try {
      var st = JSON.parse(text)
      if (st && typeof st.mode === "string" && st.mode !== "") root.mode = st.mode
    } catch (e) {}
  }

  function saveState() {
    stateFile.setText(JSON.stringify({ mode: root.mode }, null, 2) + "\n")
  }

  function cycleMode() {
    var i = root.modeNames.indexOf(root.mode)
    root.mode = root.modeNames[(i + 1) % root.modeNames.length]
    // The overlay is keyed on grid *indices*, so every one of them now means a
    // different key. Carrying the cluster over would shade the new grid by the old
    // mode's presses; the aux flashes belong to keys that may not exist here.
    root.dbgHits = []
    root.dbgStrats = ({})
    root.dbgDriveAt = 0
    root.dbgAux = ({})
    if (root.opened) root.hypr('hl.dsp.submap("moush-' + root.mode + '")')
    root.saveState()
    settings.running = true                   // the new mode brings its own keys
    root.log("mode -> " + root.mode)
    hintTimer.restart()
  }

  // Cycles which strategy steers. There is one for now, so it lands back where it
  // started; the machinery stays because adding another is then a two-line change.
  function cycleStrategy() {
    var list = root.mashDebugStrategies.length > 0 ? root.mashDebugStrategies
                                                   : root.mashStrategies
    if (list.length === 0) return
    var i = list.indexOf(root.mashStrategy)
    root.mashStrategy = list[(i + 1) % list.length]
    root.pokeIdle()
    root.log("strategy -> " + root.mashStrategy)
    if (root.mashDebug) dbgTimer.start()
  }

  function applySetting(k, v) {
    if (k === "keys") {                       // index:label:x:y, comma separated
      var lab = ({}), pos = ({})
      var parts = v === "" ? [] : v.split(",")
      for (var i = 0; i < parts.length; i++) {
        var f = parts[i].split(":")
        if (f.length !== 4) continue
        lab[f[0]] = f[1]
        pos[f[0]] = ({ x: parseFloat(f[2]), y: parseFloat(f[3]) })
      }
      root.mashLabels = lab
      root.mashPos = pos
      return
    }
    if (k === "dirs") {
      var dm = ({})
      var dp = v === "" ? [] : v.split(",")
      for (var j = 0; j < dp.length; j++) {
        var g = dp[j].split(":")
        if (g.length === 2) dm[g[0]] = g[1]
      }
      root.mashDirs = dm
      return
    }
    if (k === "modes") {
      if (v !== "") root.modeNames = v.split(",")
      // A saved mode that no longer exists -- renamed or deleted in bindings.lua --
      // would leave the session in a submap with no binds, so fall back and re-fetch.
      if (root.modeNames.indexOf(root.mode) === -1) {
        root.log("mode " + root.mode + " is gone; falling back to " + root.modeNames[0])
        root.mode = root.modeNames[0]
        root.saveState()
        settings.running = true
      }
      return
    }
    if (k === "lmb" || k === "mmb" || k === "rmb" || k === "wheel" || k === "fine"
        || k === "cycle" || k === "debug" || k === "strategy") {
      var mk = ({})
      for (var q in root.modeKeys) mk[q] = root.modeKeys[q]
      mk[k] = v
      root.modeKeys = mk
      return
    }
    if (k === "mash_strategy") {
      if (root.mashStrategies.indexOf(v) >= 0) root.mashStrategy = v
      return
    }
    if (k === "mash_debug_strategies") {
      var want = v === "" ? [] : v.split(","), good = []
      for (var d = 0; d < want.length; d++)
        if (root.mashStrategies.indexOf(want[d]) >= 0) good.push(want[d])
      root.mashDebugStrategies = good
      return
    }
    var n = parseFloat(v)
    if (!(n > 0)) return
    if (k === "fast_tap_ms") root.fastTapMs = n
    else if (k === "carry_ms") root.carryMs = n
    else if (k === "mash_gain") root.mashGain = n
    else if (k === "mash_vmax") root.mashVMax = n
    else if (k === "mash_samples") root.mashSamples = n
    else if (k === "scroll_repeat_scale_min") root.scrollRepeatScaleMin = n
    else if (k === "scroll_repeat_scale_max") root.scrollRepeatScaleMax = n
    else if (k === "scroll_repeat_scale_ultra") root.scrollRepeatScaleUltra = n
    else if (k === "scroll_increase_delay") root.scrollIncreaseDelay = n
    else if (k === "scroll_increase_time") root.scrollIncreaseTime = n
    else if (k === "scroll_repeat_ms") root.scrollRepeatMs = n
  }

  function onSettings(text) {
    var parts = String(text).trim().split(/\s+/)
    for (var i = 0; i < parts.length; i++) {
      var eq = parts[i].indexOf("=")
      if (eq > 0) root.applySetting(parts[i].slice(0, eq), parts[i].slice(eq + 1))
    }
    // The grid and the aux row are both this mode's, and they only exist once this
    // has run, so a mode cycle redraws from here rather than from cycleMode.
    if (root.mashDebug) { root.dbgLastAt = Date.now(); dbgTimer.start() }
  }

  // ---- session state ---------------------------------------------------------
  property bool opened: false                 // overlay mapped, from the chord
  property bool active: false                 // ...and the keys actually do something
  property bool sticky: false                 // long-pressed: no idle exit
  property var targetScreen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
  property real screenX: 0
  property real screenY: 0
  property real screenW: 0
  property real screenH: 0
  property real curX: 0
  property real curY: 0
  property bool cursorKnown: false
  property real lastActionAt: 0               // telling a repeat from a fresh press
  property string lastAction: ""
  property real prevGap: Infinity
  property var moveDir: [0, 0]

  // Speed model: v = k*holdH, where holdH is how long the current contiguous hold
  // has run. With k = 2*W/T^2 a hold of T seconds integrates to exactly one screen
  // width, so a hold of t seconds reaches t/T of top speed and tapping at a given
  // duration gives that fraction of a sweep's speed.
  property real holdH: 0
  property bool holdConfirmed: false          // a repeat proved this is a real hold
  property string lastHoldAction: ""
  property real holdPressAt: 0
  property real downUntil: 0                  // held as long as now() < this
  property real lastDownAt: 0                 // last move-key event: press or repeat
  property real lastTickAt: 0
  property string activeKind: ""
  property real sentX: -1
  property real sentY: -1
  property real carryGap: -1                  // diagnostics for the carry decision
  property bool carried: false
  property string keysDown: ""                // last answer from keysProbe

  // The trail is the current cluster, capped at mashSamples: a fit sees the last
  // few presses of the gesture in progress and nothing from before the pause that
  // ended the previous one.
  property var mashTrail: []
  property int clusterN: 0                    // presses in the cluster, uncapped
  property real ballVX: 0
  property real ballVY: 0
  property bool wheelHeld: false
  property bool fineHeld: false
  property real scrollAcc: 0
  property real mashLastAt: 0

  // Held in wheel mode, a direction key repeats and the repeats grow.
  property string scrollHoldName: ""
  property real scrollHoldAt: 0
  property real scrollFrac: 0
  property bool scrollUltra: false

  // A button follows its key: down while held, up when let go, so a tap is a click
  // and a hold is a drag.
  property int btnHeld: 0                     // 1 left, 2 right, 3 middle
  property string btnAction: ""
  property real btnAt: 0
  property int dragPixel: 1                   // alternates, so a drag cannot drift

  property var edgesX: []
  property var edgesY: []

  function probe() {
    return "opened=" + root.opened + " active=" + root.active + " sticky=" + root.sticky
      + " mode=" + root.mode + " modes=[" + root.modeNames.join(",") + "]"
      + " keys=" + Object.keys(root.mashPos).length
      + " fastTap=" + root.fastTapMs + " carry=" + root.carryMs
      + " gain=" + root.mashGain + " vmax=" + root.mashVMax + " samples=" + root.mashSamples
      + " strategy=" + root.mashStrategy
      + " cur=" + Math.round(root.curX) + "," + Math.round(root.curY)
      + " idle=" + idleTimer.running + " moving=" + motionTimer.running
      + " held=" + root.holdConfirmed + " holdH=" + root.holdH.toFixed(2)
      + " edges=" + root.edgesX.length + "/" + root.edgesY.length
      + " cluster=" + root.clusterN + " win=" + root.mashTrail.length
      + " ball=" + root.ballVX.toFixed(0) + "," + root.ballVY.toFixed(0)
      + " wheel=" + root.wheelHeld + " fine=" + root.fineHeld + " btn=" + root.btnHeld
      + " ultra=" + root.scrollUltra
      + " sreps=" + root.scrollReps + "/" + root.scrollDets
      + " sscale=" + (root.scrollHoldName === "" ? "-"
          : root.scrollScaleAt(Date.now() - root.scrollHoldAt).toFixed(2))
      + " carryGap=" + Math.round(root.carryGap) + " carried=" + root.carried
      + " dbg=" + root.mashDebug + " hits=" + root.dbgHits.length
  }
  property int scrollReps: 0                  // diagnostics for the scroll ramp
  property int scrollDets: 0

  function hypr(dispatcher) { Hyprland.dispatch(dispatcher) }

  function focusedScreen() {
    var monitor = Hyprland.focusedMonitor
    if (!monitor) return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
    for (var i = 0; i < Quickshell.screens.length; i++)
      if (Quickshell.screens[i].name === monitor.name) return Quickshell.screens[i]
    return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
  }

  // Toplevel geometry and the workspace they are filtered against both have to be
  // current. Refreshing only the toplevels leaves focusedWorkspace stale, and a
  // stale workspace hands back windows from elsewhere — which focusWindow would
  // follow, dragging the user to another workspace.
  function refreshState() {
    Hyprland.refreshWorkspaces()
    Hyprland.refreshMonitors()
    Hyprland.refreshToplevels()
  }

  function workspaceName() {
    return Hyprland.focusedWorkspace ? String(Hyprland.focusedWorkspace.name) : ""
  }

  function beginSession(scr) {
    root.targetScreen = scr
    root.screenX = scr.x; root.screenY = scr.y
    root.screenW = scr.width; root.screenH = scr.height
    root.lastAction = ""; root.lastHoldAction = ""
    root.prevGap = Infinity
    root.lastActionAt = 0; root.lastDownAt = 0
    root.holdH = 0; root.holdConfirmed = false
    root.activeKind = ""
    root.sentX = -1; root.sentY = -1
    root.sticky = false; root.active = false
    root.cursorKnown = false
    root.curX = scr.width / 2
    root.curY = scr.height / 2
    cursorProc.running = true
    settings.running = true
    root.refreshState()
    root.collectEdges()
    root.hypr('hl.dsp.submap("moush-' + root.mode + '")')
    root.opened = true
  }

  function activate(latched) {
    if (!root.arming()) return
    longPressTimer.stop(); armPoll.stop()
    root.sticky = latched
    root.active = true
    hintTimer.restart()
    if (!latched) root.pokeIdle()
  }

  function arming() { return root.opened && !root.active }

  // The chord both enters and leaves. How long it is held decides which flavour:
  // a long press latches, a short press stays alive only while it is being used.
  function chordPressed() {
    if (root.opened) { root.finish(); return }
    var scr = root.focusedScreen()
    if (!scr) return
    root.beginSession(scr)
    longPressTimer.restart()
    armPoll.restart()
  }

  function chordReleased() {
    if (!root.arming()) return
    root.activate(false)
  }

  function close() { if (root.opened) root.finish() }

  function finish() {
    root.releaseButton()                      // never leave a button down
    resyncTimer.stop(); idleTimer.stop(); longPressTimer.stop()
    armPoll.stop(); hintTimer.stop(); keysPoll.stop()
    wheelPoll.stop(); finePoll.stop(); btnPoll.stop()
    scrollTimer.stop(); scrollKeyPoll.stop(); dbgTimer.stop()
    root.wheelHeld = false; root.fineHeld = false
    root.scrollHoldName = ""; root.scrollUltra = false
    root.ballVX = 0; root.ballVY = 0
    ballTimer.stop()
    root.mashTrail = []
    root.dbgHits = []; root.dbgStrats = ({}); root.dbgDriveAt = 0
    root.dbgLog = []; root.dbgLogAt = 0
    root.active = false
    root.opened = false
    root.hypr('hl.dsp.submap("reset")')
    root.log("off")
  }

  function pokeIdle() {
    if (!root.active || root.sticky || root.idleMs <= 0) return
    idleTimer.restart()
  }

  // ---- clicks and scroll -----------------------------------------------------
  // ydotool's button byte is 0x40 for down, 0x80 for up, plus the button index.
  // Sending a whole click on press could never drag: by the time the pointer
  // moved, the button was already up again.
  function pressButton(button, action) {
    if (button <= 0) return
    if (root.btnHeld === button) return
    if (root.btnHeld !== 0) root.releaseButton()
    root.btnHeld = button
    root.btnAction = action
    root.btnAt = Date.now()
    Quickshell.execDetached(["ydotool", "click", "0x4" + String(button - 1)])
    btnPoll.restart()
  }

  function releaseButton() {
    if (root.btnHeld === 0) return
    // The last thing the pointer felt was a nudge pixel, so put it back before
    // letting go: where the button comes up is where a selection ends.
    root.sentX = -1
    root.warp(root.curX, root.curY)
    Quickshell.execDetached(["ydotool", "click", "0x8" + String(root.btnHeld - 1)])
    root.btnHeld = 0
    root.btnAction = ""
    btnPoll.stop()
  }

  function scroll(detents) {
    if (detents === 0) return
    Quickshell.execDetached(["ydotool", "mousemove", "-w", "-x", "0", "-y", String(detents)])
  }

  function scrollX(detents) {
    if (detents === 0) return
    Quickshell.execDetached(["ydotool", "mousemove", "-w", "-x", String(detents), "-y", "0"])
  }

  // In wheel mode the whole mode scrolls: a sweep's travel becomes detents on
  // whichever axis it mostly runs along.
  function scrollTravel(dir, px) {
    var horiz = Math.abs(dir[0]) > Math.abs(dir[1])
    root.scrollAcc += (horiz ? dir[0] : dir[1]) * px
    var det = (root.scrollAcc / root.mashScrollPx) | 0
    if (det === 0) return
    root.scrollAcc -= det * root.mashScrollPx
    if (horiz) root.scrollX(det)
    else root.scroll(-det)                    // screen-down is wheel-down
  }

  // A discrete press is worth a detent outright: accumulating an 8px step against
  // a detent's 90 would take a dozen presses to move the page once.
  function scrollPress(dir, unbounded) {
    var horiz = Math.abs(dir[0]) > Math.abs(dir[1])
    var sign = horiz ? (dir[0] > 0 ? 1 : -1) : (dir[1] > 0 ? 1 : -1)
    var n = unbounded ? root.scrollEndDetents : 1
    if (horiz) root.scrollX(sign * n)
    else root.scroll(-sign * n)
  }

  // Flat while the hold is young, then a straight ramp, then flat at the top.
  function scrollScaleAt(ms) {
    if (root.scrollUltra) return root.scrollRepeatScaleUltra
    var lo = root.scrollRepeatScaleMin, hi = root.scrollRepeatScaleMax
    var delay = root.scrollIncreaseDelay * 1000, span = root.scrollIncreaseTime * 1000
    if (ms <= delay) return lo
    if (span <= 0) return hi
    var t = (ms - delay) / span
    return t >= 1 ? hi : lo + (hi - lo) * t
  }

  // Each repeat is worth scaleAt() detents. The scale is fractional, so what does
  // not reach a whole detent is carried rather than dropped.
  function scrollRepeat(name, dir, now) {
    if (name !== root.scrollHoldName) {
      root.scrollHoldName = name; root.scrollHoldAt = now; root.scrollFrac = 0
    }
    root.pokeIdle()
    root.scrollReps += 1
    root.scrollFrac += root.scrollScaleAt(now - root.scrollHoldAt)
    var n = Math.floor(root.scrollFrac)
    if (n < 1) return
    root.scrollFrac -= n
    root.scrollDets += n
    var horiz = Math.abs(dir[0]) > Math.abs(dir[1])
    var sign = horiz ? (dir[0] > 0 ? 1 : -1) : (dir[1] > 0 ? 1 : -1)
    if (horiz) root.scrollX(sign * n)
    else root.scroll(-sign * n)
  }

  // ---- window edges ----------------------------------------------------------
  // Read from Quickshell's Hyprland toplevels, in process, so this costs no
  // subprocess and can be refreshed on every keypress.
  function pushEdge(list, c, lo, hi, max) {
    if (c < 0 || c > max) return
    list.push({ c: c, lo: lo, hi: hi })
  }

  function collectEdges() {
    var vx = [], hy = []
    var ws = root.workspaceName()
    var list = Hyprland.toplevels ? Hyprland.toplevels.values : []
    for (var i = 0; i < list.length; i++) {
      var o = list[i].lastIpcObject
      if (!o || o.mapped !== true || o.hidden === true) continue
      if (!o.workspace || String(o.workspace.name) !== ws) continue
      if (!o.at || !o.size) continue
      var ax = o.at[0] - root.screenX, ay = o.at[1] - root.screenY
      var w = o.size[0], h = o.size[1]
      if (!(w > 0) || !(h > 0)) continue
      // Edges are the last pixel *inside* the window, not the exclusive bound: a
      // window at x=12 w=734 covers 12..745, so its right edge is 745. Landing on
      // 746 would put the pointer one pixel past it, over whatever is behind.
      root.pushEdge(vx, ax,         ay, ay + h - 1, root.screenW - 1)
      root.pushEdge(vx, ax + w - 1, ay, ay + h - 1, root.screenW - 1)
      root.pushEdge(hy, ay,         ax, ax + w - 1, root.screenH - 1)
      root.pushEdge(hy, ay + h - 1, ax, ax + w - 1, root.screenH - 1)
    }
    // The screen always bounds you, so there is always something to snap to.
    vx.push({ c: 0, lo: -1e9, hi: 1e9 })
    vx.push({ c: root.screenW - 1, lo: -1e9, hi: 1e9 })
    hy.push({ c: 0, lo: -1e9, hi: 1e9 })
    hy.push({ c: root.screenH - 1, lo: -1e9, hi: 1e9 })
    root.edgesX = vx
    root.edgesY = hy
  }

  // Nearest edge strictly ahead of `from` along `sign`, level with `cross`.
  // maxDist <= 0 means unbounded, which is what a double-tap uses.
  function nextEdge(list, from, cross, sign, maxDist) {
    var bestC = NaN, bestD = Infinity
    for (var i = 0; i < list.length; i++) {
      var e = list[i]
      if (cross < e.lo || cross > e.hi) continue
      var d = (e.c - from) * sign
      if (d <= root.edgeEpsilon) continue
      if (maxDist > 0 && d > maxDist) continue
      if (d < bestD) { bestD = d; bestC = e.c }
    }
    return bestC
  }

  // ---- movement --------------------------------------------------------------
  // Enter a sweep in `dir` carrying speed `h`, without waiting for the new key's
  // first repeat. The key that will sustain it does not repeat for 250ms, so
  // downUntil has to bridge that gap or motion lapses after repeatGapMs.
  function startSweep(name, now, h) {
    root.activeKind = "move"
    root.lastHoldAction = name
    root.holdH = Math.min(root.sweepMs / 1000, h)
    root.holdPressAt = now - root.holdH * 1000
    root.holdConfirmed = true
    root.downUntil = now + root.takeoverGraceMs
    root.lastTickAt = now
    motionTimer.start()
  }

  function speedFor(h) {
    var T = root.sweepMs / 1000
    var W = root.screenW > 0 ? root.screenW : 1920
    return (2 * W / (T * T)) * h
  }

  // A diagonal is two axes at once, so it snaps on each independently: a press
  // lands on the nearest edge to the left *and* the nearest above, and a
  // double-tap runs both to their limits, which is the corner.
  function moveStepDiag(dir, px, unbounded) {
    var sx = dir[0] > 0 ? 1 : -1, sy = dir[1] > 0 ? 1 : -1
    var reach = unbounded ? 0 : px
    var ex = root.nextEdge(root.edgesX, root.curX, root.curY, sx, reach)
    var ey = root.nextEdge(root.edgesY, root.curY, root.curX, sy, reach)
    var nx = isNaN(ex) ? (unbounded ? root.curX : root.curX + dir[0] * px) : ex
    var ny = isNaN(ey) ? (unbounded ? root.curY : root.curY + dir[1] * px) : ey
    root.warp(nx, ny)
    // No crossBeyond here: leaving by a corner has no single direction to hand
    // the compositor, so a diagonal stops at the corner.
    if (unbounded) root.focusLanding(true, sx)
  }

  function moveStep(dir, px, unbounded) {
    if (root.wheelHeld) { root.scrollTravel(dir, px); return }
    if (dir[0] !== 0 && dir[1] !== 0) { root.moveStepDiag(dir, px, unbounded); return }
    var horiz = dir[0] !== 0
    var sign = horiz ? dir[0] : dir[1]
    var from = horiz ? root.curX : root.curY
    var cross = horiz ? root.curY : root.curX
    var e = root.nextEdge(horiz ? root.edgesX : root.edgesY, from, cross, sign,
                          unbounded ? 0 : px)
    if (!isNaN(e)) {
      if (horiz) root.warp(e, root.curY)
      else root.warp(root.curX, e)
      // A double-tap that hops onto the screen's own edge means "keep going", so
      // try to cross out of it; anywhere else, adopt whatever window we landed in.
      var far = horiz ? root.screenW - 1 : root.screenH - 1
      if (unbounded) {
        if (e <= 0 || e >= far) { if (!root.crossBeyond(horiz, sign)) root.focusLanding(horiz, sign) }
        else root.focusLanding(horiz, sign)
      }
      return
    }
    if (unbounded) {
      if (!root.crossBeyond(horiz, sign)) root.focusLanding(horiz, sign)
      return
    }
    root.warp(root.curX + dir[0] * px, root.curY + dir[1] * px)
  }

  function warp(x, y) {
    root.cursorKnown = true
    root.curX = Math.min(Math.max(x, 0), root.screenW - 1)
    root.curY = Math.min(Math.max(y, 0), root.screenH - 1)
    var ix = Math.round(root.screenX + root.curX)
    var iy = Math.round(root.screenY + root.curY)
    // Sub-pixel steps accumulate in curX/curY; only tell Hyprland when the rounded
    // position actually changes, so a slow crawl is not a dispatch storm.
    if (ix === root.sentX && iy === root.sentY) return
    root.sentX = ix
    root.sentY = iy
    root.hypr("hl.dsp.cursor.move({ x = " + ix + ", y = " + iy + " })")
    // The warp puts the pointer exactly where it belongs but tells no client it
    // moved, so a drag looked like button-down, silence, button-up and selected
    // nothing until release. One pixel of real device motion turns each step into
    // something a client can see.
    //
    // Deliberately a single pixel and nothing more. What the device is asked for
    // and what the pointer does are related by the user's own pointer settings and
    // not simply — 10px moved 17 here, and even 1px is not always 1px — so the
    // position is never taken from it. The warp above owns that and corrects on
    // the next step. The direction alternates so a slow drag cannot drift.
    if (root.btnHeld !== 0) {
      root.dragPixel = -root.dragPixel
      Quickshell.execDetached(["ydotool", "mousemove", "-x", String(root.dragPixel), "-y", "0"])
    }
  }

  // ---- crossing into another window -----------------------------------------
  // Focus is always by address, never by direction. hl.dsp.focus({ direction })
  // asks the *layout* what comes next, which on a single monitor is just another
  // tiled window, and Hyprland then drags the pointer into it. Addressing the
  // window the cursor reached keeps focus and pointer in agreement, and works the
  // same under any layout because it names a window rather than an ordering.
  function windowsHere() {
    var out = []
    var ws = root.workspaceName()
    if (ws === "") return out
    var list = Hyprland.toplevels ? Hyprland.toplevels.values : []
    for (var i = 0; i < list.length; i++) {
      var o = list[i].lastIpcObject
      if (!o || o.mapped !== true || o.hidden === true) continue
      if (!o.workspace || String(o.workspace.name) !== ws) continue
      if (!o.at || !o.size || !o.address) continue
      if (!(o.size[0] > 0) || !(o.size[1] > 0)) continue
      out.push({ address: String(o.address),
                 x: o.at[0] - root.screenX, y: o.at[1] - root.screenY,
                 w: o.size[0], h: o.size[1],
                 floating: o.floating === true,
                 age: typeof o.focusHistoryID === "number" ? o.focusHistoryID : 1e9 })
    }
    return out
  }

  function focusedAddress() {
    var t = Hyprland.activeToplevel
    var o = t ? t.lastIpcObject : null
    return o && o.address ? String(o.address) : ""
  }

  // windowsHere() already filters by workspace, but that filter and this check both
  // hang off cached state, so re-read the window's own workspace before committing:
  // moving the pointer must never move the user off their workspace.
  function focusWindow(address) {
    var ws = root.workspaceName()
    var list = Hyprland.toplevels ? Hyprland.toplevels.values : []
    for (var i = 0; i < list.length; i++) {
      var o = list[i].lastIpcObject
      if (!o || String(o.address) !== address) continue
      if (!o.workspace || String(o.workspace.name) !== ws) return false
      root.hypr('hl.dsp.focus({ window = "address:' + address + '" })')
      return true
    }
    return false
  }

  // Windows overlap, so pick the one actually on top rather than whichever the
  // compositor listed last — that order is not z-order. Floating sits above tiled,
  // and among equals the more recently focused is the one you can see.
  function topmostAt(x, y) {
    var best = null
    var list = root.windowsHere()
    for (var i = 0; i < list.length; i++) {
      var c = list[i]
      if (x < c.x || x >= c.x + c.w) continue
      if (y < c.y || y >= c.y + c.h) continue
      if (!best || (c.floating !== best.floating ? c.floating : c.age < best.age)) best = c
    }
    return best
  }

  // What ends up focused must be what the pointer is visually over, because that
  // is where a click will land, so the cursor's own position is asked first. Only
  // when it sits over nothing — a gap, or a far edge at x+w which is one past the
  // last pixel — does the window being *entered* decide it, probed one pixel along
  // the direction of travel.
  function focusLanding(horiz, sign) {
    var best = root.topmostAt(root.curX, root.curY)
    if (!best) best = root.topmostAt(root.curX + (horiz ? sign : 0),
                                     root.curY + (horiz ? 0 : sign))
    if (!best) return
    if (best.address === root.focusedAddress()) return
    if (!root.focusWindow(best.address)) return
    root.crossTarget = best.address
    root.crossHoriz = horiz
    root.crossSign = sign
    root.crossOff = horiz ? root.curX - best.x : root.curY - best.y
    root.crossCross = horiz ? root.curY : root.curX
    resyncTimer.restart()
  }

  // Out of edges on this screen: the double-tap wants to keep going, so look for a
  // window with content past the boundary that way. One rule covers every layout —
  // a scrolling workspace pans the row to reveal it, a second monitor brings its
  // window in, and under dwindle nothing reaches past the screen so the cursor
  // rests at the edge. Returns whether it acted.
  function crossBeyond(horiz, sign) {
    var far = (horiz ? root.screenW : root.screenH) - 1
    var cross = horiz ? root.curY : root.curX
    var focused = root.focusedAddress()
    var best = null, bestNear = 0
    var list = root.windowsHere()
    for (var i = 0; i < list.length; i++) {
      var t = list[i]
      // Already focused and still overhanging means the layout has fitted it as far
      // as it intends to; re-focusing would move nothing.
      if (t.address === focused) continue
      var lo = horiz ? t.y : t.x
      var hi = lo + (horiz ? t.h : t.w) - 1
      if (cross < lo || cross > hi) continue
      var near = horiz ? t.x : t.y
      var end = near + (horiz ? t.w : t.h) - 1
      var over = sign > 0 ? end - far : 0 - near
      if (over <= root.edgeEpsilon) continue
      if (!best || (sign > 0 ? near < bestNear : near > bestNear)) { best = t; bestNear = near }
    }
    if (!best) return false
    if (!root.focusWindow(best.address)) return false
    root.crossTarget = best.address
    root.crossHoriz = horiz
    root.crossSign = sign
    // Entering edge: crossing rightwards puts us on the window's left side.
    root.crossOff = sign > 0 ? 0 : (horiz ? best.w : best.h) - 1
    root.crossCross = cross
    resyncTimer.restart()
    return true
  }

  property string crossTarget: ""
  property bool crossHoriz: true
  property int crossSign: 1
  property real crossOff: 0
  property real crossCross: 0

  // Two ways the pointer ends up wrong after a focus change, both fixed here.
  // Hyprland drops it on the *centre* of a window it focuses, 367px from the edge
  // the sweep left through with the cross-axis thrown away; and a pan moves the
  // workspace under a stationary pointer, so entering a column from its left could
  // leave the pointer at its right. Restoring where in the window it belongs fixes
  // both, and the centre is never drawn because curX/curY never adopt it.
  function landOnEdge() {
    var want = root.crossTarget
    root.crossTarget = ""
    var list = root.windowsHere()
    for (var i = 0; i < list.length; i++) {
      var t = list[i]
      if (t.address !== want) continue
      var horiz = root.crossHoriz
      var origin = horiz ? t.x : t.y
      var travel = origin + root.crossOff
      var lo = horiz ? t.y : t.x
      var hi = lo + (horiz ? t.h : t.w) - 1
      var cross = Math.min(Math.max(root.crossCross, lo), hi)
      root.cursorKnown = true
      if (horiz) root.warp(travel, cross)
      else root.warp(cross, travel)
      // The pan that revealed it slid the window under anything floating, which
      // does not pan with the row, so re-resolve what the pointer now sits over.
      // Settles in one more pass: the second call finds what it just focused.
      root.focusLanding(horiz, root.crossSign)
      return
    }
    root.cursorKnown = false
    cursorProc.running = true
  }

  // ---- mash ------------------------------------------------------------------
  // Each key is a point in space, so the order they are struck traces a path. The
  // direction of that path drives a rolling ball; the rate sets how hard.
  function gridIndex(name) {
    if (name.length < 2 || name.charAt(0) !== "k") return -1
    var i = parseInt(name.slice(1), 10)
    return isNaN(i) ? -1 : i
  }

  function gridPos(name) {
    var i = root.gridIndex(name)
    return i < 0 ? null : (root.mashPos[String(i)] || null)
  }

  function gridDir(name) {
    var i = root.gridIndex(name)
    return i < 0 ? null : (root.mashDirs[String(i)] || null)
  }

  function gridLabel(name) {
    var i = root.gridIndex(name)
    return i < 0 ? "" : (root.mashLabels[String(i)] || "")
  }

  // The trail is already capped at mashSamples and cleared between clusters, so
  // this is the last few presses of the gesture in progress and nothing from
  // before the pause that ended the previous one.
  function mashWindow() { return root.mashTrail }

  // lsq — least squares of position against time. The slope *is* a velocity, so
  // direction and speed come out together, and one stray key barely moves it. Two
  // points are enough: the line through them is the line joining them.
  function mashLsq(now) {
    var w = root.mashWindow()
    if (w.length < 2) return null
    var tb = 0, xb = 0, yb = 0, i
    for (i = 0; i < w.length; i++) { tb += w[i].t; xb += w[i].x; yb += w[i].y }
    tb /= w.length; xb /= w.length; yb /= w.length
    var stt = 0, stx = 0, sty = 0
    for (i = 0; i < w.length; i++) {
      var dt = (w[i].t - tb) / 1000
      stt += dt * dt; stx += dt * (w[i].x - xb); sty += dt * (w[i].y - yb)
    }
    if (!(stt > 0)) return null
    return ({ x: stx / stt, y: sty / stt })
  }

  function mashCompute(name, now) {
    if (name === "lsq") return root.mashLsq(now)
    return null
  }

  // What a press does when there is no gesture to fit it into.
  function mashLone(name, now) {
    var dn = root.gridDir(name)
    if (!dn) return
    root.moveDir = root.actionDirs[dn]
    root.collectEdges()
    root.beginHold("move", dn, now)           // so holding it sweeps
    root.moveStep(root.moveDir, root.fineHeld ? root.finePx : root.baseStep, false)
  }

  function mashPress(name, now) {
    var pos = root.gridPos(name)
    if (!pos) return
    root.pokeIdle()
    // A gap ends the gesture. Everything the old cluster left behind goes with it,
    // including what the overlay is drawing: it shows one cluster at a time.
    if (now - root.mashLastAt > root.mashClusterMs) {
      root.mashTrail = []
      root.dbgStrats = ({}); root.dbgHits = []
      root.dbgDriveAt = 0; root.dbgDriveX = 0; root.dbgDriveY = 0
      root.clusterN = 0
    }
    root.clusterN += 1
    root.mashLastAt = now
    root.dbgLogEvent(root.gridLabel(name), now, true)

    var hist = root.mashTrail.concat([{ x: pos.x, y: pos.y, t: now }])
    if (hist.length > root.mashSamples) hist = hist.slice(hist.length - root.mashSamples)
    root.mashTrail = hist
    root.dbgHits = root.dbgHits.concat([{ name: name, t: now }]).slice(-root.mashSamples)
    root.dbgLastAt = now

    // Every strategy on the debug list is computed whether or not it is steering.
    var ds = ({})
    for (var k in root.dbgStrats) ds[k] = root.dbgStrats[k]
    for (var si = 0; si < root.mashDebugStrategies.length; si++) {
      var sn = root.mashDebugStrategies[si]
      var sr = root.mashCompute(sn, now)
      if (sr) ds[sn] = ({ x: sr.x, y: sr.y, t: now })
    }
    root.dbgStrats = ds
    if (root.mashDebug) dbgTimer.start()

    var drive = root.mashCompute(root.mashStrategy, now)
    var s = drive ? Math.sqrt(drive.x * drive.x + drive.y * drive.y) : 0
    if (drive) { root.dbgDriveX = drive.x; root.dbgDriveY = drive.y; root.dbgDriveAt = now }
    var ux = 0, uy = 0
    var n = hist.length
    // Nothing to fit yet: either this opened the cluster, or it landed on the same
    // key as last time and so added no displacement. Both mean the press stands
    // alone. The same-key case is why tapping one direction key quickly used to
    // stop moving: between fastTapMs and mashClusterMs the presses shared a
    // cluster without being a double-tap, and a fit over no displacement produced
    // nothing.
    if (n >= 2) {
      var dx = hist[n - 1].x - hist[n - 2].x, dy = hist[n - 1].y - hist[n - 2].y
      var m = Math.sqrt(dx * dx + dy * dy)
      if (m > 0) { ux = dx / m; uy = dy / m }
      else n = 1
    }
    if (n < 2) { root.mashLone(name, now); return }
    if (s > 0) { ux = drive.x / s; uy = drive.y / s }

    // Every press moves at least one step, the way a direction press does.
    if (root.wheelHeld) root.scrollAcc += uy * root.baseStep
    else root.warp(root.curX + ux * root.baseStep, root.curY + uy * root.baseStep)
    if (!(s > 0)) return

    // Impulse grows steeply with mash rate because the two ends of the scale are
    // far apart: a slow press should nudge, a fast burst should cross the screen.
    var imp = root.mashGain * Math.pow(s, 3)
    root.dbgLogImpulse(imp)
    root.ballVX += ux * imp
    root.ballVY += uy * imp
    var sp = Math.sqrt(root.ballVX * root.ballVX + root.ballVY * root.ballVY)
    if (sp > root.mashVMax) {
      root.ballVX *= root.mashVMax / sp
      root.ballVY *= root.mashVMax / sp
    }
    if (!ballTimer.running) { root.lastTickAt = now; ballTimer.start() }
  }

  // ---- key routing -----------------------------------------------------------
  // The first repeat lands input:repeat_delay (250ms) after the press, far outside
  // the fast-cadence window that identifies later repeats, so it looks like a fresh
  // press. Carrying the original press time forward when the same key reappears
  // within holdChainMs keeps the hold clock honest.
  function beginHold(kind, name, now) {
    var chained = (name === root.lastHoldAction) && (now - root.holdPressAt <= root.holdChainMs)
    root.activeKind = kind
    root.lastHoldAction = name
    if (!chained) root.holdPressAt = now
    root.holdConfirmed = false
    root.downUntil = now + root.repeatGapMs
    root.lastTickAt = now
    motionTimer.start()
  }

  // A repeat is the first proof that a key is genuinely held: nothing else
  // distinguishes a tap from a hold, since there is no release and the first
  // repeat only lands after 250ms.
  function confirmHold(now, graceMs) {
    root.downUntil = now + graceMs
    if (root.holdConfirmed) return
    root.holdConfirmed = true
    root.holdH = Math.max(root.holdH, (now - root.holdPressAt) / 1000)
    if (!motionTimer.running) root.lastTickAt = now
    motionTimer.start()
  }

  function handleAction(name) {
    if (!root.active) return        // still arming; the chord owns the keyboard
    var now = Date.now()
    var same = (name === root.lastAction)
    var gap = same ? (now - root.lastActionAt) : Infinity
    var repeat = same && (gap <= root.repeatGapMs)
    // Re-triggering the same action quicker than fastTapMs means "go all the way".
    // The prevGap term rejects a repeat delayed under load, which lands in the same
    // band and would otherwise teleport a sweeping cursor to an edge.
    var fastTap = same && gap < root.fastTapMs && root.prevGap > root.repeatGapMs
    root.prevGap = gap
    root.lastActionAt = now
    root.lastAction = name

    if (name === "noop") { if (!repeat) root.dbgLogEvent("·", now, false); return }
    if (name === "cycle") {
      // Flashed before the cycle, not after: cycleMode clears the aux marks along
      // with the rest of the old mode's picture.
      if (!repeat) { root.dbgAuxPress(name, now); root.pokeIdle(); root.cycleMode() }
      return
    }
    if (name === "strategy") {
      if (!repeat) { root.dbgAuxPress(name, now); root.cycleStrategy() }
      return
    }
    if (name === "debug") {
      if (!repeat) {
        root.mashDebug = !root.mashDebug
        root.pokeIdle()
        if (root.mashDebug) { root.dbgAuxPress(name, now); dbgTimer.start() }
      }
      return
    }
    if (name === "wheel") {
      // Held, not tapped: a press only says it went down, so the release has to be
      // asked about.
      if (!root.wheelHeld) { root.wheelHeld = true; root.scrollAcc = 0 }
      root.dbgAuxPress(name, now)
      root.pokeIdle()
      if (!wheelPoll.running) wheelPoll.start()
      return
    }
    if (name === "fine") {
      if (!root.fineHeld) root.fineHeld = true
      root.dbgAuxPress(name, now)
      root.pokeIdle()
      if (!finePoll.running) finePoll.start()
      return
    }
    if (name === "lmb") { root.dbgAuxPress(name, now); root.pokeIdle(); root.pressButton(1, name); return }
    if (name === "mmb") { root.dbgAuxPress(name, now); root.pokeIdle(); root.pressButton(3, name); return }
    if (name === "rmb") { root.dbgAuxPress(name, now); root.pokeIdle(); root.pressButton(2, name); return }

    if (root.gridIndex(name) >= 0) {
      var dn = root.gridDir(name)
      var mdir = dn ? root.actionDirs[dn] : null
      if (mdir && root.wheelHeld) {
        // Wheel mode owns the direction keys outright: first press a detent, held a
        // growing repeat, struck twice and kept down the top speed at once.
        if (repeat) { root.scrollRepeat(name, mdir, now); return }
        if (same && fastTap) {
          if (Math.abs(mdir[1]) > Math.abs(mdir[0])) {
            root.scrollHoldName = name; root.scrollHoldAt = now
            root.scrollFrac = 0; root.scrollReps = 0; root.scrollDets = 0
            root.scrollUltra = true
            root.pokeIdle()
            root.scrollRepeat(name, mdir, now)
            scrollTimer.interval = root.scrollRepeatMs
            scrollTimer.restart(); scrollKeyPoll.restart()
            return
          }
          root.scrollPress(mdir, true)        // sideways keeps end-of-view
          return
        }
        root.scrollHoldName = name; root.scrollHoldAt = now
        root.scrollFrac = 0; root.scrollReps = 0; root.scrollDets = 1
        root.scrollUltra = false
        root.pokeIdle()
        root.scrollPress(mdir, false)
        scrollTimer.interval = root.scrollStartMs
        scrollTimer.restart(); scrollKeyPoll.restart()
        return
      }
      // Only the two cases that cannot wait are settled here; everything else goes
      // through mashPress, so the press lands in the trail and the cluster stays
      // honest. Returning early used to skip that, leaving clusterN stale and
      // losing the first point of any sweep that opened with a direction key.
      if (mdir && repeat && root.activeKind === "move") {
        root.lastDownAt = now
        root.confirmHold(now, root.repeatGapMs)
        return
      }
      if (mdir && same && fastTap) {
        root.pokeIdle()
        root.moveDir = mdir
        root.collectEdges()
        root.moveStep(mdir, root.fineHeld ? root.finePx : root.baseStep, true)
        return
      }
      if (!repeat) root.mashPress(name, now)
      return
    }

    var d = root.actionDirs[name]
    if (!d) return
    root.pokeIdle()
    root.moveDir = d
    root.collectEdges()
    if (repeat) { root.lastDownAt = now; root.confirmHold(now, root.repeatGapMs); return }
    // Hand the speed over rather than re-running the ramp. Requiring the previous
    // key to still be down cost all of it if you let go a moment early: beginHold
    // takes one step and then nothing moves until the next auto-repeat 250ms later.
    // Measured from the last key *event*, not the motion tick, which runs
    // repeatGapMs past the final repeat and would stretch the window by that much.
    var carry = root.activeKind === "move" && root.holdH > 0
                && (now - root.lastDownAt) <= root.carryMs
    root.carryGap = root.lastDownAt > 0 ? now - root.lastDownAt : -1
    root.carried = carry
    root.lastDownAt = now
    if (carry) root.startSweep(name, now, root.holdH)
    else root.beginHold("move", name, now)
    root.moveStep(d, root.fineHeld ? root.finePx : root.baseStep, fastTap)
  }

  // ---- the debug overlay -----------------------------------------------------
  property bool mashDebug: true
  property var dbgHits: []                    // {name, t} of the cluster's presses
  property var dbgStrats: ({})                // name -> {x, y, t}
  property real dbgDriveX: 0
  property real dbgDriveY: 0
  property real dbgDriveAt: 0
  property real dbgLastAt: 0
  property var dbgLog: []                     // {g, dt, grid, imp} newest first
  property var dbgAux: ({})                   // action -> when it was last struck
  property real dbgLogAt: 0

  readonly property real dbgPitch: 26         // px between grid cells
  readonly property real dbgScale: 4          // px drawn per coordinate unit/second
  readonly property real dbgMaxLen: 92
  readonly property real dbgFootH: 20         // the colour key
  readonly property int dbgLogMax: 20
  readonly property real dbgLogLineH: 11
  readonly property real dbgLogH: root.dbgLogMax * root.dbgLogLineH + 20
  readonly property var dbgDashes: [[], [7, 4], [2, 4], [12, 4, 3, 4], [1, 5], [6, 3, 1, 3]]
  // Every struck state is light enough to carry black text, which is why the cold
  // end of the timing ramp is a deep green rather than the near-black grey it was:
  // black on that was invisible, and it also made a cluster's first press hard to
  // tell from a key nobody had touched.
  readonly property var dbgKeyIdle: [38, 38, 38]     // never struck this cluster
  readonly property var dbgKeyCold: [64, 168, 92]    // struck first
  readonly property var dbgKeyHot: [92, 250, 132]    // struck most recently
  readonly property var dbgKeyDown: [236, 84, 72]    // an aux key under the finger

  // Black on a light face, white on a dark one. The palette above is picked so the
  // struck states all land on the light side, but the guard costs three lines and
  // means a retuned colour can never silently produce unreadable text.
  function dbgInk(bg, a) {
    var lum = (0.299 * bg[0] + 0.587 * bg[1] + 0.114 * bg[2]) / 255
    return lum > 0.45 ? root.dbgRgba(0, 0, 0, a) : root.dbgRgba(255, 255, 255, a)
  }
  readonly property real dbgAuxH: 40          // the aux row, labels included
  readonly property real dbgAuxSlot: 34       // px per aux key
  readonly property int dbgAuxFlashMs: 260    // how long a momentary key stays lit

  // The aux keys in a fixed order, skipping whatever this mode leaves out, so the
  // row depicts the mode in hand rather than a canonical keyboard.
  readonly property var dbgAuxOrder: [["lmb", "lmb"], ["mmb", "mmb"], ["rmb", "rmb"],
                                      ["wheel", "wheel"], ["fine", "fine"],
                                      ["cycle", "cycle"], ["debug", "debug"],
                                      ["strategy", "strat"]]
  function dbgAuxRow() {
    var out = []
    for (var i = 0; i < root.dbgAuxOrder.length; i++) {
      var a = root.dbgAuxOrder[i][0], k = root.modeKeys[a]
      if (k === undefined || k === "") continue
      out.push({ action: a, label: root.dbgAuxOrder[i][1], cap: root.dbgKeyCap(k) })
    }
    return out
  }

  // A key's face. Single characters and the punctuation table read as themselves;
  // a longer name is a named key, and its first letter alone ("T" for TAB) tells
  // you nothing, so keep three lower-case characters of it.
  function dbgKeyCap(k) {
    if (!k) return ""
    if (root.dbgGlyphs[k]) return root.dbgGlyphs[k]
    if (k.length === 1) return k
    return k.slice(0, 3).toLowerCase()
  }

  // Held keys report their real state, so the red lasts exactly as long as the
  // finger does. The momentary ones have no state to report and flash instead.
  function dbgAuxDown(action, now) {
    if (action === "wheel") return root.wheelHeld
    if (action === "fine") return root.fineHeld
    if (action === "lmb") return root.btnHeld === 1
    if (action === "rmb") return root.btnHeld === 2
    if (action === "mmb") return root.btnHeld === 3
    return (now - (root.dbgAux[action] || 0)) < root.dbgAuxFlashMs
  }

  function dbgAuxHeld() {
    return root.wheelHeld || root.fineHeld || root.btnHeld !== 0
  }

  function dbgAuxPress(action, now) {
    var m = ({})
    for (var q in root.dbgAux) m[q] = root.dbgAux[q]
    m[action] = now
    root.dbgAux = m
    root.dbgLastAt = now
    if (root.mashDebug) dbgTimer.start()
  }

  function dbgRgba(r, g, b, a) {
    return "rgba(" + Math.round(r) + "," + Math.round(g) + "," + Math.round(b) + ","
           + a.toFixed(2) + ")"
  }

  function dbgMix(c0, c1, k) {
    return [c0[0] + (c1[0] - c0[0]) * k,
            c0[1] + (c1[1] - c0[1]) * k,
            c0[2] + (c1[2] - c0[2]) * k]
  }

  function dbgHash(str) {
    var h = 2166136261
    for (var i = 0; i < str.length; i++) { h ^= str.charCodeAt(i); h = (h * 16777619) >>> 0 }
    return h
  }

  function dbgHsl(h, sat, lum) {
    function f(n) {
      var k = (n + h * 12) % 12
      var a = sat * Math.min(lum, 1 - lum)
      return Math.round(255 * (lum - a * Math.max(-1, Math.min(k - 3, Math.min(9 - k, 1)))))
    }
    return [f(0), f(8), f(4)]
  }

  // Hue and dash come from a strategy's place in the list, not a hash of its name:
  // hashing gave no guarantee two would not land on near-identical hues, which is
  // the one thing this must not do. A name-derived jitter inside its own slot keeps
  // the palette from reading as a plain rainbow.
  function dbgStratHue(name) {
    var n = Math.max(1, root.mashStrategies.length)
    var i = root.mashStrategies.indexOf(name)
    if (i < 0) return 0
    var slot = 360 / n
    return (i * slot + (root.dbgHash(name) % Math.max(1, Math.floor(slot / 2)))) / 360
  }

  function dbgStratColor(name, a) {
    var c = root.dbgHsl(root.dbgStratHue(name), 0.95, 0.62)
    return root.dbgRgba(c[0], c[1], c[2], a)
  }

  function dbgStratDash(name) {
    var i = root.mashStrategies.indexOf(name)
    return root.dbgDashes[(i < 0 ? 0 : i) % root.dbgDashes.length]
  }

  readonly property var dbgGlyphs: ({ bracketleft: "[", bracketright: "]",
                                      apostrophe: "'", semicolon: ";", comma: ",",
                                      period: ".", slash: "/", minus: "-", grave: "`" })
  function dbgGlyph(k) {
    if (!k) return ""
    if (root.dbgGlyphs[k]) return root.dbgGlyphs[k]
    return k.length === 1 ? k : k.charAt(0)
  }

  // The log is not the fade: entries stay until pushed out by newer ones, which is
  // the point of having it. Deltas are between consecutive logged events, so a
  // stray key shows up as a row rather than silently widening a gap.
  function dbgLogEvent(glyph, now, grid) {
    var dt = root.dbgLogAt > 0 ? Math.round(now - root.dbgLogAt) : -1
    root.dbgLogAt = now
    root.dbgLog = [{ g: root.dbgGlyph(glyph), dt: dt, grid: grid, imp: 0 }]
                    .concat(root.dbgLog).slice(0, root.dbgLogMax)
    if (root.mashDebug) dbgTimer.start()
  }

  // The impulse is only known once the strategy has run, which is after the press
  // is logged, so it is filled in afterwards. A row that keeps its zero is a press
  // that drove nothing.
  function dbgLogImpulse(v) {
    if (root.dbgLog.length === 0) return
    var out = root.dbgLog.slice()
    out[0] = { g: out[0].g, dt: out[0].dt, grid: out[0].grid, imp: v }
    root.dbgLog = out
  }

  // The grid is drawn from the same coordinates the model uses, so a re-measured
  // layout draws itself. The extent is whatever the config spans.
  function dbgBounds() {
    var lo = ({ x: 1e9, y: 1e9 }), hi = ({ x: -1e9, y: -1e9 }), n = 0
    for (var k in root.mashPos) {
      var p = root.mashPos[k]
      if (p.x < lo.x) lo.x = p.x
      if (p.y < lo.y) lo.y = p.y
      if (p.x > hi.x) hi.x = p.x
      if (p.y > hi.y) hi.y = p.y
      n++
    }
    if (n === 0) return ({ x: 0, y: 0, w: 1, h: 1 })
    return ({ x: lo.x, y: lo.y, w: Math.max(0.001, hi.x - lo.x), h: Math.max(0.001, hi.y - lo.y) })
  }

  // ---- timers and probes -----------------------------------------------------
  Timer {
    id: motionTimer
    interval: root.motionTickMs
    repeat: true
    onTriggered: {
      if (!root.active) { motionTimer.stop(); return }
      var now = Date.now()
      // Real elapsed time, not the nominal interval: Qt's timer runs late and each
      // tick also writes to the Hyprland socket.
      var dt = Math.min(0.1, Math.max(0.001, (now - root.lastTickAt) / 1000))
      root.lastTickAt = now
      var down = root.holdConfirmed && (now < root.downUntil)
      // Arm the poll a little before the hold would lapse. Healthy repeats arrive
      // every 25ms and push downUntil 55ms out, so this never fires during an
      // ordinary sweep — only once repeats actually stop, which is either a real
      // release or a second key having been pressed.
      if (root.holdConfirmed && !keysPoll.running
          && now >= root.downUntil - root.keysArmMs) {
        keysPoll.start()
        if (!keysProbe.running) keysProbe.running = true
      }
      if (down) {
        root.holdH = Math.min(root.sweepMs / 1000, root.holdH + dt)
        root.pokeIdle()
        root.moveStep(root.moveDir, root.speedFor(root.holdH) * dt, false)
      } else {
        root.holdConfirmed = false
        root.holdH = Math.max(0, root.holdH - dt)
        if (root.holdH <= 0) motionTimer.stop()
      }
    }
  }

  // Rolling under friction. Distance from one impulse is v/friction, so friction
  // sets how long a throw lasts without changing how far it goes.
  Timer {
    id: ballTimer
    interval: root.motionTickMs
    repeat: true
    onTriggered: {
      if (!root.active) { ballTimer.stop(); return }
      var now = Date.now()
      var dt = Math.min(0.1, Math.max(0.001, (now - root.lastTickAt) / 1000))
      root.lastTickAt = now
      var decay = Math.exp(-root.mashFriction * dt)
      root.ballVX *= decay
      root.ballVY *= decay
      var sp = Math.sqrt(root.ballVX * root.ballVX + root.ballVY * root.ballVY)
      if (sp < 1) { root.ballVX = 0; root.ballVY = 0; root.scrollAcc = 0; ballTimer.stop(); return }
      if (root.wheelHeld) {
        var horiz = Math.abs(root.ballVX) > Math.abs(root.ballVY)
        root.scrollAcc += (horiz ? root.ballVX : root.ballVY) * dt
        var det = (root.scrollAcc / root.mashScrollPx) | 0
        if (det !== 0) {
          root.scrollAcc -= det * root.mashScrollPx
          if (horiz) root.scrollX(det)
          else root.scroll(-det)
        }
        return                                // wheel instead of pointer, not as well
      }
      root.pokeIdle()
      root.warp(root.curX + root.ballVX * dt, root.curY + root.ballVY * dt)
    }
  }

  // Repeats are not proof of release. Hyprland cancels key repeat when *any* key
  // goes up and never hands it back to one still held, so pressing right, then
  // left, then releasing right stopped the cursor dead while left was still down.
  // `release = true` binds are no help either: once two bound keys are held,
  // neither key's release fires. So when repeats lapse the compositor is asked.
  function sustain(name, now) {
    if (!root.actionDirs[name]) return
    if (name !== root.lastHoldAction || !root.holdConfirmed) {
      root.moveDir = root.actionDirs[name]
      root.startSweep(name, now, root.holdH)
    }
    root.downUntil = now + root.keysGraceMs
    if (!motionTimer.running) { root.lastTickAt = now; motionTimer.start() }
  }

  function onKeysDown(txt) {
    root.keysDown = String(txt).trim()
    // Deliberately not conditioned on holdConfirmed: motionTimer clears that the
    // instant repeats lapse, ~40ms before this answer gets back, so requiring it
    // threw away every answer that mattered.
    if (!root.active) { keysPoll.stop(); return }
    var st = ({})
    var parts = root.keysDown.split(/\s+/)
    for (var i = 0; i < parts.length; i++) {
      var kv = parts[i].split("=")
      if (kv.length === 2) st[kv[0]] = (kv[1] === "true")
    }
    var now = Date.now()
    if (st[root.lastHoldAction]) { root.sustain(root.lastHoldAction, now); return }
    var names = ["up", "down", "left", "right", "upleft", "upright", "downleft", "downright"]
    for (var j = 0; j < names.length; j++) {
      if (names[j] !== root.lastHoldAction && st[names[j]]) { root.sustain(names[j], now); return }
    }
    keysPoll.stop()
  }

  // Which key stands for which direction is known here, so the question is built
  // here too. is_key_down wants exact X spellings — "Left" where a bind says
  // "LEFT", "i" where it says "I" — and answers nil otherwise, which `or` skips.
  function keysDownExpr() {
    var lua = "local function d(s) for _, n in ipairs({ s, s:lower(), "
            + "s:sub(1,1):upper() .. s:sub(2):lower() }) do "
            + "if hl.is_key_down(n) then return true end end return false end return "
    var terms = []
    var names = ["up", "down", "left", "right", "upleft", "upright", "downleft", "downright"]
    for (var i = 0; i < names.length; i++) {
      var key = ""
      for (var idx in root.mashDirs)
        if (root.mashDirs[idx] === names[i]) key = root.mashLabels[idx] || ""
      terms.push('"' + names[i] + '=" .. tostring(' + (key === "" ? "false" : 'd("' + key + '")') + ')')
    }
    return lua + terms.join(' .. " " .. ')
  }

  Timer {
    id: keysPoll
    interval: root.keysPollMs
    repeat: true
    onTriggered: {
      if (!root.active) { keysPoll.stop(); return }
      if (!keysProbe.running) keysProbe.running = true
    }
  }

  Process {
    id: keysProbe
    command: ["hyprctl", "repl", root.keysDownExpr()]
    stdout: StdioCollector { onStreamFinished: root.onKeysDown(text) }
  }

  // The repeat wheel mode cannot get from the compositor, because 7 is always held
  // alongside and a second held key stops key repeat entirely.
  Timer {
    id: scrollTimer
    interval: root.scrollStartMs
    repeat: true
    onTriggered: {
      if (!root.active || !root.wheelHeld || root.scrollHoldName === "") { scrollTimer.stop(); return }
      scrollTimer.interval = root.scrollRepeatMs
      var dn = root.gridDir(root.scrollHoldName)
      if (!dn) { scrollTimer.stop(); return }
      root.scrollRepeat(root.scrollHoldName, root.actionDirs[dn], Date.now())
    }
  }

  Timer {
    id: scrollKeyPoll
    interval: root.wheelPollMs
    repeat: true
    onTriggered: {
      if (!root.active || !root.wheelHeld || root.scrollHoldName === "") {
        scrollKeyPoll.stop(); scrollTimer.stop(); return
      }
      if (!scrollKeyProbe.running) scrollKeyProbe.running = true
    }
  }

  function keyDownExpr(label) {
    if (!label || label === "") return 'return "false"'
    return 'local s = "' + label + '" '
         + 'for _, n in ipairs({ s, s:lower(), s:sub(1,1):upper() .. s:sub(2):lower() }) do '
         + 'if hl.is_key_down(n) then return "true" end end return "false"'
  }

  Process {
    id: scrollKeyProbe
    command: ["hyprctl", "repl", root.keyDownExpr(root.gridLabel(root.scrollHoldName))]
    stdout: StdioCollector {
      onStreamFinished: {
        if (String(text).indexOf("true") >= 0) return
        root.scrollHoldName = ""; root.scrollFrac = 0; root.scrollUltra = false
        scrollTimer.stop(); scrollKeyPoll.stop()
      }
    }
  }

  Timer {
    id: wheelPoll
    interval: root.wheelPollMs
    repeat: true
    onTriggered: {
      if (!root.active) { wheelPoll.stop(); root.wheelHeld = false; return }
      if (!wheelProbe.running) wheelProbe.running = true
    }
  }

  Process {
    id: wheelProbe
    command: ["hyprctl", "repl", root.keyDownExpr(root.modeKeys["wheel"] || "")]
    stdout: StdioCollector {
      onStreamFinished: {
        if (String(text).indexOf("true") >= 0) return
        root.wheelHeld = false; root.scrollAcc = 0
        root.scrollHoldName = ""; root.scrollFrac = 0; root.scrollUltra = false
        scrollTimer.stop(); scrollKeyPoll.stop(); wheelPoll.stop()
      }
    }
  }

  Timer {
    id: finePoll
    interval: root.wheelPollMs
    repeat: true
    onTriggered: {
      if (!root.active) { finePoll.stop(); root.fineHeld = false; return }
      if (!fineProbe.running) fineProbe.running = true
    }
  }

  Process {
    id: fineProbe
    command: ["hyprctl", "repl", root.keyDownExpr(root.modeKeys["fine"] || "")]
    stdout: StdioCollector {
      onStreamFinished: {
        if (String(text).indexOf("true") >= 0) return
        root.fineHeld = false
        finePoll.stop()
      }
    }
  }

  Timer {
    id: btnPoll
    interval: root.wheelPollMs
    repeat: true
    onTriggered: {
      if (!root.active || root.btnHeld === 0) { root.releaseButton(); return }
      if (Date.now() - root.btnAt > root.btnMaxMs) { root.releaseButton(); return }
      if (!btnProbe.running) btnProbe.running = true
    }
  }

  Process {
    id: btnProbe
    command: ["hyprctl", "repl", root.keyDownExpr(root.modeKeys[root.btnAction] || "")]
    stdout: StdioCollector {
      onStreamFinished: if (String(text).indexOf("true") < 0) root.releaseButton()
    }
  }

  // Crossing focus moves more than the pointer: on a scrolling workspace the whole
  // row pans, so every window's coordinates change and the edge list is stale too.
  // Hyprland reports the settled geometry straight away (measured at 23ms, while
  // the pan is still visibly animating), so the refresh is asked for here and
  // collected one landMs later, once it has arrived.
  Timer {
    id: resyncTimer
    interval: root.resyncMs
    onTriggered: {
      if (!root.active) return
      root.sentX = -1
      root.sentY = -1
      root.refreshState()
      landTimer.restart()
    }
  }

  Timer {
    id: landTimer
    interval: root.landMs
    onTriggered: {
      if (!root.active) return
      root.collectEdges()
      if (root.crossTarget !== "") root.landOnEdge()
      else { root.cursorKnown = false; cursorProc.running = true }
    }
  }

  Timer {
    id: dbgTimer
    interval: 50
    repeat: true
    onTriggered: {
      dbgCanvas.requestPaint()
      // Nothing animates: a few passes cover the strategy results landing after the
      // press that triggered them, and then there is nothing to redraw. A held aux
      // key is the exception -- it stays red for as long as the finger does, which
      // is unbounded, and one more pass after the release is what clears it.
      if (Date.now() - root.dbgLastAt > 300 && !root.dbgAuxHeld()) dbgTimer.stop()
    }
  }

  Timer {
    id: longPressTimer
    interval: root.longPressMs
    onTriggered: if (root.arming()) root.activate(true)
  }

  // With no key events reaching us, the chord's release has to be polled: ask the
  // compositor whether it is still down, so a short press starts when the user lets
  // go rather than at the latch threshold.
  Timer {
    id: armPoll
    interval: root.armPollMs
    repeat: true
    onTriggered: {
      if (!root.arming()) { armPoll.stop(); return }
      if (!chordProbe.running) chordProbe.running = true
    }
  }

  Process {
    id: chordProbe
    command: ["hyprctl", "repl", root.chordExpr]
    stdout: StdioCollector {
      onStreamFinished: if (root.arming() && String(text).indexOf("true") < 0) root.activate(false)
    }
  }

  // The chord's release has to be polled too, which means its keysyms are needed
  // even though Hyprland owns the bind. Either list may hold several syms — any one
  // counts, which is how Super_L/Super_R and the shifted "M" are covered.
  readonly property var chordKey: ["m", "M"]
  readonly property var chordMods: ["Super_L", "Super_R"]
  readonly property string chordExpr: {
    function any(syms) {
      var parts = []
      for (var i = 0; i < syms.length; i++)
        parts.push('hl.is_key_down("' + String(syms[i]).replace(/"/g, '') + '")')
      return "(" + parts.join(" or ") + ")"
    }
    var e = any(root.chordKey)
    if (root.chordMods.length > 0) e = e + " and " + any(root.chordMods)
    return "return tostring((" + e + ") or false)"
  }

  Timer {
    id: idleTimer
    interval: root.idleMs > 0 ? root.idleMs : 1
    onTriggered: if (root.active) root.finish()
  }

  Timer { id: hintTimer; interval: root.hintMs }

  Process {
    id: settings
    command: ["hyprctl", "repl", 'return MOUSH_SETTINGS("' + root.mode + '")']
    stdout: StdioCollector { onStreamFinished: root.onSettings(text) }
  }

  Process {
    id: cursorProc
    command: ["hyprctl", "cursorpos", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        if (root.cursorKnown) return          // already moved; do not clobber
        try {
          var p = JSON.parse(text)
          root.curX = p.x - root.screenX
          root.curY = p.y - root.screenY
        } catch (e) {}
      }
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    atomicWrites: true
    onLoaded: root.loadState(text())
    Component.onCompleted: reload()
  }

  // One shortcut per action. The grid pool is fixed and mostly unused at any given
  // moment; a mode binds as many of them as it has keys.
  Instantiator {
    model: root.actions
    delegate: QtObject {
      required property string modelData
      readonly property var shortcut: GlobalShortcut {
        appid: "moush"
        name: modelData
        description: "Moush: " + modelData
        onPressed: root.handleAction(modelData)
      }
    }
  }

  GlobalShortcut {
    appid: "moush"
    name: "toggle"
    description: "Moush (Super + M)"
    onPressed: root.chordPressed()
    onReleased: root.chordReleased()
  }

  // ---- the overlay -----------------------------------------------------------
  PanelWindow {
    id: panel
    screen: root.targetScreen
    visible: root.opened
    color: "transparent"

    // Cover the whole output and ignore the bar's exclusive zone: coordinates here
    // are screen-local, and warp() reads them as such.
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    mask: Region {}                           // visual only: never block a click

    WlrLayershell.namespace: "moush"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // What mash is thinking: the grid as it sits under the hand, which keys were
    // struck, and the vector being fitted from them. It holds the most recent
    // cluster and keeps holding it — nothing fades — so a gesture can be studied
    // once it is over; the next cluster clears the panel and draws itself instead.
    Canvas {
      id: dbgCanvas
      visible: root.active && root.mashDebug
      x: 32
      y: 44
      width: Math.max(root.dbgPitch * (root.dbgBounds().w + 1) + 2 * root.dbgMaxLen,
                      root.dbgAuxRow().length * root.dbgAuxSlot + 16)
      height: root.dbgPitch * root.dbgBounds().h + 2 * root.dbgMaxLen
              + root.dbgAuxH + root.dbgFootH + root.dbgLogH
      onVisibleChanged: if (visible) { requestPaint(); dbgTimer.start() }
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var now = Date.now()
        var pad = root.dbgMaxLen, pitch = root.dbgPitch
        var gtop = root.dbgAuxH + pad        // the grid starts below the aux row
        var b = root.dbgBounds()
        ctx.fillStyle = root.dbgRgba(0, 0, 0, 1)
        ctx.fillRect(0, 0, dbgCanvas.width, dbgCanvas.height)
        ctx.strokeStyle = root.dbgRgba(255, 255, 255, 0.18)
        ctx.lineWidth = 1
        ctx.strokeRect(0.5, 0.5, dbgCanvas.width - 1, dbgCanvas.height - 1)

        ctx.font = "10px monospace"
        ctx.textBaseline = "top"
        ctx.textAlign = "left"
        ctx.fillStyle = root.dbgRgba(64, 255, 128, 0.95)
        ctx.fillRect(8, 9, 8, 2)
        ctx.fillText("drive:" + root.mashStrategy, 20, 5)
        ctx.fillStyle = root.dbgRgba(255, 255, 255, 0.5)
        ctx.fillText(root.mode, dbgCanvas.width - 8 - root.mode.length * 6, 5)

        // The aux row: everything this mode binds that is not part of the grid, in
        // one line with its function named above the key that does it. Red says the
        // key is down -- for the buttons and the two modifiers that is the real held
        // state, so a drag or a wheel-hold stays lit for as long as it lasts.
        var aux = root.dbgAuxRow()
        ctx.textAlign = "center"
        for (var ai = 0; ai < aux.length; ai++) {
          var a = aux[ai]
          var ax = 8 + ai * root.dbgAuxSlot + root.dbgAuxSlot / 2
          var ay = 22 + root.dbgAuxH / 2
          var down = root.dbgAuxDown(a.action, now)
          ctx.font = "8px monospace"
          ctx.textBaseline = "bottom"
          ctx.fillStyle = root.dbgRgba(255, 255, 255, down ? 0.9 : 0.45)
          ctx.fillText(a.label, ax, ay - 11)
          var kc = down ? root.dbgKeyDown : root.dbgKeyIdle
          ctx.fillStyle = root.dbgRgba(kc[0], kc[1], kc[2], 1)
          ctx.beginPath(); ctx.arc(ax, ay, 9, 0, 2 * Math.PI); ctx.fill()
          // A named key needs three characters where the grid needs one, so it gets
          // a smaller face rather than one that overflows the circle.
          ctx.font = (a.cap.length > 1 ? "8px" : "10px") + " monospace"
          ctx.textBaseline = "middle"
          ctx.fillStyle = root.dbgInk(kc, down ? 1 : 0.8)
          ctx.fillText(a.cap, ax, ay + 0.5)
        }
        ctx.strokeStyle = root.dbgRgba(255, 255, 255, 0.14)
        ctx.lineWidth = 1
        ctx.beginPath()
        ctx.moveTo(6, 22 + root.dbgAuxH - 2)
        ctx.lineTo(dbgCanvas.width - 6, 22 + root.dbgAuxH - 2)
        ctx.stroke()

        // Vectors radiate from the middle of the grid: they are directions, not
        // places, so a common origin makes them comparable at a glance.
        var ox = pad + (b.w / 2) * pitch, oy = gtop + (b.h / 2) * pitch
        function arrow(sx, sy, vx, vy, col, alpha, len) {
          var m = Math.sqrt(vx * vx + vy * vy)
          if (!(m > 0) || alpha <= 0) return
          var L = Math.min(len, root.dbgMaxLen)
          var ex = sx + (vx / m) * L, ey = sy + (vy / m) * L
          ctx.strokeStyle = col; ctx.fillStyle = col; ctx.lineWidth = 2
          ctx.beginPath(); ctx.moveTo(sx, sy); ctx.lineTo(ex, ey); ctx.stroke()
          ctx.beginPath(); ctx.arc(ex, ey, 3, 0, 2 * Math.PI); ctx.fill()
        }

        ctx.font = "10px monospace"
        var dm = Math.sqrt(root.dbgDriveX * root.dbgDriveX + root.dbgDriveY * root.dbgDriveY)
        arrow(ox, oy, root.dbgDriveX, root.dbgDriveY,
              root.dbgRgba(64, 255, 128, 1), root.dbgDriveAt > 0 ? 1 : 0, dm * root.dbgScale)

        for (var si = 0; si < root.mashDebugStrategies.length; si++) {
          var sn = root.mashDebugStrategies[si]
          var rec = root.dbgStrats[sn]
          if (!rec) continue
          var rm = Math.sqrt(rec.x * rec.x + rec.y * rec.y)
          if (!(rm > 0)) continue
          ctx.setLineDash(root.dbgStratDash(sn))
          arrow(ox, oy, rec.x, rec.y, root.dbgStratColor(sn, 1), 1, rm * root.dbgScale)
          ctx.setLineDash([])
        }

        // Keys last so they sit over the vector origin rather than under it. Each is
        // shaded by *when* within the cluster it was struck — first press dark, most
        // recent bright green — and the whole grid re-shades on every press, because
        // the span it normalises against grows as the cluster does.
        var t0 = root.dbgHits.length > 0 ? root.dbgHits[0].t : 0
        var span = root.dbgHits.length > 0
                     ? root.dbgHits[root.dbgHits.length - 1].t - t0 : 0
        ctx.textAlign = "center"
        ctx.textBaseline = "middle"
        for (var key in root.mashPos) {
          var p = root.mashPos[key]
          var nm = "k" + key
          var hitT = -1
          for (var h = 0; h < root.dbgHits.length; h++)
            if (root.dbgHits[h].name === nm) hitT = root.dbgHits[h].t
          var bg = hitT < 0 ? root.dbgKeyIdle
                            : root.dbgMix(root.dbgKeyCold, root.dbgKeyHot,
                                          span > 0 ? (hitT - t0) / span : 1)
          var px = pad + (p.x - b.x) * pitch, py = gtop + (p.y - b.y) * pitch
          ctx.fillStyle = root.dbgRgba(bg[0], bg[1], bg[2], 1)
          ctx.beginPath(); ctx.arc(px, py, 9, 0, 2 * Math.PI); ctx.fill()
          // White on the grey for a key this cluster has not touched, black once
          // struck, over whatever green its timing earned it.
          ctx.fillStyle = root.dbgInk(bg, hitT < 0 ? 0.8 : 1)
          ctx.fillText(root.dbgGlyph(root.mashLabels[key]), px, py + 0.5)
        }

        // Colour key: a swatch in each strategy's dash, then its name, with the one
        // actually steering marked.
        ctx.font = "9px monospace"
        ctx.textBaseline = "middle"
        ctx.textAlign = "left"
        var fy = dbgCanvas.height - root.dbgLogH - root.dbgFootH / 2
        var fx = 8
        for (si = 0; si < root.mashDebugStrategies.length; si++) {
          var fn = root.mashDebugStrategies[si]
          var act = (fn === root.mashStrategy)
          var fw = 20 + fn.length * 5.6
          if (act) {
            ctx.fillStyle = root.dbgRgba(255, 255, 255, 0.17)
            ctx.fillRect(fx - 5, fy - 8, fw + 8, 16)
          }
          ctx.strokeStyle = root.dbgStratColor(fn, 1)
          ctx.lineWidth = act ? 3 : 2
          ctx.setLineDash(root.dbgStratDash(fn))
          ctx.beginPath(); ctx.moveTo(fx, fy); ctx.lineTo(fx + 16, fy); ctx.stroke()
          ctx.setLineDash([])
          ctx.fillStyle = root.dbgRgba(255, 255, 255, act ? 1 : 0.55)
          ctx.fillText(fn, fx + 20, fy)
          fx += 26 + fn.length * 5.6
        }

        // Event log, newest first: which key, how long since the one below it, and
        // the impulse that press applied. Reading the impulse against the delta is
        // the quickest way to see why a burst threw the cursor as far as it did.
        var ly0 = dbgCanvas.height - root.dbgLogH + 4
        ctx.strokeStyle = root.dbgRgba(255, 255, 255, 0.14)
        ctx.lineWidth = 1
        ctx.beginPath(); ctx.moveTo(6, ly0 - 3); ctx.lineTo(dbgCanvas.width - 6, ly0 - 3); ctx.stroke()
        ctx.textBaseline = "top"
        ctx.fillStyle = root.dbgRgba(255, 255, 255, 0.45)
        ctx.fillText("key", 10, ly0)
        ctx.fillText("dt ms", 44, ly0)
        ctx.fillText("imp px/s", 92, ly0)
        for (var li = 0; li < root.dbgLog.length; li++) {
          var e = root.dbgLog[li]
          var ey2 = ly0 + (li + 1) * root.dbgLogLineH
          var ea = 0.4 + 0.6 * (1 - li / root.dbgLogMax)
          ctx.fillStyle = e.grid ? root.dbgRgba(255, 255, 255, ea)
                                 : root.dbgRgba(255, 170, 90, ea)
          ctx.fillText(e.g, 10, ey2)
          ctx.fillStyle = root.dbgRgba(200, 200, 200, ea * 0.85)
          ctx.fillText(e.dt < 0 ? "-" : String(e.dt), 44, ey2)
          ctx.fillStyle = e.imp > 0 ? root.dbgRgba(120, 230, 255, ea)
                                    : root.dbgRgba(140, 140, 140, ea * 0.7)
          ctx.fillText(e.imp > 0 ? String(Math.round(e.imp)) : "-", 92, ey2)
        }
      }
    }

    // Hyprland hides the real pointer on key press (cursor:hide_on_key_press), so
    // without this marker there is nothing to aim with.
    Item {
      x: root.curX
      y: root.curY
      visible: root.active

      Rectangle {
        x: -root.markerSize / 2
        y: -root.markerSize / 2
        width: root.markerSize
        height: root.markerSize
        radius: root.markerSize / 2
        color: "#66ff2d2d"
        border.color: "#ccff5555"
        border.width: 1
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.markerSize / 2 + 4
        text: root.mode
        color: "#ddffffff"
        font.pixelSize: 12
        visible: hintTimer.running
      }
    }
  }
}
