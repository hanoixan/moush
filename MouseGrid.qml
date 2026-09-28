import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland

// Mouse Keys — drive the pointer from the keyboard.
//
// Super + Left Alt enters. How long you hold the chord decides both when the
// session starts and how long it lasts:
//   short press   starts on the chord's RELEASE; exits after idleMs idle
//   long press    starts the moment chordLongPressMs elapses, chord still
//                 down; latched until you hit the chord again
//
// Three keymaps, cycled with Tab. The choice persists across sessions.
//
//            move                  buttons L/M/R      scroll up/down
//   left     i j k l  (right hand)   c  x  z            y   h
//   right    w a s d  (left hand)    ,  .  /            r   f
//   arrows   arrow keys              d  s  a            PgUp PgDn
//
// Two hard-won constraints shape this:
//
//  - The overlay takes NO keyboard focus, and input arrives as global
//    shortcuts driven by binds in the plugin's own submap. Both grab modes
//    fail, measured against a click-logging client: Exclusive focus makes
//    Hyprland swallow every pointer event so injected clicks never reach the
//    app, and OnDemand passes clicks but delivers exactly one key event per
//    session before losing focus.
//  - Nothing here needs a key RELEASE, because none is available: a
//    `release = true` bind fires for exec_cmd but never when it dispatches
//    hl.dsp.global. Movement and scroll ride Hyprland's own key repeat
//    (250ms delay, then 40/s) instead, and a key is taken to be up once the
//    repeats stop for repeatGapMs.
//  - Buttons are ordinary keys, not modifiers. A click fired while its own
//    modifier is held arrives as Shift+click or Alt+scroll, which apps read as
//    extend-selection or ignore outright; and modifier keys never report a
//    release (neither GlobalShortcut.released() nor a `release = true` bind),
//    so they cannot drive hold or drag either.
Item {
  id: root

  // Injected by omarchy-shell when the overlay loads.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  // ---- tunables -------------------------------------------------------------
  readonly property real baseStep: 1          // floor: any press moves at least this
  readonly property real shiftScale: 8        // any Shift multiplies movement by this
  readonly property int sweepMs: 1500         // hold this long to cross one screen width
  readonly property real scrollMaxRate: 25    // detents/s at full acceleration
  readonly property int motionTickMs: 16      // how often held motion is integrated
  readonly property int repeatGapMs: 55       // movement: longer gap than this => key is up
                                              // (repeats land 25-34ms apart, so 55 is safe
                                              //  and halves the coast after release)
  readonly property int scrollPollMs: 80      // how often we ask if a scroll key is still down
  readonly property int scrollGapMs: 150      // scroll: grace between polls before calling it up
  readonly property int holdChainMs: 400      // same key again within this => same hold, keep its clock
  readonly property int idleMs: 2000          // short-press session idles out; 0 disables
  readonly property int chordLongPressMs: 500 // chord held this long latches instead
  readonly property int armPollMs: 70         // how often we check if the chord is still down
  readonly property real markerSize: 28       // the red disk's diameter
  readonly property bool debug: false

  // ---- keymaps --------------------------------------------------------------
  // evdev keycodes (nativeScanCode - 8), so the maps are layout-independent.
  readonly property var keymaps: ({
    "left":   { up: 23, left: 36, down: 37, right: 38,     // i j k l
                lmb: 46, mmb: 45, rmb: 44,                 // c x z
                su: 21, sd: 35 },                          // y h
    "right":  { up: 17, left: 30, down: 31, right: 32,     // w a s d
                lmb: 51, mmb: 52, rmb: 53,                 // , . /
                su: 19, sd: 33 },                          // r f
    "arrows": { up: 103, left: 105, down: 108, right: 106,  // arrow keys
                lmb: 32, mmb: 31, rmb: 30,                 // d s a
                su: 104, sd: 109 }                         // PgUp PgDn
  })
  readonly property var modeOrder: ["left", "right", "arrows"]
  readonly property int keyTab: 15
  // Keysyms for the scroll keys, for hl.is_key_down polling.
  readonly property var keySyms: ({ "21": "y", "35": "h", "19": "r", "33": "f",
                                    "104": "Prior", "109": "Next" })

  // Chord keys. Super is only ever the chord; Left Alt is too, and since no
  // button is a modifier any more it has no second meaning to disambiguate.
  readonly property var superKeys: [125, 126]
  readonly property int keyLAlt: 56

  // ---- persisted setting ------------------------------------------------------
  property string keymap: "right"
  readonly property string statePath: Quickshell.statePath("mousekeys.json")

  function loadState(text) {
    try {
      var s = JSON.parse(text)
      if (s && root.modeOrder.indexOf(String(s.keymap)) !== -1) root.keymap = String(s.keymap)
    } catch (e) {}
  }

  function saveState() {
    stateFile.setText(JSON.stringify({ keymap: root.keymap }, null, 2) + "\n")
  }

  function cycleKeymap() {
    var i = root.modeOrder.indexOf(root.keymap)
    root.keymap = root.modeOrder[(i + 1) % root.modeOrder.length]
    root.saveState()
    root.log("keymap -> " + root.keymap)
    hintTimer.restart()
  }

  readonly property var km: root.keymaps[root.keymap] || root.keymaps["right"]

  // ---- session state ----------------------------------------------------------
  property bool opened: false                 // overlay mapped (from the chord press)
  property bool active: false                 // ...and the keys actually do something
  property bool sticky: false                 // chord was long-pressed: no idle exit
  property var targetScreen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
  property real screenX: 0
  property real screenY: 0
  property real screenW: 0
  property real screenH: 0
  property real curX: 0
  property real curY: 0
  property bool cursorKnown: false
  property real lastKeyAt: 0                  // for telling a repeat from a fresh press
  property int lastKeyCode: -1
  // Speed model: v = k*holdH, where holdH is how long the current contiguous
  // hold has run, growing while a key is down and receding when none is. With
  // k = 2*W/T^2 a hold of T seconds integrates to exactly one screen width, and
  // a hold of t seconds reaches t/T of top speed — so tapping at a given
  // duration gives that fraction of a sweep's speed.
  property real holdH: 0                      // seconds of accumulated hold
  property bool holdConfirmed: false          // a repeat proved this is a real hold
  property real holdPressAt: 0                // when the current press began
  property real downUntil: 0                  // held as long as now() < this
  property string scrollSym: ""                // keysym polled while a scroll key is held
  property real lastTickAt: 0                 // for integrating against real elapsed time
  property int lastHoldCode: -1               // for chaining a press to its own first repeat
  property string activeKind: ""               // "move" | "scroll"
  property var moveDir: [0, 0]
  property bool moveShift: false              // Shift was held on the latest movement event
  property int scrollSign: 0
  property real scrollAcc: 0                  // fractional detents awaiting emission
  property real sentX: -1                     // last position actually dispatched
  property real sentY: -1

  function log(msg) { if (root.debug) console.warn("[mousekeys] " + msg) }

  function arming() { return root.opened && !root.active }

  // Diagnostic: omarchy-shell shell call <id> probe ""
  function probe() {
    return "opened=" + root.opened + " active=" + root.active + " sticky=" + root.sticky
      + " keymap=" + root.keymap
      + " kmUp=" + (root.km ? root.km.up : "NOKM")
      + " idle=" + idleTimer.running + " long=" + longPressTimer.running
      + " moving=" + motionTimer.running + " held=" + root.holdConfirmed
      + " shift=" + root.moveShift
      + " holdH=" + root.holdH.toFixed(2) + " v=" + root.speedFor(root.holdH).toFixed(0)
  }

  // Hyprland 0.56 parses dispatch arguments as Lua, and Quickshell already
  // holds the request socket — so this is one write on a live connection,
  // where shelling out to `hyprctl eval` was a process spawn per cursor move.
  function hypr(dispatcher) {
    Hyprland.dispatch(dispatcher)
  }

  // The output Hyprland has focused is where a keyboard-summoned overlay belongs.
  function focusedScreen() {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? String(monitor.name || "") : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++)
      if (String(screens[i].name) === name) return screens[i]
    return screens.length > 0 ? screens[0] : null
  }

  // ---- lifecycle ---------------------------------------------------------------
  function beginSession(scr) {
    root.targetScreen = scr
    root.screenX = scr.x
    root.screenY = scr.y
    root.screenW = scr.width
    root.screenH = scr.height
    root.lastKeyCode = -1
    root.lastHoldCode = -1
    root.lastKeyAt = 0
    root.holdH = 0
    root.holdConfirmed = false
    root.scrollAcc = 0
    root.activeKind = ""
    root.moveShift = false
    root.sentX = -1
    root.sentY = -1
    root.sticky = false
    root.active = false
    root.cursorKnown = false
    root.curX = scr.width / 2
    root.curY = scr.height / 2
    cursorProc.running = true

    // Empty submap so Omarchy's own bindings can't eat movement keys, and so
    // the wheel events we synthesize don't reach SUPER+scroll bindings.
    // The submap is the input mechanism now, not just a shield: every movement,
    // button and scroll key is bound inside it.
    root.hypr('hl.dsp.submap("mousegrid")')
    root.opened = true
  }

  // Arming resolved: the keys start doing something now.
  function activate(latched) {
    if (!root.arming()) return
    longPressTimer.stop()
    armPoll.stop()
    root.sticky = latched
    root.active = true
    hintTimer.restart()
    if (!latched) root.pokeIdle()
    root.log(latched ? "active, latched" : "active, idle deadline applies")
  }

  // The chord both enters and leaves. How long it is held decides which
  // flavour you get: a long press latches, a short press stays alive only
  // while you keep using it.
  function chordPressed() {
    if (root.opened) {
      root.finish()
      return
    }
    var scr = root.focusedScreen()
    if (!scr) return
    root.beginSession(scr)
    longPressTimer.restart()
    armPoll.restart()
    root.log("arming on " + scr.name)
  }

  function chordReleased() {
    if (!root.arming()) return
    root.activate(false)
  }

  // Called by the shell's hide(); also our own teardown.
  function close() {
    if (root.opened) root.finish()
  }

  function finish() {
    motionTimer.stop()
    scrollPoll.stop()
    idleTimer.stop()
    longPressTimer.stop()
    armPoll.stop()
    hintTimer.stop()
    root.active = false
    root.opened = false
    root.hypr('hl.dsp.submap("reset")')
    root.log("off")
  }

  function pokeIdle() {
    if (!root.active || root.sticky || root.idleMs <= 0) return
    idleTimer.restart()
  }

  // ---- clicks & scroll ----------------------------------------------------------
  // The session stays up across clicks, so it cannot unmap first. The window's
  // input region is empty and its keyboard focus is OnDemand, so the click
  // passes through to whatever is underneath.
  function clickNow(button) {
    if (button <= 0) return
    var code = button === 1 ? "0xC0" : button === 2 ? "0xC1" : "0xC2"
    Quickshell.execDetached(["ydotool", "click", code])
    root.log("click " + button)
  }

  // ydotool's wheel axis: +1 is one detent up, -1 one down.
  function scroll(detents) {
    if (detents === 0) return
    Quickshell.execDetached(["ydotool", "mousemove", "-w", "-x", "0", "-y", String(detents)])
  }

  // ---- speed model ----------------------------------------------------------
  // k = 2W/T^2, so integrating k*h over a hold of T seconds gives exactly W.
  function speedFor(h) {
    var T = root.sweepMs / 1000
    var W = root.screenW > 0 ? root.screenW : 1920
    return (2 * W / (T * T)) * h
  }

  function scrollRateFor(h) {
    return root.scrollMaxRate * h / (root.sweepMs / 1000)
  }

  function dirFor(code) {
    var m = root.km
    if (code === m.up) return [0, -1]
    if (code === m.down) return [0, 1]
    if (code === m.left) return [-1, 0]
    if (code === m.right) return [1, 0]
    return null
  }

  // ---- movement -------------------------------------------------------------
  // Shift is not a separate key here: the submap binds a SHIFT + <key> variant
  // of every key, so whether Shift was down arrives with the event itself.
  // Hyprland's SHIFT modmask is side-agnostic, so either Shift works.
  function shiftFactor() { return root.moveShift ? root.shiftScale : 1 }

  function moveBy(dir, px) {
    root.warp(root.curX + dir[0] * px, root.curY + dir[1] * px)
  }

  function warp(x, y) {
    root.cursorKnown = true
    root.curX = Math.min(Math.max(x, 0), root.screenW - 1)
    root.curY = Math.min(Math.max(y, 0), root.screenH - 1)
    var ix = Math.round(root.screenX + root.curX)
    var iy = Math.round(root.screenY + root.curY)
    // Sub-pixel steps accumulate in curX/curY; only tell Hyprland when the
    // rounded position actually changes, so a slow crawl is not a dispatch storm.
    if (ix === root.sentX && iy === root.sentY) return
    root.sentX = ix
    root.sentY = iy
    root.hypr("hl.dsp.cursor.move({ x = " + ix + ", y = " + iy + " })")
  }

  // ---- key routing ----------------------------------------------------------
  // The first repeat lands input:repeat_delay (250ms) after the press, far
  // outside the fast-cadence window that identifies later repeats, so it looks
  // like a fresh press. Carrying the original press time forward when the same
  // key reappears within holdChainMs keeps the hold clock honest — without it a
  // 1.5s hold measured only 1.3s of acceleration and fell ~20% short.
  function beginHold(kind, code, now) {
    var chained = (code === root.lastHoldCode) && (now - root.holdPressAt <= root.holdChainMs)
    root.activeKind = kind
    root.lastHoldCode = code
    if (!chained) root.holdPressAt = now
    root.holdConfirmed = false
    root.downUntil = now + root.repeatGapMs
    root.lastTickAt = now
    motionTimer.start()
  }

  // A repeat is the first proof that a key is genuinely held — nothing else
  // distinguishes a tap from a hold, since Hyprland gives no key release and
  // the first repeat only lands after input:repeat_delay (250ms).
  function confirmHold(now, graceMs) {
    root.downUntil = now + graceMs
    if (root.holdConfirmed) return
    root.holdConfirmed = true
    root.holdH = Math.max(root.holdH, (now - root.holdPressAt) / 1000)
    if (!motionTimer.running) root.lastTickAt = now
    motionTimer.start()
  }

  function handleKey(code, shifted) {
    if (!root.active) return        // still arming; the chord owns the keyboard
    var m = root.km
    var now = Date.now()
    var repeat = (code === root.lastKeyCode) && (now - root.lastKeyAt <= root.repeatGapMs)
    root.lastKeyAt = now
    root.lastKeyCode = code

    // Buttons and the keymap switch must not auto-fire: several of these keys
    // are movement in another keymap, so they are bound as repeating.
    if (code === root.keyTab) { if (!repeat) { root.pokeIdle(); root.cycleKeymap() } return }
    if (code === m.lmb) { if (!repeat) { root.pokeIdle(); root.clickNow(1) } return }
    if (code === m.mmb) { if (!repeat) { root.pokeIdle(); root.clickNow(3) } return }
    if (code === m.rmb) { if (!repeat) { root.pokeIdle(); root.clickNow(2) } return }

    // Scroll cannot ride key repeat: injecting a wheel event through ydotool
    // cancels Hyprland's repeat for the key being held (measured: 40 repeats
    // become 8). So the held state is polled from the compositor instead.
    if (code === m.su || code === m.sd) {
      root.pokeIdle()
      root.scrollSign = (code === m.su) ? 1 : -1
      if (repeat) return                    // a repeat may still slip in; polling owns this
      root.scrollSym = root.keySyms[code] || ""
      root.beginHold("scroll", code, now)
      root.scroll(root.scrollSign)          // the one-detent floor
      if (root.scrollSym) scrollPoll.restart()
      return
    }

    var d = root.dirFor(code)
    if (!d) return
    root.pokeIdle()
    root.moveDir = d
    root.moveShift = (shifted === true)
    if (repeat) { root.confirmHold(now, root.repeatGapMs); return }
    root.beginHold("move", code, now)
    root.moveBy(d, root.baseStep * root.shiftFactor())   // the floor, scaled
  }

  // ---- input ----------------------------------------------------------------
  // One global shortcut per physical key, dispatched from binds in the submap.
  // Each carries the key's evdev code so everything downstream is unchanged
  // from when these arrived as key events. Keys that move or scroll in any
  // keymap also need a release, to stop the accel timer and start the glide.
  readonly property var keyDefs: [
    { n: "I", c: 23 }, { n: "J", c: 36 }, { n: "K", c: 37 }, { n: "L", c: 38 },
    { n: "Y", c: 21 }, { n: "H", c: 35 },
    { n: "W", c: 17 }, { n: "A", c: 30 }, { n: "S", c: 31 }, { n: "D", c: 32 },
    { n: "R", c: 19 }, { n: "F", c: 33 },
    { n: "UP", c: 103 }, { n: "DOWN", c: 108 }, { n: "LEFT", c: 105 }, { n: "RIGHT", c: 106 },
    { n: "Prior", c: 104 }, { n: "Next", c: 109 },
    { n: "C", c: 46 }, { n: "X", c: 45 }, { n: "Z", c: 44 },
    { n: "comma", c: 51 }, { n: "period", c: 52 }, { n: "slash", c: 53 },
    { n: "TAB", c: 15 }
  ]

  Instantiator {
    model: root.keyDefs
    delegate: QtObject {
      required property var modelData
      readonly property var shortcut: GlobalShortcut {
        appid: "mousegrid"
        name: "k" + modelData.n
        description: "Mouse keys " + modelData.n
        onPressed: root.handleKey(modelData.c, false)
      }
    }
  }

  // Every key also gets a SHIFT + variant, so Shift never falls through to the
  // focused app and movement can scale by shiftScale. Shift is a no-op for
  // buttons, Tab and scrolling.
  Instantiator {
    model: root.keyDefs
    delegate: QtObject {
      required property var modelData
      readonly property var shortcut: GlobalShortcut {
        appid: "mousegrid"
        name: "k" + modelData.n + "-shift"
        description: "Mouse keys Shift+" + modelData.n
        onPressed: root.handleKey(modelData.c, true)
      }
    }
  }

  // ---- triggers ------------------------------------------------------------------------
  // Bound in ~/.config/hypr/bindings.lua via hl.dsp.global("mousegrid:<name>").
  // One bind per press order, because Hyprland only matches the bind whose
  // final key completes it.
  GlobalShortcut {
    appid: "mousegrid"
    name: "open-light-alt"
    description: "Mouse keys (Super, then Left Alt)"
    onPressed: root.chordPressed()
    onReleased: root.chordReleased()
  }

  GlobalShortcut {
    appid: "mousegrid"
    name: "open-light-super"
    description: "Mouse keys (Left Alt, then Super)"
    onPressed: root.chordPressed()
    onReleased: root.chordReleased()
  }

  // ---- helpers -----------------------------------------------------------------------------
  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
  }

  Process {
    id: cursorProc
    command: ["hyprctl", "cursorpos", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        if (root.cursorKnown) return  // user already moved; don't clobber
        try {
          var p = JSON.parse(text)
          root.curX = p.x - root.screenX
          root.curY = p.y - root.screenY
        } catch (e) {}
      }
    }
  }







  Timer {
    id: scrollPoll
    interval: root.scrollPollMs
    repeat: true
    onTriggered: {
      if (!root.active || root.activeKind !== "scroll" || !root.scrollSym) { scrollPoll.stop(); return }
      if (!scrollProbe.running) scrollProbe.running = true
    }
  }

  Process {
    id: scrollProbe
    command: ["hyprctl", "repl", "return tostring(hl.is_key_down(\"" + root.scrollSym + "\"))"]
    stdout: StdioCollector {
      onStreamFinished: {
        if (!root.active || root.activeKind !== "scroll") return
        if (String(text).indexOf("true") >= 0) {
          root.confirmHold(Date.now(), root.scrollGapMs)
          if (!motionTimer.running) { root.lastTickAt = Date.now(); motionTimer.start() }
        } else {
          scrollPoll.stop()
          root.holdConfirmed = false
        }
      }
    }
  }


  // Integrates held motion. holdH grows while the key is down and recedes when
  // it is not, so a re-press resumes part-way up the ramp rather than from rest.
  Timer {
    id: motionTimer
    interval: root.motionTickMs
    repeat: true
    onTriggered: {
      if (!root.active) { motionTimer.stop(); return }
      var now = Date.now()
      // Real elapsed time, not the nominal interval: Qt's timer runs late and
      // each tick also writes to the Hyprland socket.
      var dt = Math.min(0.1, Math.max(0.001, (now - root.lastTickAt) / 1000))
      root.lastTickAt = now
      var down = root.holdConfirmed && (now < root.downUntil)
      if (down) {
        root.holdH = Math.min(root.sweepMs / 1000, root.holdH + dt)
        root.pokeIdle()
        if (root.activeKind === "move") {
          root.moveBy(root.moveDir, root.speedFor(root.holdH) * dt * root.shiftFactor())
        } else if (root.activeKind === "scroll") {
          root.scrollAcc += root.scrollRateFor(root.holdH) * dt
          while (root.scrollAcc >= 1) { root.scroll(root.scrollSign); root.scrollAcc -= 1 }
        }
      } else {
        root.holdConfirmed = false
        root.holdH = Math.max(0, root.holdH - dt)
        root.scrollAcc = 0
        if (root.holdH <= 0) motionTimer.stop()
      }
    }
  }

  // At the threshold, ask the compositor whether the chord is still physically
  // down rather than trusting that we saw its release: the overlay maps during
  // the press, so a quick release can land before it has keyboard focus, and
  // that used to latch every short press by default.
  Timer {
    id: longPressTimer
    interval: root.chordLongPressMs
    onTriggered: if (root.arming()) root.activate(true)
  }

  // With no key events reaching us, the chord's release has to be polled: ask
  // the compositor every armPollMs whether it is still down, so a short press
  // still starts when the user lets go rather than at the latch threshold.
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
    command: ["hyprctl", "repl",
      "return tostring((hl.is_key_down(\"Alt_L\") and (hl.is_key_down(\"Super_L\")"
      + " or hl.is_key_down(\"Super_R\"))) or false)"]
    stdout: StdioCollector {
      // Still down: keep waiting for either the release or the latch timer.
      // Up: that was a short press, so start now with the idle deadline.
      onStreamFinished: if (root.arming() && String(text).indexOf("true") < 0) root.activate(false)
    }
  }

  // Short-press sessions live only as long as they are being used.
  Timer {
    id: idleTimer
    interval: root.idleMs > 0 ? root.idleMs : 1
    onTriggered: if (root.active) {
      root.log("idle timeout")
      root.finish()
    }
  }

  // Names the active keymap briefly on entry and after Tab, so the mode is
  // discoverable without having to remember what persisted.
  Timer {
    id: hintTimer
    interval: 1200
  }

  // ---- UI --------------------------------------------------------------------------------------
  PanelWindow {
    id: panel
    screen: root.targetScreen
    visible: root.opened
    color: "transparent"

    // Cover the whole output and ignore the bar's exclusive zone: coordinates
    // here are screen-local, and warp() reads them as such, so the surface has
    // to start at the real screen origin.
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore

    // Visual-only surface: keep the input region empty so it never blocks a click.
    mask: Region {}

    WlrLayershell.namespace: "mousegrid"
    WlrLayershell.layer: WlrLayer.Overlay
    // Never take keyboard focus: any focus mode either swallows the clicks we
    // inject (Exclusive) or stops delivering keys after the first one
    // (OnDemand). Keys come from submap binds instead — see keyDefs below.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // Hyprland hides the real pointer on key press (cursor:hide_on_key_press),
    // so without this marker there is nothing to aim with.
    Item {
      x: root.curX
      y: root.curY
      visible: root.active          // nothing to aim with until the keys are live

      Rectangle {
        x: -root.markerSize / 2
        y: -root.markerSize / 2
        width: root.markerSize
        height: root.markerSize
        radius: root.markerSize / 2
        color: Qt.rgba(1, 0.13, 0.13, 0.33)
        border.width: 1
        border.color: Qt.rgba(1, 0.33, 0.33, 0.7)
      }

      Text {
        visible: hintTimer.running
        text: root.keymap
        font.pixelSize: 11
        font.bold: true
        color: Qt.rgba(1, 1, 1, 0.92)
        style: Text.Outline
        styleColor: Qt.rgba(0, 0, 0, 0.65)
        x: -width / 2
        y: root.markerSize / 2 + 3
      }
    }

  }
}
