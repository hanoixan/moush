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
omarchy plugin add https://github.com/hanoixan/moush --enable
```

That clones the repo, validates the manifest, installs it as `moush`, and turns it
on. Omarchy will warn you first that plugins run unsandboxed inside its shell
process, which is true of every plugin and worth taking seriously: read the source
before you say yes.

**Then give it its keys.** The plugin ships with no bindings of its own, so until
this step nothing responds:

```bash
cat ~/.config/omarchy/plugins/moush/bindings.lua.example >> ~/.config/hypr/bindings.lua
hyprctl reload
```

That file is the whole of Moush's configuration: the chord, both layouts, every
key. It is yours to edit, and Hyprland reloads it on save.

Press `Super` + `M` and a red disc should appear.

### Updating and removing

```bash
omarchy plugin update moush        # fast-forwards, revalidates, rolls back if it fails
omarchy plugin remove moush
```

An update only touches the plugin, never `~/.config/hypr/bindings.lua`, so your
layouts survive it. If a release changes the configuration format, the README will
say so; diff your file against the new `bindings.lua.example` to pick up additions.

### Installing by hand

If you would rather not hand a git URL to the installer, clone it yourself. The
folder has to be named for the plugin id, which is `moush`:

```bash
git clone https://github.com/hanoixan/moush ~/.config/omarchy/plugins/moush
omarchy plugin validate ~/.config/omarchy/plugins/moush
omarchy-shell shell rescanPlugins
omarchy plugin enable moush
```

`omarchy plugin update` still works on a hand-cloned copy, since it is an ordinary
git checkout with a remote.

## Turning it on

`Super + M` starts a session. How long you hold the chord decides how long the
session lasts:

| | starts | ends |
|---|---|---|
| **Tap it** | when you let go | on its own, after `idle_ms` with no input |
| **Hold it** for half a second | right then, before you let go | when you press `Super + M` again |

Tap it for a quick correction and forget about it. Hold it when you are going to be
driving for a while. Either way, `Super + M` always gets you out.

While a session is running, a translucent red disc shows where the pointer is.
Hyprland hides the real cursor as soon as you touch a key, so the disc is what you
aim with.

## The keys

Two layouts ship. `mash` sits under the right hand, `mash_lh` under the left. `F2`
switches between them, and your choice is remembered between sessions and across a
shell restart.

```
mash                        mash_lh

 8 9 0 - =                   2 3 4 5 6
U I O P [     the grid      Q W E R T
J K L ; '                   A S D F G
 M , . /                     Z X C V

space V B     buttons       space B Tab      left, middle, right
H     hold    scroll        CapsLock hold
```

Three keys do the same thing in either layout, so they are set once rather than per
layout:

```
F1   show or hide the display
F2   switch layout

Shift  hold  bigger:  32px a tap, 4x sweep speed, and a swipe goes to the next edge
Ctrl   hold  smaller:  1px a tap, an eighth the sweep speed, and a shorter roll
```

Everything not listed still types normally, so you can keep working with a session
open. A few keys next to the grid are deliberately bound to nothing, so a stray
reach does not spill letters into whatever you were writing.

## Moving the pointer

Eight keys steer. In `mash` they are `I` up, `K` down, `J` left, `L` right, with
`8` `9` `U` `O` for the four diagonals; in `mash_lh`, `W` `S` `A` `D` and `2` `3`
`Q` `E`. The rest of the grid has no direction of its own and does nothing when
tapped alone; those keys exist for mashing.

The two lower diagonals are picked for where the fingers fall rather than for where
the keys sit, so `U` means down-left from a key that is physically up-left. That
only applies to a key struck on its own: inside a sweep every key is just a point
and the direction comes from the gesture, so nothing is inconsistent.

**One tap is a small step.** Eight pixels, or six on each axis for a diagonal.

**Two modifiers change the size of everything.** Hold **Shift** and a tap moves 32
pixels instead of 8. Hold **Ctrl** and it moves one pixel, for when you need to be
exact. Holding both counts as Ctrl.

They scale a held key by the same ratio, so the two mean one thing whether you tap
or sweep. Measured on a 0.4 second hold: 124px plain, 494px with Shift, 12px with
Ctrl.

**You can change your mind mid-sweep.** Press or let go of a modifier while a
direction key is already down and the speed follows immediately, so you can start a
sweep across the screen and ease onto Ctrl as you come up to what you were aiming
for. Measured over the second half of a one-second hold: 482px plain, 1355px once
Shift went down, 73px once Ctrl did. Letting go takes about a quarter second to
register, because nothing announces a modifier being released and it has to be
asked about.

**Holding sweeps, and picks up speed.** The longer you hold, the faster it goes. A
hold of about a second and a half crosses the screen; measured on a 1536-pixel-wide
screen, a 1.5 second hold travelled 1475 pixels. Let go and tap to fine-tune.
Letting go of one direction and pressing another keeps the speed you had built up,
so you can steer a sweep instead of restarting it.

**Hold Shift and swipe to jump to the next edge.** Not a step and not a roll: the
pointer goes straight to the nearest window edge in that direction, however far
away. Shift with `J K` jumps right, with `M I` jumps up, with `L J` jumps left.

The direction is the swipe's own, so this does not depend on any key meaning an
arrow. Shift with `U O` jumps right too, because `U` to `O` points right, even
though neither is a direction key. Any two keys that describe the direction you
want will do.

One jump per swipe, however many keys you cross: Shift with `J K`, `J K L` and
`J K L ;` all land in the same place. To jump again, pause and swipe again, and it
carries on to the next edge each time until it runs out of screen.

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
the way your hand went. Mash `U I O P` left to right and it rolls right. Mash
`I K ,` downward and it rolls down. It reads the direction from the order you hit
the keys, so no single key means anything on its own.

How far it rolls depends on both how far your hand travels and how fast, the way a
trackball does. Measured across a row:

```
keys crossed     slow      medium     fast
                 170ms     110ms      60ms
two                53px     149px     325px
three              53px     262px     388px
four              101px     372px     443px

                 measured at mash_gain 1.0 and mash_vmax 1000, so read the
                 shape rather than the figures: distance grows with both how
                 far the hand went and how fast
```

So a short, unhurried swipe nudges the pointer a little way and a long, quick one
carries it a few hundred pixels, with everything in between available without
thinking about it. Raise `mash_vmax` if you want the fast end to reach further than
that; it is the ceiling the quickest swipes are already pressing against.

Keys struck more than about a fifth of a second apart are treated as separate taps
rather than one gesture, which is what lets tapping and mashing share the same keys
without getting in each other's way.

**A new gesture starts from rest.** Whatever is still rolling stops the moment the
next one begins, so a fresh mash sets the direction outright instead of being
dragged towards the last one, and a direction key moves where you pointed it rather
than fighting the leftovers. Within one gesture nothing changes: successive presses
still build on each other, which is what makes a swipe gather speed.

## Clicking and dragging

In `mash` the buttons are `space`, `V` and `B` for left, middle and right; in
`mash_lh`, `space`, `B` and `Tab`. They sit under the hand that is not mashing. A
button is down while its key is down, so a tap is a click and a hold is a drag.
Hold `space`, sweep across a line of text, and let go, and the text is selected
exactly as a mouse would have selected it. Clicking also focuses whatever window
the pointer is over.

Modifiers reach the application. Hold `Shift` and click, and the click arrives as a
shift-click, extending a selection rather than starting a new one.

## Scrolling

Hold the wheel key -- `H` in `mash` -- and the same direction keys scroll instead
of moving the pointer. The pointer stays where it is.

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

**The modifiers work here too, and they work while you hold them.** Shift asks
straight away for the rate the ramp would otherwise take seconds to climb to, and
Ctrl pins it to the slowest and never climbs. Holding M down for a second and a
half, from the same line each time:

```
plain          27 notches
with Shift    250 notches
```

Over five seconds, where the plain ramp has time to climb, plain sends 263 and Ctrl
sends 84. Press or release a modifier part way through and the rate changes at
once, the same as it does for pointer movement.

For a long document, hold Shift and swipe. Scrolling goes to a hundred times the
base rate at once and stays there while you keep the last key of the swipe down.

**Every direction scrolls one axis.** Up and right both scroll one way, down and
left the other, so whichever keys fall under your fingers the sense is the same.
A swipe scrolls the way the swipe runs, not the way its individual keys point, so
passing over a sideways key on the way up does not push back against you.

## The display

`F1` shows or hides a panel in the top left. It is there to make the layout
legible while you are learning it, or after you have rearranged the keys.

The top row shows every key the layout binds that is not part of the grid, each
under the name of its job, and a key turns red while it is held.

**The heading reads out the speed the last press asked for**, and **the arrow turns
cyan once that passes `mash_vmax`**, which is then named beside it:

```
drive:lsq   137 px/s                    within the ceiling, arrow green
drive:lsq  4200 px/s   at vmax 2000     past it, arrow cyan
```

That is the point beyond which swiping harder changes nothing, so between them
they say whether you are using the range you have or pressing against the ceiling.
The speed is measured before the clamp, so it is what the swipe asked for rather
than what it was given. The grid below
shows your keys where they sit under your hand, lighting up as you strike them and
shading brighter green with how recent each strike was, so you can see the shape of
the gesture you just made. An arrow shows the direction the roll was read as, and a
log along the bottom lists recent keys with the gap between them, and the impulse
each one applied.

Press `F2` and the whole panel redraws for the other layout.

## Making it yours

Everything lives in `~/.config/hypr/bindings.lua`, in one table. Edit it and run
`hyprctl reload`; there is nothing to restart and no other file to touch.

Each layout declares its own keys, so the two can share nothing at all:

```lua
MOUSH = {
  carry_ms   = 175,       -- press a new direction this soon and keep your speed
  coarse_mod = "SHIFT",   -- hold for bigger
  fine_mod   = "CTRL",    -- hold for smaller

  -- Not part of a layout, so set once rather than in each one.
  cycle    = "F2",        -- next layout
  debug    = "F1",        -- show or hide the display

  modes = {
    mash = {
      keys = {
        -- key, then where it sits: x to the right, y downward
        { "8", 0.5, 0 }, { "9", 1.5, 0 }, { "0", 2.5, 0 }, { "minus", 3.5, 0 }, { "equal", 4.5, 0 },
        { "U", 0.0, 2 }, { "I", 1.0, 2 }, { "O", 2.0, 2 }, { "P", 3.0, 2 }, { "bracketleft", 4.0, 2 },
        { "J", 0.0, 4 }, { "K", 1.0, 4 }, { "L", 2.0, 4 }, { "semicolon", 3.0, 4 }, { "apostrophe", 4.0, 4 },
        { "M", 0.5, 6 }, { "comma", 1.5, 6 }, { "period", 2.5, 6 }, { "slash", 3.5, 6 },
      },

      -- which of those also steer when tapped on their own
      dirs = {
        I = "up", K = "down", J = "left", L = "right",
        ["8"] = "upleft", ["9"] = "upright", U = "downleft", O = "downright",
      },

      buttons = { lmb = "space", mmb = "V", rmb = "B" },
      wheel   = "H",        -- hold to scroll
      mouse_arrows = true,  -- arrow keys alias the four steering keys

      -- bound so they do nothing, rather than typing into your window
      inert = { "N", "7", "Y", "G", "backslash", "bracketright" },
    },

    ["mash_lh"] = { ... },
  },
}
```

`dirs` must name keys that are in `keys`. `buttons` and `wheel` must not be, since
a key cannot both be a grid position and do something else -- bind it twice and the
grid wins, silently.

### The grid

The numbers after each key say where it sits. The only rule is that x grows to the
right and y grows downward, matching the screen. Beyond that the units are yours:
the shipped layouts count in key widths, with the number and bottom rows set half a
key across from the two in the middle, which is close enough to the real stagger to
feel right under the hand. An ortholinear keyboard would use whole numbers with no
offset at all. Larger or smaller numbers work too, as long as you are consistent.

Only keys in `dirs` steer on their own. Leave a key out of `dirs` and it is purely
part of the grid.

**The arrow keys stand in for the four cardinal steering keys**, unless a layout
sets `mouse_arrows = false`. They are aliases rather than a second set of
bindings: pressing `Left` *is* pressing whichever key `dirs` maps to `left`, with
the same step, the same sweep when held, the same place in a mash. Measured, a
gesture ending on the up key and the same gesture ending on the up arrow roll
identically.

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

Add another entry under `modes`. `F2` cycles through them in alphabetical order.

### How mashing feels

```lua
mash_gain    = 0.25,   -- how hard each key press shoves the pointer
mash_vmax    = 2000,   -- its top speed, which sets the longest roll
mash_samples = 4,      -- how many recent presses the direction is read from
```

`mash_gain` is the one to reach for, and it is worth understanding, because it
decides whether swiping faster does anything at all.

Each press adds speed, growing steeply with how fast you swipe, and the ball is
then capped at `mash_vmax`. Set the gain high and even a leisurely swipe is already
past the cap, so every swipe travels the same distance and swiping harder changes
nothing. Set it low and the whole range fits under the cap, so speed comes through.
The same four-key swipe, measured at three speeds:

```
gain    slow     medium   fast     spread
        170ms    110ms    60ms
20       521px    519px    433px   1.2x   speed does nothing
 2       104px    510px    469px   4.9x   only the slowest is distinct
 0.5      60px    226px    427px   7.1x   responds across the range
 0.15     42px     79px    230px   5.5x   responsive, but short
 0.05     16px     41px     84px   5.2x   too short to cross a screen
```

Those figures were taken at `mash_vmax` 1000; the shape is what matters rather than
the exact pixels. The point is that a high gain throws the whole range above the
cap, where swiping harder changes nothing, and a low one keeps the range underneath
it where speed comes through.

`mash_vmax` is the ceiling itself, and so the longest possible roll: a press cannot
carry further than roughly `mash_vmax / 3` pixels. Raise it along with the gain if
you want the fast end to reach further.

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

`idle_ms` is how long a tapped session survives with nothing pressed. It ships at
1500. A session opened by holding the chord is latched and ignores it entirely.

What holds a swipe together is the gap between its presses: leave more than about a
fifth of a second and it becomes two gestures rather than one. That single rule
governs both mashing and the jump-to-edge gesture, and since the jump is asked for
with a modifier rather than a rhythm, there is no tapping speed that can trigger it
by accident.

### The entry chord

`Super + M` is three settings at the top of the table, and they have to agree:

```lua
chord_mods    = { "Super_L", "Super_R" },
chord_key     = { "m", "M" },
chord_hl_bind = "SUPER + M",
```

`chord_hl_bind` is what Hyprland acts on, handed straight to the binding at the
bottom of the block. The other two are the same keys written as X keysyms, which is
how Moush tells a tap from a hold: it asks whether the chord is still down, and
Hyprland will not report a release for this kind of binding.

Either list may hold several syms and any one counts, which is how both Super keys
and the shifted letter are covered. Set `chord_mods` to `{}` for a bare key. Edit,
save, and the next `hyprctl reload` has it; nothing else to restart.

If the keysyms disagree with the binding, the chord still opens a session but Moush
is asking about a key that is never down, so it never sees the chord released and
every session latches.

Two things to know if you move it. Twelve of Omarchy's forty-three `Super`
bindings do not report a key name, so a combination can look free when it is
already taken; check with `omarchy menu keybindings --print` rather than by eye.
And the chord key must not be one of the keys your layout uses in a session, or it
will click or move while you are trying to exit.

**Caps Lock is free, but has to be bound by keycode.** Omarchy sets
`kb_options = compose:caps`, so that key emits `Multi_key`, and a binding written
as `SUPER + Caps_Lock` registers and then never fires -- measured, six presses, no
session. By keycode it behaves like any other key:

```lua
chord_mods    = { "Super_L", "Super_R" },
chord_key     = { "Caps_Lock", "Multi_key" },
chord_hl_bind = "SUPER + code:66",
```

Tapping it opened and closed a session six times out of six, holding it latched,
and typing afterwards was unaffected, so the compose mapping costs nothing here.

### Where a keycode works, and where it does not

`code:NN` binds like any other key, so it is fine for `inert`, for `cycle` and
`debug`, and for a grid position in `keys`.

It is **not** fine for `wheel`, for `buttons`, or for any key named in `dirs`.
Those are the ones Moush has to ask about while they are held, because Hyprland
reports no release for them, and the question only takes a keysym:
`hl.is_key_down("code:66")` answers nothing at all, so the key reads as released
the instant it is pressed. A `wheel` set to a keycode turns scroll mode off again
within a tenth of a second.

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
