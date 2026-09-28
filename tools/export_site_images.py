#!/usr/bin/env python3
"""tools/export_site_images.py — regenerate the site gallery assets.

AGENTS §26: `site/img` must stay small (the deploy root matters) and every image
that is not a Godot-rendered screenshot is a RE-ENCODED copy, never a raw one
(`parking_lot.jpg` is 5.7 MB, `parking_lot3.svg` is 9 MB). This tool is the
versioned version of what used to be a hand-run PIL snippet:

  * generated floors (estacionamento/gen_*.png) -> long side capped at 1600 px;
  * the existing photo/vector floors          -> same cap;
  * the car skins                             -> 4x NEAREST (pixel art stays crisp).

Usage: python3 tools/export_site_images.py
"""
import os

from PIL import Image

OUT = "site/img"
CAP = 1600


def shrink(src, dst, cap=CAP):
    im = Image.open(src)
    if max(im.size) > cap:
        k = cap / float(max(im.size))
        im = im.resize((max(1, int(im.width * k)), max(1, int(im.height * k))),
                       Image.LANCZOS)
    im.save(dst, optimize=True)
    return os.path.getsize(dst)


def upscale(src, dst, factor=4):
    im = Image.open(src).convert("RGBA")
    im = im.resize((im.width * factor, im.height * factor), Image.NEAREST)
    im.save(dst, optimize=True)
    return os.path.getsize(dst)


def generated_floors():
    """Every floor the level generator wrote, discovered instead of listed:
    a hardcoded list silently skipped Fase8/Fase9 when they were added."""
    out = []
    for name in sorted(os.listdir("estacionamento")):
        if name.startswith("gen_fase") and name.endswith(".png"):
            out.append((os.path.join("estacionamento", name),
                        name.replace("gen_", "piso-")))
    return out


def main():
    os.makedirs(OUT, exist_ok=True)
    total = 0
    jobs = generated_floors() + [
        ("estacionamento/parking_lot.jpg", "piso-parking-lot1.jpg"),
        ("estacionamento/parking_lot4.jpg", "piso-parking-lot4.jpg"),
        ("estacionamento/Parkinglot5.jpeg", "piso-parking-lot5.jpg"),
    ]
    for src, name in jobs:
        if not os.path.exists(src):
            print("SKIP (missing) %s" % src)
            continue
        n = shrink(src, os.path.join(OUT, name))
        total += n
        print("IMG %-34s -> %-24s %6.1f KB" % (src, name, n / 1024.0))

    skins = [
        ("assets/sprites/sedan_vermelho.png", "carro-sedan.png"),
        ("assets/sprites/suv_branco.png", "carro-suv.png"),
        ("assets/sprites/musclecar_amarelo.png", "carro-muscle.png"),
        ("assets/sprites/taxi.png", "carro-taxi.png"),
        ("assets/sprites/carro.png", "carro-classic.png"),
    ]
    for src, name in skins:
        if not os.path.exists(src):
            print("SKIP (missing) %s" % src)
            continue
        n = upscale(src, os.path.join(OUT, name))
        total += n
        print("IMG %-34s -> %-24s %6.1f KB" % (src, name, n / 1024.0))

    print("EXPORT_IMAGES_OK %d files, %.2f MB" % (len(jobs) + len(skins), total / 1048576.0))


if __name__ == "__main__":
    main()
