#!/usr/bin/env python3
# Flattens the Lucide SVGs in lucide/ into polylines and generates
# src/client/lucide_gen.odin. The client draws them with round caps/joints
# (DrawLineEx + circles), matching Lucide's stroke style at any scale.
#
# Usage: python3 generate.py [preview.png]
#   With a preview path it also renders a contact sheet for visual checks.

import math
import os
import re
import sys

ICON_DIR = os.path.join(os.path.dirname(__file__), "lucide")
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "src", "client", "lucide_gen.odin")

CUBIC_SEGS = 14
QUAD_SEGS = 10
ARC_DEG_PER_SEG = 9.0
RDP_EPS = 0.025

TOKEN = re.compile(r"[MmLlHhVvCcSsQqTtAaZz]|-?\d*\.?\d+(?:e[+-]?\d+)?")


def parse_path(d):
    toks = TOKEN.findall(d)
    i = 0
    polys = []
    cur = []
    pos = (0.0, 0.0)
    start = (0.0, 0.0)
    prev_cmd = None
    prev_ctrl = None

    def num():
        nonlocal i
        v = float(toks[i])
        i += 1
        return v

    def flush():
        nonlocal cur
        if len(cur) > 1:
            polys.append(cur)
        cur = []

    cmd = None
    while i < len(toks):
        if re.match(r"[A-Za-z]", toks[i]):
            cmd = toks[i]
            i += 1
        # implicit repeat: M -> L, m -> l
        elif cmd == "M":
            cmd = "L"
        elif cmd == "m":
            cmd = "l"

        rel = cmd.islower()
        c = cmd.upper()

        if c == "M":
            flush()
            x, y = num(), num()
            if rel:
                x, y = pos[0] + x, pos[1] + y
            pos = (x, y)
            start = pos
            cur = [pos]
        elif c == "L":
            x, y = num(), num()
            if rel:
                x, y = pos[0] + x, pos[1] + y
            pos = (x, y)
            cur.append(pos)
        elif c == "H":
            x = num()
            if rel:
                x = pos[0] + x
            pos = (x, pos[1])
            cur.append(pos)
        elif c == "V":
            y = num()
            if rel:
                y = pos[1] + y
            pos = (pos[0], y)
            cur.append(pos)
        elif c in ("C", "S"):
            if c == "C":
                x1, y1 = num(), num()
            else:
                # reflect previous control point
                if prev_cmd in ("C", "S") and prev_ctrl:
                    x1, y1 = 2 * pos[0] - prev_ctrl[0], 2 * pos[1] - prev_ctrl[1]
                else:
                    x1, y1 = pos
            x2, y2 = num(), num()
            x, y = num(), num()
            if rel:
                if c == "C":
                    x1, y1 = pos[0] + x1, pos[1] + y1
                x2, y2 = pos[0] + x2, pos[1] + y2
                x, y = pos[0] + x, pos[1] + y
            elif c == "S" and prev_cmd not in ("C", "S"):
                pass
            p0 = pos
            for t in range(1, CUBIC_SEGS + 1):
                u = t / CUBIC_SEGS
                v = 1 - u
                px = v**3 * p0[0] + 3 * v**2 * u * x1 + 3 * v * u**2 * x2 + u**3 * x
                py = v**3 * p0[1] + 3 * v**2 * u * y1 + 3 * v * u**2 * y2 + u**3 * y
                cur.append((px, py))
            prev_ctrl = (x2, y2)
            pos = (x, y)
        elif c in ("Q", "T"):
            if c == "Q":
                x1, y1 = num(), num()
                if rel:
                    x1, y1 = pos[0] + x1, pos[1] + y1
            else:
                if prev_cmd in ("Q", "T") and prev_ctrl:
                    x1, y1 = 2 * pos[0] - prev_ctrl[0], 2 * pos[1] - prev_ctrl[1]
                else:
                    x1, y1 = pos
            x, y = num(), num()
            if rel:
                x, y = pos[0] + x, pos[1] + y
            p0 = pos
            for t in range(1, QUAD_SEGS + 1):
                u = t / QUAD_SEGS
                v = 1 - u
                px = v**2 * p0[0] + 2 * v * u * x1 + u**2 * x
                py = v**2 * p0[1] + 2 * v * u * y1 + u**2 * y
                cur.append((px, py))
            prev_ctrl = (x1, y1)
            pos = (x, y)
        elif c == "A":
            rx, ry = num(), num()
            rot = math.radians(num())
            large = num() != 0
            sweep = num() != 0
            x, y = num(), num()
            if rel:
                x, y = pos[0] + x, pos[1] + y
            for p in flatten_arc(pos, (x, y), rx, ry, rot, large, sweep):
                cur.append(p)
            pos = (x, y)
        elif c == "Z":
            if cur and cur[-1] != start:
                cur.append(start)
            pos = start
        prev_cmd = c
        if c not in ("C", "S", "Q", "T"):
            prev_ctrl = None
    flush()
    return polys


def flatten_arc(p0, p1, rx, ry, phi, large, sweep):
    # SVG endpoint arc -> center parametrization (W3C appendix B.2.4)
    if rx == 0 or ry == 0:
        return [p1]
    x0, y0 = p0
    x1, y1 = p1
    dx, dy = (x0 - x1) / 2, (y0 - y1) / 2
    cosp, sinp = math.cos(phi), math.sin(phi)
    xp = cosp * dx + sinp * dy
    yp = -sinp * dx + cosp * dy
    lam = xp**2 / rx**2 + yp**2 / ry**2
    if lam > 1:
        s = math.sqrt(lam)
        rx, ry = rx * s, ry * s
    num = rx**2 * ry**2 - rx**2 * yp**2 - ry**2 * xp**2
    den = rx**2 * yp**2 + ry**2 * xp**2
    co = math.sqrt(max(0.0, num / den)) if den else 0.0
    if large == sweep:
        co = -co
    cxp = co * rx * yp / ry
    cyp = -co * ry * xp / rx
    cx = cosp * cxp - sinp * cyp + (x0 + x1) / 2
    cy = sinp * cxp + cosp * cyp + (y0 + y1) / 2

    def angle(ux, uy, vx, vy):
        d = math.hypot(ux, uy) * math.hypot(vx, vy)
        a = math.acos(max(-1, min(1, (ux * vx + uy * vy) / d)))
        return -a if ux * vy - uy * vx < 0 else a

    th1 = angle(1, 0, (xp - cxp) / rx, (yp - cyp) / ry)
    dth = angle((xp - cxp) / rx, (yp - cyp) / ry, (-xp - cxp) / rx, (-yp - cyp) / ry)
    if not sweep and dth > 0:
        dth -= 2 * math.pi
    elif sweep and dth < 0:
        dth += 2 * math.pi
    segs = max(2, int(abs(math.degrees(dth)) / ARC_DEG_PER_SEG))
    out = []
    for t in range(1, segs + 1):
        th = th1 + dth * t / segs
        px = cx + rx * math.cos(th) * cosp - ry * math.sin(th) * sinp
        py = cy + rx * math.cos(th) * sinp + ry * math.sin(th) * cosp
        out.append((px, py))
    out[-1] = p1
    return out


def ellipse_poly(cx, cy, rx, ry):
    pts = []
    n = 40
    for t in range(n + 1):
        a = 2 * math.pi * t / n - math.pi / 2
        pts.append((cx + rx * math.cos(a), cy + ry * math.sin(a)))
    return pts


def rdp(pts, eps):
    if len(pts) < 3:
        return pts
    ax, ay = pts[0]
    bx, by = pts[-1]
    dmax, idx = 0.0, 0
    for i in range(1, len(pts) - 1):
        px, py = pts[i]
        if ax == bx and ay == by:
            d = math.hypot(px - ax, py - ay)
        else:
            d = abs((by - ay) * px - (bx - ax) * py + bx * ay - by * ax) / math.hypot(bx - ax, by - ay)
        if d > dmax:
            dmax, idx = d, i
    if dmax <= eps:
        return [pts[0], pts[-1]]
    left = rdp(pts[: idx + 1], eps)
    right = rdp(pts[idx:], eps)
    return left[:-1] + right


ATTR = lambda el, name, default="0": re.search(rf'{name}="([^"]+)"', el).group(1) if re.search(rf'{name}="([^"]+)"', el) else default


def parse_svg(text):
    polys = []
    for el in re.findall(r"<(path|circle|rect|line|polyline|polygon|ellipse)\b[^>]*>", text):
        pass
    for m in re.finditer(r"<(path|circle|rect|line|polyline|polygon|ellipse)\b([^>]*)>", text):
        kind, attrs = m.group(1), m.group(2)
        if kind == "path":
            d = re.search(r'd="([^"]+)"', attrs).group(1)
            polys.extend(parse_path(d))
        elif kind == "circle":
            cx, cy, r = (float(ATTR(attrs, a)) for a in ("cx", "cy", "r"))
            polys.append(ellipse_poly(cx, cy, r, r))
        elif kind == "ellipse":
            cx, cy = float(ATTR(attrs, "cx")), float(ATTR(attrs, "cy"))
            rx, ry = float(ATTR(attrs, "rx")), float(ATTR(attrs, "ry"))
            polys.append(ellipse_poly(cx, cy, rx, ry))
        elif kind == "rect":
            x, y = float(ATTR(attrs, "x")), float(ATTR(attrs, "y"))
            w, h = float(ATTR(attrs, "width")), float(ATTR(attrs, "height"))
            rx = float(ATTR(attrs, "rx", "0"))
            if rx <= 0:
                polys.append([(x, y), (x + w, y), (x + w, y + h), (x, y + h), (x, y)])
            else:
                d = (f"M{x+rx} {y}H{x+w-rx}A{rx} {rx} 0 0 1 {x+w} {y+rx}V{y+h-rx}"
                     f"A{rx} {rx} 0 0 1 {x+w-rx} {y+h}H{x+rx}A{rx} {rx} 0 0 1 {x} {y+h-rx}"
                     f"V{y+rx}A{rx} {rx} 0 0 1 {x+rx} {y}Z")
                polys.extend(parse_path(d))
        elif kind == "line":
            polys.append([
                (float(ATTR(attrs, "x1")), float(ATTR(attrs, "y1"))),
                (float(ATTR(attrs, "x2")), float(ATTR(attrs, "y2"))),
            ])
        elif kind in ("polyline", "polygon"):
            nums = [float(v) for v in re.findall(r"-?\d*\.?\d+", ATTR(attrs, "points", ""))]
            pts = list(zip(nums[0::2], nums[1::2]))
            if kind == "polygon" and pts:
                pts.append(pts[0])
            polys.append(pts)
    return [rdp(p, RDP_EPS) for p in polys]


def odin_name(fname):
    return "_".join(w.capitalize() for w in fname.replace(".svg", "").split("-"))


def main():
    icons = {}
    for f in sorted(os.listdir(ICON_DIR)):
        if not f.endswith(".svg"):
            continue
        icons[odin_name(f)] = parse_svg(open(os.path.join(ICON_DIR, f)).read())

    with open(OUT, "w") as o:
        o.write("package main\n\n")
        o.write("// GENERATED by assets/icons/generate.py from the Lucide icon set\n")
        o.write("// (https://lucide.dev, ISC license — assets/icons/lucide/LICENSE).\n")
        o.write("// Polylines in the 24x24 Lucide box; drawn by draw_icon (lucide.odin).\n\n")
        o.write("Icon :: enum u8 {\n")
        for name in icons:
            o.write(f"\t{name},\n")
        o.write("}\n\n")
        o.write("Icon_Poly :: [][2]f32\n\n")
        o.write("LUCIDE := [Icon][]Icon_Poly{\n")
        for name, polys in icons.items():
            o.write(f"\t.{name} = {{\n")
            for p in polys:
                pts = ", ".join(f"{{{x:.6g}, {y:.6g}}}" for x, y in p)
                o.write(f"\t\t{{{pts}}},\n")
            o.write("\t},\n")
        o.write("}\n")

    total = sum(len(p) for ps in icons.values() for p in ps)
    print(f"{len(icons)} icons, {total} points -> {os.path.relpath(OUT)}")

    if len(sys.argv) > 1:
        preview(icons, sys.argv[1])


def preview(icons, path):
    # Contact sheet drawn exactly like the client renderer: thick lines +
    # circles at every vertex (round caps/joints).
    from PIL import Image, ImageDraw
    cell, pad = 96, 16
    cols = 6
    rows = (len(icons) + cols - 1) // cols
    img = Image.new("RGB", (cols * (cell + pad) + pad, rows * (cell + pad) + pad), (24, 24, 27))
    dr = ImageDraw.Draw(img)
    s = cell / 24
    th = max(2, int(2 * s))
    for i, (name, polys) in enumerate(icons.items()):
        ox = pad + (i % cols) * (cell + pad)
        oy = pad + (i // cols) * (cell + pad)
        for p in polys:
            pts = [(ox + x * s, oy + y * s) for x, y in p]
            if len(pts) > 1:
                dr.line(pts, fill=(250, 250, 250), width=th, joint="curve")
            for x, y in (pts[0], pts[-1]):
                dr.ellipse([x - th / 2, y - th / 2, x + th / 2, y + th / 2], fill=(250, 250, 250))
    img.save(path)
    print("preview:", path)


if __name__ == "__main__":
    main()
