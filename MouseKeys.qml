import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland

// Mouse Keys — drive the pointer from the keyboard.
//
// Super + M enters. How long you hold the chord decides both when the
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
  readonly property real baseStep: 8          // floor: any press moves at least this
  readonly property real edgeEpsilon: 0.5     // an edge this close counts as already there
  // bindings.lua owns the keys, so it owns this too — see luaConf. Hyprland's
  // Lua VM keeps globals across config loads, so MOUSEKEYS.fast_tap_ms set there
  // is readable from here and survives a hyprctl reload.
  property int fastTapMs: 135                 // re-pressing a key quicker than this skitters
  // A new direction within this of the last evidence a move key was down keeps
  // the speed already built up instead of starting the ramp again. Unrelated to
  // fastTapMs even when the numbers happen to match.
  property int carryMs: 175                   // grace for handing speed to a new direction
  readonly property int scrollEndDetents: 120 // a fast scroll re-tap runs to the end of the view
  readonly property int resyncMs: 130         // wait for a focus warp to settle, then re-read
  readonly property int landMs: 60            // ...then for the refreshed geometry to arrive
  readonly property int sweepMs: 1500         // hold this long to cross one screen width
  readonly property real scrollMaxRate: 25    // detents/s at full acceleration
  readonly property int motionTickMs: 16      // how often held motion is integrated
  readonly property int repeatGapMs: 55       // movement: longer gap than this => key is up
                                              // (repeats land 25-34ms apart, so 55 is safe
                                              //  and halves the coast after release)
  readonly property int scrollArmMs: 250      // held this long before auto-scroll starts
  readonly property int scrollMaxMs: 8000     // safety cap if the release callback never lands
  readonly property int holdChainMs: 400      // same key again within this => same hold, keep its clock
  readonly property int takeoverGraceMs: 320  // bridges a new key's repeat delay so motion never lapses
  // ---- mash ------------------------------------------------------------------
  readonly property int mashEwmaTauMs: 400    // ewma's decay constant; the rest use the cluster
  readonly property real mashFriction: 3.0    // e-folds per second of rolling decay
  property real mashGain: 0.30                // impulse per (key-width/s)^mashExp
  readonly property real mashStepPx: 1        // every press moves at least this far
  // A fit has to carry real speed to count. Zero is not a rounding error here: a
  // straight reversal (L K L) fits to an axis with exactly no motion along it, and
  // comes out as ~1e-15 rather than 0, which would pass a bare "> 0" and be taken
  // as a valid contribution that happens to move nothing.
  readonly property real mashMinSpeed: 0.05   // key-widths/s below this is degenerate
  // A gap longer than this ends the gesture: the next press starts a fresh
  // cluster, and a fit is only ever made from presses within one. Mixing two
  // sweeps separated by a pause produced a direction belonging to neither.
  readonly property int mashClusterMs: 200
  // The fit sees at most this many of the most recent presses. Still clipped by
  // the cluster — a new gesture starts empty — so it is the last mashSamples
  // events *within* the current cluster, never a mix of two.
  property int mashSamples: 4
  readonly property var mashStrategies: ["cpa", "lsq", "net", "pca", "ewma"]
  readonly property real dbgPitch: 26         // px between grid cells
  readonly property real dbgScale: 4          // px drawn per key-width/second
  readonly property real dbgMaxLen: 92        // ...but never longer than this
  readonly property real dbgDeadLen: 26       // degenerate vectors have no speed to scale
  readonly property real dbgFootH: 20         // strip along the bottom for the colour key
  readonly property int dbgLogMax: 20         // events kept in the log, newest first
  readonly property real dbgLogLineH: 11
  readonly property real dbgLogH: root.dbgLogMax * root.dbgLogLineH + 20
  readonly property var dbgGlyphs: ({ bracketleft: "[", bracketright: "]",
                                      apostrophe: "'", semicolon: ";", comma: ",",
                                      period: ".", slash: "/", minus: "-", grave: "`" })
  readonly property real mashExp: 3.0         // maps mash rate to impulse, see README
  property real mashVMax: 1000                // px/s ceiling; also the longest throw
  readonly property real mashScrollPx: 90     // px of ball travel per wheel detent
  readonly property int wheelPollMs: 70       // w gives no reliable release; ask instead
  // A finger still resting on a key is a hand still on the ball. Checked by asking
  // the compositor, because a release event cannot be relied on: once two bound
  // keys are held Hyprland delivers neither key's release, and a missed one would
  // leave the ball gripped for the rest of the session.
  // A lone tap is a nudge: a small, exact push away from the middle of the grid,
  // for the last few pixels rather than for travelling.
  property bool mashNudge: true
  property real nudgeInnerPx: 1               // an inner-ring key pushes this far
  property real nudgeOuterPx: 5               // an outer-ring key this far
  property var nudgeInnerNames: []            // action names, published by bindings.lua
  property var nudgeOuterNames: []
  property string nudgeName: ""               // the key the last nudge came from
  // Grid positions that double as directions on a lone press. Published by
  // bindings.lua, which owns which key sits where.
  property var mashDirs: ({})
  // Held in wheel mode, a direction key repeats, and the repeats grow: flat for
  // scrollIncreaseDelay, then ramping to the maximum over scrollIncreaseTime and
  // staying there. Seconds, not milliseconds — the names say so.
  property real scrollRepeatScaleMin: 1
  property real scrollRepeatScaleMax: 10
  property real scrollIncreaseDelay: 1.5
  property real scrollIncreaseTime: 5
  // Hyprland stops repeating a key as soon as a second bound key is held, and in
  // wheel mode 7 always is, so the repeat has to be generated here and the release
  // asked about. These are that clock, not the compositor's.
  property int scrollRepeatMs: 60             // between self-driven repeats
  readonly property int scrollStartMs: 250    // before the first, as a key would
  property string scrollHoldName: ""          // the key being leaned on
  property real scrollHoldAt: 0               // when it went down
  property real scrollFrac: 0                 // detents owed but not yet whole
  property int scrollReps: 0                  // diagnostic: repeats seen this hold
  property int scrollDets: 0                  // diagnostic: detents actually sent
  property bool fineHeld: false               // the fine modifier is down
  readonly property real finePx: 1            // ...so a press steps this far instead
  // Held rather than tapped, a nudge repeats — the same push, over and over, so
  // the grid can be leaned on for a longer adjustment. Confirmed by asking whether
  // the key is still down, since a release is not reliably delivered.
  property bool nudgeRepeat: true
  property int nudgeDelayMs: 250              // first repeat, as a key would
  property int nudgeRateMs: 90                // and every this often after
  property bool mashGrip: false               // grip the ball while a key is held
  property real mashGripFriction: 12          // e-folds/s bled off while gripped
  readonly property int holdCheckMs: 50       // quiet for this long, then ask
  readonly property int holdPollMs: 70        // ...and keep asking while it is held

  readonly property int keysArmMs: 25         // ask the compositor this long before a hold would lapse
  readonly property int keysPollMs: 60        // ...and keep asking this often while it says held
  readonly property int keysGraceMs: 60       // each "still down" answer is good for this long
  readonly property int idleMs: 2000          // short-press session idles out; 0 disables
  readonly property int chordLongPressMs: 500 // chord held this long latches instead
  readonly property int armPollMs: 70         // how often we check if the chord is still down
  readonly property real markerSize: 28       // the red disk's diameter
  readonly property bool debug: false

  // ---- keymaps --------------------------------------------------------------
  // evdev keycodes (nativeScanCode - 8), so the maps are layout-independent.
  // Keys live in bindings.lua, not here. Each keymap is a Hyprland submap whose
  // binds point at these action names, so remapping a key is a one-line edit in
  // that file and needs no change to this plugin.
  // Mash grid positions are actions too, named by coordinate: "m<x4>_<y>", where
  // x4 is the column in *quarter*-key steps, which is the coarsest unit the real
  // stagger fits in: the top two rows sit on halves, and the bottom two are a
  // further quarter to the right again. That puts the entire spatial layout in
  // bindings.lua — which physical key sits at which grid position is a binding,
  // like everything else here.
  // Row 0 is gone: 7 8 9 0 are the wheel and the mouse buttons now, and - is the
  // fine modifier, so none of them is a point in space any more. y still counts
  // from the number row so the coordinates, and the action names, do not shift.
  readonly property var mashCols: [[],                         // 7 8 9 0 -     buttons
                                   [0, 4, 8, 12, 16, 20],      // Y U I O P [   x.00
                                   [1, 5, 9, 13, 17, 21],      // H J K L ; '   x.25
                                   [3, 7, 11, 15, 19]]         // N M , . /     x.75
  readonly property var mashActions: {
    var out = []
    for (var y = 0; y < root.mashCols.length; y++)
      for (var i = 0; i < root.mashCols[y].length; i++)
        out.push("m" + root.mashCols[y][i] + "_" + y)
    return out
  }
  readonly property var actions: ["up", "down", "left", "right",
                                  "lmb", "mmb", "rmb",
                                  "scrollup", "scrolldown", "cycle",
                                  "noop", "wheel", "debug", "strategy", "fine",
                                  "upleft", "upright", "downleft",
                                  "downright"].concat(root.mashActions)
  // Diagonals are normalised, so one press covers the same ground as a cardinal
  // press rather than 1.41 times as much.
  readonly property real diag: 0.70710678
  readonly property var actionDirs: ({ "up": [0, -1], "down": [0, 1],
                                       "left": [-1, 0], "right": [1, 0],
                                       "upleft": [-root.diag, -root.diag],
                                       "upright": [root.diag, -root.diag],
                                       "downleft": [-root.diag, root.diag],
                                       "downright": [root.diag, root.diag] })

  // Chord keys. Super is only ever the chord; Left Alt is too, and since no
  // button is a modifier any more it has no second meaning to disambiguate.

  // ---- persisted setting ------------------------------------------------------
  // "Settings are inline on the entry" — the shell README's storage rule 3. The
  // shell object is injected, so we read our own plugins[] entry off it.
  readonly property var settings: {
    var cfg = root.shell && root.shell.shellConfig ? root.shell.shellConfig : null
    var list = cfg && cfg.plugins ? cfg.plugins : []
    for (var i = 0; i < list.length; i++)
      if (list[i] && String(list[i].id) === "mousekeys") return list[i]
    return ({})
  }
  // The entry chord's release has to be polled (see chordProbe), which means the
  // plugin needs the chord's keysyms even though Hyprland owns the bind. Change
  // the bind and these move with it, from shell.json. Either list may hold
  // several syms — any one counts, which is how Super_L/Super_R and the shifted
  // "M" are covered. An empty chordMods means the key stands alone.
  readonly property var chordKey: (root.settings.chordKey && root.settings.chordKey.length > 0)
    ? root.settings.chordKey : ["m", "M"]
  readonly property var chordMods: root.settings.chordMods !== undefined
    ? root.settings.chordMods : ["Super_L", "Super_R"]

  // "(is_key_down(a) or is_key_down(b)) and (is_key_down(c) or ...)"
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

  readonly property var keymapNames: (root.settings.keymaps && root.settings.keymaps.length > 0)
    ? root.settings.keymaps : ["left", "right", "arrows", "mash"]

  property string keymap: "arrows"
  readonly property string statePath: Quickshell.statePath("mousekeys.json")

  function loadState(text) {
    try {
      var s = JSON.parse(text)
      if (s && root.keymapNames.indexOf(String(s.keymap)) !== -1) root.keymap = String(s.keymap)
    } catch (e) {}
  }

  function saveState() {
    stateFile.setText(JSON.stringify({ keymap: root.keymap }, null, 2) + "\n")
  }

  function cycleKeymap() {
    var i = root.keymapNames.indexOf(root.keymap)
    root.keymap = root.keymapNames[(i + 1) % root.keymapNames.length]
    if (root.opened) root.hypr('hl.dsp.submap("mousekeys-' + root.keymap + '")')
    root.saveState()
    root.log("keymap -> " + root.keymap)
    hintTimer.restart()
  }


  // Set while a skitter is crossing into another window: which window we asked
  // for, which way we were going, and the cross-axis position to preserve.
  property string crossTarget: ""
  property bool crossHoriz: true
  property int crossSign: 1
  property real crossOff: 0                   // where in the window to sit, along travel
  property real crossCross: 0                 // screen coordinate to hold on the other axis

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
  property real lastActionAt: 0               // for telling a repeat from a fresh press
  property string lastAction: ""
  // Speed model: v = k*holdH, where holdH is how long the current contiguous
  // hold has run, growing while a key is down and receding when none is. With
  // k = 2*W/T^2 a hold of T seconds integrates to exactly one screen width, and
  // a hold of t seconds reaches t/T of top speed — so tapping at a given
  // duration gives that fraction of a sweep's speed.
  property real holdH: 0                      // seconds of accumulated hold
  property bool holdConfirmed: false          // a repeat proved this is a real hold
  property real holdPressAt: 0                // when the current press began
  property real downUntil: 0                  // held as long as now() < this
  property real lastDownAt: 0                 // last move-key event: press or repeat
  property string keysDown: ""                // diagnostic: last answer from keysProbe
  // Always reassigned, never mutated in place: an in-place push on a `var`
  // property does not reliably survive, which quietly left the subvector list
  // empty while the presses themselves were arriving perfectly well.
  property string mashStrategy: "cpa"         // which one drives the pointer
  property var mashDebugStrategies: ["cpa", "lsq", "pca", "ewma"]
  property var dbgStrats: ({})                // name -> {x, y, t}, newest result each
  property var dbgLog: []                     // {g, dt, grid} newest first, for the log
  property real dbgLogAt: 0                   // previous logged event, for the delta
  property var mashTrail: []                  // the last mashSamples of the cluster
  property int clusterN: 0                    // presses in the cluster, uncapped
  property var mashSubs: []                   // recent subvectors: {x, y, t}
  property real ballVX: 0
  property real ballVY: 0
  property bool wheelHeld: false
  property bool ballHeld: false               // a grid key is still down: no free spin
  property real scrollAcc: 0
  property real mashLastAt: 0
  property bool mashDebug: true               // the grid overlay; backtick toggles it
  property var mashLabels: ({})                // action -> key name, from bindings.lua
  property var dbgHits: []                    // {name, t} of recent presses
  property var dbgVecs: []                    // {x, y, t, ok} subvectors, red when !ok
  property real dbgDriveX: 0
  property real dbgDriveY: 0
  property real dbgDriveAt: 0
  property real dbgLastAt: 0                  // newest of the above, for the fade clock
  property int mashCount: 0                   // diagnostic: presses mashPress() saw
  property string mashLog: ""                 // diagnostic: recent grid actions
  // Diagnostics for the carry decision: the gap the last fresh move press saw,
  // and whether it kept the speed. Reported by probe(); nothing depends on them.
  property real carryGap: -1
  property bool carried: false
  property real lastTickAt: 0                 // for integrating against real elapsed time
  property real prevGap: Infinity              // gap before the previous event, for fast-tap
  property string lastHoldAction: ""           // for chaining a press to its own first repeat
  property string activeKind: ""               // "move" | "scroll"
  property var moveDir: [0, 0]
  property var edgesX: []                     // vertical edges: { c, lo, hi }, screen-local
  property var edgesY: []                     // horizontal edges, likewise
  property int scrollSign: 0
  property real sentX: -1                     // last position actually dispatched
  property real sentY: -1

  function log(msg) { if (root.debug) console.warn("[mousekeys] " + msg) }

  function arming() { return root.opened && !root.active }

  // Diagnostic: omarchy-shell shell call <id> probe ""
  function probe() {
    return "opened=" + root.opened + " active=" + root.active + " sticky=" + root.sticky
      + " keymap=" + root.keymap + " fastTap=" + root.fastTapMs + " carry=" + root.carryMs
      + " cur=" + Math.round(root.curX) + "," + Math.round(root.curY)
      + " focus=" + root.focusedAddress()
      + " idle=" + idleTimer.running + " long=" + longPressTimer.running
      + " moving=" + motionTimer.running + " held=" + root.holdConfirmed
      + " edges=" + root.edgesX.length + "/" + root.edgesY.length
      + " autoscroll=" + autoScroll.running
      + " holdH=" + root.holdH.toFixed(2) + " v=" + root.speedFor(root.holdH).toFixed(0)
      + " carryGap=" + Math.round(root.carryGap) + " carried=" + root.carried
      + " keysDown=" + (root.keysDown === "" ? "none" : root.keysDown.replace(/ /g, ","))
      + " ball=" + root.ballVX.toFixed(0) + "," + root.ballVY.toFixed(0)
      + " subs=" + root.mashSubs.length + " wheel=" + root.wheelHeld
      + " gain=" + root.mashGain.toFixed(2) + " vmax=" + root.mashVMax
      + " samples=" + root.mashSamples
      + " sramp=" + root.scrollRepeatScaleMin + "-" + root.scrollRepeatScaleMax
      + "/" + root.scrollIncreaseDelay + "s+" + root.scrollIncreaseTime + "s"
      + " sreps=" + root.scrollReps + "/" + root.scrollDets
      + " sscale=" + (root.scrollHoldName === "" ? "-"
          : root.scrollScaleAt(Date.now() - root.scrollHoldAt).toFixed(2))
      + " fine=" + root.fineHeld + " dirs=" + Object.keys(root.mashDirs).length
      + " nudge=" + root.mashNudge + "/" + root.nudgeInnerPx + "-" + root.nudgeOuterPx
      + " rings=" + root.nudgeInnerNames.length + "/" + root.nudgeOuterNames.length
      + " nudged=" + (root.nudgeName === "" ? "-" : root.nudgeName)
      + " rep=" + root.nudgeRepeat + "/" + root.nudgeDelayMs + "/" + root.nudgeRateMs
      + (nudgePoll.running ? "*" : "")
      + " gripOn=" + root.mashGrip + "/" + root.mashGripFriction.toFixed(0)
      + " grip=" + root.ballHeld
      + " cluster=" + root.clusterN + " win=" + root.mashTrail.length
      + " strategy=" + root.mashStrategy
      + " shown=[" + root.mashDebugStrategies.join(",") + "]"
      + " dbg=" + root.mashDebug + " labels=" + Object.keys(root.mashLabels).length
      + " dbgVecs=" + (function () {
          var ok = 0
          for (var i = 0; i < root.dbgVecs.length; i++) if (root.dbgVecs[i].ok) ok++
          return ok + "ok/" + (root.dbgVecs.length - ok) + "dead"
        })() + " dbgHits=" + root.dbgHits.length
      + " mashN=" + root.mashCount + " trailN=" + root.mashTrail.length
      + " mashLog=[" + root.mashLog.trim() + "]"
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
    root.lastAction = ""
    root.lastHoldAction = ""
    root.lastDownAt = 0
    root.keysDown = ""
    root.wheelHeld = false
    root.ballHeld = false
    holdPoll.stop()
    keysPoll.stop()
    wheelPoll.stop()
    root.mashStop()
    root.dbgHits = []; root.dbgVecs = []; root.dbgDriveAt = 0; root.dbgStrats = ({})
    root.dbgLog = []; root.dbgLogAt = 0
    dbgTimer.stop()
    root.prevGap = Infinity
    root.lastActionAt = 0
    root.holdH = 0
    root.holdConfirmed = false
    root.activeKind = ""
    root.sentX = -1
    root.sentY = -1
    root.sticky = false
    root.active = false
    root.cursorKnown = false
    root.curX = scr.width / 2
    root.curY = scr.height / 2
    cursorProc.running = true
    luaConf.running = true
    root.refreshState()
    root.collectEdges()

    // Empty submap so Omarchy's own bindings can't eat movement keys, and so
    // the wheel events we synthesize don't reach SUPER+scroll bindings.
    // The submap is the input mechanism now, not just a shield: every movement,
    // button and scroll key is bound inside it.
    root.hypr('hl.dsp.submap("mousekeys-' + root.keymap + '")')
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
    root.stopScroll()
    resyncTimer.stop()
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

  function scrollX(detents) {
    if (detents === 0) return
    Quickshell.execDetached(["ydotool", "mousemove", "-w", "-x", String(detents), "-y", "0"])
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

  // ---- movement -------------------------------------------------------------
  // ---- window edges ---------------------------------------------------------
  // Read from Quickshell's Hyprland toplevels, whose lastIpcObject carries at/
  // size — in process, so this costs no subprocess and can be refreshed on every
  // keypress. Only windows on the focused monitor's active workspace count, and
  // each edge remembers the span it covers on the other axis: an edge you are
  // not level with is not one you could collide with.
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
      // Edges are stored as the *last pixel inside* the window, not the exclusive
      // bound: a window at x=12 w=734 covers 12..745, so its right edge is 745 and
      // not 746. Landing on 746 puts the pointer one pixel past the window, over
      // whatever is behind it — so a double-tap down inside a floating window used
      // to come to rest just below it and focus the window underneath instead of
      // staying put. Keeping every edge inside its own window also means a landing
      // is always over the window whose edge it is, which is what makes focus
      // follow correctly with no special cases.
      //
      // Doing it here rather than when landing is why nextEdge() needs no
      // adjustment: the stored coordinate is already the reachable one, so
      // "strictly ahead" keeps making progress on its own.
      //
      // Windows routinely extend past the screen, and an edge you cannot reach
      // is not a snap target: warp() would clamp it back and the press would do
      // nothing — worse, it would hide the fact that we have run out of edges.
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
  // maxDist <= 0 means unbounded, which is what a fast re-tap uses.
  function nextEdge(list, from, cross, sign, maxDist) {
    var bestC = NaN, bestD = Infinity
    for (var i = 0; i < list.length; i++) {
      var e = list[i]
      if (cross < e.lo || cross > e.hi) continue
      var d = (e.c - from) * sign
      if (d <= root.edgeEpsilon) continue      // strictly ahead, so we always progress
      if (maxDist > 0 && d > maxDist) continue
      if (d < bestD) { bestD = d; bestC = e.c }
    }
    return bestC
  }

  // Enter a sweep in `dir` carrying speed `h`, without waiting for the new key's
  // first repeat. Used when a new direction is pressed mid-sweep, which must
  // take over without the motion stopping and without losing the acceleration
  // already built up. The key that will sustain the sweep does not repeat for
  // input:repeat_delay (250ms), so downUntil has to bridge that gap or motion
  // lapses after repeatGapMs.
  function startSweep(name, now, h) {
    root.activeKind = "move"
    root.lastHoldAction = name
    root.holdH = Math.min(root.sweepMs / 1000, h)
    root.holdPressAt = now - root.holdH * 1000   // keep holdH ~ elapsed invariant
    root.holdConfirmed = true
    root.downUntil = now + root.takeoverGraceMs
    root.lastTickAt = now
    motionTimer.start()
  }

  // Move `px` along `dir`, but land on a window edge if one lies in the way.
  // Bounded, only edges within the travel distance count, so movement is
  // magnetic without being teleportive. Unbounded, the cursor lands on the next
  // edge however far off it is — that is the skitter.
  // A diagonal is two axes at once, so it snaps on each independently: a press
  // lands on the nearest edge to the left *and* the nearest above, and a
  // double-tap runs both to their limits, which is the corner. The axis-at-a-time
  // path below cannot express that — it picks one axis and ignores the other.
  function moveStepDiag(dir, px, unbounded) {
    var sx = dir[0] > 0 ? 1 : -1, sy = dir[1] > 0 ? 1 : -1
    var reach = unbounded ? 0 : px
    var ex = root.nextEdge(root.edgesX, root.curX, root.curY, sx, reach)
    var ey = root.nextEdge(root.edgesY, root.curY, root.curX, sy, reach)
    var nx = isNaN(ex) ? (unbounded ? root.curX : root.curX + dir[0] * px) : ex
    var ny = isNaN(ey) ? (unbounded ? root.curY : root.curY + dir[1] * px) : ey
    root.warp(nx, ny)
    // No crossBeyond here: leaving by a corner has no single direction to hand to
    // the compositor, so a diagonal stops at the corner.
    if (unbounded) root.focusLanding(true, sx)
  }

  // In wheel mode the whole mode scrolls: a sweep's travel becomes detents rather
  // than pointer movement, on whichever axis it mostly runs along.
  function scrollTravel(dir, px) {
    var horiz = Math.abs(dir[0]) > Math.abs(dir[1])
    root.scrollAcc += (horiz ? dir[0] : dir[1]) * px
    var det = (root.scrollAcc / root.mashScrollPx) | 0
    if (det === 0) return
    root.scrollAcc -= det * root.mashScrollPx
    if (horiz) root.scrollX(det)
    else root.scroll(-det)              // screen-down is wheel-down
  }

  // A discrete press is worth a detent outright: accumulating 8px against a
  // detent's 90 would take a dozen presses to move the page once.
  function scrollPress(dir, unbounded) {
    var horiz = Math.abs(dir[0]) > Math.abs(dir[1])
    var sign = horiz ? (dir[0] > 0 ? 1 : -1) : (dir[1] > 0 ? 1 : -1)
    var n = unbounded ? root.scrollEndDetents : 1
    if (horiz) root.scrollX(sign * n)
    else root.scroll(-sign * n)
  }

  // 1x while the hold is young, then a straight ramp to the maximum, then flat.
  function scrollScaleAt(ms) {
    var lo = root.scrollRepeatScaleMin, hi = root.scrollRepeatScaleMax
    var delay = root.scrollIncreaseDelay * 1000, span = root.scrollIncreaseTime * 1000
    if (ms <= delay) return lo
    if (span <= 0) return hi
    var t = (ms - delay) / span
    return t >= 1 ? hi : lo + (hi - lo) * t
  }

  // Each repeat is worth scaleAt() detents. The scale is fractional, so what does
  // not reach a whole detent is carried rather than dropped — otherwise anything
  // under 1x would scroll not at all, and the ramp would move in visible steps.
  function scrollRepeat(name, dir, now) {
    if (name !== root.scrollHoldName) {        // a different key restarts the ramp
      root.scrollHoldName = name
      root.scrollHoldAt = now
      root.scrollFrac = 0
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
      // A double-tap that hops onto the screen's own edge means "keep going",
      // so try to cross out of it; anywhere else, just adopt whatever window we
      // landed in. The warp happens either way, so running out of places to go
      // leaves the cursor resting on the edge rather than doing nothing.
      var far = horiz ? root.screenW - 1 : root.screenH - 1
      if (unbounded) {
        if (e <= 0 || e >= far) { if (!root.crossBeyond(horiz, sign)) root.focusLanding(horiz, sign) }
        else root.focusLanding(horiz, sign)
      }
      return
    }
    if (unbounded) {
      // Nowhere left to snap: the double-tap ran into the screen edge, so take
      // it as "keep going" and try to cross out of the screen entirely.
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
    // Sub-pixel steps accumulate in curX/curY; only tell Hyprland when the
    // rounded position actually changes, so a slow crawl is not a dispatch storm.
    if (ix === root.sentX && iy === root.sentY) return
    root.sentX = ix
    root.sentY = iy
    root.hypr("hl.dsp.cursor.move({ x = " + ix + ", y = " + iy + " })")
  }

  // ---- crossing into another window -----------------------------------------
  // Focus is always by address, never by direction. hl.dsp.focus({ direction })
  // asks the *layout* what comes next, which on a single monitor is simply
  // another tiled window, and Hyprland then drags the pointer into it
  // (cursor:no_warps = false) — the cursor jumps somewhere you never aimed at.
  // Addressing the window the cursor actually reached keeps focus and pointer in
  // agreement, and works the same under dwindle, scrolling, master or anything
  // else, because it names a window instead of asking about layout order.

  // Toplevel geometry AND the workspace they are filtered against both have to be
  // current. Refreshing only the toplevels leaves focusedWorkspace stale, and a
  // stale workspace means windowsHere() hands back windows from somewhere else —
  // which focusWindow() would then follow, dragging the user to another
  // workspace. Measured: switching workspace outside the shell left the cache
  // pointing at the old one, and a skitter focused a window there.
  function refreshState() {
    Hyprland.refreshWorkspaces()
    Hyprland.refreshMonitors()
    Hyprland.refreshToplevels()
  }

  function workspaceName() {
    return Hyprland.focusedWorkspace ? String(Hyprland.focusedWorkspace.name) : ""
  }

  // Every mapped window on this screen's workspace, in screen-relative coords.
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
                 // 0 is the focused window, 1 the one before it, and so on.
                 age: typeof o.focusHistoryID === "number" ? o.focusHistoryID : 1e9 })
    }
    return out
  }

  function focusedAddress() {
    var t = Hyprland.activeToplevel
    var o = t ? t.lastIpcObject : null
    return o && o.address ? String(o.address) : ""
  }

  // windowsHere() already filters by workspace, but that filter and this check
  // both hang off cached state, so re-read the window's own workspace before
  // committing: moving the pointer must never move the user off their workspace.
  function focusWindow(address) {
    var ws = root.workspaceName()
    var list = Hyprland.toplevels ? Hyprland.toplevels.values : []
    for (var i = 0; i < list.length; i++) {
      var o = list[i].lastIpcObject
      if (!o || String(o.address) !== address) continue
      if (!o.workspace || String(o.workspace.name) !== ws) {
        root.log("refusing cross-workspace focus " + address)
        return false
      }
      root.hypr('hl.dsp.focus({ window = "address:' + address + '" })')
      return true
    }
    return false
  }

  // A skitter that lands inside a window nobody is focused on: adopt it. The
  // pointer is already inside, and Hyprland only warps when focusing a window
  // the pointer is *outside* of, so this costs no cursor movement at all.
  // Windows overlap, so pick the one actually on top at a point rather than
  // whichever the compositor listed last — that order is not z-order (a window
  // focused three ago was listed ahead of the one focused last). Floating sits
  // above tiled in Hyprland, and among equals the more recently focused one is
  // the one you can see.
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
  // is where a click will land. So the cursor's own position is asked first.
  //
  // Only when it sits over nothing — a gap, or a window's far edge, which is at
  // x + w and therefore one past the last pixel — does the window being *entered*
  // decide it, probed one pixel along the direction of travel. That case is why
  // snapping leftwards onto a window's right edge used to leave it unfocused
  // while the mirror going right worked, a left edge being a window's first pixel.
  //
  // Probing the nudge first is wrong, and was: landing on a short floating
  // window's top edge is already *inside* it, so nudging up escaped to the tiled
  // window behind and focused something the pointer was not over.
  function focusLanding(horiz, sign) {
    var best = root.topmostAt(root.curX, root.curY)
    if (!best) best = root.topmostAt(root.curX + (horiz ? sign : 0),
                                     root.curY + (horiz ? 0 : sign))
    if (best) {
      var t = best
      if (t.address === root.focusedAddress()) return   // already ours, nothing moves
      // Focusing can pan the workspace under a stationary pointer, so remember
      // where in this window we are and restore that afterwards. Under a layout
      // that does not pan, the offset resolves to where we already stand.
      if (!root.focusWindow(t.address)) return
      root.crossTarget = t.address
      root.crossHoriz = horiz
      root.crossSign = sign
      root.crossOff = horiz ? root.curX - t.x : root.curY - t.y
      root.crossCross = horiz ? root.curY : root.curX
      root.log("focus landing " + t.address)
      resyncTimer.restart()
    }
  }

  // Out of edges on this screen: the skitter wants to keep going, so look for a
  // window with content past the boundary that way — exactly the windows
  // collectEdges() refuses as snap targets because they are unreachable. One
  // rule covers every layout: a scrolling workspace pans the row to reveal it, a
  // second monitor brings its window in, and under dwindle nothing reaches past
  // the screen so the cursor just rests at the edge. Returns whether it acted.
  function crossBeyond(horiz, sign) {
    var far = (horiz ? root.screenW : root.screenH) - 1
    var cross = horiz ? root.curY : root.curX
    var focused = root.focusedAddress()
    var best = null, bestNear = 0
    var list = root.windowsHere()
    for (var i = 0; i < list.length; i++) {
      var t = list[i]
      // Already focused and still overhanging means the layout has fitted it as
      // far as it intends to; re-focusing would not move anything.
      if (t.address === focused) continue
      var lo = horiz ? t.y : t.x
      var hi = lo + (horiz ? t.h : t.w) - 1
      if (cross < lo || cross > hi) continue
      var near = horiz ? t.x : t.y
      // Last pixel again, so a window ending exactly on the screen edge is not
      // mistaken for one with a further pixel to reveal.
      var end = near + (horiz ? t.w : t.h) - 1
      // Does it reach past the boundary we are pinned against?
      var over = sign > 0 ? end - far : 0 - near
      if (over <= root.edgeEpsilon) continue
      // Nearest first along the direction of travel, so a row is crossed one
      // window at a time rather than jumping to the far end.
      if (!best || (sign > 0 ? near < bestNear : near > bestNear)) {
        best = t; bestNear = near
      }
    }
    if (!best) { root.log("nothing beyond " + (sign > 0 ? "+" : "-")); return false }
    if (!root.focusWindow(best.address)) return false
    root.crossTarget = best.address
    root.crossHoriz = horiz
    root.crossSign = sign
    // Entering edge: crossing rightwards puts us on the window's left side.
    root.crossOff = sign > 0 ? 0 : (horiz ? best.w : best.h) - 1
    root.crossCross = cross
    root.log("cross into " + best.address)
    // The focus settles in ~23ms but every window on a scrolling workspace moves
    // with it, so wait for the warp, refresh, then land — see resyncTimer.
    resyncTimer.restart()
    return true
  }

  // Two ways the pointer ends up wrong after a focus change, both fixed here.
  // Hyprland drops the pointer on the *centre* of a window it focuses (measured
  // 367px from the edge we left through, with the cross-axis position thrown
  // away), which breaks a sweep in half. Put it where the movement was heading:
  // the edge we entered through, at the height we left at. curX/curY never adopt
  // the centre, and the visible pointer is our own marker
  // (cursor:hide_on_key_press hides the real one), so that excursion is never
  // drawn — the marker goes from the old edge straight to the new one.
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
      root.log("landed at " + Math.round(travel) + "," + Math.round(cross))
      // Landing is correct relative to the window we crossed into, but the pan
      // that brought it here slid that window *under* anything floating, which
      // does not pan with the row. So what the pointer now sits over may not be
      // what is focused — re-resolve at the final position. This settles in one
      // more pass: the second call finds the window it just focused and stops.
      root.focusLanding(horiz, root.crossSign)
      return
    }
    // It went away mid-flight; fall back to believing the compositor.
    root.cursorKnown = false
    cursorProc.running = true
  }

  // ---- mash: a trackball driven by mashing a key grid ------------------------
  // Each key is a point in space, so the order they are struck traces a path. The
  // direction of that path drives a rolling ball; the rate you strike them sets
  // how hard it is pushed.

  function mashPos(name) {
    var m = /^m(\d+)_(\d+)$/.exec(name)
    if (!m) return null
    // Quartered, so a column step and a row step are the same distance and the
    // row stagger comes out at its true fraction of a key rather than the nearest
    // half.
    return ({ x: parseInt(m[1], 10) / 4, y: parseInt(m[2], 10) })
  }

  // Direction through the last three presses, chosen so the two projected
  // velocities are as equal — and as large — as possible. Maximising their
  // product does both at once: for a given sum a product peaks when the terms are
  // equal, and any direction with no motion along it scores zero. Minimising
  // their difference alone would not do: a mash straight right that speeds up
  // projects to 10 and 20 along x, but to 0 and 0 along y, so "most uniform"
  // would always pick the perpendicular and the ball would never move.
  //
  // maximise (a.u)(b.u) = u' M u for M = (ab' + ba')/2, so u is M's principal
  // eigenvector — in 2D that is one atan2, no iteration.
  // Always returns something: a fit that contributes nothing comes back with
  // ok = false rather than as null, so the debug display can show it in red
  // instead of it vanishing silently. Only ok fits steer the ball.
  function mashSubvector(p1, p2, p3) {
    var dt1 = (p2.t - p1.t) / 1000, dt2 = (p3.t - p2.t) / 1000
    // A rejected fit still wants a direction to draw; the span of the triple is
    // the only one left when the timing itself is what went wrong.
    var sx = p3.x - p1.x, sy = p3.y - p1.y
    var sm = Math.sqrt(sx * sx + sy * sy)
    // ox/oy: where the triple started, so the debug view can draw the subvector
    // from the key it was measured from rather than from a shared origin.
    var dead = ({ x: sm > 0 ? sx / sm : 0, y: sm > 0 ? sy / sm : 0,
                  ox: p1.x, oy: p1.y, t: p3.t, ok: false })
    if (!(dt1 > 0) || !(dt2 > 0)) return dead          // struck together, no velocity
    var ax = (p2.x - p1.x) / dt1, ay = (p2.y - p1.y) / dt1
    var bx = (p3.x - p2.x) / dt2, by = (p3.y - p2.y) / dt2
    var m11 = ax * bx, m22 = ay * by, m12 = (ax * by + ay * bx) / 2
    var th = 0.5 * Math.atan2(2 * m12, m11 - m22)
    var ux = Math.cos(th), uy = Math.sin(th)
    if ((ax + bx) * ux + (ay + by) * uy < 0) { ux = -ux; uy = -uy }   // orient it
    // Speed along that axis: the average of the velocities between successive
    // closest points of approach, which is what projecting onto u gives.
    var v = ((ax * ux + ay * uy) + (bx * ux + by * uy)) / 2
    if (!(v > root.mashMinSpeed)) { dead.x = ux; dead.y = uy; return dead }   // reversal or restrike
    return ({ x: ux * v, y: uy * v, ox: p1.x, oy: p1.y, t: p3.t, ok: true })
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

  // Dark grey at the start of the cluster, bright green at the end.
  readonly property var dbgKeyIdle: [38, 38, 38]     // never struck this cluster
  readonly property var dbgKeyCold: [52, 52, 52]     // struck first
  readonly property var dbgKeyHot: [40, 235, 95]     // struck most recently
  readonly property var dbgKeyNudge: [225, 55, 55]   // a lone tap: a nudge

  // Colour and dash come from the strategy's name, so a strategy looks the same
  // every run and two of them never collide by accident.
  function dbgHash(str) {
    var h = 2166136261
    for (var i = 0; i < str.length; i++) {
      h ^= str.charCodeAt(i)
      h = (h * 16777619) >>> 0
    }
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

  readonly property var dbgDashes: [[], [7, 4], [2, 4], [12, 4, 3, 4], [1, 5], [6, 3, 1, 3]]

  // Hue and dash come from the strategy's place in mashStrategies, not from a
  // hash of its name: hashing gave no guarantee two of them would not land on
  // near-identical hues, which is the one thing this must not do. An index gives
  // each an evenly spaced slot, and a name-derived jitter inside its own slot
  // keeps the palette from looking like a plain rainbow without ever letting two
  // slots touch. A strategy therefore keeps its colour whichever subset is drawn.
  function dbgStratHue(name) {
    var n = root.mashStrategies.length
    var i = root.mashStrategies.indexOf(name)
    if (i < 0) return 0
    var slot = 360 / n
    return (i * slot + (root.dbgHash(name) % Math.floor(slot / 2))) / 360
  }

  function dbgStratColor(name, a) {
    // Saturation and lightness stay pinned high so every strategy reads as bright.
    var c = root.dbgHsl(root.dbgStratHue(name), 0.95, 0.62)
    return root.dbgRgba(c[0], c[1], c[2], a)
  }

  function dbgStratDash(name) {
    var i = root.mashStrategies.indexOf(name)
    return root.dbgDashes[(i < 0 ? 0 : i) % root.dbgDashes.length]
  }

  // The log is not the fade: entries stay until pushed out by newer ones, which is
  // the point of having it. Deltas are between consecutive logged events, so a
  // stray key shows up as a row of its own rather than silently widening a gap.
  function dbgLogEvent(glyph, now, grid) {
    var dt = root.dbgLogAt > 0 ? Math.round(now - root.dbgLogAt) : -1
    root.dbgLogAt = now
    root.dbgLog = [{ g: glyph, dt: dt, grid: grid, imp: 0 }].concat(root.dbgLog)
                    .slice(0, root.dbgLogMax)
    if (root.mashDebug) dbgTimer.start()
  }

  // The impulse is only known once the strategy has run, which is after the press
  // is logged, so it is filled in afterwards rather than passed in. A row that
  // keeps its zero is a press that drove nothing: too early in the cluster for the
  // strategy to fit, or a fit that came back degenerate.
  function dbgLogImpulse(v) {
    if (root.dbgLog.length === 0) return
    var out = root.dbgLog.slice()
    out[0] = { g: out[0].g, dt: out[0].dt, grid: out[0].grid, imp: v }
    root.dbgLog = out
  }

  function dbgGlyph(k) {
    if (!k) return ""
    if (root.dbgGlyphs[k]) return root.dbgGlyphs[k]
    return k.length === 1 ? k : k.charAt(0)
  }

  // ---- strategies -----------------------------------------------------------
  // Each turns the recent presses into one velocity in key-widths per second, and
  // they are interchangeable: bindings.lua picks which one steers the pointer, and
  // any of them can be drawn in the debug view alongside it for comparison.

  // The trail is already capped at mashSamples and cleared between clusters, so
  // this is the last few presses of the gesture in progress and nothing from
  // before the pause that ended the previous one.
  function mashWindow() { return root.mashTrail }

  // cpa — magnitude-weighted mean of the fitted subvectors. Longer hops count for
  // more and a mash that reverses cancels itself out. Alone among these it cannot
  // start before the third press: a subvector compares the two velocities within a
  // triple, and two presses give only one.
  function mashCpa(now) {
    var sx = 0, sy = 0, n = 0
    for (var i = 0; i < root.mashSubs.length; i++) {
      var sv = root.mashSubs[i]
      sx += sv.x; sy += sv.y; n++
    }
    return n === 0 ? null : ({ x: sx / n, y: sy / n })
  }

  // lsq — least squares of position against time. The slope *is* a velocity, so
  // direction and speed come out together, and one stray key barely moves it.
  // The steadiest of these without being blind to the middle of the gesture.
  function mashLsq(now) {
    var w = root.mashWindow()
    // Two points are enough: the least-squares line through them is simply the
    // line joining them. Demanding three left the first two presses of every
    // cluster driving nothing at all.
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

  // net — where the hand got to, over how long it took. Blind to the path in
  // between, which makes it the calmest and the slowest to notice a turn.
  function mashNet(now) {
    var w = root.mashWindow()
    if (w.length < 2) return null
    var a = w[0], b = w[w.length - 1]
    var dt = (b.t - a.t) / 1000
    if (!(dt > 0)) return null
    return ({ x: (b.x - a.x) / dt, y: (b.y - a.y) / dt })
  }

  // pca — dominant axis of the positions, with speed from the distance travelled
  // *along* it. Alone among these it survives mashing back and forth on one line:
  // the others average that to nothing, this reads it as motion on that axis.
  function mashPca(now) {
    var w = root.mashWindow()
    // Two points are enough here too: the dominant axis of a pair is the line
    // joining them, which is exactly the answer wanted.
    if (w.length < 2) return null
    var xb = 0, yb = 0, i
    for (i = 0; i < w.length; i++) { xb += w[i].x; yb += w[i].y }
    xb /= w.length; yb /= w.length
    var cxx = 0, cyy = 0, cxy = 0
    for (i = 0; i < w.length; i++) {
      var dx = w[i].x - xb, dy = w[i].y - yb
      cxx += dx * dx; cyy += dy * dy; cxy += dx * dy
    }
    if (!(cxx + cyy > 0)) return null
    var th = 0.5 * Math.atan2(2 * cxy, cxx - cyy)
    var ux = Math.cos(th), uy = Math.sin(th)
    var first = w[0], last = w[w.length - 1]
    if ((last.x - first.x) * ux + (last.y - first.y) * uy < 0) { ux = -ux; uy = -uy }
    var span = 0
    for (i = 1; i < w.length; i++)
      span += Math.abs((w[i].x - w[i - 1].x) * ux + (w[i].y - w[i - 1].y) * uy)
    var tot = (last.t - first.t) / 1000
    if (!(tot > 0)) return null
    return ({ x: ux * span / tot, y: uy * span / tot })
  }

  // ewma — every hop's own velocity, weighted so the newest dominate. No hard
  // window edge, so it turns fastest, at the cost of being the twitchiest.
  function mashEwma(now) {
    var w = root.mashWindow()
    if (w.length < 2) return null
    var sx = 0, sy = 0, sw = 0
    for (var i = 1; i < w.length; i++) {
      var dt = (w[i].t - w[i - 1].t) / 1000
      if (!(dt > 0)) continue
      var wt = Math.exp(-(now - w[i].t) / root.mashEwmaTauMs)
      sx += wt * (w[i].x - w[i - 1].x) / dt
      sy += wt * (w[i].y - w[i - 1].y) / dt
      sw += wt
    }
    return sw > 0 ? ({ x: sx / sw, y: sy / sw }) : null
  }

  // Cycles within the strategies the debug view is drawing, so the one being
  // switched to is always visible to compare against — and always the one the
  // legend highlights. The config stays the source of truth: this is a live
  // experiment, and the next session takes its strategy from bindings.lua again.
  function cycleStrategy() {
    var list = root.mashDebugStrategies.length > 0 ? root.mashDebugStrategies
                                                   : root.mashStrategies
    if (list.length === 0) return
    var i = list.indexOf(root.mashStrategy)          // -1 lands on the first
    root.mashStrategy = list[(i + 1) % list.length]
    root.pokeIdle()
    root.log("strategy -> " + root.mashStrategy)
    if (root.mashDebug) dbgTimer.start()
  }

  function mashCompute(name, now) {
    if (name === "cpa") return root.mashCpa(now)
    if (name === "lsq") return root.mashLsq(now)
    if (name === "net") return root.mashNet(now)
    if (name === "pca") return root.mashPca(now)
    if (name === "ewma") return root.mashEwma(now)
    return null
  }

  // The rings are named in bindings.lua, which owns the layout; their geometry is
  // worked out from the coordinates here. The centre is the middle of the inner
  // ring, and the two mean radii bracket the keys that sit between the rings.
  function nudgeGeom() {
    var inn = root.nudgeInnerNames, out = root.nudgeOuterNames
    var cx = 0, cy = 0, n = 0, i, q
    for (i = 0; i < inn.length; i++) {
      q = root.mashPos(inn[i])
      if (q) { cx += q.x; cy += q.y; n++ }
    }
    if (n === 0) return null
    cx /= n; cy /= n
    function meanR(names) {
      var sum = 0, m = 0
      for (var j = 0; j < names.length; j++) {
        var r = root.mashPos(names[j])
        if (!r) continue
        sum += Math.sqrt((r.x - cx) * (r.x - cx) + (r.y - cy) * (r.y - cy)); m++
      }
      return m > 0 ? sum / m : 0
    }
    return ({ cx: cx, cy: cy, ri: meanR(inn), ro: meanR(out) })
  }

  // A key *on* a ring pushes that ring's distance exactly; only keys between the
  // rings interpolate. Going by radius alone would shortchange them — the outer
  // ring is not a circle, and its top and bottom middles sit well inside the mean,
  // so 9 would push 3.2px where - pushes 5.
  function nudgePixels(name, g, d) {
    if (root.nudgeInnerNames.indexOf(name) >= 0) return root.nudgeInnerPx
    if (root.nudgeOuterNames.indexOf(name) >= 0) return root.nudgeOuterPx
    var t = g.ro > g.ri ? (d - g.ri) / (g.ro - g.ri) : 0
    t = t < 0 ? 0 : (t > 1 ? 1 : t)
    return root.nudgeInnerPx + (root.nudgeOuterPx - root.nudgeInnerPx) * t
  }

  function mashNudgeDo(name, now) {
    if (!root.mashNudge) return
    var g = root.nudgeGeom(), q = root.mashPos(name)
    if (!g || !q) return
    var dx = q.x - g.cx, dy = q.y - g.cy
    var d = Math.sqrt(dx * dx + dy * dy)
    if (!(d > 0)) return                       // dead centre: no direction to push
    var px = root.nudgePixels(name, g, d)
    root.nudgeName = name
    root.pokeIdle()
    root.warp(root.curX + (dx / d) * px, root.curY + (dy / d) * px)
    if (root.mashDebug) dbgTimer.start()
    if (root.nudgeRepeat) {
      nudgePoll.interval = root.nudgeDelayMs   // the first one waits, as a key does
      nudgePoll.restart()
    }
  }

  // Repeat the push the current nudge key stands for, without disturbing the
  // cluster: a repeat is the same key still down, not a new press.
  function nudgeAgain() {
    var g = root.nudgeGeom(), q = root.mashPos(root.nudgeName)
    if (!g || !q) { nudgePoll.stop(); return }
    var dx = q.x - g.cx, dy = q.y - g.cy
    var d = Math.sqrt(dx * dx + dy * dy)
    if (!(d > 0)) { nudgePoll.stop(); return }
    var px = root.nudgePixels(root.nudgeName, g, d)
    root.pokeIdle()
    root.warp(root.curX + (dx / d) * px, root.curY + (dy / d) * px)
  }

  function mashPress(name, now) {
    var pos = root.mashPos(name)
    if (!pos) return
    root.pokeIdle()
    // A gap ends the gesture. Everything the old cluster left behind goes with it,
    // including what the overlay is drawing: the graphic shows one cluster at a
    // time, so the new one replaces the old rather than accumulating over it.
    if (now - root.mashLastAt > root.mashClusterMs) {
      root.mashTrail = []; root.mashSubs = []
      root.dbgStrats = ({}); root.dbgHits = []; root.dbgVecs = []
      root.dbgDriveAt = 0; root.dbgDriveX = 0; root.dbgDriveY = 0
      root.nudgeName = ""
      nudgePoll.stop()
      root.clusterN = 0
    }
    root.clusterN += 1

    root.mashCount += 1
    root.mashLog = (root.mashLog + " " + name).slice(-70)
    root.dbgLogEvent(root.dbgGlyph(root.mashLabels[name]), now, true)
    root.mashLastAt = now
    // One trail, long enough for the widest window any strategy asks for; each
    // reads whatever slice of it it wants.
    var hist = root.mashTrail.concat([{ x: pos.x, y: pos.y, t: now }])
    if (hist.length > root.mashSamples) hist = hist.slice(hist.length - root.mashSamples)
    root.mashTrail = hist
    // The overlay shows exactly what the fit is working from: the same last
    // mashSamples events, so a key that has aged out of the window goes back to
    // looking untouched rather than implying it still counts.
    if (root.clusterN > 1) {                       // a sweep, not a nudge
      root.nudgeName = ""
      nudgePoll.stop()
    }
    root.dbgHits = root.dbgHits.concat([{ name: name, t: now }]).slice(-root.mashSamples)
    root.dbgLastAt = now
    if (hist.length >= 3) {
      var sv = root.mashSubvector(hist[hist.length - 3], hist[hist.length - 2],
                                  hist[hist.length - 1])
      root.dbgVecs = root.dbgVecs.concat([sv]).slice(-Math.max(1, root.mashSamples - 2))
      if (sv.ok) {
        // Five events make three overlapping triples, so cpa keeps that many to
        // stay level with the window the others fit over.
        var keep = Math.max(1, root.mashSamples - 2)
        root.mashSubs = root.mashSubs.concat([sv]).slice(-keep)
      }
    }
    // Every strategy on the debug list is computed whether or not it is steering,
    // which is the point: they can be compared against each other live.
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
    if (s > 0) {
      ux = drive.x / s; uy = drive.y / s
    } else {
      // Fewer than three presses, so there is no fitted speed yet — only the hop
      // just made, which gives a direction but no velocity. It steers the
      // single-pixel step below and contributes no impulse: its length is a
      // distance in key widths, and feeding that to a formula expecting key
      // widths per second would throw the ball at an arbitrary speed.
      var n = hist.length
      // The opening press of a cluster: no second point yet, so no direction to
      // fit. This is where a lone press does its own thing — a direction key
      // steers, anything else nudges — immediately, rather than waiting out the
      // cluster to confirm it was alone. A sweep that follows keeps whatever
      // pixels were already spent, which are lost in it.
      if (n < 2) {
        var dn = root.mashDirs[name]
        if (dn) {
          root.moveDir = root.actionDirs[dn]
          root.collectEdges()
          root.beginHold("move", dn, now)       // so holding it sweeps
          root.moveStep(root.moveDir, root.fineHeld ? root.finePx : root.baseStep, false)
        } else {
          root.mashNudgeDo(name, now)
        }
        return
      }
      var dx = hist[n - 1].x - hist[n - 2].x, dy = hist[n - 1].y - hist[n - 2].y
      var m = Math.sqrt(dx * dx + dy * dy)
      if (!(m > 0)) return
      ux = dx / m; uy = dy / m
    }
    // Every press moves at least mashStepPx, the way every press in the other
    // keymaps moves at least baseStep. Slow mashing lives entirely here: at a
    // couple of presses a second the impulse below works out to a tenth of a
    // pixel, which would round away to nothing, so the floor is what makes slow
    // mashing advance the cursor pixel by pixel instead of not at all.
    if (root.wheelHeld) root.scrollAcc += uy * root.mashStepPx
    else root.warp(root.curX + ux * root.mashStepPx, root.curY + uy * root.mashStepPx)
    // Impulse grows steeply with mash rate because the two ends of the scale are
    // far apart: a slow press should nudge a single pixel, a fast burst should
    // throw the cursor across the whole screen.
    if (!(s > 0)) return                    // the step above was the whole move
    var imp = root.mashGain * Math.pow(s, root.mashExp)
    root.dbgLogImpulse(imp)
    root.ballVX += ux * imp
    root.ballVY += uy * imp
    var sp = Math.sqrt(root.ballVX * root.ballVX + root.ballVY * root.ballVY)
    if (sp > root.mashVMax) {
      root.ballVX *= root.mashVMax / sp
      root.ballVY *= root.mashVMax / sp
    }
    if (!ballTimer.running) { root.lastTickAt = now; ballTimer.start() }
    if (root.wheelHeld && !wheelPoll.running) wheelPoll.start()
  }

  // The ball coming to rest is not the end of the gesture: the press history has
  // to outlive it, or a slow mash — whose first impulses stop the ball almost at
  // once — would keep erasing the very presses a subvector is fitted from, and no
  // direction could ever be computed.
  function ballStop() {
    root.ballVX = 0; root.ballVY = 0
    root.scrollAcc = 0
    root.ballHeld = false
    holdPoll.stop()
    ballTimer.stop()
  }

  function mashStop() {
    root.ballStop()
    root.mashTrail = []; root.mashSubs = []
  }

  // ---- key routing ----------------------------------------------------------
  // The first repeat lands input:repeat_delay (250ms) after the press, far
  // outside the fast-cadence window that identifies later repeats, so it looks
  // like a fresh press. Carrying the original press time forward when the same
  // key reappears within holdChainMs keeps the hold clock honest — without it a
  // 1.5s hold measured only 1.3s of acceleration and fell ~20% short.
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

  // Repeats are not proof of release. Hyprland cancels key repeat when *any* key
  // goes up and never hands it back to a key still held, so pressing Right, then
  // Left, then releasing Right stopped the cursor dead while Left was still down
  // — is_key_down confirmed it was. `release = true` binds are no help either:
  // measured, once two bound keys are held, neither key's release bind fires.
  //
  // So when repeats lapse the compositor gets asked directly. bindings.lua owns
  // the keys and evaluates the question there, which keeps keysyms out of here —
  // is_key_down needs exact X spellings ("Left", not "LEFT"; "i", not "I") and
  // answers nil for anything it does not recognise, so guessing them from bind
  // names would be fragile. The answer names actions, like everything else.
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
    // instant repeats lapse, which is ~40ms before this answer gets back, so
    // requiring it here threw away every answer that mattered. A key the
    // compositor says is down *should* be moving the cursor, so reviving a hold
    // is the correct response, not an anomaly.
    if (!root.active) { keysPoll.stop(); return }
    var st = ({})
    var parts = root.keysDown.split(/\s+/)
    for (var i = 0; i < parts.length; i++) {
      var kv = parts[i].split("=")
      if (kv.length === 2) st[kv[0]] = (kv[1] === "true")
    }
    var now = Date.now()
    if (st[root.lastHoldAction]) { root.sustain(root.lastHoldAction, now); return }
    // The key driving the sweep is up. Another direction still down takes it over
    // rather than the motion dying — the mirror of releasing the other key.
    var names = ["up", "down", "left", "right"]
    for (var j = 0; j < names.length; j++) {
      if (names[j] !== root.lastHoldAction && st[names[j]]) {
        root.sustain(names[j], now)
        return
      }
    }
    keysPoll.stop()
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

  function handleAction(name) {
    if (!root.active) return        // still arming; the chord owns the keyboard
    root.log("action " + name)
    var now = Date.now()
    var same = (name === root.lastAction)
    var gap = same ? (now - root.lastActionAt) : Infinity
    var repeat = same && (gap <= root.repeatGapMs)
    // Re-triggering the same action quicker than fastTapMs means "go all the
    // way": the next edge for movement, the end of the view for scrolling. The
    // prevGap term rejects a repeat delayed under load, which lands in the same
    // band and would otherwise teleport a sweeping cursor to an edge.
    var fastTap = same && gap < root.fastTapMs && root.prevGap > root.repeatGapMs
    root.prevGap = gap
    root.lastActionAt = now
    root.lastAction = name

    if (name === "debug") {
      if (!repeat) {
        root.mashDebug = !root.mashDebug
        root.pokeIdle()
        if (root.mashDebug) dbgTimer.start()
        root.log("debug display " + (root.mashDebug ? "on" : "off"))
      }
      return
    }
    if (name === "strategy") {
      if (!repeat) root.cycleStrategy()
      return
    }
    if (name === "fine") {
      // Held, not tapped: a press only says it went down, so the release has to be
      // asked about, like the wheel key.
      if (!root.fineHeld) root.fineHeld = true
      root.pokeIdle()
      if (!finePoll.running) finePoll.start()
      return
    }
    if (name === "noop") {               // a stray key in mash mode, deliberately inert
      if (!repeat) root.dbgLogEvent("\u00b7", now, false)   // logged, so a gap is explained
      return
    }
    if (name === "wheel") {
      // w has no dependable release either, so it is asked about rather than
      // waited on. Holding it turns the ball into a wheel instead of a pointer.
      if (!root.wheelHeld) { root.wheelHeld = true; root.scrollAcc = 0 }
      root.pokeIdle()
      if (!wheelPoll.running) wheelPoll.start()
      return
    }
    if (root.mashPos(name)) {
      // A grid key that also stands for a direction is whichever the company it
      // keeps makes it: alone it steers, in a crowd it is a point on a sweep. Only
      // the two cases that cannot wait are handled here — everything else goes
      // through mashPress, so the press still lands in the trail and the cluster
      // stays honest. Returning early used to skip that, which left clusterN stale
      // and lost the first point of any sweep that opened with a direction key.
      var mdir = root.mashDirs[name] ? root.actionDirs[root.mashDirs[name]] : null
      if (mdir && root.wheelHeld) {
        // Wheel mode owns the direction keys outright: first press a detent, held
        // a growing repeat, struck twice the end of the view.
        if (repeat) { root.scrollRepeat(name, mdir, now); return }
        if (same && fastTap) { root.scrollPress(mdir, true); return }
        root.scrollHoldName = name
        root.scrollHoldAt = now
        root.scrollFrac = 0
        root.scrollReps = 0
        root.scrollDets = 1                    // the press itself
        root.pokeIdle()
        root.scrollPress(mdir, false)
        scrollTimer.interval = root.scrollStartMs
        scrollTimer.restart()
        scrollKeyPoll.restart()
        return
      }
      if (mdir && repeat && root.activeKind === "move") {
        root.lastDownAt = now                   // held: sustain the sweep
        root.confirmHold(now, root.repeatGapMs)
        return
      }
      if (mdir && same && fastTap) {            // the same key twice: skitter
        root.pokeIdle()
        root.moveDir = mdir
        root.collectEdges()
        root.moveStep(mdir, root.fineHeld ? root.finePx : root.baseStep, true)
        return
      }
      if (!repeat) root.mashPress(name, now)
      return
    }

    // These must not auto-fire, and several of their keys repeat.
    if (name === "cycle") { if (!repeat) { root.pokeIdle(); root.cycleKeymap() } return }
    if (name === "lmb") { if (!repeat) { root.pokeIdle(); root.clickNow(1) } return }
    if (name === "mmb") { if (!repeat) { root.pokeIdle(); root.clickNow(3) } return }
    if (name === "rmb") { if (!repeat) { root.pokeIdle(); root.clickNow(2) } return }

    if (name === "scrollup" || name === "scrolldown") {
      root.pokeIdle()
      root.scrollSign = (name === "scrollup") ? 1 : -1
      if (repeat) return
      root.stopScroll()
      if (fastTap) {
        root.scroll(root.scrollSign * root.scrollEndDetents)
        return
      }
      root.scroll(root.scrollSign)          // the one-detent floor
      scrollArm.restart()                   // becomes auto-scroll if still held
      return
    }

    var d = root.actionDirs[name]
    if (!d) return
    root.pokeIdle()
    root.moveDir = d
    root.collectEdges()                 // cheap, and keeps up with moved windows
    if (repeat) { root.lastDownAt = now; root.confirmHold(now, root.repeatGapMs); return }
    // Hand the speed over rather than re-running the ramp. This used to require
    // the previous key to still count as down, so letting go for even a moment
    // cost all of it: beginHold() takes one baseStep and then nothing moves until
    // the first auto-repeat lands 250ms later. Measuring from the last tick a key
    // was actually down covers both the still-held case and a brief gap between
    // keys. holdH has decayed over that gap, so what carries over is the speed as
    // it stands now, not as it was at release.
    var carry = root.activeKind === "move" && root.holdH > 0
                && (now - root.lastDownAt) <= root.carryMs
    root.carryGap = root.lastDownAt > 0 ? now - root.lastDownAt : -1
    root.carried = carry
    root.lastDownAt = now                 // this press is itself such an event
    if (carry) {
      root.startSweep(name, now, root.holdH)             // hand the speed over
    } else {
      root.beginHold("move", name, now)
    }
    root.moveStep(d, root.fineHeld ? root.finePx : root.baseStep, fastTap)
  }

  // A scroll key's release cannot dispatch a global shortcut — `release = true`
  // binds only fire with exec_cmd — so bindings.lua execs back into this over
  // the shell's IPC. Measured at ~35ms, under one detent of overrun.
  function scrollstop(arg) {
    root.stopScroll()
    return "ok"
  }

  function stopScroll() {
    scrollArm.stop()
    autoScroll.stop()
    scrollCap.stop()
  }


  // ---- input ----------------------------------------------------------------
  // One global shortcut per physical key, dispatched from binds in the submap.
  // Each carries the key's evdev code so everything downstream is unchanged
  // from when these arrived as key events. Keys that move or scroll in any
  // keymap also need a release, to stop the accel timer and start the glide.
  Instantiator {
    model: root.actions
    delegate: QtObject {
      required property var modelData
      readonly property var shortcut: GlobalShortcut {
        appid: "mousekeys"
        name: modelData
        description: "Mouse keys: " + modelData
        onPressed: root.handleAction(modelData)
      }
    }
  }


  // ---- triggers ------------------------------------------------------------------------
  // Bound in ~/.config/hypr/bindings.lua via hl.dsp.global("mousekeys:<name>").
  // One bind per press order, because Hyprland only matches the bind whose
  // final key completes it.
  GlobalShortcut {
    appid: "mousekeys"
    name: "toggle"
    description: "Mouse keys (Super + M)"
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

  // bindings.lua is where every key lives, so the timing that goes with them
  // belongs there too rather than in a second file. Hyprland's Lua VM keeps its
  // globals, so a MOUSEKEYS table assigned at config load can simply be read
  // back — and it re-reads on every session, so hyprctl reload is enough to
  // apply a change.
  Process {
    id: luaConf
    command: ["hyprctl", "repl",
      'local m = MOUSEKEYS or {} '
      + 'local L = ((m.keys or {}).mash or {}).labels or {} '
      + 'local t = {} for a, k in pairs(L) do t[#t+1] = a .. ":" .. k end '
      + 'return "fast_tap_ms=" .. tostring(m.fast_tap_ms or "") '
      + '.. " carry_ms=" .. tostring(m.carry_ms or "") '
      + '.. " labels=" .. table.concat(t, ",") '
      + '.. " mash_strategy=" .. tostring(m.mash_strategy or "") '
      + '.. " mash_debug_strategies=" .. tostring(m.mash_debug_strategies or "") '
      + '.. " mash_gain=" .. tostring(m.mash_gain or "") '
      + '.. " mash_vmax=" .. tostring(m.mash_vmax or "") '
      + '.. " mash_samples=" .. tostring(m.mash_samples or "") '
      + '.. " mash_grip=" .. tostring(m.mash_grip) '
      + '.. " mash_grip_friction=" .. tostring(m.mash_grip_friction or "") '
      + '.. " mash_nudge=" .. tostring(m.mash_nudge) '
      + '.. " mash_nudge_inner=" .. tostring(m.mash_nudge_inner or "") '
      + '.. " mash_nudge_outer=" .. tostring(m.mash_nudge_outer or "") '
      + '.. " mash_inner=" .. tostring(((m.keys or {}).mash or {}).inner or "") '
      + '.. " mash_outer=" .. tostring(((m.keys or {}).mash or {}).outer or "") '
      + '.. " mash_dirs=" .. tostring(((m.keys or {}).mash or {}).dirs or "") '
      + '.. " scroll_repeat_scale_min=" .. tostring(m.scroll_repeat_scale_min or "") '
      + '.. " scroll_repeat_scale_max=" .. tostring(m.scroll_repeat_scale_max or "") '
      + '.. " scroll_increase_delay=" .. tostring(m.scroll_increase_delay or "") '
      + '.. " scroll_increase_time=" .. tostring(m.scroll_increase_time or "") '
      + '.. " scroll_repeat_ms=" .. tostring(m.scroll_repeat_ms or "") '
      + '.. " mash_nudge_repeat=" .. tostring(m.mash_nudge_repeat) '
      + '.. " mash_nudge_delay_ms=" .. tostring(m.mash_nudge_delay_ms or "") '
      + '.. " mash_nudge_rate_ms=" .. tostring(m.mash_nudge_rate_ms or "")']
    stdout: StdioCollector {
      // "fast_tap_ms=135 carry_ms=135" — named pairs so adding a knob is one term
      // here and one in bindings.lua, and a missing one just keeps its default.
      onStreamFinished: {
        var parts = String(text).trim().split(/\s+/)
        for (var i = 0; i < parts.length; i++) {
          var kv = parts[i].split("=")
          if (kv.length !== 2) continue
          if (kv[0] === "mash_strategy") {
            if (root.mashStrategies.indexOf(kv[1]) >= 0) root.mashStrategy = kv[1]
            continue
          }
          if (kv[0] === "mash_debug_strategies") {
            var want = kv[1].split(",")
            var good = []
            for (var d = 0; d < want.length; d++)
              if (root.mashStrategies.indexOf(want[d]) >= 0) good.push(want[d])
            root.mashDebugStrategies = good
            continue
          }
          if (kv[0] === "labels") {
            var lm = ({})
            var lp = kv[1].split(",")
            for (var j = 0; j < lp.length; j++) {
              var ab = lp[j].split(":")
              if (ab.length === 2) lm[ab[0]] = ab[1]
            }
            root.mashLabels = lm
            continue
          }
          if (kv[0] === "mash_grip" || kv[0] === "mash_nudge"
              || kv[0] === "mash_nudge_repeat") {
            if (kv[1] !== "true" && kv[1] !== "false") continue
            var on = (kv[1] === "true")
            if (kv[0] === "mash_grip") root.mashGrip = on
            else if (kv[0] === "mash_nudge") root.mashNudge = on
            else root.nudgeRepeat = on
            continue
          }
          if (kv[0] === "mash_dirs") {
            var dm = ({})
            var dp = kv[1] === "" ? [] : kv[1].split(",")
            for (var w = 0; w < dp.length; w++) {
              var ab2 = dp[w].split(":")
              if (ab2.length === 2) dm[ab2[0]] = ab2[1]
            }
            root.mashDirs = dm
            continue
          }
          if (kv[0] === "mash_inner" || kv[0] === "mash_outer") {
            var names = kv[1] === "" ? [] : kv[1].split(",")
            if (kv[0] === "mash_inner") root.nudgeInnerNames = names
            else root.nudgeOuterNames = names
            continue
          }
          if (kv[0] === "mash_gain" || kv[0] === "mash_grip_friction"
              || kv[0] === "mash_nudge_inner" || kv[0] === "mash_nudge_outer"
              || kv[0] === "scroll_repeat_scale_min" || kv[0] === "scroll_repeat_scale_max"
              || kv[0] === "scroll_increase_delay" || kv[0] === "scroll_increase_time") {
            var g = parseFloat(kv[1])
            if (!(g > 0)) continue
            if (kv[0] === "mash_gain") root.mashGain = g
            else if (kv[0] === "mash_grip_friction") root.mashGripFriction = g
            else if (kv[0] === "mash_nudge_inner") root.nudgeInnerPx = g
            else if (kv[0] === "mash_nudge_outer") root.nudgeOuterPx = g
            else if (kv[0] === "scroll_repeat_scale_min") root.scrollRepeatScaleMin = g
            else if (kv[0] === "scroll_repeat_scale_max") root.scrollRepeatScaleMax = g
            else if (kv[0] === "scroll_increase_delay") root.scrollIncreaseDelay = g
            else root.scrollIncreaseTime = g
            continue
          }
          var v = parseInt(kv[1], 10)
          if (!(v > 0)) continue
          if (kv[0] === "fast_tap_ms" && v !== root.fastTapMs) {
            root.fastTapMs = v
            root.log("fastTapMs <- " + v + " (bindings.lua)")
          } else if (kv[0] === "carry_ms" && v !== root.carryMs) {
            root.carryMs = v
            root.log("carryMs <- " + v + " (bindings.lua)")
          } else if (kv[0] === "mash_vmax" && v !== root.mashVMax) {
            root.mashVMax = v
            root.log("mashVMax <- " + v + " (bindings.lua)")
          } else if (kv[0] === "mash_samples" && v !== root.mashSamples) {
            root.mashSamples = v
            root.log("mashSamples <- " + v + " (bindings.lua)")
          } else if (kv[0] === "mash_nudge_delay_ms") {
            root.nudgeDelayMs = v
          } else if (kv[0] === "mash_nudge_rate_ms") {
            root.nudgeRateMs = v
          } else if (kv[0] === "scroll_repeat_ms") {
            root.scrollRepeatMs = v
          }
        }
      }
    }
  }

  // Rolling under friction. Distance from a single impulse is v/friction, so the
  // friction constant sets how long a throw takes without changing how far it
  // goes — the gain above decides that.
  Timer {
    id: dbgTimer
    interval: 50
    repeat: true
    onTriggered: {
      dbgCanvas.requestPaint()
      // Nothing animates any more: a few passes cover the strategy results landing
      // after the press that triggered them, and then there is nothing to redraw
      // until the next press.
      if (Date.now() - root.dbgLastAt > 300) dbgTimer.stop()
    }
  }

  Timer {
    id: ballTimer
    interval: root.motionTickMs
    repeat: true
    onTriggered: {
      if (!root.active) { ballTimer.stop(); return }
      var now = Date.now()
      var dt = Math.min(0.1, Math.max(0.001, (now - root.lastTickAt) / 1000))
      root.lastTickAt = now
      // Still gripped: a hand on the ball bleeds the spin off rather than storing
      // it, so the momentum decays while held and letting go does not resume the
      // swipe. Grip friction is well above rolling friction — holding on is meant
      // to stop the cursor, not to slow it gently — so a grip of a couple of
      // hundred milliseconds leaves nothing to continue with. The cursor does not
      // move meanwhile; only the momentum drains.
      // Turned off mid-grip, so let go of whatever is being held.
      if (!root.mashGrip && root.ballHeld) { root.ballHeld = false; holdPoll.stop() }
      if (root.ballHeld) {
        var gd = Math.exp(-root.mashGripFriction * dt)
        root.ballVX *= gd
        root.ballVY *= gd
        if (Math.sqrt(root.ballVX * root.ballVX + root.ballVY * root.ballVY) < 1)
          root.ballStop()
        return
      }
      // Quiet for a moment with the ball still rolling is when a held key would
      // matter, so that is when it gets asked about — not on every press, which
      // would be a subprocess per tap.
      if (root.mashGrip && root.keymap === "mash" && !holdPoll.running
          && now - root.mashLastAt > root.holdCheckMs) {
        holdPoll.start()
        if (!holdProbe.running) holdProbe.running = true
      }
      var decay = Math.exp(-root.mashFriction * dt)
      root.ballVX *= decay
      root.ballVY *= decay
      var sp = Math.sqrt(root.ballVX * root.ballVX + root.ballVY * root.ballVY)
      if (sp < 1) { root.ballStop(); return }
      if (root.wheelHeld) {
        // The larger component wins the axis, so a mostly-vertical mash scrolls
        // the page and a mostly-horizontal one scrolls sideways.
        var horiz = Math.abs(root.ballVX) > Math.abs(root.ballVY)
        root.scrollAcc += (horiz ? root.ballVX : root.ballVY) * dt
        var det = (root.scrollAcc / root.mashScrollPx) | 0
        if (det !== 0) {
          root.scrollAcc -= det * root.mashScrollPx
          if (horiz) root.scrollX(det)
          else root.scroll(-det)        // screen-down is wheel-down
        }
        return                          // wheel instead of pointer, not as well
      }
      root.pokeIdle()
      root.warp(root.curX + root.ballVX * dt, root.curY + root.ballVY * dt)
    }
  }

  Timer {
    id: nudgePoll
    interval: root.nudgeDelayMs
    repeat: true
    onTriggered: {
      if (!root.active || !root.mashNudge || !root.nudgeRepeat
          || root.keymap !== "mash" || root.nudgeName === "") {
        nudgePoll.stop(); return
      }
      if (!nudgeProbe.running) nudgeProbe.running = true
    }
  }

  // Asks about the one key the nudge came from. Its name comes from the labels
  // bindings.lua already publishes, so the spelling stays in the one place that
  // knows it.
  Process {
    id: nudgeProbe
    command: ["hyprctl", "repl",
      'local s = "' + (root.mashLabels[root.nudgeName] || "") + '" '
      + 'if s == "" then return "false" end '
      + 'for _, n in ipairs({ s, s:lower(), s:sub(1,1):upper() .. s:sub(2):lower() }) do '
      + 'if hl.is_key_down(n) then return "true" end end return "false"']
    stdout: StdioCollector {
      onStreamFinished: {
        if (String(text).indexOf("true") < 0) { nudgePoll.stop(); return }
        root.nudgeAgain()
        nudgePoll.interval = root.nudgeRateMs   // past the first, repeat faster
      }
    }
  }

  Timer {
    id: holdPoll
    interval: root.holdPollMs
    repeat: true
    onTriggered: {
      if (!root.active || !root.mashGrip || root.keymap !== "mash") {
        holdPoll.stop(); root.ballHeld = false; return
      }
      if (!holdProbe.running) holdProbe.running = true
    }
  }

  // Counts how many of the grid's keys are physically down. bindings.lua already
  // publishes their names for the debug display, so the question is asked there
  // and the answer is a single number.
  Process {
    id: holdProbe
    command: ["hyprctl", "repl",
      'local L = (((MOUSEKEYS or {}).keys or {}).mash or {}).labels or {} '
      + 'local function d(s) if not s then return false end '
      + 'for _, n in ipairs({ s, s:lower(), s:sub(1,1):upper() .. s:sub(2):lower() }) do '
      + 'if hl.is_key_down(n) then return true end end return false end '
      + 'local n = 0 for _, k in pairs(L) do if d(k) then n = n + 1 end end '
      + 'return "held=" .. n']
    stdout: StdioCollector {
      onStreamFinished: {
        var n = parseInt(String(text).replace("held=", "").trim(), 10)
        root.ballHeld = (n > 0)
        if (!root.ballHeld) holdPoll.stop()      // rolling again; nothing to watch
        else if (!holdPoll.running) holdPoll.start()
      }
    }
  }

  // The repeat wheel mode cannot get from the compositor.
  Timer {
    id: scrollTimer
    interval: root.scrollStartMs
    repeat: true
    onTriggered: {
      if (!root.active || !root.wheelHeld || root.scrollHoldName === "") {
        scrollTimer.stop(); return
      }
      scrollTimer.interval = root.scrollRepeatMs       // the first one waited longer
      var dn = root.mashDirs[root.scrollHoldName]
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

  // Which key is being leaned on comes from the labels bindings.lua publishes, so
  // the spelling stays in the one place that knows it.
  Process {
    id: scrollKeyProbe
    command: ["hyprctl", "repl",
      'local s = "' + (root.mashLabels[root.scrollHoldName] || "") + '" '
      + 'if s == "" then return "false" end '
      + 'for _, n in ipairs({ s, s:lower(), s:sub(1,1):upper() .. s:sub(2):lower() }) do '
      + 'if hl.is_key_down(n) then return "true" end end return "false"']
    stdout: StdioCollector {
      onStreamFinished: {
        if (String(text).indexOf("true") >= 0) return
        root.scrollHoldName = ""                      // let go: the ramp is over
        root.scrollFrac = 0
        scrollTimer.stop()
        scrollKeyPoll.stop()
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
    command: ["hyprctl", "repl",
      'local k = ((MOUSEKEYS or {}).keys or {})["mash"] or {} '
      + 'local s = k.fine if not s then return "false" end '
      + 'for _, n in ipairs({ s, s:lower(), s:sub(1,1):upper() .. s:sub(2):lower() }) do '
      + 'if hl.is_key_down(n) then return "true" end end return "false"']
    stdout: StdioCollector {
      onStreamFinished: {
        if (String(text).indexOf("true") >= 0) return
        root.fineHeld = false
        finePoll.stop()
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
    command: ["hyprctl", "repl",
      'local k = ((MOUSEKEYS or {}).keys or {})["mash"] or {} '
      + 'local s = k.wheel if not s then return "false" end '
      + 'for _, n in ipairs({ s, s:lower(), s:sub(1,1):upper() .. s:sub(2):lower() }) do '
      + 'if hl.is_key_down(n) then return "true" end end return "false"']
    stdout: StdioCollector {
      onStreamFinished: {
        if (String(text).indexOf("true") >= 0) return
        root.wheelHeld = false
        root.scrollAcc = 0
        root.scrollHoldName = ""               // the ramp ends with wheel mode
        root.scrollFrac = 0
        scrollTimer.stop()
        scrollKeyPoll.stop()
        wheelPoll.stop()
      }
    }
  }

  Timer {
    id: keysPoll
    interval: root.keysPollMs
    repeat: true
    onTriggered: {
      // Stops itself once an answer comes back with nothing held; see onKeysDown.
      if (!root.active) { keysPoll.stop(); return }
      if (!keysProbe.running) keysProbe.running = true
    }
  }

  // Asks bindings.lua which direction keys are down, for the active keymap. The
  // spelling dance covers bind names not matching keysyms: is_key_down wants
  // "Left" where the bind says "LEFT", and "i" where it says "I". An unknown name
  // answers nil, which `or` skips, so a wrong guess costs nothing.
  Process {
    id: keysProbe
    command: ["hyprctl", "repl",
      'local k = ((MOUSEKEYS or {}).keys or {})["' + root.keymap + '"] or {} '
      + 'local function d(s) if not s then return false end '
      + 'for _, n in ipairs({ s, s:lower(), s:sub(1,1):upper() .. s:sub(2):lower() }) do '
      + 'if hl.is_key_down(n) then return true end end return false end '
      + 'return "up=" .. tostring(d(k.up)) .. " down=" .. tostring(d(k.down)) '
      + '.. " left=" .. tostring(d(k.left)) .. " right=" .. tostring(d(k.right))']
    stdout: StdioCollector { onStreamFinished: root.onKeysDown(text) }
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







  // Crossing focus moves more than the pointer: on a scrolling workspace the
  // whole row pans, so every window's coordinates change and the edge list is
  // stale too. Hyprland reports the settled geometry straight away (measured at
  // 23ms, while the pan is still visibly animating), so the refresh is asked for
  // here and collected one landMs later, once it has arrived.
  Timer {
    id: resyncTimer
    interval: root.resyncMs
    onTriggered: {
      if (!root.active) return
      root.sentX = -1               // force the next warp to dispatch
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
      if (root.crossTarget !== "") {
        root.landOnEdge()
      } else {
        root.cursorKnown = false    // let cursorProc's result through
        cursorProc.running = true
      }
    }
  }

  // A tap is one detent; still held after scrollArmMs, it becomes auto-scroll.
  Timer {
    id: scrollArm
    interval: root.scrollArmMs
    onTriggered: if (root.active) { autoScroll.start(); scrollCap.restart() }
  }

  Timer {
    id: autoScroll
    interval: Math.max(16, Math.round(1000 / root.scrollMaxRate))
    repeat: true
    onTriggered: {
      if (!root.active) { root.stopScroll(); return }
      root.pokeIdle()
      root.scroll(root.scrollSign)
    }
  }

  // The release callback is the normal stop; this is in case it never arrives.
  Timer {
    id: scrollCap
    interval: root.scrollMaxMs
    onTriggered: root.stopScroll()
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
      // Arm the poll a little before the hold would lapse. Healthy repeats arrive
      // every 25ms and push downUntil 55ms out, so this never fires during an
      // ordinary sweep — only once repeats actually stop, which is either a real
      // release or the multi-key case above.
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
    command: ["hyprctl", "repl", root.chordExpr]
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

    WlrLayershell.namespace: "mousekeys"
    WlrLayershell.layer: WlrLayer.Overlay
    // Never take keyboard focus: any focus mode either swallows the clicks we
    // inject (Exclusive) or stops delivering keys after the first one
    // (OnDemand). Keys arrive as action shortcuts from the submap binds.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // What mash is thinking: the grid as it sits under your hand, which keys were
    // just struck, and the vectors being fitted from them. Yellow subvectors steer
    // the ball, red ones were rejected and contribute nothing, green is the drive
    // vector they average to. It holds the most recent cluster and keeps holding
    // it — nothing fades — so a gesture can be studied once it is over; the next
    // cluster clears the panel and draws itself instead.
    Canvas {
      id: dbgCanvas
      visible: root.active && root.keymap === "mash" && root.mashDebug
      x: 32
      y: 44
      width: root.dbgPitch * 5.25 + 2 * root.dbgMaxLen
      height: root.dbgPitch * 3 + 2 * root.dbgMaxLen + root.dbgFootH + root.dbgLogH
      onVisibleChanged: if (visible) { requestPaint(); dbgTimer.start() }
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var now = Date.now()
        var pad = root.dbgMaxLen, pitch = root.dbgPitch
        ctx.fillStyle = root.dbgRgba(0, 0, 0, 1)
        ctx.fillRect(0, 0, dbgCanvas.width, dbgCanvas.height)
        ctx.strokeStyle = root.dbgRgba(255, 255, 255, 0.18)
        ctx.lineWidth = 1
        ctx.strokeRect(0.5, 0.5, dbgCanvas.width - 1, dbgCanvas.height - 1)

        // Legend, so the colours do not have to be remembered.
        ctx.font = "10px monospace"
        ctx.textBaseline = "top"
        ctx.textAlign = "left"
        var lx = 8
        var legend = [["subvector", 255, 214, 0], ["drive:" + root.mashStrategy, 64, 255, 128],
                      ["ignored", 255, 72, 72]]
        for (var g = 0; g < legend.length; g++) {
          ctx.fillStyle = root.dbgRgba(legend[g][1], legend[g][2], legend[g][3], 0.95)
          ctx.fillRect(lx, 9, 8, 2)
          ctx.fillText(legend[g][0], lx + 12, 5)
          lx += 20 + legend[g][0].length * 6
        }

        // Vectors all radiate from the middle of the grid: they are directions,
        // not places, so a common origin makes them comparable at a glance.
        var ox = pad + 2.6 * pitch, oy = pad + 1.5 * pitch
        function arrow(sx, sy, vx, vy, col, alpha, len) {
          var m = Math.sqrt(vx * vx + vy * vy)
          if (!(m > 0) || alpha <= 0) return
          var L = Math.min(len, root.dbgMaxLen)
          var ex = sx + (vx / m) * L, ey = sy + (vy / m) * L
          ctx.strokeStyle = col; ctx.fillStyle = col; ctx.lineWidth = 2
          ctx.beginPath(); ctx.moveTo(sx, sy); ctx.lineTo(ex, ey); ctx.stroke()
          ctx.beginPath(); ctx.arc(ex, ey, 3, 0, 2 * Math.PI); ctx.fill()
        }

        // Nothing here fades. The panel holds the most recent cluster and keeps
        // holding it, so a gesture can be studied after it has finished; the next
        // cluster clears it and draws itself instead.
        //
        // Subvectors start at the first key of the triple they were measured from,
        // so each one sits on the stretch of the gesture it describes. Held at half
        // opacity: there is one per press and they are working detail, not the
        // answer, so they should not crowd out the drive vector.
        for (var i = 0; i < root.dbgVecs.length; i++) {
          var sv = root.dbgVecs[i]
          var a = 0.5
          var mag = Math.sqrt(sv.x * sv.x + sv.y * sv.y)
          arrow(pad + sv.ox * pitch, pad + sv.oy * pitch, sv.x, sv.y,
                sv.ok ? root.dbgRgba(255, 214, 0, a) : root.dbgRgba(255, 72, 72, a),
                a, sv.ok ? mag * root.dbgScale : root.dbgDeadLen)
        }
        var dm = Math.sqrt(root.dbgDriveX * root.dbgDriveX + root.dbgDriveY * root.dbgDriveY)
        var da = root.dbgDriveAt > 0 ? 1 : 0
        arrow(ox, oy, root.dbgDriveX, root.dbgDriveY, root.dbgRgba(64, 255, 128, da),
              da, dm * root.dbgScale)

        // Every strategy on the debug list, in its own colour and dash, so they can
        // be read against each other and against the green one actually steering.
        // Which is which is settled by the legend along the bottom rather than by
        // labels on the vectors: those collided precisely when the strategies
        // agreed, which is when telling them apart matters most.
        for (var si = 0; si < root.mashDebugStrategies.length; si++) {
          var sn = root.mashDebugStrategies[si]
          var rec = root.dbgStrats[sn]
          if (!rec) continue
          var ra = 1
          var rm = Math.sqrt(rec.x * rec.x + rec.y * rec.y)
          if (ra <= 0 || !(rm > 0)) continue
          ctx.setLineDash(root.dbgStratDash(sn))
          arrow(ox, oy, rec.x, rec.y, root.dbgStratColor(sn, ra), ra, rm * root.dbgScale)
          ctx.setLineDash([])
        }

        // Colour key along the bottom: a swatch in each strategy's own dash, then
        // its name. Greyed out when that strategy has produced nothing to draw.
        ctx.font = "9px monospace"
        ctx.textBaseline = "middle"
        ctx.textAlign = "left"
        var fy = dbgCanvas.height - root.dbgLogH - root.dbgFootH / 2
        var fx = 8
        for (si = 0; si < root.mashDebugStrategies.length; si++) {
          var fn = root.mashDebugStrategies[si]
          var act = (fn === root.mashStrategy)       // the one actually steering
          var live = root.dbgStrats[fn] ? 1 : 0
          var fa = act ? 1 : (0.45 + 0.45 * live)
          var fw = 20 + fn.length * 5.6
          if (act) {
            ctx.fillStyle = root.dbgRgba(255, 255, 255, 0.17)
            ctx.fillRect(fx - 5, fy - 8, fw + 8, 16)
          }
          ctx.strokeStyle = root.dbgStratColor(fn, fa)
          ctx.lineWidth = act ? 3 : 2
          ctx.setLineDash(root.dbgStratDash(fn))
          ctx.beginPath(); ctx.moveTo(fx, fy); ctx.lineTo(fx + 16, fy); ctx.stroke()
          ctx.setLineDash([])
          ctx.fillStyle = root.dbgRgba(255, 255, 255, act ? 1 : 0.55)
          ctx.fillText(fn, fx + 20, fy)
          fx += 26 + fn.length * 5.6
        }

        // Event log along the bottom, newest first: which key, and how long since
        // the one below it. Reading the deltas is how a mash that felt fast but
        // did not move anything gets explained.
        var ly0 = dbgCanvas.height - root.dbgLogH + 4
        ctx.strokeStyle = root.dbgRgba(255, 255, 255, 0.14)
        ctx.lineWidth = 1
        ctx.beginPath(); ctx.moveTo(6, ly0 - 3); ctx.lineTo(dbgCanvas.width - 6, ly0 - 3); ctx.stroke()
        ctx.font = "9px monospace"
        ctx.textBaseline = "top"
        ctx.textAlign = "left"
        ctx.fillStyle = root.dbgRgba(255, 255, 255, 0.45)
        ctx.fillText("key", 10, ly0)
        ctx.fillText("dt ms", 44, ly0)
        ctx.fillText("imp px/s", 92, ly0)
        for (var li = 0; li < root.dbgLog.length; li++) {
          var e = root.dbgLog[li]
          var ey2 = ly0 + (li + 1) * root.dbgLogLineH
          // Newest at full strength, older rows stepped down so the top of the
          // list reads first without the rest disappearing.
          var ea = 0.4 + 0.6 * (1 - li / root.dbgLogMax)
          ctx.fillStyle = e.grid ? root.dbgRgba(255, 255, 255, ea)
                                 : root.dbgRgba(255, 170, 90, ea)
          ctx.fillText(e.g, 10, ey2)
          ctx.fillStyle = root.dbgRgba(200, 200, 200, ea * 0.85)
          ctx.fillText(e.dt < 0 ? "-" : String(e.dt), 44, ey2)
          // Impulse is cubic in mash rate, so reading it against the dt beside it
          // is the quickest way to see why a burst threw the cursor as far as it did.
          ctx.fillStyle = e.imp > 0 ? root.dbgRgba(120, 230, 255, ea)
                                    : root.dbgRgba(140, 140, 140, ea * 0.7)
          ctx.fillText(e.imp > 0 ? String(Math.round(e.imp)) : "-", 92, ey2)
        }

        // A nudge's vector runs from the middle of the inner ring to the key that
        // made it, which is the push it actually applied — unlike the drive vector,
        // which is a direction and starts at the grid's centre.
        if (root.nudgeName !== "") {
          var ng = root.nudgeGeom(), nq = root.mashPos(root.nudgeName)
          if (ng && nq) {
            var nox = pad + ng.cx * pitch, noy = pad + ng.cy * pitch
            var ndx = (nq.x - ng.cx) * pitch, ndy = (nq.y - ng.cy) * pitch
            var nlen = Math.sqrt(ndx * ndx + ndy * ndy)
            ctx.strokeStyle = root.dbgRgba(64, 255, 128, 1)
            ctx.fillStyle = ctx.strokeStyle
            ctx.lineWidth = 2
            ctx.beginPath(); ctx.moveTo(nox, noy); ctx.lineTo(nox + ndx, noy + ndy); ctx.stroke()
            ctx.beginPath(); ctx.arc(nox + ndx, noy + ndy, 3, 0, 2 * Math.PI); ctx.fill()
          }
        }

        // Keys last so they sit over the vector origin rather than under it.
        //
        // Each key is shaded by *when* within the cluster it was struck — first
        // press dark, most recent bright green — so the timing of the gesture reads
        // off the grid at a glance: an even sweep shades evenly, while a burst that
        // stalled halfway leaves a cliff between two neighbouring keys.
        //
        // The whole grid re-shades on every press, because the span it normalises
        // against grows as the cluster does. So the newest key is always at full
        // green and the rest slide back toward grey behind it, live, rather than
        // the picture only resolving once the gesture is over.
        var t0 = root.dbgHits.length > 0 ? root.dbgHits[0].t : 0
        var span = root.dbgHits.length > 0
                     ? root.dbgHits[root.dbgHits.length - 1].t - t0 : 0
        ctx.textAlign = "center"
        ctx.textBaseline = "middle"
        for (var y = 0; y < root.mashCols.length; y++) {
          for (var c = 0; c < root.mashCols[y].length; c++) {
            var x4 = root.mashCols[y][c]
            var nm = "m" + x4 + "_" + y
            // Latest strike wins, so a key hit twice shades by its most recent.
            var hitT = -1
            for (var h = 0; h < root.dbgHits.length; h++)
              if (root.dbgHits[h].name === nm) hitT = root.dbgHits[h].t
            // A cluster of one has no span to divide by, and its only key is also
            // its most recent, so it reads as fully green.
            // A nudge is its own thing, not a point on the gesture's timeline, so
            // it is marked rather than shaded.
            var bg = nm === root.nudgeName ? root.dbgKeyNudge
                   : hitT < 0 ? root.dbgKeyIdle
                              : root.dbgMix(root.dbgKeyCold, root.dbgKeyHot,
                                            span > 0 ? (hitT - t0) / span : 1)
            var px = pad + (x4 / 4) * pitch, py = pad + y * pitch
            ctx.fillStyle = root.dbgRgba(bg[0], bg[1], bg[2], 1)
            ctx.beginPath(); ctx.arc(px, py, 9, 0, 2 * Math.PI); ctx.fill()
            // Black on the grey for a key this cluster has not touched, so it
            // recedes; white once it has been struck, over whatever green its
            // timing earned it.
            ctx.fillStyle = hitT < 0 ? root.dbgRgba(0, 0, 0, 1)
                                     : root.dbgRgba(255, 255, 255, 1)
            ctx.fillText(root.dbgGlyph(root.mashLabels[nm]), px, py + 0.5)
          }
        }
      }
    }

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
