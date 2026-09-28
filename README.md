# Mouse Keys — an Omarchy Quattro overlay plugin

Drive the pointer from the keyboard: move, click and scroll without a mouse.

## Entry — Super + Left Alt

How long you hold the chord decides **both** when the session starts and how
long it lasts:

| Gesture | Starts | Lasts |
|---------|--------|-------|
| **Short press** (chord tapped) | when the chord is **released** | until `idleMs` (2s) passes with no input |
| **Long press** (held past `chordLongPressMs`, 500ms) | the moment 500ms elapses, **chord still down** | latched — until you hit Super + Left Alt again |

Hitting the chord again always exits. While the chord is down and neither has
happened yet, the session is *armed but inert*: keys do nothing, no marker.

## Keymaps — Tab cycles, and the choice persists

|  | move (up/left/down/right) | left btn | middle btn | right btn | scroll up/down |
|---|---|---|---|---|---|
| **left** | `i` `j` `k` `l` | `c` | `x` | `z` | `y` / `h` |
| **right** *(default)* | `w` `a` `s` `d` | `,` | `.` | `/` | `r` / `f` |
| **arrows** | arrow keys | `d` | `s` | `a` | PgUp / PgDn |

Holding **either Shift** with a movement key does two things: a discrete press
moves `shiftScale` (8) pixels instead of 1, and a held press **sweeps at once**
rather than waiting out the acceleration ramp. Shift is a no-op for the buttons,
Tab and scrolling.

`Tab` cycles left → right → arrows. The active keymap is written to
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
sweep by holding, fine-tune by tapping. Any single press moves at least 1px, and
any scroll press emits at least 1 detent, regardless of `h`.

**A new direction pressed mid-sweep takes over without the motion stopping**, and
carries the accumulated `h` with it — you can steer a sweep rather than having to
restart it. This needs an explicit bridge: the key that will sustain the sweep
does not repeat for 250ms, so without one the motion would lapse after
`repeatGapMs` and the speed would bleed away while waiting.

**Shift starts a sweep at full `h` immediately**, skipping the ramp. It scales
the discrete per-press step by `shiftScale` but deliberately does *not* also
scale the held sweep — that ramp is already maxed, and multiplying it by 8 would
cross the screen in under 100ms.

Measured:

```
unshifted 'd', 150ms in        1px     the ramp wait, unchanged
SHIFT + 'd',   150ms in      370px     sweeping at once
takeover, both keys held     255px     in 180ms, speed carried over
takeover, old key released   349px     in 180ms, ~1939px/s
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
movement   tap        1px          scroll   tap      1 detent
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
  repeat, which lands 250ms in. So every press under 250ms is a 1px tap and the
  "0.25s taps give 1/6 speed" case degrades to "taps give 1px each" — frequency
  still modulates speed, duration below 250ms does not. Getting that back needs a
  helper reading `/dev/input` directly.
- **A wheel event cancels Hyprland's key repeat.** Injecting a scroll through
  ydotool kills the repeat of the key being held — measured, 40 repeats become 8.
  So auto-scroll cannot ride repeats like movement does; instead the plugin polls
  `hl.is_key_down(<keysym>)` every `scrollPollMs` (80ms) while a scroll key is
  down. That is one short-lived subprocess per poll, and only while scrolling.

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

- **Nothing here waits for a key release**, because none is available: a
  `release = true` bind fires when it dispatches `exec_cmd` but never when it
  dispatches `hl.dsp.global`. Movement and scroll ride Hyprland's own key
  repeat instead (250ms delay, then 40/s — close enough to the 150ms/50Hz ramp
  this used to run on its own timer), and a key is taken to be up once repeats
  stop for `repeatGapMs`.
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

A latched session has no timeout and no Escape, so **Super + Left Alt is its
only exit**. `CTRL + ALT + Escape` restores your keybindings if the shell dies
holding the submap, but the overlay keeps its surface until
`omarchy-shell shell hide mousekeys`.

## Known conflict

`SUPER+ALT` carries 25 Omarchy bindings. Pressing Super then Left Alt en route
to `SUPER+ALT+SPACE` (Apps menu), `SUPER+ALT+RETURN` (Tmux) or `SUPER+ALT+F`
(Full width) arms this plugin instead, and the submap swallows the third key.

This is largely self-limiting: a real `SUPER+ALT+<key>` is pressed quickly, so
it registers as a **short** press and the session closes itself 2s later. You
lose the keystroke, not your session. Hitting Super + Left Alt again exits
immediately.
