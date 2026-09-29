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
  readonly property var actions: ["up", "down", "left", "right",
                                  "lmb", "mmb", "rmb",
                                  "scrollup", "scrolldown", "cycle"]
  readonly property var actionDirs: ({ "up": [0, -1], "down": [0, 1],
                                       "left": [-1, 0], "right": [1, 0] })

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
    ? root.settings.keymaps : ["left", "right", "arrows"]

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
      + " keymap=" + root.keymap + " fastTap=" + root.fastTapMs
      + " cur=" + Math.round(root.curX) + "," + Math.round(root.curY)
      + " focus=" + root.focusedAddress()
      + " idle=" + idleTimer.running + " long=" + longPressTimer.running
      + " moving=" + motionTimer.running + " held=" + root.holdConfirmed
      + " edges=" + root.edgesX.length + "/" + root.edgesY.length
      + " autoscroll=" + autoScroll.running
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
    root.lastAction = ""
    root.lastHoldAction = ""
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
  function moveStep(dir, px, unbounded) {
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
    if (repeat) { root.confirmHold(now, root.repeatGapMs); return }
    if (root.holdConfirmed && root.activeKind === "move") {
      root.startSweep(name, now, root.holdH)             // hand the speed over
    } else {
      root.beginHold("move", name, now)
    }
    root.moveStep(d, root.baseStep, fastTap)
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
      'return tostring((MOUSEKEYS and MOUSEKEYS.fast_tap_ms) or "")']
    stdout: StdioCollector {
      onStreamFinished: {
        var v = parseInt(String(text).trim(), 10)
        if (v > 0 && v !== root.fastTapMs) {
          root.fastTapMs = v
          root.log("fastTapMs <- " + v + " (bindings.lua)")
        }
      }
    }
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
