#!/usr/bin/env python3
"""tools/gen_level.py — generate a Godot 4 level scene from a declarative spec.

WHY THIS EXISTS (AGENTS §0/#40): Fase5 was a hand-authored scene with 89 bays
of 245x466 px on a 38 px pitch — bays overlapping into a wall, so no bay had a
free preparation point and the car could never reach one (gate_reach: 0 of 89
with a route). The defect class is "bay grid authored by hand"; the fix is to
DERIVE the grid from the car's own footprint so overlap is impossible by
construction, and to assert that invariant before writing the file.

Invariants asserted before writing (a violation aborts, per AGENTS #40):
  1. every bay of a row fits inside the world rect;
  2. bays of a row never overlap each other (pitch >= bay width);
  3. every bay has a preparation point inside the world rect;
  4. no bay rect and no preparation point overlaps a wall/sidewalk body
     (a silent unreachable-bay factory: the bay is in the scene, `gate_reach`
     is the only other thing that would catch it);
  5. every cone is inside the world AND at least
     `swept_radius + cone_radius + 40` px from every bay centre and every
     preparation point (AGENTS #19);
  6. the emitted scene has the same number of `[node ` headers it rendered.

Usage:
  python3 tools/gen_level.py tools/specs/Fase5.json
"""
import json
import os
import re
import sys

# Must mirror scenes/Vaga.tscn / scenes/Carro.tscn (the geometry contract).
VAGA_BASE = (90.0, 120.0)      # Area rect of Vaga.tscn, local px
OBSTACULO_BASE = (88.0, 190.0)  # CollisionShape2D of Obstaculo.tscn
CARRO_BASE = (88.0, 74.0)      # CollisionShape2D of Carro.tscn
CARRO_SPRITE = (70.0, 121.0)   # Kenney texture, before the child's 1.62 scale
CARRO_SPRITE_SCALE = 1.62
ENTRE_EIXOS = 60.0

# --- TAMANHO DA VAGA: DADO DO MUNDO REAL, NAO NUMERO SOLTO NO SPEC ----------
# Uma vaga perpendicular de verdade mede 2,50 x 5,00 m. O carro de verdade
# mede 1,80 x 4,40 m — e o que o JOGO mostra e' o sprite (70 x 121 px antes da
# escala do filho), entao e' pelo sprite que a vaga tem de ser cotada:
#
#   largura = 1,80 * (2,50 / 1,80) = 2,50 m -> 1,389 x a largura do carro
#   profun. = 4,40 * (5,00 / 4,40) = 5,00 m -> 1,136 x o comprimento do carro
#
# MEDIDO (2026-10-01, erro do usuario): o `bay_scale` dos specs era dado solto e
# media 2,30 x 2,73 carros na Fase5 e 1,93 x 3,56 nas Fase6..Fase10 — ou seja,
# 12 m e 22 m de profundidade, contra 5 m na realidade. Agora a vaga e' DERIVADA
# e nao ha como um nivel nascer com vaga de outro mundo.
VAGA_M = (2.50, 5.00)            # metros: largura x profundidade
CARRO_M = (1.80, 4.40)           # metros
VAGA_REAL_PX = (VAGA_M[0] / CARRO_M[0], VAGA_M[1] / CARRO_M[1])  # (1.389, 1.136)


def bay_scale_do_carro(scale):
    """`bay_scale` do spec para a Area de Vaga de uma vaga de verdade.

    `car_footprint()[1]` devolve (COMPRIMENTO, LARGURA) do sprite ja escalado —
    a textura do Kenney e' retrato (70 x 121) e o eixo do mundo X aponta para a
    frente, entao a primeira componente e' o comprimento.
    """
    comprimento, largura = car_footprint(scale)[1]
    return (VAGA_REAL_PX[0] * largura / VAGA_BASE[0],
            VAGA_REAL_PX[1] * comprimento / VAGA_BASE[1])


RESOLUCAO = 15.0   # Planejador.resolucao (scripts/Planejador.gd)


def car_footprint(scale):
    """Collision box and visual box of the car at a level scale."""
    col = (CARRO_BASE[0] * scale, CARRO_BASE[1] * scale)
    vis = (CARRO_SPRITE[1] * CARRO_SPRITE_SCALE * scale,
           CARRO_SPRITE[0] * CARRO_SPRITE_SCALE * scale)  # sprite is rotated 90 deg
    return col, vis


def swept_radius(scale):
    import math
    return 0.5 * math.hypot(CARRO_BASE[0] * scale, CARRO_BASE[1] * scale)


def prep_reach(scale):
    """Carro.alcance_preparo(): entre_eixos * escala * 2.5 + 80."""
    return ENTRE_EIXOS * scale * 2.5 + 80.0


def bay_rect(spec, cx, cy):
    """World AABB of a bay. The Area is axis-aligned; `rot` only picks the nose."""
    w = VAGA_BASE[0] * spec["scale"][0]
    h = VAGA_BASE[1] * spec["scale"][1]
    return (cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2)


def build_bays(spec, world):
    """Expand the row specs into concrete bay nodes and check the invariants."""
    ww, wh = world
    x0, y0, x1, y1 = -ww / 2, -wh / 2, ww / 2, wh / 2
    reach = prep_reach(spec["car_scale"])
    bays = []
    parked = []
    for row in spec["rows"]:
        count = int(row["count"])
        side = row["side"]
        span = float(row["to"]) - float(row["from"])
        # pitch: bays spread evenly across [from..to]; must not overlap
        if count < 2:
            pitch = span
        else:
            pitch = span / (count - 1)
        bs = row.get("bay_scale") or bay_scale_do_carro(spec["car_scale"])
        bw = VAGA_BASE[0] * bs[0]
        if count > 1 and pitch < bw:
            die("row %s: pitch %.1f < bay width %.1f -> bays would overlap"
                % (row["name"], pitch, bw))
        for k in range(count):
            cx = float(row["from"]) + pitch * k
            cy = float(row["y_edge"]) + (row["depth"] / 2.0) * row["dir"]
            cx = round(cx, 1)
            cy = round(cy, 1)
            r = bay_rect({"scale": bs}, cx, cy)
            if r[0] < x0 or r[2] > x1 or r[1] < y0 or r[3] > y1:
                die("row %s bay %d: rect %s outside world %s"
                    % (row["name"], k, r, (x0, y0, x1, y1)))
            nose = (0.0, 1.0) if row["rot"] > 0 else (0.0, -1.0)
            prep = (cx - nose[0] * reach, cy - nose[1] * reach)
            if not (x0 < prep[0] < x1 and y0 < prep[1] < y1):
                die("row %s bay %d: prep point %s outside world" % (row["name"], k, prep))
            name = "%s_%d" % (row["name"], k + 1)
            if k in row.get("parked", []):
                # A stall that is ALREADY taken: an Obstaculo instead of a Vaga.
                # Same slot, so the pitch invariant still governs the spacing;
                # this is how the lot gets real obstacles that do not block the
                # aisle (a car parked in the aisle would).
                parked.append(dict(
                    name="Estacionado_%s" % name, pos=(cx, cy),
                    scale=(bw / OBSTACULO_BASE[0], row["depth"] / OBSTACULO_BASE[1]),
                    rot=0.0 if row["rot"] < 0 else 3.141592653589793))
                continue
            bays.append(dict(name=name, pos=(cx, cy),
                             scale=bs, rot=row["rot"], prep=prep,
                             y_edge=float(row["y_edge"])))
    # cross-row overlap check (cheap AABB sweep)
    for i in range(len(bays)):
        for j in range(i + 1, len(bays)):
            a = bay_rect({"scale": bays[i]["scale"]}, *bays[i]["pos"])
            b = bay_rect({"scale": bays[j]["scale"]}, *bays[j]["pos"])
            if a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]:
                die("bays %s and %s overlap" % (bays[i]["name"], bays[j]["name"]))
    return bays, parked


def rect_of(entry):
    """World AABB of a sidewalk/wall entry: [centre_x, centre_y, w, h]."""
    cx, cy, w, h = entry["rect"]
    return (cx - w / 2.0, cy - h / 2.0, cx + w / 2.0, cy + h / 2.0)


def overlaps(a, b, tol=1.0):
    """Real overlap, not a mere touch: a bay is DRAWN from the sidewalk edge,
    so its back line lands exactly on the kerb and floating point makes an
    equality test flaky. Only > `tol` px of intersection in BOTH axes counts."""
    return (min(a[2], b[2]) - max(a[0], b[0]) > tol
            and min(a[3], b[3]) - max(a[1], b[1]) > tol)


def inside(pt, r):
    return r[0] <= pt[0] <= r[2] and r[1] <= pt[1] <= r[3]


def dist_pt_rect(pt, r):
    """Gap in px from a point to an axis-aligned rect (0 when inside)."""
    dx = max(r[0] - pt[0], pt[0] - r[2], 0.0)
    dy = max(r[1] - pt[1], pt[1] - r[3], 0.0)
    return (dx * dx + dy * dy) ** 0.5


def check_solids(spec, world, bays):
    """Invariants about the STATIC BODIES (walls/sidewalks) and the cones.

    Both defect classes here are unreachable-bay factories and both are silent
    in the scene file: a bay that overlaps a wall can never be entered (the
    car's own sweep cannot fit), and a preparation point inside a wall makes
    A* return an empty route — the car just sits in SEEKING. The cone rule is
    AGENTS #19: a solid cone must stay `swept_radius + cone_radius + 40` px
    from anything the car is meant to drive to.
    """
    walls = [rect_of(s) for s in spec["sidewalks"]]
    x0, y0, x1, y1 = -world[0] / 2, -world[1] / 2, world[0] / 2, world[1] / 2
    for b in bays:
        r = bay_rect({"scale": b["scale"]}, *b["pos"])
        for w in walls:
            if overlaps(r, w):
                die("bay %s overlaps wall rect %s" % (b["name"], w))
        for w in walls:
            if inside(b["prep"], w):
                die("bay %s prep point %s is inside wall rect %s"
                    % (b["name"], b["prep"], w))
        # AGENTS §1.24: nao encostar na parede NAO e' suficiente. A grade do
        # planejador marca solida toda celula dentro de `raio varrido + 1.5
        # celulas` da parede, entao uma baia a 110 px da guia (Fase6, 3 de 13
        # inalcancaveis) tem o CENTRO dentro da faixa inflada e nunca pode ser
        # alcancada — o `gate_reach` e' que mede isso, e o gerador precisa
        # abortar antes, como aborta para sobreposicao.
        need = swept_radius(spec["car_scale"]) + 1.5 * RESOLUCAO + RESOLUCAO
        for w in walls:
            # A parede contra a qual a baia esta ENCOSTADA de proposito (a
            # fileira nasce dela) nao conta: o carro entra de frente e o casco
            # encosta na traseira, como numa vaga de verdade. O que a grade do
            # planejador marca solido e o CENTRO da celula, entao e' o CENTRO da
            # baia (e o ponto de preparacao) que precisa de folga — e com uma
            # celula a mais, porque um centro a 103 px da parede pode cair em
            # celula solida por causa do arredondamento (Fase6: 3 de 13 baias
            # inalcancaveis por causa dos espigões fecharem a faixa, AGENTS §1.24).
            if abs(w[3] - b["y_edge"]) < 0.5 or abs(w[1] - b["y_edge"]) < 0.5:
                continue
            d = dist_pt_rect(b["pos"], w)
            if d < need:
                die("bay %s centre is only %.0f px from wall rect %s (needs "
                    "%.0f = swept radius + 2.5 cells)"
                    % (b["name"], d, w, need))
            dp = dist_pt_rect(b["prep"], w)
            if dp < need:
                die("prep of bay %s is only %.0f px from wall rect %s (needs "
                    "%.0f = swept radius + 2.5 cells)"
                    % (b["name"], dp, w, need))
    clear = swept_radius(spec["car_scale"]) + 18.0 + 40.0
    for i, cone in enumerate(spec.get("cones", []), 1):
        p = (cone["pos"][0], cone["pos"][1])
        if not (x0 < p[0] < x1 and y0 < p[1] < y1):
            die("cone %d at %s outside world" % (i, p))
        for b in bays:
            d = ((p[0] - b["pos"][0]) ** 2 + (p[1] - b["pos"][1]) ** 2) ** 0.5
            if d < clear:
                die("cone %d at %s is %.0f px from bay %s (needs %.0f)"
                    % (i, p, d, b["name"], clear))
            d = ((p[0] - b["prep"][0]) ** 2 + (p[1] - b["prep"][1]) ** 2) ** 0.5
            if d < clear:
                die("cone %d at %s is %.0f px from prep of %s (needs %.0f)"
                    % (i, p, d, b["name"], clear))


def die(msg):
    print("GEN_FAIL %s" % msg)
    sys.exit(1)


XL = 'ExtResource("%s")'


def generate(spec):
    mapa = spec["mapa"]
    # world = imported texture size * escala_mapa. `import_size` lets the spec
    # declare the texture size Godot actually imports (parking_lot.jpg is
    # 6001x5201 on disk but 4095x3550 after `process/size_limit=4096`).
    iw, ih = spec["import_size"]
    world = (iw * spec["escala_mapa"], ih * spec["escala_mapa"])
    bays, parked_cars = build_bays(spec, world)
    col, vis = car_footprint(spec["car_scale"])
    check_solids(spec, world, bays)

    ext = [
        ("Script", "res://scripts/FaseBase.gd", "1_base"),
        ("Texture2D", mapa, "2_map"),
        ("PackedScene", "res://scenes/Obstaculo.tscn", "3_obs"),
        ("PackedScene", "res://scenes/Vaga.tscn", "4_vaga"),
        ("PackedScene", "res://scenes/Carro.tscn", "5_carro"),
        ("Script", "res://scripts/Planejador.gd", "6_plan"),
        ("PackedScene", "res://scenes/Hud.tscn", "7_hud"),
        ("PackedScene", "res://scenes/Seta.tscn", "8_seta"),
        ("PackedScene", "res://scenes/Cone.tscn", "9_cone"),
        ("Script", "res://src/world/Crosser.gd", "10_crosser"),
        ("Script", "res://src/world/Pedestrian.gd", "12_pede"),
        ("Script", "res://src/world/Tire.gd", "13_tire"),
        ("Script", "res://src/world/StalledCar.gd", "14_stalled"),
    ]
    # One ext_resource per UNIQUE actor skin (a texture loaded twice is a
    # Godot warning, and the spec may want two cars of the same colour).
    # The STALLED cars share the dedup list with the crossers: both draw a
    # Kenney car, so the same colour must stay one ext_resource.
    crosser_tex = []
    for c in spec.get("crossers", []):
        t = c.get("texture", "res://assets/kenney/cars/car_yellow_5.png")
        if t not in crosser_tex:
            crosser_tex.append(t)
    for s in spec.get("stalled_cars", []):
        t = s.get("texture", "res://assets/kenney/cars/car_red_5.png")
        if t not in crosser_tex:
            crosser_tex.append(t)
    for i, t in enumerate(crosser_tex):
        ext.append(("Texture2D", t, "11_tex%d" % i))
    sub = []
    for s in spec["sidewalks"]:
        sub.append((s["name"], s["rect"]))

    out = ["[gd_scene format=3]", ""]
    for t, p, i in ext:
        out.append('[ext_resource type="%s" path="%s" id="%s"]' % (t, p, i))
    out.append("")
    for name, rect in sub:
        out.append('[sub_resource type="RectangleShape2D" id="Rect_%s"]' % name)
        out.append("size = Vector2(%s, %s)" % (rect[2], rect[3]))
        out.append("")

    # ---- root ----
    out.append('[node name="%s" type="Node2D"]' % spec["id"])
    out.append('script = %s' % XL % "1_base")
    out.append('mapa = %s' % XL % "2_map")
    out.append("escala_mapa = %s" % spec["escala_mapa"])
    out.append("zoom_camera = %s" % spec["zoom_camera"])
    out.append("posicao_aleatoria = %s" % ("true" if spec.get("posicao_aleatoria", True) else "false"))
    out.append("")

    out.append('[node name="Mapa" type="Sprite2D" parent="."]')
    out.append("scale = Vector2(%s, %s)" % (spec["escala_mapa"], spec["escala_mapa"]))
    out.append('texture = %s' % XL % "2_map")
    out.append("")

    out.append('[node name="Obstaculos" type="Node2D" parent="."]')
    out.append("")
    for name, rect in sub:
        out.append('[node name="%s" type="StaticBody2D" parent="Obstaculos"]' % name)
        out.append("position = Vector2(%s, %s)" % (rect[0], rect[1]))
        out.append("collision_layer = 2")
        out.append("")
        out.append('[node name="Colisao" type="CollisionShape2D" parent="Obstaculos/%s"]' % name)
        out.append('shape = SubResource("Rect_%s")' % name)
        out.append("")
    for car in list(parked_cars) + list(spec.get("parked_cars", [])):
        out.append('[node name="%s" parent="Obstaculos" instance=%s]' % (car["name"], XL % "3_obs"))
        out.append("position = Vector2(%s, %s)" % (car["pos"][0], car["pos"][1]))
        out.append("scale = Vector2(%.4f, %.4f)" % (car["scale"][0], car["scale"][1]))
        if car.get("rot"):
            out.append("rotation = %s" % car["rot"])
        out.append("")

    for i, cone in enumerate(spec.get("cones", []), 1):
        out.append('[node name="Cone%d" parent="Obstaculos" instance=%s]' % (i, XL % "9_cone"))
        out.append("position = Vector2(%s, %s)" % (cone["pos"][0], cone["pos"][1]))
        out.append("")

    out.append('[node name="Setas" type="Node2D" parent="."]')
    out.append("")
    for i, s in enumerate(spec.get("setas", []), 1):
        out.append('[node name="Seta%d" parent="Setas" instance=%s]' % (i, XL % "8_seta"))
        out.append("position = Vector2(%s, %s)" % (s["pos"][0], s["pos"][1]))
        if s.get("direcao") is not None:
            out.append("direcao = %s" % s["direcao"])
        out.append("")

    out.append('[node name="Rotas" type="Node2D" parent="."]')
    out.append("")
    for r in spec.get("rotas", []):
        pts = ", ".join("%s, %s" % (p[0], p[1]) for p in r["points"])
        out.append('[node name="%s" type="Line2D" parent="Rotas"]' % r["name"])
        out.append("points = PackedVector2Array(%s)" % pts)
        out.append("width = 4.0")
        out.append("default_color = Color(0.2, 0.8, 1, 0.6)")
        out.append("")

    out.append('[node name="Paredes" type="Node2D" parent="."]')
    out.append("")
    out.append('[node name="Waypoints" type="Node2D" parent="."]')
    out.append("")

    out.append('[node name="Vagas" type="Node2D" parent="."]')
    out.append("")
    for b in bays:
        out.append('[node name="%s" parent="Vagas" instance=%s]' % (b["name"], XL % "4_vaga"))
        out.append("position = Vector2(%s, %s)" % (b["pos"][0], b["pos"][1]))
        out.append("scale = Vector2(%s, %s)" % (b["scale"][0], b["scale"][1]))
        out.append("rotacao_alvo = %s" % b["rot"])
        out.append("")

    out.append('[node name="Carro" parent="." instance=%s]' % (XL % "5_carro"))
    out.append("position = Vector2(%s, %s)" % (spec["car_pos"][0], spec["car_pos"][1]))
    out.append("scale = Vector2(%s, %s)" % (spec["car_scale"], spec["car_scale"]))
    out.append("auto_navegacao = true")
    out.append("modo_trilha = false")
    out.append("brain_enabled = true")
    out.append("keep_right_shift = %s" % spec.get("keep_right_shift", 300.0))
    # The declarative knob for "which spot should the route end in" (AGENTS
    # #15: honoured by the autonomous branch too, exactly like the trail's).
    # A transit level uses it to force the LONG route across the aisle.
    if spec.get("vaga_prioritaria"):
        out.append("vaga_prioritaria = NodePath(\"%s\")" % spec["vaga_prioritaria"])
    # FAROL rollout switch. DEFAULT 0 on purpose: a level is promoted one at a
    # time, by DECLARING it here, so regenerating a spec can never silently turn
    # the pilot on in a level nobody reviewed (the promotion rule is in
    # .kilo/plans/1790717727010-swift-squid.md §4: 0 = legacy, 1 = shadow
    # (measures, does not drive), 2 = the FAROL pilot drives).
    out.append("farol_mode = %d" % int(spec.get("farol_mode", 0)))
    # FAROL · ROTA (S2): the right-hand rule as A* cost. Same promotion
    # discipline as farol_mode: default 0 (the post-hoc LaneOffset shift),
    # declared per level in the spec, reviewed one level at a time.
    out.append("lane_cost_mode = %d" % int(spec.get("lane_cost_mode", 0)))
    out.append("")

    out.append('[node name="Planejador" type="Node2D" parent="."]')
    out.append('script = %s' % XL % "6_plan")
    out.append("")

    for i, c in enumerate(spec.get("crossers", []), 1):
        tex = c.get("texture", "res://assets/kenney/cars/car_yellow_5.png")
        out.append('[node name="%s" type="Node2D" parent="."]' % c.get("name", "CarroDeTransito%d" % i))
        out.append("position = Vector2(%s, %s)" % (c["pos"][0], c["pos"][1]))
        out.append('script = %s' % (XL % "10_crosser"))
        out.append("point_a = Vector2(%s, %s)" % (c["point_a"][0], c["point_a"][1]))
        out.append("point_b = Vector2(%s, %s)" % (c["point_b"][0], c["point_b"][1]))
        out.append("cruise_speed = %s" % c.get("cruise_speed", 160.0))
        out.append("pause_time = %s" % c.get("pause_time", 0.85))
        out.append("spawn_distance = %s" % c.get("spawn_distance", 700.0))
        out.append("trigger_distancia = %s" % c.get("trigger_distancia", 900.0))
        out.append("")
        # The Kenney art faces -Y: the child carries the +90 deg, exactly like
        # Carro.tscn / Crosser.gd, so the node rotation IS the world heading
        # and the car never drives sideways (AGENTS #29).
        out.append('[node name="Sprite" type="Sprite2D" parent="%s"]'
                   % c.get("name", "CarroDeTransito%d" % i))
        out.append("rotation = 1.5708")
        out.append("scale = Vector2(1.62, 1.62)")
        out.append('texture = %s' % (XL % ("11_tex%d" % crosser_tex.index(tex))))
        out.append("")

    # TRAZEGO actors (docs/tasks_trafego.md T2). The PEDESTRIAN is sensor-only
    # (group "pedestre" — the car YIELDS, never runs one over); the TIRE is a
    # solid hazard the car DODGES (its body is built in _ready, so no
    # sub_resources here); the STALLED car is the accident that exercises the
    # blocked_ahead -> detour reactive layer.
    for i, p in enumerate(spec.get("pedestrians", []), 1):
        nome = p.get("name", "Pedestre%d" % i)
        out.append('[node name="%s" type="Node2D" parent="."]' % nome)
        out.append("position = Vector2(%s, %s)" % (p["pos"][0], p["pos"][1]))
        out.append('script = %s' % (XL % "12_pede"))
        out.append("point_a = Vector2(%s, %s)" % (p["point_a"][0], p["point_a"][1]))
        out.append("point_b = Vector2(%s, %s)" % (p["point_b"][0], p["point_b"][1]))
        out.append("walk_speed = %s" % p.get("walk_speed", 55.0))
        out.append("pause_time = %s" % p.get("pause_time", 2.0))
        out.append("spawn_distance = %s" % p.get("spawn_distance", 700.0))
        out.append("initial_delay = %s" % p.get("initial_delay", 0.0))
        out.append("head_start_px = %s" % p.get("head_start_px", 0.0))
        out.append("")

    for i, t in enumerate(spec.get("tires", []), 1):
        out.append('[node name="Tire%d" type="StaticBody2D" parent="."]' % i)
        out.append("position = Vector2(%s, %s)" % (t["pos"][0], t["pos"][1]))
        out.append('script = %s' % (XL % "13_tire"))
        out.append("point_a = Vector2(%s, %s)" % (t["point_a"][0], t["point_a"][1]))
        out.append("point_b = Vector2(%s, %s)" % (t["point_b"][0], t["point_b"][1]))
        out.append("roll_speed = %s" % t.get("roll_speed", 70.0))
        out.append("pause_time = %s" % t.get("pause_time", 1.5))
        out.append("spawn_distance = %s" % t.get("spawn_distance", 500.0))
        out.append("initial_delay = %s" % t.get("initial_delay", 0.0))
        out.append("head_start_px = %s" % t.get("head_start_px", 0.0))
        out.append("")

    for i, s in enumerate(spec.get("stalled_cars", []), 1):
        nome = s.get("name", "CarroAcidentado%d" % i)
        tex = s.get("texture", "res://assets/kenney/cars/car_red_5.png")
        out.append('[node name="%s" type="StaticBody2D" parent="."]' % nome)
        out.append("position = Vector2(%s, %s)" % (s["pos"][0], s["pos"][1]))
        out.append('script = %s' % (XL % "14_stalled"))
        out.append("point_a = Vector2(%s, %s)" % (s["point_a"][0], s["point_a"][1]))
        out.append("point_b = Vector2(%s, %s)" % (s["point_b"][0], s["point_b"][1]))
        out.append("drive_speed = %s" % s.get("drive_speed", 140.0))
        out.append("stall_after_px = %s" % s.get("stall_after_px", 600.0))
        out.append("spawn_distance = %s" % s.get("spawn_distance", 700.0))
        out.append("initial_delay = %s" % s.get("initial_delay", 0.0))
        out.append("")
        # The Kenney art faces -Y: the child carries the +90 deg, exactly like
        # Carro.tscn / Crosser.gd (AGENTS #29). The collision box (190x88) is
        # built by the script in _ready, long axis on node X = the facing.
        out.append('[node name="Sprite" type="Sprite2D" parent="%s"]' % nome)
        out.append("rotation = 1.5708")
        out.append("scale = Vector2(1.62, 1.62)")
        out.append('texture = %s' % (XL % ("11_tex%d" % crosser_tex.index(tex))))
        out.append("")

    out.append('[node name="Camera" type="Camera2D" parent="."]')
    out.append("")
    out.append('[node name="UI" type="CanvasLayer" parent="."]')
    out.append("")
    out.append('[node name="Control" parent="UI" instance=%s]' % (XL % "7_hud"))
    out.append("")

    text = "\n".join(out)
    # AGENTS #40: never write a scene file without counting the headers.
    rendered = text.count("[node ")
    parsed = len(re.findall(r"^\[node ", text, re.M))
    if rendered != parsed:
        die("header render mismatch: %d rendered vs %d parseable" % (rendered, parsed))
    print("GEN_OK %s bays=%d nodes=%d world=(%.0f x %.0f) car_col=(%.0f x %.0f) car_vis=(%.0f x %.0f) swept_r=%.1f prep_reach=%.1f"
          % (spec["id"], len(bays), rendered, world[0], world[1], col[0], col[1],
             vis[0], vis[1], swept_radius(spec["car_scale"]), prep_reach(spec["car_scale"])))
    return text, bays


def main():
    spec_path = sys.argv[1]
    spec = json.load(open(spec_path, encoding="utf-8"))
    text, bays = generate(spec)
    out_path = spec.get("output", "scenes/fases/%s.tscn" % spec["id"])
    if "--dry-run" in sys.argv:
        print("(dry run, not written)")
        return
    old = ""
    if os.path.exists(out_path):
        old = open(out_path, encoding="utf-8").read()
    old_nodes = len(re.findall(r"^\[node ", old, re.M))
    new_nodes = len(re.findall(r"^\[node ", text, re.M))
    # AGENTS #40: um script que reescreve cena DEVE contar os cabecalhos antes e
    # depois e abortar se perder algum (dois incidentes ja destruiram as 6
    # cenas, e a recuperacao veio do .pck do export).
    if "[gd_scene" not in text or new_nodes == 0:
        sys.exit("GEN_ABORTOU: cena gerada sem cabecalho [gd_scene] ou sem nodes")
    open(out_path, "w", encoding="utf-8").write(text)
    lido = open(out_path, encoding="utf-8").read()
    lido_nodes = len(re.findall(r"^\[node ", lido, re.M))
    if lido_nodes != new_nodes:
        sys.exit("GEN_ABORTOU: escreveu %d nodes e releu %d" % (new_nodes, lido_nodes))
    print("GEN_WROTE %s (%d vagas, %d nodes, antes %d)" % (
        out_path, len(bays), new_nodes, old_nodes))


if __name__ == "__main__":
    main()
