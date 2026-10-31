#!/usr/bin/env python3
"""Draws the website's isometric line figures into scripts/site/fig-*.svg: python3 -I scripts/site/tools/figures.py.

The four How it works figures keep the geometry of the originals. Elements that move in a
loop carry fx-* classes (see the loop rules in docs/assets/site.css); --i staggers a row.
"""
import math
from pathlib import Path

parts = Path(__file__).resolve().parents[1]
c, s = math.cos(math.radians(30)), math.sin(math.radians(30))


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


def group(cls, children):
    return [f'<g class="{cls}">'] + ["  " + child for child in children] + ["</g>"]


def svg(cls, body, box="0 0 256 200"):
    head = (f'<svg class="art {cls}" viewBox="{box}" fill="none" stroke="currentColor" stroke-width="1" '
            'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">')
    return "\n".join([head] + ["  " + line for line in body] + ["</svg>"]) + "\n"


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


def corners(u0, v0, u1, v1, k=10, cls="blue"):
    out = []
    for u, v, du, dv in [(u0, v0, 1, 1), (u1, v0, -1, 1), (u1, v1, -1, -1), (u0, v1, 1, -1)]:
        out.append(path([P(u + du * k, v), P(u, v), P(u, v + dv * k)], cls=cls))
    return out


def line_box(i):
    v, l = rows[i]
    return [P(9, v - 4), P(15 + l, v - 4), P(15 + l, v + 4), P(9, v + 4)]


def select():
    body = [plane()]
    for i in range(len(rows)):
        lit = i in picked
        body.append(text_row(i, cls="fx-lit" if lit else "", extra_style=f"; --i:{picked.index(i)}" if lit else ""))
    u0, v0, u1, v1 = sel
    frame = corners(*sel)
    frame.append(path([P(u0, v0), P(u1, v0), P(u1, v1), P(u0, v1)], close=True, cls="blue fx-ants", length=False,
                      extra=' stroke-dasharray="2 3" opacity="0.6"'))
    return svg("art-select", body + group("fx-frame", frame))


def recognize():
    body = [plane()]
    body += [text_row(i) for i in (0, 4, 5)]
    for n, i in enumerate(picked):
        body.append(text_row(i, cls="hi fx-read", extra_style=f"; --i:{n}"))
        body.append(path(line_box(i), close=True, cls="blue fx-trace", style=f"--d:{200 + (n + 1) * 90}; --i:{n}"))
    body.append(path([P(6, 18), P(92, 18)], cls="blue fx-scan"))
    return svg("art-recognize", body)


def lift():
    z = 36
    body = [plane()]
    for n, i in enumerate(picked):
        body.append(path(line_box(i), close=True, cls="fx-hole", length=False, style=f"--i:{n}",
                         extra=' stroke-dasharray="2 3" opacity="0.7"'))
    body += [text_row(i) for i in (0, 4, 5)]
    for n, i in enumerate(picked):
        v, _ = rows[i]
        body.append(text_row(i, cls="hi fx-rise", z=z, delay=300 + (n + 1) * 60, extra_style=f"; --i:{n}"))
        body.append(path([P(12, v, 4), P(12, v, z - 4)], cls="fx-guide", length=False, style=f"--i:{n}",
                         extra=' stroke-dasharray="1.5 3" opacity="0.7"'))
    return svg("art-lift", body)


def set_():
    new = {1: 64, 2: 46, 3: 58}
    body = [plane()]
    body += [text_row(i) for i in (0, 4, 5)]
    for n, i in enumerate(picked):
        body.append(path(line_box(i), close=True, extra=' opacity="0.35"'))
        body.append(text_row(i, cls="blue fx-write", length=new[i], delay=(n + 1) * 90,
                             extra_style=f"; --i:{n}").replace(" />", ' stroke-width="1.6" />'))
    return svg("art-set", body + group("fx-mark", corners(*sel, cls="hi")))


# Any app: two windows of different apps on one desk plane, the second overlapping the first, and
# one selection frame drawn across both. Each window is filled with the page colour, so the one in
# front hides what is behind it. Inside the frame both apps' lines are set in another language
# (blue); outside it they stay as they were.
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

    def inside(u, v):
        return fu0 <= u <= fu1 and fv0 <= v <= fv1

    body, new = [], []
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
                # A translation is rarely as long as its original, but it stays inside the frame.
                shift = (-8, -2, -12, -4, -6)[len(new) % 5]
                new.append(path([P2(a, v), P2(max(a + 10, b + shift), v)], cls="blue fx-new",
                                style=f"{d}; --i:{len(new)}", extra=' stroke-width="1.5"'))
        # Each window's lines are drawn with it, so the one in front covers them.
        if w == 0:
            body += new
            new = []
    body += new
    frame = [path([P2(u + du * 10, v), P2(u, v), P2(u, v + dv * 10)], cls="blue")
             for u, v, du, dv in [(fu0, fv0, 1, 1), (fu1, fv0, -1, 1), (fu1, fv1, -1, -1), (fu0, fv1, 1, -1)]]
    frame.append(path([P2(fu0, fv0), P2(fu1, fv0), P2(fu1, fv1), P2(fu0, fv1)], close=True,
                      cls="blue fx-ants", length=False, extra=' stroke-dasharray="2 3" opacity="0.6"'))
    return svg("art-apps", body + group("fx-frame", frame), box=box)


for name, draw in [("fig-select", select), ("fig-recognize", recognize), ("fig-lift", lift), ("fig-set", set_),
                   ("fig-apps", apps)]:
    (parts / f"{name}.svg").write_text(draw())
    print("wrote", name)
