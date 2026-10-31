#!/usr/bin/env python3
"""Draws the website's isometric line figures into scripts/site/fig-*.svg: python3 -I scripts/site/tools/figures.py.

Each figure is drawn as it looks at rest. Elements that move in its loop carry lp-* classes; the
keyframes are in docs/assets/site.css. --i staggers a row of lines, --dx and --dy are a move in
user units, and transform-origin is the point a frame grows from or snaps around.
"""
import math
from pathlib import Path

parts = Path(__file__).resolve().parents[1]
c, s = math.cos(math.radians(30)), math.sin(math.radians(30))
# A macOS pointer with its tip at 0 0, about 13 units tall.
POINTER = "M0 0 L0 11.2 L2.8 8.6 L4.9 13.1 L6.9 12.2 L4.9 7.8 L8.6 7.8 Z"


def projection(cx, cy, k):
    return lambda u, v, z=0: (cx + (u - v) * c * k, cy + ((u + v) * s - z) * k)


def f(p):
    return f"{p[0]:.1f} {p[1]:.1f}"


def path(points, close=False, cls="", length=True, style="", extra=""):
    d = "M" + " L".join(f(p) for p in points) + (" Z" if close else "")
    attrs = ' pathLength="1"' if length else ""
    if cls:
        attrs += f' class="{cls}"'
    attrs += extra
    if style:
        attrs += f' style="{style}"'
    return f'<path d="{d}"{attrs} />'


def group(cls, children, style=""):
    head = f'<g class="{cls}"' + (f' style="{style}"' if style else "") + ">"
    return [head] + ["  " + child for child in children] + ["</g>"]


def svg(cls, body, box="0 0 256 200"):
    head = (f'<svg class="art {cls}" viewBox="{box}" fill="none" stroke="currentColor" stroke-width="1" '
            'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">')
    return "\n".join([head] + ["  " + line for line in body] + ["</svg>"]) + "\n"


def frame(project, u0, v0, u1, v1, corner_cls="blue", grow=True):
    """A selection frame: the dashed outline grows from its first corner while a pointer drags it
    to the opposite corner, then the corner marks snap around its centre."""
    a, b, d = project(u0, v0), project(u1, v0), project(u0, v1)
    end = project(u1, v1)
    centre = project((u0 + u1) / 2, (v0 + v1) / 2)
    corners = [path([project(u + du * 10, v), project(u, v), project(u, v + dv * 10)], cls=corner_cls)
               for u, v, du, dv in [(u0, v0, 1, 1), (u1, v0, -1, 1), (u1, v1, -1, -1), (u0, v1, 1, -1)]]
    outline = path([a, b, end, d], close=True, cls="blue lp-ants", length=False,
                   extra=' stroke-dasharray="2 3" opacity="0.6"')
    out = []
    if grow:
        out += group("lp-grow", [outline], style=f"transform-origin: {a[0]:.1f}px {a[1]:.1f}px")
    out += group("lp-snap" + ("" if grow else " is-late"), corners,
                 style=f"transform-origin: {centre[0]:.1f}px {centre[1]:.1f}px")
    if grow:
        dx, dy = end[0] - a[0], end[1] - a[1]
        out += [f'<g transform="translate({f(a)})">',
                f'  <path d="{POINTER}" class="hi lp-cursor" fill="currentColor" stroke="#08090a" stroke-width="0.9" '
                f'stroke-dasharray="none" style="--dx: {dx:.1f}px; --dy: {dy:.1f}px" />',
                "</g>"]
    return out


# How it works: one page, its six lines of text, and the frame around three of them.
P = projection(111, 42, 1.38)
U, V = 112, 84
rows = [(14, 70), (26, 52), (38, 78), (50, 40), (62, 66), (74, 30)]
picked = [1, 2, 3]
sel = (6, 20, 92, 56)


def plane():
    return path([P(0, 0), P(U, 0), P(U, V), P(0, V)], close=True)


def text_row(i, cls="", z=0, length=None, delay=None, extra_style=""):
    v, l = rows[i]
    style = f"--d:{i * 60 if delay is None else delay}" + extra_style
    return path([P(12, v, z), P(12 + (length or l), v, z)], cls=cls, style=style)


def line_box(i):
    v, l = rows[i]
    return [P(9, v - 4), P(15 + l, v - 4), P(15 + l, v + 4), P(9, v + 4)]


def select():
    # The frame is dragged out over three lines, which light up when it snaps.
    body = [plane()]
    for i in range(len(rows)):
        lit = i in picked
        body.append(text_row(i, cls="hi lp-lit" if lit else "", extra_style=f"; --i:{picked.index(i)}" if lit else ""))
    return svg("art-select", body + frame(P, *sel))


def recognize():
    # A scan line sweeps down the selection and each line is boxed as it passes.
    body = [plane()]
    body += [text_row(i) for i in (0, 4, 5)]
    for n, i in enumerate(picked):
        body.append(text_row(i, cls="hi"))
        body.append(path(line_box(i), close=True, cls="blue lp-trace", style=f"--d:{200 + (n + 1) * 90}; --i:{n}"))
    a, b = P(6, 18), P(92, 18)
    dx, dy = P(0, 40)[0] - P(0, 0)[0], P(0, 40)[1] - P(0, 0)[1]
    body.append(path([a, b], cls="blue lp-scan", style=f"--dx: {dx:.1f}px; --dy: {dy:.1f}px", extra=' stroke-width="1.4"'))
    return svg("art-recognize", body)


def lift():
    # The lines sink back onto the page, then rise off it again, leaving their outlines behind.
    z = 36
    body = [plane()]
    for n, i in enumerate(picked):
        body.append(path(line_box(i), close=True, cls="lp-hole", length=False, style=f"--i:{n}",
                         extra=' stroke-dasharray="2 3" opacity="0.7"'))
    body += [text_row(i) for i in (0, 4, 5)]
    for n, i in enumerate(picked):
        v, _ = rows[i]
        body.append(text_row(i, cls="hi lp-rise", z=z, delay=300 + (n + 1) * 60,
                             extra_style=f"; --i:{n}; --dy: {z * 1.38:.1f}px"))
        body.append(path([P(12, v, 4), P(12, v, z - 4)], cls="lp-hole", length=False, style=f"--i:{n}",
                         extra=' stroke-dasharray="1.5 3" opacity="0.7"'))
    return svg("art-lift", body)


def set_():
    # The new lines are written in one by one where the old ones were, then the frame marks snap.
    new = {1: 64, 2: 46, 3: 58}
    body = [plane()]
    body += [text_row(i) for i in (0, 4, 5)]
    for n, i in enumerate(picked):
        body.append(text_row(i, cls="blue lp-write", length=new[i], delay=(n + 1) * 90,
                             extra_style=f"; --i:{n}").replace(" />", ' stroke-width="1.6" />'))
    return svg("art-set", body + frame(P, *sel, corner_cls="hi", grow=False))


# Any app: two windows of different apps on one desk plane, the second overlapping the first, and
# one selection frame dragged across both. Each window is filled with the page colour, so the one
# in front hides what is behind it. When the frame snaps, the lines inside it, from both apps,
# turn into the translation (blue) one after another; outside it they stay as they were.
def apps():
    k = 1.3
    # u0, u1, v0, v1 and the text rows (v offset from the title bar, length)
    left = (0, 104, 0, 86, [(10, 70), (19, 52), (28, 84), (37, 46), (46, 66), (55, 40), (64, 58)])
    right = (78, 186, 22, 104, [(10, 76), (19, 58), (28, 90), (37, 50), (46, 70), (55, 44)])
    windows = [left, right]
    fu0, fu1, fv0, fv1 = 30, 150, 40, 78
    pad = 8
    xs, ys = [], []
    P0 = projection(0, 0, k)
    for u0, u1, v0, v1, _ in windows:
        for u, v in [(u0, v0), (u1, v0), (u1, v1), (u0, v1)]:
            x, y = P0(u, v)
            xs.append(x)
            ys.append(y)
    P2 = projection(pad - min(xs), pad - min(ys), k)
    box = f"0 0 {math.ceil(max(xs) - min(xs) + 2 * pad)} {math.ceil(max(ys) - min(ys) + 2 * pad)}"

    body, count = [], 0
    for w, (u0, u1, v0, v1, table) in enumerate(windows):
        delay = w * 160
        outline = [P2(u0, v0), P2(u1, v0), P2(u1, v1), P2(u0, v1)]
        # The fill hides the window behind; it has no stroke, so it never draws in.
        d = "M" + " L".join(f(p) for p in outline) + " Z"
        body.append(f'<path d="{d}" class="fill" stroke="none" />')
        body.append(path(outline, close=True, style=f"--d:{delay}"))
        body.append(path([P2(u0, v0 + 9), P2(u1, v0 + 9)], style=f"--d:{delay + 60}"))
        body.append(path([P2(u0 + 4, v0 + 4.5), P2(u0 + 11, v0 + 4.5)], cls="hi", style=f"--d:{delay + 60}"))
        for n, (dv, l) in enumerate(table):
            v = v0 + 9 + dv
            start, end = u0 + 8, min(u0 + 8 + l, u1 - 8)
            d = f"--d:{delay + 100 + n * 36}"
            if not fv0 + 3 < v < fv1 - 3:
                if start < end:
                    body.append(path([P2(start, v), P2(end, v)], style=d))
                continue
            a, b = max(start, fu0 + 5), min(end, fu1 - 5)
            if start < a - 5:
                body.append(path([P2(start, v), P2(a - 5, v)], style=d))
            if end > b + 5:
                body.append(path([P2(b + 5, v), P2(end, v)], style=d))
            if a < b:
                # The original stays on screen until its translation replaces it; a translation is
                # rarely as long as its original, but it stays inside the frame.
                body.append(path([P2(a, v), P2(b, v)], cls="lp-old", style=f"--i:{count}"))
                shift = (-8, -2, -12, -4, -6)[count % 5]
                body.append(path([P2(a, v), P2(max(a + 10, b + shift), v)], cls="blue lp-new",
                                 style=f"{d}; --i:{count}", extra=' stroke-width="1.5"'))
                count += 1
    return svg("art-apps", body + frame(P2, fu0, fv0, fu1, fv1), box=box)


for name, draw in [("fig-select", select), ("fig-recognize", recognize), ("fig-lift", lift), ("fig-set", set_),
                   ("fig-apps", apps)]:
    (parts / f"{name}.svg").write_text(draw())
    print("wrote", name)
