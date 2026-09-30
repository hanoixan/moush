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

**A button follows its key: down while held, up when let go.** A tap is therefore
a click and a hold is a drag, which is what selecting text needs. Sending a
complete click on press could never drag — by the time the pointer moved, the
button was already back up.

```
tap 8            btn=0 shortly after            down then up: a click
hold 8, move     btn=1 throughout, cur 700->732 the button stays down
release          btn=0
exit while held  btn=0                          never stranded
```

Like every other held key it is polled rather than waited on, and a button that
has claimed to be down for longer than `btnMaxMs` is let up regardless — a lost
release must not leave the pointer dragging everything it touches.

**Shift and Ctrl are yours, not the plugin's.** Every key is bound with
`ignore_mods`, so it reaches the plugin whatever modifiers are held — and those
modifiers then ride along on the pointer events the plugin injects. So
`Shift`+scroll is horizontal scrolling and `Ctrl`+scroll is zoom, in whatever app
is underneath, and `Shift`+click extends a selection. Measured: the client sees
`mods=33554432` (Shift) and `mods=67108864` (Ctrl) on the injected events.

**Re-tapping a scroll key within `fast_tap_ms` (135ms)** sends
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
  fast_tap_ms = 135,   -- re-press the same key quicker than this to double-tap
  carry_ms    = 175,   -- press a direction this soon after another to keep its speed
}
```

`fast_tap_ms` must stay under `input:repeat_delay` (250ms), or a held key's first
auto-repeat would read as a deliberate re-press. The two are independent and start
out equal only by coincidence.

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

### mash — a trackball made of keys

`mash` is a fourth keymap with a different idea behind it. Instead of a key per
direction, the keys form a grid under your right hand, and mashing across them
rolls the pointer the way dragging a finger rolls a trackball.

```
 7 8 9 0 -          7 (held) wheel mode     tab  next keymap
Y U I O P [         8 9 0   left/middle/right click
 H J K L ; '        - (held) 1px steps      `    the debug display
  N M , . /         z       next strategy   5 6 R T F G V B a s d w  inert
```

Everything else passes through, so typing still works.

**Eight of the grid keys double as directions.** Struck alone, a key steers with
the arrow keys' own model behind it — `baseStep`, acceleration while held, edge
snapping, and a double-tap that skitters to the next edge. Struck as part of a
sweep it is a point in space again.

```
  U  I  O      up-left    up     up-right
  J  .  K      left              right
  N  M  ,      down-left  down   down-right
```

```
lone I                        (  +0,  -8)   a step, snapping to an edge
lone U                        (  -6,  -6)   diagonal, normalised
I then U                      (-299,  -8)   two keys: it was a sweep
I I fast                      (  +0,-462)   double-tap: skitter
hold I for 0.9s               (  +0,-500)   accelerating sweep
```

They cannot be separately bound as direction keys — Hyprland fires one dispatcher
per key, and these are already grid keys — so the plugin decides per press. Only
two cases are settled before the mash machinery sees the press: a repeat, which
sustains a sweep, and the same key struck twice quickly, which skitters. Everything
else goes through as a normal press, so the cluster stays honest and a sweep that
opens with a direction key keeps its first point.

**Diagonals snap on both axes.** A press lands on the nearest edge to the left
*and* the nearest above; a double-tap runs both to their limits, which is the
corner. The cardinal path cannot express that — it picks one axis and ignores the
other — so diagonals take their own route through `moveStep`. They do not cross
off-screen: leaving by a corner has no single direction to hand the compositor.

**Held, `-` makes every step one pixel** instead of `baseStep`, for placing the
cursor exactly. It applies to the discrete step, not to the speed of a sweep. Like
the wheel key it is polled rather than waited on, since a release is not reliably
delivered.

**The grid is a binding, not code.** Each position is an action named
`m<x4>_<y>` — row `y`, column `x4` in quarter-key steps — so `bindings.lua` says
which physical key sits at which grid point, and the plugin only ever reads
coordinates out of the action name. Re-measuring the grid for a differently
staggered keyboard is an edit there and nothing else.

x is in quarters because the real stagger is not uniform. The number row sits half
a key right of `YUIOP`, and `HJKL` and `NM` are a further quarter right again:

```
 7 8 9 0 -      +0.50 keys
Y U I O P [     +0.00
 H J K L ; '    +0.25
  N M , . /     +0.75
```

Quartering keeps a column step and a row step the same distance, so the grid
measures the way it feels under the hand rather than the way it is easiest to
type out.

**The fit sees the last `mash_samples` (4) presses.** Older ones drop out, so a
long mash steers by what your hand is doing now rather than by an average over the
whole gesture. `cpa` keeps three subvectors to match, since five events make three
overlapping triples.

```
presses in cluster   2   3   5   6   8
window               2   3   5   5   5
cpa subvectors       0   1   3   3   3
```

**The overlay shows exactly those presses and no more.** A key that has aged out
of the window goes back to looking untouched, and the green timing shade
renormalises over what remains, so the grid always depicts what the fit is
actually working from rather than the whole gesture. Mashing `Y U I O P [ H J`
with `mash_samples = 5` leaves `O P [ H J` lit and `Y U I` dark; at 3 only
`[ H J` remain.

**Presses are grouped into clusters, and a fit never spans two.** A gap longer
than `mashClusterMs` (200ms) ends the gesture, and the next press starts a fresh
cluster with nothing carried over. Without that, two sweeps either side of a pause
were fitted together and produced a direction belonging to neither. The cluster bounds what a fit may see; the five-press window above bounds it
further.

```
presses 52ms apart   -> cluster = 4     one gesture
presses 140ms apart  -> cluster = 1     each press starts its own
```

**Which strategy turns presses into a direction is configurable**, because there
is no obviously right answer and they are easy to compare. All five read the same
press trail and return one velocity in key-widths per second:

| | how it decides | character |
|---|---|---|
| `cpa` | fits each three presses to the axis where the two velocities are most equal and largest, then averages those | the original; smooths curvature without ignoring it |
| `lsq` | least squares of position against time — the slope *is* the velocity | steadiest all-rounder, one stray key barely moves it |
| `net` | first press to last, over elapsed time | calmest; blind to the path between, slowest to turn |
| `pca` | dominant axis of the positions, speed from distance *along* it | the only one that reads mashing back and forth on one line as motion; the others average it to nothing |
| `ewma` | every hop's own velocity, newest weighted most | turns fastest, twitchiest, no hard window edge |

All of them steer from the **second** press of a cluster except `cpa`, which cannot
start before the third: a subvector compares the two velocities inside a triple,
and two presses give only one. Until a strategy has enough to work with, a press
moves the cursor by the `mashStepPx` floor and nothing more.

```
                cpa    lsq    net    pca    ewma
2 presses        1px   324px  376px  410px  366px
3 presses      569px  1135px    -   1135px    -
```

```lua
MOUSEKEYS = {
  mash_strategy = "lsq",                        -- steers the pointer
  mash_gain = 20,                               -- how hard each press shoves it
  mash_vmax = 1000,                             -- ceiling, and so the longest throw
  mash_samples = 4,                             -- presses a fit may see
  mash_debug_strategies = "cpa,lsq,pca,ewma",   -- also drawn, for comparison
}
```

`mash_gain` is the one dial worth reaching for when mash feels too eager or too
sluggish: the impulse is `mash_gain * speed^3`, so a press carries
`mash_gain * speed^3 / 3` pixels once friction has run out. Being cubic, a change
here is felt hardest at the fast end — halving it barely alters a slow nudge but
takes a long way off a burst.

An unrecognised name is ignored rather than breaking the mode. Measured on the
same four-press run across a row, they land within about 12% of each other
(`ball` 1189–1355 px/s), so any of them is usable; the differences show up in
how they handle curves, reversals and stray keys rather than in raw speed.

**Direction comes from a fit over the last three presses** — this is `cpa`, the
default. With
`a = (p₂-p₁)/Δt₁` and `b = (p₃-p₂)/Δt₂`, pick the unit `u` maximising
`(a·u)(b·u)`. For a given sum a product peaks when its terms are equal, so this
asks for the direction along which the two velocities are as *equal* — and as
*large* — as possible, in one term. It is the principal eigenvector of
`(abᵀ+baᵀ)/2`: one `atan2`, no iteration.

Asking only for equal velocities does not work, and the failure is quiet. A mash
straight right that speeds up projects to 10 and 20 along x, but to **0 and 0**
along y — perfectly equal, and motionless. Uniformity alone always picks the
perpendicular, and the ball never moves. Multiplying rejects it: any direction
with no motion along it scores zero.

The subvector's length is the mean of those two projected velocities — the speed
along the fitted axis, ignoring sideways scatter. The subvectors of the current
cluster are averaged, weighted by length, into one drive vector,
so longer hops count for more and a mash that reverses cancels itself out.

#### Nudging

A lone tap is not a swipe. `mash_nudge` turns one into a **nudge**: a small push
away from the middle of the grid, for the last few pixels rather than for
travelling. Two rings say how far.

```
   7  8  9  0  -        outer ring, mash_nudge_outer (5px)
  Y  U  I  O  P  [      I O inner (1px), Y [ outer, U P between
   H  J  K  L  ;  '     K L inner,       H ' outer, J ; between
    N  M  ,  .  /       outer ring
```

A key *on* a ring pushes that ring's distance exactly; only keys between the rings
interpolate, by how far out they sit. Going by radius alone would shortchange the
ring members — the outer ring is not a circle, and its top and bottom middles sit
well inside the mean radius, so `9` would push 3.2px where `-` pushes 5.

The direction is from the centre of the inner ring through the key, so the grid
works like a dial: the further out you tap, the further it goes.

```
key     ring      moved      distance
I       inner     (-1,-1)     1.41px
O       inner     (+1, 0)     1.00px
U       between   (-4,-1)     4.12px
7       outer     (-4,-3)     5.00px
Y       outer     (-5,-1)     5.10px
```

**Held rather than tapped, a nudge repeats** — the same push over and over, so the
grid can be leaned on for a longer adjustment. The first repeat waits
`mash_nudge_delay_ms` (250ms), as a held key does, so a slow tap is still exactly
one nudge; after that it goes every `mash_nudge_rate_ms` (90ms).

```
quick tap on 7        moved (-4,-3)            one nudge
hold 7 for 1.2s       (-12,-9) -> (-82,-58)    repeats, stops on release
repeat off, hold O    moved (+1,-1)            one nudge only
```

Each repeat is confirmed by asking whether that key is still down, rather than
assumed until a release arrives — the same reason the grip polls. A repeat is the
same key still held, not a new press, so it does not enter the cluster or disturb
what a fit would see.

The nudge fires on the opening press of a cluster rather than waiting to confirm
the tap stayed alone — waiting would put 200ms of delay on the one gesture that
exists to be precise. A sweep that follows keeps the pixel or two already pushed,
which vanishes into it, and clears the marking on its next press.

In the debug view a nudged key goes **red**, with a green vector from the ring
centre out to it: the push actually applied, unlike the drive vector, which is a
direction drawn from the grid's centre.

**A finger still on a key is a hand still on the ball.** If a swipe ends without
lifting every key, the ball is *gripped*: the cursor stops, and the momentum bleeds
away rather than being stored. Letting go does not resume the swipe.

Grip friction (`mashGripFriction`, 12 e-folds/second) is well above rolling
friction, because holding on is meant to stop the cursor rather than slow it
gently — a couple of hundred milliseconds leaves nothing to continue with.

```
gripped   +0.35s x=307  grip=true   ball=2,0
          +1.05s x=307  grip=true   ball=0,0       stopped, momentum gone
released  +1.05s x=307  grip=false  ball=0,0       +0px: the swipe is over
```

This is polled rather than driven by key releases, because a release cannot be
relied on: once two bound keys are held Hyprland delivers neither key's release,
and a missed one would leave the ball gripped for the rest of the session. The poll
starts only once the ball has been rolling quietly for `holdCheckMs` (50ms) — not
on every press, which would cost a subprocess per tap — so there is a brief glide,
bounded by that plus the round trip, before the grip takes hold.

**The ball.** Each press adds an impulse along the drive direction and friction
bleeds it away: `v += u·mash_gain·speed³`, then `v *= e^(-friction·dt)`, capped at
`mashVMax`. Total distance from one impulse is `v/friction`, so friction sets how
long a throw lasts without changing how far it goes — the gain decides that.

Direction passes through unscaled. Both grid axes are in key widths, so a 45° mash
gives 45° on screen with no aspect correction: crossing the wider screen dimension
takes correspondingly more mashing.

Measured on four-press runs, the impulse tracks the cube of the mash rate and runs
a little steeper still, because faster presses also decay less between each other:

```
gap    speed      predicted s^3   measured ball
 60ms  16.7 kw/s         27.0x           40.7x
 90ms  11.1 kw/s          8.0x           11.6x
130ms   7.7 kw/s          2.7x            3.1x
180ms   5.6 kw/s          1.0x            1.0x
``` The exponent is
steep because the two ends of the scale are far apart: a press at two per second
should nudge a single pixel, a four-press burst should cross the screen.

```
slow, ~2 presses/sec   +1px per press          (the mashStepPx floor)
fast, 4 presses/180ms  0 -> 1535px, clamped    (~one screen width)
vertical mash 7 Y H N  y 100 -> 863            (down, as struck)
5 R F V                no movement at all      (inert)
```

Every press moves at least `mashStepPx` (1px), the way every press elsewhere
moves at least `baseStep`. Slow mashing lives entirely in that floor: at two
presses a second the impulse works out to about a tenth of a pixel, which would
round away to nothing.

**Holding `7`** turns the whole mode into a wheel: the larger component of the
motion picks the axis, so a mostly-vertical gesture scrolls the page and a
mostly-horizontal one scrolls sideways. The pointer holds still while it is down.
That covers all three ways of moving — a direction press is worth a detent
outright, a double-tap runs to the end of the view, and a sweep's travel
accumulates into detents. A discrete press is given its own detent because
accumulating an 8px step against a detent's 90 would take a dozen presses to move
the page once.

**Held, a direction key repeats, and the repeats grow.** Flat at
`scroll_repeat_scale_min` for `scroll_increase_delay`, then ramping to
`scroll_repeat_scale_max` over `scroll_increase_time`, then flat again — so the
same key serves a line and a page.

```lua
scroll_repeat_scale_min = 1,     -- detents per repeat to begin with
scroll_repeat_scale_max = 10,    -- and once the ramp has run out
scroll_increase_delay   = 1.5,   -- seconds flat before it starts
scroll_increase_time    = 5,     -- seconds the ramp takes
scroll_repeat_ms        = 60,    -- between repeats
```

The two ramp timings are in **seconds**, unlike the `_ms` settings elsewhere.

**Struck twice and kept down, a vertical key skips the ramp** and starts at
`scroll_repeat_scale_ultra` (100) at once, holding there until released — for
crossing a long document in one gesture. Only `I` and `M`: a document is long, not
wide, so the sideways keys keep their end-of-view double-tap instead.

```
single press + hold I    scale 1.00 -> 5.72     the ordinary ramp
double-tap + hold I      100.00 immediately     ~1800 detents/sec
double-tap + hold K      scale 1.00 -> 5.52     sideways: no ultra
```

```
   t     +reps  +detents  det/rep  scale
 1.2s      15        15     1.0     1.00   flat through the delay
 2.3s      19        27     1.4     2.42   ramping
 3.5s      20        69     3.5     4.52
 5.9s      19       151     7.9     8.95
 7.1s      19       185     9.7    10.00   capped
 9.3s      18       180    10.0    10.00
```

The repeats are the plugin's own, not the compositor's. Hyprland stops repeating a
key once a second bound key is held, and in wheel mode `7` always is — so a
key-repeat ramp produced exactly one detent and then nothing, while the scale went
on climbing against a clock. The release is polled for the same reason.

Fractional scales are carried rather than dropped, so a scale under 1 still
scrolls eventually and the ramp climbs smoothly instead of in visible steps.

`7` has no dependable release, so it is polled — and the poll must be told which
key to ask about. When the wheel moved from `w` to `7` the binding moved but the
published keysym did not, so the poll asked whether `w` was down, found it was not,
and switched wheel mode off within 70ms of every press. The symptom was that
holding the key appeared to do nothing at all.

Two things this needed that were not obvious. The press history has to outlive the
ball: stopping the ball used to clear it, and since a slow mash's first impulses
stop the ball almost immediately, that erased the very presses a fit needs, so no
direction could ever be computed. And the two-press fallback, used before a fit
exists, yields a *direction* only — its length is a distance in key widths, and
feeding that to a formula expecting key widths per second throws the ball at an
arbitrary speed.

#### Seeing what mash is thinking

While mash is the active keymap, a debug display sits in the upper left. It is on
by default and **backtick** toggles it. **`z` switches which strategy steers**,
cycling through the ones being drawn so the new one is always on screen to compare
against, and the legend highlights it. That is a live experiment rather than a
setting: the next session takes its strategy from `mash_strategy` again.

```
- subvector  - drive  - ignored          legend, in the colours below

  7  8  9  0  -                          the grid as it sits under your hand;
 Y  U  I  O  P  [                        struck: white on a grey shaded green
 H  J  K  L  ;  '                        by when in the cluster it was struck;
  N  M  ,  .  /                          untouched: black on grey, receding

        \|/                              vectors, drawn from the grid centre
         *                               because they are directions, not places
```

Yellow is a subvector, green the drive vector actually steering the pointer, red
a fit that was rejected and contributed nothing.

**Subvectors start at the first key of the triple they were measured from**, so
each sits on the stretch of the gesture it describes and the chain of them traces
the path the hand took. They are drawn at half opacity: there is one per press,
and they are working detail rather than the answer, so they should not crowd out
the drive vector. Only the aggregates — the drive vector and the strategies —
radiate from the grid centre, since those are directions rather than places.

**Keys are shaded by their timing within the cluster**, from dark grey at the
start of the gesture to bright green at the most recent press, by
`(t - t_first) / (t_latest - t_first)`. The rhythm then reads straight off the
grid: an even sweep shades evenly, and a burst that stalled leaves a visible cliff
between two neighbouring keys.

```
struck  Y     U     I     O     P
dt ms   -     19    19    111   142
normal  0.00  0.07  0.13  0.51  1.00
        dark  .............green....  three quick, then two laboured
```

**The whole grid re-shades on every press**, because the span it normalises
against grows with the cluster. The newest key is always at full green and the
rest slide back toward grey behind it, so the picture is live from the first press
rather than only resolving once the gesture is over.

A key struck twice shades by its later strike. A cluster of one has no span to
divide by, and its only key is also its most recent, so it reads as fully green.

**The graphic holds one cluster and does not fade.** It shows the most recent
cluster and keeps showing it, so a gesture can be studied after it has finished
rather than disappearing while you look at it; the next cluster clears the panel
and draws itself instead. The log below is the exception — it spans clusters, and
the gap that ended one shows up there as a large delta. 

**Every strategy in `mash_debug_strategies` is drawn too**, whether or not it is
the one steering, so they can be read against each other live. A colour key along
the bottom of the panel says which is which, greying out any that has produced
nothing to draw.

Colour and dash come from a strategy's place in the canonical list rather than
from a hash of its name. Hashing gave no guarantee that two would not land on
near-identical hues, which is the one thing this must not do; an index gives each
an evenly spaced slot, with a name-derived jitter *inside* its own slot so the
palette does not read as a plain rainbow while no two slots can ever touch. The
five are 57° apart at the closest. A strategy keeps its colour whichever subset is
drawn.

Labels on the vectors themselves were tried first and removed: they collided
precisely when the strategies agreed, which is when telling them apart matters
most. Staggering them along the ray and across it helped but never fully fixed it,
and the key along the bottom does the job without cluttering the vectors.

The red is the reason this is worth having. A reversal — `L K L`, say — fits to
an axis with *exactly no motion along it*, so it steers nothing. Without the
display that is invisible: the ball simply does not respond and there is nothing
to look at. It also caught a real bug. Such a fit comes back as `1e-15` rather
than `0`, which passed a bare `v > 0` and was recorded as a valid contribution
that happened to move nothing — visible in the display as a vector that was
never drawn, because its length was zero. Hence `mashMinSpeed`: a fit has to
carry real speed to count, and anything below it is drawn red and ignored.

**An event log runs along the bottom**, newest first, up to 20 entries: which key
was struck and how many milliseconds since the one below it. Unlike everything
else on the panel it does not fade — entries stay until pushed out — because its
job is to be read after the fact.

```
key  dt ms  imp px/s
P    146    529        laboured, so barely a shove
O    105    1800
I     20    37500      mashed hard: far past the 8000 px/s cap
U     20    37500
Y     -     -          first press: nothing to measure, nothing to fit
```

The third column is the impulse that press applied, `mash_gain * speed³`. Reading
it against the `dt` beside it is the quickest way to see why a burst threw the
cursor as far as it did — and to spot the cubic saturating: past about 25
key-widths/second a single press already exceeds `mashVMax`, so mashing harder
stops adding anything. A dash means the press drove nothing, either because the
strategy had too few events yet or because its fit came back degenerate.

A stray null key is logged too, so a gap in the deltas is explained rather than
mysterious:

```
·    201     inert, but it happened
```

Strays are logged in orange rather than skipped. A null key does nothing to the
model, so without a row of its own it would show up only as an unexplained gap
between two deltas.

The panel's backdrop is fully opaque. At 96% the bright text underneath still read
through clearly enough to fight with the log, and a debug overlay is worth more
legible than see-through.

The key names come from `bindings.lua`, which publishes the grid's labels next to
the keys themselves, so a re-measured grid labels itself correctly with no change
here.

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

**The handover survives letting go**, for `carry_ms` (175ms). Requiring the old key
to still be down meant releasing it a moment early threw the speed away: the new
key took one `baseStep` and then nothing moved until its first auto-repeat landed
250ms later. The window is measured from the last key *event* proving a direction
was down — a press or a repeat — rather than from the motion tick, which runs
`repeatGapMs` past the final repeat and would stretch the window by that much.
What carries over is the speed as it stands at the new press, not as it was at
release, since `h` decays across the gap.

```
hold Right 1.0s (h≈0.93, ~1275px/s), release, wait, then one press of Down:
  gap seen by the plugin     8   50   86  122  148 | 176  219 ms
  carried                  yes  yes  yes  yes  yes |  no   no
  travel from that press       107..462px          |    8px
```

The gap is the one the plugin measured, not the one asked for: harness timing could
not set it reliably, so `probe()` reports what each press actually saw. Travel
varies across the carried cases because the cursor clamps at a screen edge part way
through some of them; the decision is the thing being measured.

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
| **double-tap** — same key re-pressed within `fast_tap_ms` (135ms) | unbounded | skitters to the next edge however far away |

An edge is stored as **the last pixel inside its window**, not the exclusive
bound. A window at `x=12 w=734` covers `12..745`, so its right edge is `745`; the
snap target is never `746`. This matters because `746` is *outside* the window —
resting there puts the pointer over whatever is behind, so a double-tap down
inside a floating window came to rest one row below it and focus fell through to
the window underneath. Keeping edges inside their own window means a landing is
always over the window whose edge it is, which is what lets focus follow with no
special cases. Doing it at collection time is also why the search needs no
adjustment: the stored coordinate is already the reachable one, so "strictly
ahead" keeps making progress by itself.

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

  Which window that is comes from **the cursor's own position first**, because
  what gets focused has to be what the pointer is visually over — that is where a
  click will land.

  Only when the cursor sits over *nothing* does the direction of travel decide,
  probed one pixel along it. Since edges are last-pixel-inside coordinates, that
  now only happens in genuinely empty space — the strip above every window, or a
  gap the screen bound falls in — so it is a fallback rather than the main path.

  Probing the nudge *first* is wrong, and was: a short floating window's top edge
  is already inside it, so nudging upwards escaped to the tiled window behind and
  focused something the pointer was not over.

  Focus has to be set explicitly; moving the pointer is not enough. Omarchy runs
  `input:follow_mouse = 1`, but that acts on real pointer motion, not on a
  dispatcher warp: a cursor parked deep inside another window by
  `hl.dsp.cursor.move` leaves focus where it was. Measured both ways.

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

**Focus is re-resolved once the pointer has landed.** The landing is correct
relative to the window crossed into, but the pan that revealed it slid that window
*underneath* anything floating, which does not pan with the row — so the pointer
can come to rest over a float while focus sits on the tiled window behind it.
Observed: crossing right put the pointer at `790 + 30 = 820`, inside a float
spanning `733..1532`, with focus left on the tiled window. Re-resolving at the
final position settles in one further pass, since the second attempt finds the
window it just focused and stops.

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
  sweep, so only the 55–135ms band can count as fast tapping.
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

- **Two keys held at once needs the compositor asked directly.** Hyprland cancels
  key repeat when *any* key is released and never hands it back to a key still
  held, so pressing Right, then Left, then releasing Right stopped the cursor dead
  even though Left was still down — `is_key_down` confirmed it was. Release binds
  are no help: measured, once two bound keys are held, *neither* key's release
  bind fires, and a held set built from them silently never empties. So when
  repeats lapse the plugin asks `hl.is_key_down` which direction keys are down,
  and either sustains the sweep or hands it to whichever direction is still held.

  The question is evaluated in `bindings.lua`, which publishes its key table for
  the purpose, so keysyms stay out of the plugin: `is_key_down` wants exact X
  spellings — `Left` where the bind says `LEFT`, `i` where it says `I` — and
  answers nil for anything it does not recognise. The reply names actions, like
  everything else here.

  The poll is armed `keysArmMs` before a hold would lapse, which never happens
  during an ordinary sweep: repeats arrive every 25ms and push the deadline 55ms
  out, so the margin is never crossed while they keep coming. It costs nothing
  until repeats actually stop.

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
