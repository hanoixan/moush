import subprocess, html, re

def settings(m):
    t = subprocess.run(["hyprctl","repl",'return MOUSH_SETTINGS("%s")'%m],
                       capture_output=True, text=True).stdout
    return {k:v for k,v in (tok.split("=",1) for tok in t.split() if "=" in tok)}

SRC = open("/home/user/.config/omarchy/plugins/moush/implementation.lua").read()
def inert(mode):
    blk = SRC[SRC.index('["%s"]'%mode if mode!="mash" else "    mash = {"):]
    m = re.search(r'inert\s*=\s*\{([^}]*)\}', blk)
    return re.findall(r'"([^"]+)"', m.group(1) if m else "")

# ---- keyboard geometry: US ANSI, widths in key units -----------------------
# Widths in key units. Every row totals 18.5 so the columns line up, with the
# arrow cluster tucked into the right-hand 3.5 the way a compact board does it.
ROWS = [
 [("Escape","esc",1.0),("","gap",1.0)] + [("F%d"%i,"f%d"%i,1.0) for i in range(1,13)] +
   [("","gap",3.5)],
 [("grave","`",1.0)] + [(str(d),str(d),1.0) for d in [1,2,3,4,5,6,7,8,9,0]] +
   [("minus","-",1.0),("equal","=",1.0),("BackSpace","⌫",2.0),("","gap",3.5)],
 [("Tab","Tab",1.5)] + [(c,c,1.0) for c in "QWERTYUIOP"] +
   [("bracketleft","[",1.0),("bracketright","]",1.0),("backslash","\\",1.5),
    ("","gap",3.5)],
 [("Caps","Caps",1.75)] + [(c,c,1.0) for c in "ASDFGHJKL"] +
   [("semicolon",";",1.0),("apostrophe","'",1.0),("Return","Enter",2.25),
    ("","gap",3.5)],
 [("Shift_L","Shift",2.25)] + [(c,c,1.0) for c in "ZXCVBNM"] +
   [("comma",",",1.0),("period",".",1.0),("slash","/",1.0),("Shift_R","Shift",2.75),
    ("","gap",1.25),("Up","↑",1.0),("","gap",1.25)],
 [("Control_L","Ctrl",1.25),("Super_L","Super",1.25),("Alt_L","Alt",1.25),
  ("space","Space",6.25),("Alt_R","Alt",1.25),("Super_R","Super",1.25),
  ("Menu","Menu",1.25),("Control_R","Ctrl",1.25),("","gap",0.5),
  ("Left","←",1.0),("Down","↓",1.0),("Right","→",1.0)],
]
ARROW_KEY = {"up":"Up","down":"Down","left":"Left","right":"Right"}
ARROW = {"up":"↑","down":"↓","left":"←","right":"→",
         "upleft":"↖","upright":"↗","downleft":"↙","downright":"↘"}

def roles_for(mode):
    d = settings(mode)
    grid, labels = {}, {}
    for e in d["keys"].split(","):
        f = e.split(":")
        if len(f)==4: grid[f[1]] = f[0]; labels[f[0]] = f[1]
    dirs = {}
    for e in d.get("dirs","").split(","):
        if ":" in e:
            i,dn = e.split(":")
            if i in labels: dirs[labels[i]] = dn
    r = {}
    for k in grid: r[k] = ("grid", "grid")
    for k,dn in dirs.items(): r[k] = ("steer", ARROW[dn])
    r[d["lmb"]] = ("btn","left click"); r[d["mmb"]] = ("btn","middle click")
    r[d["rmb"]] = ("btn","right click")
    r[d["wheel"]] = ("wheel","hold: scroll")
    r[d["debug"]] = ("glob","overlay")
    r[d["cycle"]] = ("glob","switch layout")
    if d.get("mouse_arrows") == "true":
        for k, dn in dirs.items():
            if dn in ARROW_KEY: r[ARROW_KEY[dn]] = ("steer", "= " + k)
    for k in inert(mode): r[k] = ("inert","blocked")
    for k in ("Shift_L","Shift_R"): r[k] = ("mod","coarse")
    for k in ("Control_L","Control_R"): r[k] = ("mod","fine")
    for k in ("Super_L","Super_R"): r[k] = ("chord","+M exits")
    return r

def keyboard(mode):
    r = roles_for(mode)
    out = ['<div class="kb">']
    for row in ROWS:
        out.append('<div class="kbrow">')
        for name, lab, w in row:
            if name == "":
                out.append('<div class="kgap" style="flex:%g"></div>' % w); continue
            role, note = r.get(name, (None,None))
            cls = "key" + (" r-"+role if role else "")
            cls_note = "note alias" if (note or "").startswith("= ") else "note"
            sub = '<span class="%s">%s</span>' % (cls_note, html.escape(note)) if note else ""
            out.append('<div class="%s" style="flex:%g"><span class="cap">%s</span>%s</div>'
                       % (cls, w, html.escape(lab), sub))
        out.append('</div>')
    out.append('</div>')
    return "\n".join(out)

# ---- the Atari-style hero ---------------------------------------------------
FONT = {
 "M":["10001","11011","10101","10001","10001","10001","10001"],
 "O":["01110","10001","10001","10001","10001","10001","01110"],
 "U":["10001","10001","10001","10001","10001","10001","01110"],
 "S":["01111","10000","10000","01110","00001","00001","11110"],
 "H":["10001","10001","10001","11111","10001","10001","10001"],
}
def title(x0,y0,px,colour):
    out=[]
    for li,ch in enumerate("MOUSH"):
        for ry,rowbits in enumerate(FONT[ch]):
            for cx,bit in enumerate(rowbits):
                if bit=="1":
                    out.append('<rect x="%g" y="%g" width="%g" height="%g" fill="%s"/>'
                               % (x0+(li*6+cx)*px, y0+ry*px, px, px, colour))
    return "".join(out)

ORANGE, CYAN, GREEN, YELLOW, GREY = "#d87f33","#4fc3c9","#6cc24a","#e0c341","#555"
def hero():
    s=['<svg class="hero" viewBox="0 0 160 112" preserveAspectRatio="xMidYMid meet">']
    s.append('<rect width="160" height="112" fill="#000"/>')
    # HUD: score blocks
    for i in range(6):
        s.append('<rect x="%d" y="5" width="4" height="6" fill="%s"/>' % (8+i*6, ORANGE if i<4 else "#222"))
    for i in range(6):
        s.append('<rect x="%d" y="5" width="4" height="6" fill="%s"/>' % (116+i*6, CYAN if i<2 else "#222"))
    s.append(title(50, 18, 2, ORANGE))
    # playfield: two windows the pointer crosses between
    s.append('<rect x="12" y="44" width="58" height="52" fill="none" stroke="%s" stroke-width="2"/>'%CYAN)
    s.append('<rect x="90" y="44" width="58" height="52" fill="none" stroke="%s" stroke-width="2"/>'%GREEN)
    for i in range(5):
        s.append('<rect x="16" y="%d" width="%d" height="3" fill="#1b3a3d"/>'%(52+i*8, 38-i*4))
        s.append('<rect x="94" y="%d" width="%d" height="3" fill="#1b3320"/>'%(52+i*8, 20+i*4))
    # the mash trail, left window to right
    for i in range(7):
        s.append('<rect x="%d" y="%d" width="3" height="3" fill="%s" opacity="%.2f"/>'
                 % (62+i*5, 70-i, YELLOW, 0.25+i*0.11))
    # chunky pointer at the landing edge
    P=["10000000","11000000","11100000","11110000","11111000","11111100",
       "11111110","11111000","11011000","10001100","00001100"]
    for ry,rowbits in enumerate(P):
        for cx,b in enumerate(rowbits):
            if b=="1":
                s.append('<rect x="%g" y="%g" width="1.6" height="1.6" fill="#fff"/>'
                         % (96+cx*1.6, 60+ry*1.6))
    s.append('</svg>')
    return "".join(s)

QUICK = """
<h2>Quickstart</h2>

<div class="cols">
<section>
<h3>1 &middot; Turn it on</h3>
<p><b>Tap <kbd>Super</kbd>+<kbd>M</kbd></b> and the session ends by itself after a
second and a half of no input &mdash; good for one correction. <b>Hold it half a second</b> and the
session latches until you press <kbd>Super</kbd>+<kbd>M</kbd> again.</p>
<p>A translucent red disc shows the pointer, because Hyprland hides the real cursor
the moment you touch a key.</p>
</section>

<section>
<h3>2 &middot; Move three ways</h3>
<p><b>Tap</b> a steering key for one small step, 8&nbsp;px, snapping to a window edge
it would otherwise step past.</p>
<p><b>Hold</b> it to sweep, gathering speed. About a second and a half crosses the
screen.</p>
<p><b>Mash</b> across the grid and the pointer rolls the way your hand went, further
the faster and wider you swipe. Only the arrowed keys steer on their own; the rest
exist to be swept across.</p>
</section>

<section>
<h3>3 &middot; Two modifiers</h3>
<p><kbd>Shift</kbd> makes everything bigger: a tap moves 32&nbsp;px, a sweep runs four
times faster, and a swipe jumps straight to the next window edge.</p>
<p><kbd>Ctrl</kbd> makes everything smaller: one pixel a tap, an eighth the sweep
speed, a much shorter roll. Holding both counts as <kbd>Ctrl</kbd>.</p>
<p>Press or release either one mid-sweep and the speed follows at once.</p>
</section>

<section>
<h3>4 &middot; Click and drag</h3>
<p>A button is down while its key is down, so a tap is a click and a hold is a drag.
Hold the left button, sweep across a line of text, let go, and it is selected.</p>
<p>Modifiers reach the application too: <kbd>Shift</kbd> and a click arrives as a
shift-click.</p>
</section>

<section>
<h3>5 &middot; Scroll</h3>
<p>Hold the wheel key and the steering keys scroll instead of moving the pointer,
which stays put. Keep one down and the rate climbs over a few seconds.</p>
<p><kbd>Shift</kbd> jumps straight to the fast rate, <kbd>Ctrl</kbd> pins it slow.
Up and right scroll one way, down and left the other.</p>
</section>

<section>
<h3>6 &middot; Crossing windows</h3>
<p>Run out of edges and the pointer crosses into the next window and focuses it,
whichever Hyprland layout you use. <kbd>F2</kbd> switches layout, <kbd>F1</kbd> shows
the overlay, and anything unbound still types normally.</p>
</section>
</div>
"""

LEGEND = [("steer","steers &mdash; and part of the grid"),
          ("grid","grid only &mdash; mash across these"),
          ("btn","mouse button"),
          ("wheel","hold to scroll"),
          ("mod","size modifier"),
          ("glob","overlay and layout"),
          ("chord","opens a session"),
          ("inert","swallowed, so a stray reach types nothing")]

doc = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>Moush &mdash; drive the pointer from the keyboard</title>
<style>
:root{--bg:#07080b;--ink:#e8e4d9;--dim:#8d8778;--line:#23262e;
 --orange:#d87f33;--cyan:#4fc3c9;--green:#6cc24a;--yellow:#e0c341;--violet:#9b6bd6;}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);
 font:15px/1.6 ui-monospace,"DejaVu Sans Mono",monospace;}
.wrap{max-width:1024px;margin:0 auto;padding:0 28px 56px}
.screen{position:relative;background:#000;border:6px solid #15171c;border-radius:10px;
 margin:28px 0 8px;overflow:hidden}
.hero{display:block;width:100%;image-rendering:pixelated;background:#000}
.screen::after{content:"";position:absolute;inset:0;pointer-events:none;
 background:repeating-linear-gradient(to bottom,rgba(0,0,0,.42) 0 2px,transparent 2px 4px)}
.tag{text-align:center;color:var(--orange);letter-spacing:.42em;font-size:12px;
 text-transform:uppercase;margin:14px 0 2px}
.sub{text-align:center;color:#b9b2a3;font-size:17px;letter-spacing:.14em;
 margin:0 0 32px}
h2{font-size:13px;letter-spacing:.3em;text-transform:uppercase;color:var(--yellow);
 border-bottom:2px solid var(--line);padding-bottom:8px;margin:40px 0 18px}
h3{font-size:13px;color:var(--cyan);margin:0 0 6px;letter-spacing:.06em}
p{margin:0 0 10px;color:#c9c4b8}
b{color:var(--ink)}
kbd{background:#1a1d24;border:1px solid #30343d;border-bottom-width:2px;border-radius:3px;
 padding:0 5px;font:inherit;font-size:12px;color:var(--ink)}
.cols{columns:2;column-gap:34px}
.cols section{break-inside:avoid;margin:0 0 20px}
.install{border:1px solid #2a2f38;border-left:4px solid var(--orange);
 background:#0c0e12;border-radius:6px;padding:14px 16px;margin:0 0 34px}
.ihead{font-size:11px;letter-spacing:.26em;text-transform:uppercase;
 color:var(--orange);margin-bottom:9px}
.cmd{font-size:13px;color:#cfd6c8;white-space:nowrap;overflow-x:auto;
 padding:2px 0;line-height:1.5}
.cmd .p{color:#4a5a46;margin-right:9px}
.inote{font-size:12px;color:var(--dim);margin:9px 0 0}
.modename{display:flex;align-items:baseline;gap:12px;margin:26px 0 10px}
.modename .n{font-size:17px;color:var(--orange);letter-spacing:.1em}
.modename .d{font-size:12px;color:var(--dim)}
.kb{background:#0d0f13;border:1px solid var(--line);border-radius:7px;padding:9px}
.kbrow{display:flex;gap:4px;margin-bottom:4px}
.kbrow:last-child{margin-bottom:0}
.kgap{}
.key{flex:1;min-width:0;background:#15181e;border:1px solid #262a33;border-radius:4px;
 padding:5px 3px 4px;text-align:center;min-height:42px;
 display:flex;flex-direction:column;justify-content:center;gap:1px}
.cap{font-size:11px;color:#6f6a60;line-height:1.1}
.note{font-size:8.5px;line-height:1.15;color:#55505a;word-break:break-word}
.r-grid{background:#10242a;border-color:#2b5c66}
.r-grid .cap{color:var(--cyan)} .r-grid .note{color:#4c8d94}
.r-steer{background:#132a16;border-color:#38703a}
.r-steer .cap{color:var(--green)} .r-steer .note{font-size:15px;color:var(--green)}
.r-steer .note.alias{font-size:9px;color:#4f8a52;letter-spacing:.04em}
.r-btn{background:#2a1a0c;border-color:#6d4520}
.r-btn .cap{color:var(--orange)} .r-btn .note{color:#a06734}
.r-wheel{background:#241433;border-color:#5b3a86}
.r-wheel .cap{color:var(--violet)} .r-wheel .note{color:#8f6ec4}
.r-mod{background:#101d33;border-color:#2e4a7a}
.r-mod .cap{color:#6f9ae0} .r-mod .note{color:#5d7fb8}
.r-glob{background:#2b2710;border-color:#6d6224}
.r-glob .cap{color:var(--yellow)} .r-glob .note{color:#9c8c38}
.r-chord{background:#2d1118;border-color:#79303f}
.r-chord .cap{color:#e06c80} .r-chord .note{color:#a85160}
.r-inert{background:#0b0c0f;border-color:#1b1d22}
.r-inert .cap{color:#3a3c42} .r-inert .note{color:#303238}
.arrows{font-size:12px;color:var(--dim);margin:11px 0 0}
.arrows .ar{color:var(--green)}
.arrows code{color:#9aa39a}
.legend{display:flex;flex-wrap:wrap;gap:8px 20px;margin:12px 0 0;font-size:11px}
.legend span{display:flex;align-items:center;gap:7px;color:var(--dim)}
.sw{width:13px;height:13px;border-radius:3px;border:1px solid}
.foot{margin-top:44px;padding-top:16px;border-top:2px solid var(--line);
 color:var(--dim);font-size:12px}
</style></head><body><div class="wrap">

<div class="screen">@@HERO@@</div>
<div class="tag">Moush</div>
<p class="sub">Move it. Click it. Mash it.</p>

<div class="install">
<div class="ihead">Install &mdash; all three lines</div>
<div class="cmd"><span class="p">$</span> omarchy plugin add https://github.com/hanoixan/moush --enable</div>
<div class="cmd"><span class="p">$</span> echo 'require("omarchy.plugins.moush.implementation")()' &gt;&gt; ~/.config/hypr/bindings.lua</div>
<div class="cmd"><span class="p">$</span> hyprctl reload</div>
<p class="inote">Moush ships no bindings of its own. Stop after the first line and it
installs, enables, and does nothing at all. The second line is the whole of it:
one call, and every layout and default stays inside the plugin where an update can
reach it.</p>
</div>

<h2>Keymap &mdash; mash</h2>
<div class="modename"><span class="n">mash</span>
<span class="d">right hand on the grid, left hand on the buttons</span></div>
@@KB1@@

<h2>Keymap &mdash; mash_lh</h2>
<div class="modename"><span class="n">mash_lh</span>
<span class="d">the same shape under the left hand &mdash; press F2 to switch</span></div>
@@KB2@@
@@LEGEND@@
<p class="arrows">The arrow keys are aliases for the four steering keys, so
<kbd>&larr;</kbd> is the same press as the key marked <span class="ar">&larr;</span>
&mdash; same step, same sweep, same place in a mash. Turn them off for a layout
with <code>mouse_arrows = false</code>.</p>

@@QUICK@@

<p class="foot">Every key shown is read from the running configuration. Pass a table
to that one call to change any of it &mdash; a layout that already exists takes only
the fields you name &mdash; then reload.</p>
</div></body></html>
"""

leg = '<div class="legend">' + "".join(
  '<span><i class="sw" style="background:%s;border-color:%s"></i>%s</span>'
  % ({"steer":"#132a16","grid":"#10242a","btn":"#2a1a0c","wheel":"#241433",
      "mod":"#101d33","glob":"#2b2710","chord":"#2d1118","inert":"#0b0c0f"}[c],
     {"steer":"#38703a","grid":"#2b5c66","btn":"#6d4520","wheel":"#5b3a86",
      "mod":"#2e4a7a","glob":"#6d6224","chord":"#79303f","inert":"#1b1d22"}[c], t)
  for c,t in LEGEND) + '</div>'

out = (doc.replace("@@HERO@@", hero())
          .replace("@@KB1@@", keyboard("mash"))
          .replace("@@KB2@@", keyboard("mash_lh"))
          .replace("@@LEGEND@@", leg)
          .replace("@@QUICK@@", QUICK))
open("/home/user/.config/omarchy/plugins/moush/docs/moush.html","w").write(out)
print("written")
