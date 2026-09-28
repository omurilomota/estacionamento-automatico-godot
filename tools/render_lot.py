#!/usr/bin/env python3
"""tools/render_lot.py — draw a parking-lot floor from the SAME spec as the scene.

WHY: for the existing levels the floor is a photo, and the collision geometry
was eyeballed onto it — Fase5 ended up with bays 245x466 px on a 38 px pitch
(they overlapped into a wall) partly because nobody could measure the painted
stripes. Rendering the art FROM the spec inverts that: the paint is derived
from the geometry, so a stall line can never disagree with its `Vaga` trigger,
and new lots cost no art licensing (nothing is downloaded; every pixel is drawn
here).

Layout, in world px (the image centre is the world origin, so escala_mapa must
be 1.0 for the art to land on the collision):
  asphalt + perimeter concrete + sidewalk slabs with a kerb + stall stripes
  (back line thicker, so the nose is readable) + dashed aisle centre line +
  direction arrows + parked cars composited from the in-repo Kenney sprites.

Usage: python3 tools/render_lot.py tools/specs/Fase6.json
"""
import json
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

VAGA_BASE = (90.0, 120.0)
CARRO_SPRITE = "assets/kenney/cars/car_blue_5.png"
CARRO_SPRITE_SCALE = 1.62

ASPHALT = (58, 60, 64)
ASPHALT2 = (63, 65, 70)
CONCRETE = (120, 122, 126)
SIDEWALK = (156, 158, 162)
KERB = (205, 206, 208)
PAINT = (228, 228, 222)
PAINT_DIM = (170, 170, 165)
LANE = (232, 214, 120)


def w2px(x, y, W, H):
    return (x + W / 2.0, y + H / 2.0)


def drawn_bay(scale):
    """The world rect (w, h) of a bay: 1.26x the visual width, 1.6x its length."""
    vis_w = 70.0 * CARRO_SPRITE_SCALE * scale
    vis_l = 121.0 * CARRO_SPRITE_SCALE * scale
    return (1.26 * vis_w, 1.6 * vis_l)


def render(spec):
    escala = spec["escala_mapa"]
    iw, ih = spec["import_size"]
    W, H = int(round(iw * escala)), int(round(ih * escala))
    img = Image.new("RGB", (W, H), ASPHALT)
    # stalls that the spec marks as ALREADY TAKEN (rows[].parked) get a parked
    # car drawn in them -- same source of truth as the Obstaculo the scene
    # generator emits for that slot.
    parked_art = list(spec.get("parked_art", []))
    for row in spec.get("rows", []):
        if not row.get("parked"):
            continue
        count = int(row["count"])
        span = float(row["to"]) - float(row["from"])
        pitch = span / (count - 1) if count > 1 else span
        cy = float(row["y_edge"]) + (float(row["depth"]) / 2.0) * row["dir"]
        for k in row["parked"]:
            parked_art.append({"pos": [float(row["from"]) + pitch * k, cy],
                               "rot": row["rot"]})
    d = ImageDraw.Draw(img)

    # --- asphalt texture: cheap deterministic noise, a few px at a time ---
    for y in range(0, H, 7):
        for x in range(0, W, 7):
            if ((x // 7) * 31 + (y // 7) * 17) % 5 == 0:
                d.rectangle([x, y, x + 6, y + 6], fill=ASPHALT2)

    # --- perimeter concrete + kerb ---
    edge = int(round(40 * escala))
    d.rectangle([0, 0, W, edge], fill=CONCRETE)
    d.rectangle([0, H - edge, W, H], fill=CONCRETE)
    d.rectangle([0, 0, edge, H], fill=CONCRETE)
    d.rectangle([W - edge, 0, W, H], fill=CONCRETE)

    # --- sidewalks (declared rects, world coords) ---
    for s in spec["sidewalks"]:
        cx, cy, w, h = s["rect"]
        x0, y0 = w2px(cx - w / 2.0, cy - h / 2.0, W, H)
        x1, y1 = w2px(cx + w / 2.0, cy + h / 2.0, W, H)
        d.rectangle([x0, y0, x1, y1], fill=SIDEWALK)
        d.rectangle([x0, y0, x1, y1], outline=KERB, width=max(2, int(4 * escala)))
        # paving joints, so a flat slab does not read as a missing texture
        step = max(12, int(28 * escala))
        yy = y0 + step
        while yy < y1:
            d.line([x0, yy, x1, yy], fill=(146, 148, 152), width=1)
            yy += step

    # --- stall stripes ---
    bay_w, bay_h = None, None
    for row in spec["rows"]:
        bw, bh = drawn_bay(spec["car_scale"])
        bay_w, bay_h = bw, bh
        count = int(row["count"])
        span = float(row["to"]) - float(row["from"])
        pitch = span / (count - 1) if count > 1 else span
        depth = float(row["depth"])
        cy = float(row["y_edge"]) + (depth / 2.0) * row["dir"]
        lw = max(2, int(4 * escala))
        for k in range(count):
            cx = float(row["from"]) + pitch * k
            x0, y0 = w2px(cx - bw / 2.0, cy - bh / 2.0, W, H)
            x1, y1 = w2px(cx + bw / 2.0, cy + bh / 2.0, W, H)
            # sides (the shared dividers of the stalls)
            d.rectangle([x0, y0, x0 + lw, y1], fill=PAINT)
            d.rectangle([x1 - lw, y0, x1, y1], fill=PAINT)
            # the BACK of the stall is the far side from the mouth (nose side)
            nose_up = row["rot"] < 0
            if nose_up:
                d.rectangle([x0, y0, x1, y0 + lw + 2], fill=PAINT)
            else:
                d.rectangle([x0, y1 - lw - 2, x1, y1], fill=PAINT)
            # white-lead ghost: a faded centre tick, like worn paint
            d.line([x0 + bw / 4.0, (y0 + y1) / 2.0, x1 - bw / 4.0, (y0 + y1) / 2.0],
                   fill=PAINT_DIM, width=1)

    # --- dashed aisle centre line between the rows ---
    if len(spec["rows"]) >= 2:
        ys = []
        for row in spec["rows"]:
            ys.append(float(row["y_edge"]) + float(row["depth"]) * row["dir"])
        ys.sort()
        ymid = (ys[-2] + ys[-1]) / 2.0     # between the two innermost edges
        x_from, x_to = -W / 2.0 + 120, W / 2.0 - 120
        dash, gap = 60.0, 60.0
        x = x_from
        while x < x_to:
            a = w2px(x, ymid, W, H)
            b = w2px(min(x + dash, x_to), ymid, W, H)
            d.line([a, b], fill=LANE, width=max(2, int(5 * escala)))
            x += dash + gap

    # --- direction arrows along the authored lanes ---
    for rota in spec.get("rotas", []):
        pts = rota["points"]
        if len(pts) < 2:
            continue
        a, b = pts[0], pts[-1]
        ang = math.atan2(b[1] - a[1], b[0] - a[0])
        length = math.hypot(b[0] - a[0], b[1] - a[1])
        n = max(1, int(length // 420))
        for i in range(n):
            t = (i + 0.5) / n
            px = a[0] + (b[0] - a[0]) * t
            py = a[1] + (b[1] - a[1]) * t
            _arrow(d, px, py, ang, escala, W, H)

    # --- parked cars, composited from the in-repo Kenney sprite ---
    if os.path.exists(CARRO_SPRITE):
        car = Image.open(CARRO_SPRITE).convert("RGBA")
        cs = CARRO_SPRITE_SCALE * spec["car_scale"]
        car = car.resize((max(1, int(car.width * cs)), max(1, int(car.height * cs))),
                         Image.LANCZOS)
        for p in parked_art:
            spr = car if p.get("rot", -1.5708) < 0 else car.rotate(180)
            cx, cy = w2px(p["pos"][0], p["pos"][1], W, H)
            img.paste(spr, (int(cx - spr.width / 2), int(cy - spr.height / 2)), spr)

    img = img.filter(ImageFilter.SMOOTH)
    return img


def _arrow(d, x, y, ang, escala, W, H):
    """A simple painted lane arrow: a stem plus a solid head."""
    size = 60.0 * escala
    ux, uy = math.cos(ang), math.sin(ang)
    nx, ny = -uy, ux
    tip = (x + ux * size, y + uy * size)
    left = (x - ux * size * 0.5 + nx * size * 0.55, y - uy * size * 0.5 + ny * size * 0.55)
    right = (x - ux * size * 0.5 - nx * size * 0.55, y - uy * size * 0.5 - ny * size * 0.55)
    d.polygon([w2px(tip[0], tip[1], W, H), w2px(left[0], left[1], W, H),
               w2px(right[0], right[1], W, H)], fill=PAINT)
    tail = (x - ux * size * 1.6, y - uy * size * 1.6)
    d.line([w2px(tail[0], tail[1], W, H), w2px(x, y, W, H)],
           fill=PAINT, width=max(2, int(6 * escala)))


def main():
    spec = json.load(open(sys.argv[1], encoding="utf-8"))
    img = render(spec)
    out = spec.get("art", "estacionamento/gen_%s.png" % spec["id"].lower())
    img.save(out)
    print("ART_OK %s %dx%d -> %s" % (spec["id"], img.width, img.height, out))


if __name__ == "__main__":
    main()
