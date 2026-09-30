# Moush

Move, click, drag and scroll the mouse pointer without touching a mouse.

Moush is a plugin for [Omarchy](https://omarchy.org). Hold `Super + M` and your
keyboard becomes the pointer until you let it go.

## Why it exists

Keyboard mouse emulation usually works one of two ways, and both are tiring. Arrow
keys crawl a few pixels at a time, so crossing a screen takes a held key and a long
wait. Acceleration schemes fix the crossing but overshoot everything small.

Moush gives you three ways to move, and you switch between them without thinking:

- **Tap** a direction for a small, exact step.
- **Hold** it to sweep across the screen, gathering speed as you go.
- **Mash** across a block of keys, the way you would drag a finger across a
  trackball, and the pointer rolls in the direction your hand travelled.

On top of that, the pointer is magnetic to the edges of your windows. A single tap
lands on an edge it would otherwise step past, and holding Shift while you swipe
sends it straight to the next edge, however far away it is. Most of the places you want to
click are at or near an edge, so getting there stops being the slow part.

## What you need

Moving the pointer needs nothing extra. Clicking and scrolling need `ydotool`,
because a Wayland application is not allowed to press mouse buttons by itself:

```bash
sudo pacman -S ydotool
systemctl --user enable --now ydotool
```

Then reboot once, or run `sudo modprobe uinput` to skip the reboot. Nothing else is
needed on Omarchy. Do not hand-write a udev rule; the packaged one is enough.

## Install

```bash
git clone https://github.com/hanoixan/moush ~/.config/omarchy/plugins/moush
omarchy plugin validate ~/.config/omarchy/plugins/moush
omarchy-shell shell rescanPlugins
omarchy plugin enable moush
```

The folder must be named `moush`. Then append the contents of
`bindings.lua.example` to `~/.config/hypr/bindings.lua` and run `hyprctl reload`.
That file holds every key Moush uses, and it is yours to edit.

## Turning it on

`Super + M` starts a session. How long you hold the chord decides how long the
session lasts:

| | starts | ends |
|---|---|---|
| **Tap it** | when you let go | on its own, after two seconds of no input |
| **Hold it** for half a second | right then, before you let go | when you press `Super + M` again |

Tap it for a quick correction and forget about it. Hold it when you are going to be
driving for a while. Either way, `Super + M` always gets you out.

While a session is running, a translucent red disc shows where the pointer is.
Hyprland hides the real cursor as soon as you touch a key, so the disc is what you
aim with.

## The keys

Two layouts ship. `mash` sits under the right hand, `mash-lh` under the left. `Tab`
switches between them, and your choice is remembered between sessions and across
a shell restart.

```
mash                                   mash-lh

 7 8 9 0 -                             2 3 4 5 6
Y U I O           the grid             W E R T
 H J K L                                S D F G
  N M , .                                X C V B

8 9 0    left, middle, right button     5 4 3
7  hold  scroll instead of move         6  hold
` shows or hides the display          Tab switches layout

Shift  hold  bigger: 32px a tap, and a swipe goes to the next edge
Ctrl   hold  smaller: 1px a tap, and a much shorter roll
```

Everything not listed still types normally, so you can keep working with a session
open. A few keys next to the grid are deliberately bound to nothing, so a stray
reach does not spill letters into whatever you were writing.

## Moving the pointer

Eight keys steer. In `mash` they are `I` up, `M` down, `J` left, `K` right, and
`U` `O` `N` `,` for the four diagonals. The rest of the grid has no direction of
its own and does nothing when tapped alone; those keys exist for mashing.

**One tap is a small step.** Eight pixels, or six on each axis for a diagonal.

**Two modifiers change the size of everything.** Hold **Shift** and a tap moves 32
pixels instead of 8. Hold **Ctrl** and it moves one pixel, for when you need to be
exact. Holding both counts as Ctrl.

**Holding sweeps, and picks up speed.** The longer you hold, the faster it goes. A
hold of about a second and a half crosses the screen; measured on a 1536-pixel-wide
screen, a 1.5 second hold travelled 1475 pixels. Let go and tap to fine-tune.
Letting go of one direction and pressing another keeps the speed you had built up,
so you can steer a sweep instead of restarting it.

**Hold Shift and swipe to jump to the next edge.** Not a step and not a roll: the
pointer goes straight to the nearest window edge in that direction, however far
away. Shift with `J K` jumps right, with `M I` jumps up, with `O Y` jumps left.

The direction is the swipe's own, so this does not depend on any key meaning an
arrow. Shift with `Y O` jumps right too, because `Y` to `O` points right. Any two
keys that describe the direction you want will do.

One jump per swipe, however many keys you cross: Shift with `J K`, `J K L` and
`J K L ,` all land in the same place. To jump again, pause and swipe again.

Because a modifier says what you mean, nothing you do with the keys alone can
trigger this by accident. Tapping one key over and over is just tapping, at any
speed.

**Run out of edges and it crosses into the next window, and focuses it.** Walking
left out of a window, the pointer stops on that window's left edge, then appears on
the right edge of the window beside it, which becomes the focused window. This
works the same whichever Hyprland layout you use.

## Mashing

The grid is the part that is unlike other keyboard mouse tools. Instead of one key
per direction, you run your fingers across a block of keys, and the pointer rolls
the way your hand went. Mash `Y U I O` left to right and it rolls right. Mash
`I K ,` downward and it rolls down. It reads the direction from the order you hit
the keys, so no single key means anything on its own.

How far it rolls depends on how far your hand travels in one go:

| keys crossed in one gesture | pointer travels |
|---|---|
| two | about 320 px |
| three | about 420 px |
| four | about 535 px |

Keys struck more than about a fifth of a second apart are treated as separate taps
rather than one gesture, which is what lets tapping and mashing share the same
keys without getting in each other's way.

With the settings as shipped, the roll reaches its top speed almost immediately, so
distance follows how far across the keys you went rather than how hard you hit
them. If you would rather have speed matter, see `mash_gain` below.

## Clicking and dragging

`8` `9` `0` are the left, middle and right buttons. A button is down while its key
is down, so a tap is a click and a hold is a drag. Hold `8`, sweep across a line of
text, and let go, and the text is selected exactly as a mouse would have selected
it. Clicking also focuses whatever window the pointer is over.

Modifiers reach the application. Hold `Shift` and click, and the click arrives as a
shift-click, extending a selection rather than starting a new one.

## Scrolling

Hold `7` and the same direction keys scroll instead of moving the pointer. The
pointer stays where it is.

Keep the key down and the scrolling accelerates: steady for the first second and a
half, then climbing over the next five seconds to ten times the starting rate,
where it stays. Measured while holding one key:

```
after 0.8s   1.0x      still steady
       2.0s   2.9x     climbing
       3.5s   6.0x
       5.5s  10.0x     at the top
       7.5s  10.0x
```

**The modifiers work here too.** Hold Shift and a single press scrolls ten notches
instead of one, the size the ramp would otherwise take seconds to reach. Hold Ctrl
and the ramp switches off: every repeat stays one notch for as long as you hold it.

For a long document, hold Shift and swipe. Scrolling goes to a hundred times the
base rate at once and stays there while you keep the last key of the swipe down.

**Every direction scrolls one axis.** Up and right both scroll one way, down and
left the other, so whichever keys fall under your fingers the sense is the same.

## The display

Backtick shows or hides a panel in the top left. It is there to make the layout
legible while you are learning it, or after you have rearranged the keys.

The top row shows every key the layout binds that is not part of the grid, each
under the name of its job, and a key turns red while it is held. The grid below
shows your keys where they sit under your hand, lighting up as you strike them and
shading brighter green with how recent each strike was, so you can see the shape of
the gesture you just made. An arrow shows the direction the roll was read as, and a
log along the bottom lists recent keys with the gap between them.

Press `Tab` and the whole panel redraws for the other layout.

## Making it yours

Everything lives in `~/.config/hypr/bindings.lua`, in one table. Edit it and run
`hyprctl reload`; there is nothing to restart and no other file to touch.

Each layout declares its own keys, so the two can share nothing at all:

```lua
MOUSH = {
  carry_ms   = 175,       -- press a new direction this soon and keep your speed
  coarse_mod = "SHIFT",   -- hold for bigger
  fine_mod   = "CTRL",    -- hold for smaller

  modes = {
    mash = {
      keys = {
        -- key, then where it sits: x to the right, y downward
        { "Y", 0.0, 1 }, { "U", 1.0, 1 }, { "I", 2.0, 1 }, { "O", 3.0, 1 },
        { "H", 0.5, 2 }, { "J", 1.5, 2 }, { "K", 2.5, 2 }, { "L", 3.5, 2 },
        { "N", 1.0, 3 }, { "M", 2.0, 3 }, { "comma", 3.0, 3 }, { "period", 4.0, 3 },
      },

      -- which of those also steer when tapped on their own
      dirs = {
        I = "up", M = "down", J = "left", K = "right",
        U = "upleft", O = "upright", N = "downleft", comma = "downright",
      },

      buttons = { lmb = "8", mmb = "9", rmb = "0" },
      wheel   = "7",        -- hold to scroll
      cycle   = "TAB",      -- next layout
      debug   = "grave",    -- show or hide the display

      -- bound so they do nothing, rather than typing into your window
      inert = { "6", "T", "G", "B", "P", "semicolon", "slash" },
    },

    ["mash-lh"] = { ... },
  },
}
```

### The grid

The numbers after each key say where it sits. The only rule is that x grows to the
right and y grows downward, matching the screen. Beyond that the units are yours:
the shipped layout counts in key widths, with each row set half a key right of the
one above, which is roughly how a staggered keyboard feels under the hand. An
ortholinear keyboard would use whole numbers with no offset. Larger or smaller
numbers work too, as long as you are consistent.

Only keys in `dirs` steer on their own. Leave a key out of `dirs` and it is purely
part of the grid.

### The two modifiers

`coarse_mod` and `fine_mod` take any Hyprland modifier name: `SHIFT`, `CTRL`,
`ALT`, `SUPER`. They apply only to the grid keys, so a modifier still reaches the
application when you use it with a mouse button: Shift and a click is still a
shift-click.

The flip side is that Shift and Ctrl are no longer invisible to Moush while a
session is open. Ctrl with a scroll still zooms in your browser, but it also means
"fine" here, so the scrolling will not accelerate while you hold it. If that gets
in the way, move the modifier to `ALT`.

`SUPER` and `ALT` are left alone by default, so those combinations still reach your
normal bindings during a session.

### Leaving things out

Any of these can be omitted. A layout with no `wheel` cannot scroll. A layout with
no `dirs` is a pure trackball. A layout with only `lmb` has only a left button.
Nothing else is affected.

### Adding a layout

Add another entry under `modes`. `Tab` cycles through them in alphabetical order.

### How mashing feels

```lua
mash_gain    = 20,     -- how hard each key press shoves the pointer
mash_vmax    = 1000,   -- its top speed, which sets the longest roll
mash_samples = 4,      -- how many recent presses the direction is read from
```

`mash_gain` is the one to reach for. It sets how much speed a press adds, and it
grows steeply, so a change is felt far more at the fast end than the slow end. At
the shipped value of 20 almost any real mash hits the `mash_vmax` ceiling, which is
why distance follows how far your hand travelled rather than how fast it moved.
Lower it and speed starts to matter: at `0.01`, the same four presses travelled
16 px when mashed slowly and 43 px when mashed quickly.

`mash_vmax` sets the longest possible roll. Raise it for bigger screens.

### How scrolling feels

```lua
scroll_repeat_scale_min   = 1,    -- wheel notches per repeat to begin with
scroll_repeat_scale_max   = 10,   -- once it has finished, and what Shift jumps to
scroll_repeat_scale_ultra = 100,  -- the rate a coarse swipe asks for
scroll_increase_delay     = 1.5,  -- seconds steady before it starts climbing
scroll_increase_time      = 5,    -- seconds it takes to climb
scroll_repeat_ms          = 60,   -- how often it repeats
```

The two `increase` values are in seconds; everything ending in `_ms` is in
milliseconds.

### Timings

`carry_ms` is how long you have, after releasing one direction, to press another
and keep the speed you had built up.

What holds a swipe together is the gap between its presses: leave more than about a
fifth of a second and it becomes two gestures rather than one. That single rule
governs both mashing and the jump-to-edge gesture, and since the jump is asked for
with a modifier rather than a rhythm, there is no tapping speed that can trigger it
by accident.

### The entry chord

`Super + M` is set by an ordinary binding at the top of the block. Moush also needs
to know which keys that chord uses, which lives in `~/.config/omarchy/shell.json`:

```json
{ "id": "moush", "chordKey": ["m", "M"], "chordMods": ["Super_L", "Super_R"] }
```

Moush uses these to tell a tap from a hold, so keep them in step with the
binding if you change it.

One thing to know if you move it. Twelve of Omarchy's forty-three `Super`
bindings do not report a key name, so a combination can look free when it is
already taken; check with `omarchy menu keybindings --print` rather than by eye.
And the chord key must not be one of the keys your layout uses in a session, or it
will click or move while you are trying to exit.

## If something is not working

Clicking and scrolling do nothing, but the pointer moves: `ydotool` is not running.
Check with `systemctl --user status ydotool`.

Keys do nothing at all after editing a layout: run `hyprctl reload`, then check
that the layout name in `modes` has no typo, since `Tab` moves between layouts by
name.

You can ask a running session what it thinks is going on:

```bash
omarchy-shell shell call moush probe ""
```

If the shell itself gets stuck holding the keyboard, `Ctrl + Alt + Escape` restores
your normal bindings.
