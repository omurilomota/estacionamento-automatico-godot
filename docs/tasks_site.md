# Tasks — Theme Site (panel-style presentation + build log)

> RESUMO PT-BR: site estatico em `site/` (PT-BR), isolado do Godot
> (fora do .pck via exclude_filter), pronto p/ GitHub Pages. Cada secao
> explica o que fizemos + mostra onde ver na simulacao. Conteudo maximiza
> explicacao p/ banca: FSM+A*+sensores visiveis, tabela honesta
> Fase2/Fase3 OK vs Fase1/4/5 fora de escopo, ML como capitulo avancado.

## Locked decisions

- Scope: full site (hero, IA explicada, fases, time, download), static, NO web export.
- Language: site in PT-BR (presentation piece); game code/docs stay English per AGENTS.md.
- `site/` never references `res://`; PNGs are copied, never `.import`.
- Real screenshots only after F3 green; placeholders until then.
- Local test: `python3 -m http.server`; publish via GitHub Pages.
- **SUPERSEDED 2026-09-26** (backlog §1.11): the web export is NOT off — the
  game runs in the page (`site/game/`, 6.2 MB .pck + 39.5 MB .wasm), and the
  publish target is **Vercel**, not GitHub Pages. The `vercel.json` (cache +
  `nosniff` rules) and the project link (`site/.vercel/project.json`) live
  inside `site/` ONLY; run `vercel --prod --yes` from that directory.
  `site/data/` is a generated copy of `ml/modelo/` (never hand-edited — see
  AGENTS #26) and the gallery images are re-encoded down, never copied raw.

## Sections (each = explanation + where-to-see-in-sim)

1. Hero (pitch + Jogar/Ver a IA buttons)
2. O problema (decide rota sozinho, vague livre, entrada de frente)
3. Como funciona (VER/DECIDIR/AGIR cards)
4. FSM (SEEKING/AVOIDING/ALIGNING/PARKED/RECOVERING: enter/exit)
5. A* planner (occupancy grid + route prints)
6. Sensores (12 rays + snapshot 22)
7. ML (gravar->treinar->testar + honest limits)
8. Resultados (Fase2/Fase3 numbers; Fase1/4/5 out-of-scope w/ reason)
9. Time (Gian/Murilo/Matheus)
10. Download (.x86_64) + Como jogar (1-5, R)

## Tasks

- [x] S1 scaffold: site/index.html + styles.css + main.js + assets/ (asphalt+neon theme, tabs, placeholders). Excluded from export.
- [x] S2 banca content: PT-BR texts, FSM/A*/sensor/ML sections, honest results table, team, download + controls.
- [x] S3 polish+Pages: local http test, exclude_filter in preset, publish instructions.

## Run log

| date | task | command | result |
|---|---|---|---|
| 2026-09-25 | real game-state banner images | Godot headless dump -> /tmp/mkshots.py (PIL) | fase2.png + fase3.png (1600x900, real floor/route/car) |
| 2026-09-25 | fix OOM in image pipeline | Godot 1x raster (ThorVG) instead of cairosvg | cairosvg hit 13 GB RSS and was OOM-killed; new path peaks at a few MB |
| 2026-09-25 | slim exports | vehicles/.gdignore + site/.gdignore, exclude_filter in both presets | web .pck 255 MB -> 6.2 MB; Linux .pck 6.2 MB |
| 2026-09-25 | web export | `--export-release Web site/game/index.html` | site/game/ complete (wasm 39 MB, pck 6.2 MB) |
| 2026-09-25 | linux export | `--export-release Linux` | "Estacionamento Autônomo.x86_64" (73 MB) + .pck |
| 2026-09-25 | local http test | python3 -m http.server + curl | all site refs 200; game/index.html live |

## Honest review (fill at S3)

- What passed: local HTTP test green; both banner images are real engine dumps; web export loads (index.html + wasm + pck); Linux binary exports clean.
- What failed and why: cairosvg at world scale OOM-killed at 13 GB (parking_lot3.svg); first export embedded vehicles/ (435 MB, no code refs) and blew the timeout; site PNGs got .import pollution until site/.gdignore.
- What I would not do again: rasterise big SVGs in pure-Python at world scale; export before checking what the pck embeds (du + grep Storing File).
- Next steps: publish to GitHub Pages / Vercel; attach .x86_64 to a release and point the download button at it.

## Run log (2 — 2026-09-26)

| date | task | command | result |
|---|---|---|---|
| 2026-09-26 | site data as a reproducible copy | `bash tools/export_site_data.sh` | `site/data/{pesos,evolucao_historico}.json` + contract check (`[22,32,16,2]`, 22 mu/sigma, no sigma <= 0) |
| 2026-09-26 | 5 floors + 5 car skins in the gallery | Godot 1x SVG raster (`/tmp/lotpng.gd`, ThorVG) + PIL resize only | `site/img` 1.8 MB, long side <= 1600 px (raw sources would be 21 MB) |
| 2026-09-26 | neural playground | `site/js/ml.js` (one math, exported to node) | 22 sliders, live outputs, 3 weight matrices, z-score per input |
| 2026-09-26 | numeric gate (browser math == game math) | `/tmp/ml_probe.gd` + `node /tmp/ml_js_probe.js` | worst diff 4.043e-13 (limit 1e-6) → `GATE_ML_OK` |
| 2026-09-26 | UI smoke gate | `node /tmp/ml_ui_smoke.js` (DOM shim) | `GATE_UI_OK`; caught 2 real bugs before deploy |
| 2026-09-26 | stale metrics corrected | — | 27,6 s → 32,5 s, "110 px" → 177/151 px, ML wording, key bar (`G` for the grid does not exist) |
| 2026-09-26 | publish | `vercel --prod --yes` from `site/` | live URL; `/data/pesos.json` and `/game/index.wasm` verified 200 |

## Run log (3 — 2026-09-27, release v0.4.0)

| date | task | command | result |
|---|---|---|---|
| 2026-09-27 | data re-synced before deploy | `bash tools/export_site_data.sh` | `EXPORT_DATA_OK`, contract `[22,32,16,2]`; `site/data` byte-identical to `ml/modelo`, so no commit |
| 2026-09-27 | web export | `bash tools/export_web.sh` | `EXPORT_OK site/game`, `index.pck` 6 648 520 B |
| 2026-09-27 | publish | `vercel --prod --yes` from `site/` | **https://site-pi-tan-51.vercel.app** |
| 2026-09-27 | live check | `curl` on the alias | `/` `200`, `/game/index.{html,pck}` `200`, `index.pck` = 6 648 520 B = the local build, **0 `location` headers** (AGENTS #33) |

**The alias moved and nothing in the repo said so.** `estacionamento-automatico.vercel.app`
answers **404**: the project belongs to the team
`murilohenriquemota935-1958s-projects`, so the production alias is scoped to
`site-pi-tan-51.vercel.app`. The dead URL survives in commit messages
(`aaaf037`), so `grep` finds it and it looks authoritative. Two other traps in
the same check:

- the per-deployment URL (`estacionamento-automatico-<hash>.vercel.app`) answers
  `302` to `vercel.com/sso-api` — that is Deployment Protection, **not** a
  broken site. Test the alias;
- `vercel ls` prints several "Ready" deployments and the newest one is not
  necessarily the one behind the alias; read `Aliases` from `vercel inspect`,
  never the first URL of the list.


Honest review (round 2):

- What passed: the cross-language gate is real — the node probe loads the
  browser file itself, so a duplicated math implementation would fail it. Two
  genuine UI bugs (unpainted weight matrices, a missing output-activation
  array that threw before the readouts were painted) were caught by the DOM
  shim, not by reading the code.
- What I would not do again: trusting a page's numbers because they were
  written "a while ago" — every figure on the site is now a row of the
  §1.10.6 gate table or it is not on the site.
- Next steps: attach the `.x86_64` to a release and point the download button
  at it; DAgger so the 8 constant inputs get real data.
