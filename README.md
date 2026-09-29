# Mouse Keys — an Omarchy Quattro overlay plugin

Drive the pointer from the keyboard: move, click and scroll without a mouse.

## Entry — Super + M

How long you hold the chord decides **both** when the session starts and how
long it lasts:

| Gesture | Starts | Lasts |
|---------|--------|-------|
| **Short press** (chord tapped) | when the chord is **released** | until `idleMs` (2s) passes with no input |
| **Long press** (held past `chordLongPressMs`, 500ms) | the moment 500ms elapses, **chord still down** | latched — until you hit Super + M again |

Hitting the chord again always exits. While the chord is down and neither has
happened yet, the session is *armed but inert*: keys do nothing, no marker.

## Keymaps — Tab cycles, and the choice persists

|  | move (up/left/down/right) | left btn | middle btn | right btn | scroll up/down |
|---|---|---|---|---|---|
| **left** | `i` `j` `k` `l` | `c` | `x` | `z` | `y` / `h` |
| **right** | `w` `a` `s` `d` | `,` | `.` | `/` | `r` / `f` |
| **arrows** *(default)* | arrow keys | `d` | `s` | `a` | PgUp / PgDn |

**Shift and Ctrl are yours, not the plugin's.** Every key is bound with
`ignore_mods`, so it reaches the plugin whatever modifiers are held — and those
modifiers then ride along on the pointer events the plugin injects. So
`Shift`+scroll is horizontal scrolling and `Ctrl`+scroll is zoom, in whatever app
is underneath, and `Shift`+click extends a selection. Measured: the client sees
`mods=33554432` (Shift) and `mods=67108864` (Ctrl) on the injected events.

**Re-tapping a scroll key within `fast_tap_ms` (130ms)** sends
`scrollEndDetents` (120) notches in one event, which carries an ordinary view to
its beginning or end.

### Remapping any of it

Every key above is configured in `bindings.lua`, not in the plugin. The binds
name **actions**, never keys: the plugin registers one global shortcut per
action — `up down left right lmb mmb rmb scrollup scrolldown cycle`, plus
`toggle` for the chord — and each keymap is a submap that points keys at them.

So changing a key is a one-line edit with no plugin change and no restart,
just `hyprctl reload`:

```lua
mousekeys_map("left", {
  up = "I", down = "K", left = "J", right = "L",
  lmb = "C", mmb = "X", rmb = "Z", scrollup = "Y", scrolldown = "H",
  -- cycle = "TAB",   -- optional; TAB is the default
})
```

Adding a fourth keymap is one more `mousekeys_map(...)` call plus its name in
the cycle order. The order lives in `shell.json`, which is where Omarchy keeps
plugin settings — inline on the plugin's own entry:

```json
{ "id": "mousekeys", "keymaps": ["arrows", "left"] }
```

Timing goes in `bindings.lua` too, so the keys and the behaviour that depends on
them stay in one file. Hyprland keeps its Lua globals across config loads, so the
plugin reads this table back over `hyprctl repl` when a session starts — which
means `hyprctl reload` is enough to apply a change, with no shell restart:

```lua
MOUSEKEYS = {
  fast_tap_ms = 130,   -- re-press the same key quicker than this to double-tap
}
```

`fast_tap_ms` must stay under `input:repeat_delay` (250ms), or a held key's first
auto-repeat would read as a deliberate re-press.

Omit it and you get `["left", "right", "arrows"]`. Names must match the
`mousekeys_map` calls: the plugin dispatches `hl.dsp.submap("mousekeys-<name>")`
and a name with no submap behind it leaves you in a session that ignores keys.
The entry chord is an ordinary bind at the top of the block, so `SUPER + M` is
changed the same way — with one extra step. The plugin has to poll whether the
chord is still held (it is how a short press is told from a long one, see
[How input actually gets here](#how-input-actually-gets-here-and-why)), so it
needs the chord's **keysyms** as well as the bind:

```json
{ "id": "mousekeys", "chordKey": ["b"], "chordMods": ["Super_L", "Super_R"] }
```

Either list may hold several syms and any one counts — that is how `Super_L`
and `Super_R`, and the shifted `M`, are both covered by the defaults
(`["m", "M"]` and `["Super_L", "Super_R"]`). Set `chordMods` to `[]` for a bare
key. Get these wrong and the bind still works, but every press latches: the poll
never sees the chord go up.

`Tab` cycles through that list. The active keymap is written to
`$XDG_STATE_HOME/quickshell/by-shell/<id>/mousekeys.json` and restored on load;
its name flashes under the cursor on entry and after each Tab.

The pointer's position is drawn as a **translucent red disk** (`markerSize`,
28px) — Hyprland hides the real cursor on key press
(`cursor:hide_on_key_press`), so without a marker there is nothing to aim with.

### Speed model — hold duration sets speed

Both movement and scrolling run off one model. `h` is how long the current
contiguous hold has run; speed is proportional to it:

```
v = k · h        k = 2W/T²        T = sweepMs (1.5s),  W = screen width
```

`k = 2W/T²` is chosen so that **integrating a hold of T seconds gives exactly one
screen width**, and a hold of `t` seconds reaches `t/T` of top speed — so a 0.25s
hold reaches 1/6 the speed of a 1.5s one. `h` grows while a direction key is down
and recedes when none is, so releasing and re-pressing resumes part-way up the
ramp instead of from rest. That is what lets **tap frequency modulate speed**:
sweep by holding, fine-tune by tapping. Any single press moves at least
`baseStep` (8px), and any scroll press emits at least 1 detent, regardless of
`h`. 8px is therefore the finest positioning step — drop `baseStep` to 1 if you
want pixel-exact placement back.

**A new direction pressed mid-sweep takes over without the motion stopping**, and
carries the accumulated `h` with it — you can steer a sweep rather than having to
restart it. This needs an explicit bridge: the key that will sustain the sweep
does not repeat for 250ms, so without one the motion would lapse after
`repeatGapMs` and the speed would bleed away while waiting.

Both modes wait out the acceleration ramp identically; Shift changes *where the
cursor lands*, not how fast it gets going.

```
takeover, both keys held     255px     in 180ms, speed carried over
takeover, old key released   349px     in 180ms, ~1939px/s
```

### Edge snapping

Movement is magnetic to window edges. Every press looks for the nearest edge
ahead of the cursor in that direction:

| | search range | effect |
|---|---|---|
| **single press** | within the distance this press would travel | lands on an edge it would otherwise step over; otherwise moves the full distance |
| **double-tap** — same key re-pressed within `fast_tap_ms` (130ms) | unbounded | skitters to the next edge however far away |

Only edges **on screen** are candidates. Windows routinely extend past the
display, and an edge you cannot reach is not a snap target: `warp()` clamps it
back, so the press appears to do nothing — and worse, it hides the fact that the
skitter has run out of edges.

#### Crossing into another window

A run of double-taps walks edge to edge across a window, crosses into the next,
and carries on. Two things happen along the way, and both **focus a window by
address** — never by direction.

- **Landing inside an unfocused window** adopts it. The pointer is already
  inside, and Hyprland only warps when focusing a window the pointer is *outside*
  of, so this costs no cursor movement at all.

  Which window that is gets decided one pixel **along the direction of travel**,
  not at the cursor itself. A window's far edge sits at `x + w`, one past its last
  pixel, so arriving on it from the other side lands *outside* the window just
  reached: snapping leftwards onto a window's right edge left it unfocused, while
  the mirror case going right worked, because a left edge is a window's first
  pixel. Nudging also settles which window an edge belongs to when two of them
  touch with no gap — the one being entered wins.

  When windows overlap, the one on top wins: floating above tiled, and among
  equals the more recently focused (`focusHistoryID`). Hyprland's client list is
  not in z-order — a window focused three ago was listed ahead of the one focused
  last — so it cannot be used to break the tie.
- **Landing on the screen's own edge** looks for a window with content past that
  boundary — exactly the windows that are not snap targets because they are
  unreachable — and focuses the nearest one.

`hl.dsp.focus({ direction = … })` is deliberately **not** used, and that is the
whole point of this section. It asks the *layout* what comes next, which on a
single monitor is just another tiled window, and Hyprland then drags the pointer
into it (`cursor:no_warps = false`) — the cursor arrives somewhere you never
aimed at. Naming the window instead keeps focus and pointer in agreement.

**Why this is the same in every layout.** Addressing a window says nothing about
layout order, so the rule needs no per-layout cases — and each layout then does
its own native thing with the focus:

| layout | window past the screen edge? | what focusing it does |
|---|---|---|
| `scrolling` | yes — the row is wider than the viewport | pans the row to reveal it (`scrolling:follow_focus`) |
| second monitor | yes — its windows are past the edge | brings that monitor's window in |
| `dwindle`, `master` | no — everything is on screen | nothing; the cursor rests on the edge |

There is no API for the other approach — moving the viewport *without* focusing.
`hl.dsp.focus` takes only `window`, `direction`, `monitor`, `workspace` and
`urgent_or_last`; the `scrolling` layout's `layoutmsg` vocabulary is
`fit_into_view promote colresize consume consume_or_expel inhibit_scroll monocle`
and none of them pans on its own (`+col`, `-col`, `toend`, `tobeg` and `expand`
return *"no such layoutmsg for scrolling"* — they belong to `master`). With
`scrolling:follow_focus = true`, focus **is** the pan mechanism.

##### Keeping the pointer continuous

A focus change can move the pointer in two ways, and both would break a sweep in
half, so the landing position is always recomputed rather than accepted:

- **Hyprland drops the pointer on the centre of a window it focuses** — measured
  367px from the edge the sweep left through, with the cross-axis position thrown
  away entirely.
- **The workspace can pan under a stationary pointer.** Focusing a partly-visible
  column moved it from `1503..2237` to `790..1524`; the pointer stayed at screen
  x=1503 and so ended up near the window's right side having entered from its
  left.

Both are fixed by remembering where in the target window the pointer belongs —
the entering edge when crossing in from outside, or its existing offset when it
is already inside — and restoring that once the geometry settles, with the
cross-axis coordinate preserved and clamped into the new window's span.

```
double-tapping right across a scrolling row (y held at 300 throughout):
  300 -> 746 -> 760 -> 1489 -> 790 -> 1524 -> 1535 -> stays
                               ^^^ crossed in; row panned, pointer followed it
```

The correction is safe to make because Hyprland issues exactly **one** warp, at
focus time, settled within 23ms. A correction dispatched 0, 25, 60 or 130ms
later stuck in all four cases — there is no second warp to lose a race against.
Nor is there any need to wait out the pan animation: `at`/`size` report the
*settled* geometry immediately, while the row is still visibly sliding.

The user never sees the centre excursion, because `curX`/`curY` never adopt it
and the visible pointer is the plugin's own marker
(`cursor:hide_on_key_press` hides the real one) — the marker goes from the old
edge straight to the new one.

**The whole edge list is refreshed too**, not just the pointer. A pan moves every
window on the workspace — one went from `12` to `-701` — so the coordinates
collected before the crossing describe edges that no longer exist.

**Focusing must never change workspace.** Window lookup filters by Quickshell's
cached `focusedWorkspace`, and a stale cache hands back windows from elsewhere —
which focusing would then follow, dragging you to another workspace. This was
observed: switching workspace outside the shell left the cache pointing at the
old one and a skitter focused a window there. So the refresh covers workspaces
and monitors as well as toplevels, and a window's own workspace is re-checked
immediately before focusing it.

Edges come from Quickshell's Hyprland toplevels, whose `lastIpcObject` carries
`at`/`size` **in process** — no subprocess, so the set is rebuilt on every
keypress and keeps up with windows that move. Only windows on the focused
monitor's active workspace count, and each edge remembers the span it covers on
the *other* axis: an edge you are not level with is not one you could collide
with. The screen's own bounds are always included, so there is always something
to snap to and Shift never leaves you with nowhere to go.

Candidates must be *strictly* ahead (`edgeEpsilon`), which is what stops a sweep
sticking: a held key snaps onto each edge as it passes and then carries on past
it, rather than pinning to the first one it meets.

#### Fast tapping and auto-repeat share a window

Hyprland's key repeat also arrives on the same key well inside `fast_tap_ms`, so
"tapped again quickly" and "still held down" have to be told apart or a held key
would skitter to the screen edge instead of sweeping. Two things separate them:

- Anything within `repeatGapMs` (55ms) is classified as a repeat and drives the
  sweep, so only the 55–130ms band can count as fast tapping.
- A repeat **delayed under load** still lands in that band, so the event before
  it is checked too (`prevGap`). A deliberate re-press can only follow a release,
  so it is never preceded by another event one repeat-interval earlier; a delayed
  repeat always is. Without this an identical 0.75s sweep measured 427px, 557px
  and then 746px — that last one exactly a window edge, the cursor teleporting
  mid-sweep.

Consequences:

- A **held** key never skitters. Its first repeat lands ~250ms out (outside
  `fast_tap_ms`) and the rest arrive 25–34ms apart (inside `repeatGapMs`).
- Tapping **faster than 55ms** is indistinguishable from auto-repeat, so it
  sweeps rather than skitters. That is the floor, and it cannot be lifted without
  key-release events, which this input path does not get.

Measured from `x=0` against the same three windows:

```
3 taps @200ms apart  -> x=20    8, 12 (snapped), 20 — ordinary stepping
4 taps @100ms apart  -> x=760   8, then skitter 12 -> 746 -> 760
4 taps @70ms  apart  -> x=760   same
hold 0.75s           -> x=407   sweeps, does not skitter
5 taps @40ms apart   -> x=35    read as auto-repeat, so it sweeps
```

Measured against a workspace with windows at `x:12..746`, `x:760..1489` and
`x:1503..2237` on a 1536px screen:

```
from x=0   tap right   ->    8    nothing within 8px, so a full step
           tap right   ->   12    snapped: the window edge was 4px away
           tap right   ->   20    nothing within 8px again
  dbl-tap right      ->  746 -> 760 -> 1489 -> 1503 -> 1535 -> stays
  dbl-tap left       -> 1503    and back again
sweep right 0.75s      ->  406px  passes through edges, does not stick
from y=0 dbl-tap down  ->   38 -> 852 -> 863   window top, bottom, screen
```

Shift is not read as a separate key — it cannot be, with no keyboard grab. The
submap binds a `SHIFT + <key>` variant of **every** key, so whether Shift was
down arrives with the event itself. This is also why the variants exist for keys
Shift does nothing for: a bind matches on an exact modifier mask, so an unbound
`SHIFT + <key>` would fall straight through to the focused app and type a
character instead.

Scrolling uses the same `h` with `scrollMaxRate` (25 detents/s at full
acceleration) in place of `k`, and auto-repeats while held.

Measured:

```
movement   tap        8px          scroll   tap      1 detent
           hold 0.4s   92px                 hold 0.6s   4 detents
           hold 0.75s 398px  (ideal 384)    hold 1.2s  13 detents
           hold 1.0s  726px  (ideal 683)
           hold 1.5s 1535px  = one screen width
```

Within ~6% of the model for holds past 0.75s; shorter holds fall below it because
of the dead zone described next.

#### Two platform limits worth knowing

- **Presses shorter than `input:repeat_delay` (250ms) are indistinguishable.**
  With no key release available, the only proof a key is *held* is its first
  repeat, which lands 250ms in. So every press under 250ms is a `baseStep` tap
  and the "0.25s taps give 1/6 speed" case degrades to "taps give one step
  each" — frequency
  still modulates speed, duration below 250ms does not. Getting that back needs a
  helper reading `/dev/input` directly.
- **A wheel event cancels Hyprland's key repeat.** Injecting a scroll through
  ydotool kills the repeat of the key being held — measured, 40 repeats become 8.
  So auto-scroll cannot ride repeats like movement does — the plugin would have
  no evidence the key is still down. Each scroll key therefore carries a second,
  `release = true` bind that runs
  `omarchy-shell -q shell call mousekeys scrollstop ''`. That is the one place
  `exec_cmd` earns its keep: it is the only bind form that fires on release, and
  it lands in ~35ms — inside a single detent, so scrolling stops where you let
  go. Auto-scroll also self-caps at `scrollMaxMs` (8s) in case a release is ever
  missed, and one subprocess per release beats one per 80ms poll.

## How input actually gets here, and why

This is the part that took the longest to get right, so it is worth writing
down. The overlay takes **no keyboard focus at all**; every key arrives as a
global shortcut dispatched from a bind inside the plugin's own submap.

Both keyboard-grab modes are dead ends, measured against a click-logging
Wayland client rather than guessed at:

| `WlrLayershell.keyboardFocus` | keys | clicks reaching the app |
|---|---|---|
| `Exclusive` | delivered | **none** — an exclusive-focus layer makes Hyprland swallow every pointer event |
| `OnDemand` | **one, then focus is lost** | delivered |
| `None` + submap binds | delivered | delivered |

A compositor-level bind probe is not enough to catch this: with `Exclusive` a
plain `mouse:272` bind still fires, so the button clearly reaches Hyprland — it
just never reaches the client. Only a real client that logs what it receives
shows the difference.

Two consequences fall out of the bind route:

- **Movement never waits for a key release**, because none is available to it:
  a `release = true` bind fires when it dispatches `exec_cmd` but never when it
  dispatches `hl.dsp.global`. Movement rides Hyprland's own key repeat instead
  (250ms delay, then 40/s — close enough to the 150ms/50Hz ramp this used to
  run on its own timer), and a key is taken to be up once repeats stop for
  `repeatGapMs`. Scroll keys are the exception and take the `exec_cmd` route
  deliberately; see below.
- **Buttons and Tab ignore repeats.** Several of those keys are movement in
  another keymap, so they are bound as repeating; firing on a repeat would turn
  a held key into a click storm.

Keys you don't bind pass through to the focused app, so typing during a latched
session inserts text. Bound keys are consumed and won't leak.

## Requirements

Cursor movement needs nothing — it goes over Quickshell's existing Hyprland
socket. **Clicking and scrolling need `ydotool`**, because Wayland doesn't let a
client synthesize pointer buttons and Hyprland's Lua API is keyboard-only
(`hl.dsp.send_key_state` accepts `BTN_LEFT` but emits no pointer button):

```bash
sudo pacman -S ydotool                   # also ships the /dev/uinput udev rule
systemctl --user enable --now ydotool    # user service — no sudo
```

Then reboot once, or `sudo modprobe uinput` to skip the reboot. Nothing else is
needed on Omarchy: the `ydotool` package installs
`/usr/lib/udev/rules.d/80-uinput.rules`, `uinput` is listed in
`modules.devname` so its static node is created at boot with that rule's
`root:input 0660`, and Omarchy already puts every user in the `input` group
(`install/hardware/input-group.sh`). Don't hand-write a udev rule — the packaged
one is enough.

## Install

1. Clone into `~/.config/omarchy/plugins/mousekeys/` — the directory name must
   match the manifest `id`, which is how `omarchy plugin add` names its clone.
   Note the GlobalShortcut **appid** (also `mousekeys`) is a separate identifier
   from the plugin id, and every binding below references it — change one
   without the other and all the bindings silently stop working.
2. Copy the folder to `~/.config/omarchy/plugins/mousekeys/`.
3. Check it, then load and enable it:

   ```bash
   omarchy plugin validate ~/.config/omarchy/plugins/mousekeys
   omarchy-shell shell rescanPlugins
   omarchy plugin enable mousekeys
   ```

   `validate` only checks `manifest.json` — it never loads the QML. Set
   `debug: true` in `MouseKeys.qml` to trace keys (the log is at
   `/run/user/$UID/quickshell/by-id/<id>/log.qslog`, read it with
   `quickshell log <file>`), or ask the running plugin for its state:

   ```bash
   omarchy-shell shell call mousekeys probe ""
   # opened=true active=true sticky=false keymap=right moving=false bonus=0.0
   ```

4. Add the bindings from `bindings.lua.example` to `~/.config/hypr/bindings.lua`.

Saving files under `~/.config/omarchy/plugins/` hot-reloads most edits, but a
`keepLoaded` plugin like this one keeps its mounted instance — run
`omarchy-restart-shell` to pick up QML changes.

A latched session has no timeout and no Escape, so **Super + M is its only
exit**. `CTRL + ALT + Escape` restores your keybindings if the shell dies
holding the submap, but the overlay keeps its surface until
`omarchy-shell shell hide mousekeys`.

## Choosing the chord

`SUPER + M` is deliberate: Omarchy leaves it unbound, and `M` is not one of the
keys the plugin binds in-session. Both halves matter.

The earlier chord was `SUPER + Left Alt`, which collided with the 25 `SUPER+ALT`
bindings Omarchy ships — reaching for `SUPER+ALT+SPACE` armed the plugin instead
and the submap swallowed the third key.

If you want to move it, two traps are worth knowing:

- **Omarchy binds some `SUPER` combinations by raw keycode**, and
  `hyprctl binds` reports those with an *empty* key name. `SUPER+1`…`SUPER+0`
  (workspaces, `code:10`–`code:19`) and `SUPER+minus`/`SUPER+equal` (window
  resize, `code:20`/`code:21`) therefore look free to a name-based scan and are
  not. Of 43 taken `SUPER+<key>` combinations, 12 are invisible that way.
- **The chord key must not be one of the plugin's in-session keys.** Those are
  bound with `ignore_mods`, so they fire whatever modifiers are held — a chord on
  one of them would move the cursor or click while exiting. That rules out
  `A D H I R Y Z period Prior Next`, which are otherwise free.

What that leaves: letters `B E M N Q U`, punctuation `semicolon apostrophe
bracketleft bracketright grave backslash`, and `DELETE END INSERT F1`–`F12`.

`SUPER + Caps_Lock` also works, but **only bound by keycode as `code:66`**:
Omarchy sets `kb_options = "compose:caps"`, so the physical key emits
`Multi_key`, not `Caps_Lock`. A keysym bind registers and silently never fires,
and a `release = true` bind on it would have to name `Multi_key` too.
