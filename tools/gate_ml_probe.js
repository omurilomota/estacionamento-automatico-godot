/* GATE 5 (lado B) — roda o MESMO site/js/ml.js que o navegador carrega.
 *
 * Uso: node tools/gate_ml_probe.js /tmp/gate_ml_godot.log
 * Requer o log do lado A (godot --headless --path . --script tools/gate_ml_probe.gd).
 * Passa com pior |diff| <= 1e-6 nas duas saidas.
 */
'use strict';

const fs = require('fs');
const path = require('path');

const RAIZ = path.resolve(__dirname, '..');
const ml = require(path.join(RAIZ, 'site/js/ml.js'));

const vetor = JSON.parse(fs.readFileSync(path.join(RAIZ, 'tools/ml_probe_vector.json'), 'utf8'));
const pesos = JSON.parse(fs.readFileSync(path.join(RAIZ, 'site/data/pesos.json'), 'utf8'));
const log = fs.readFileSync(process.argv[2] || '/tmp/gate_ml_godot.log', 'utf8');

function pick(tag) {
  const m = log.match(new RegExp('^' + tag + '\\s*=\\s*(-?[0-9.]+)$', 'm'));
  if (!m) throw new Error('nao encontrei ' + tag + ' no log do Godot');
  return parseFloat(m[1]);
}

const net = ml.fromJSON(pesos);
const r = net.forward(vetor);
console.log('JS_ESTERCAMENTO = ' + r.out[0].toFixed(12));
console.log('JS_VELOCIDADE   = ' + r.out[1].toFixed(12));

const godot = [pick('GODOT_ESTERCAMENTO'), pick('GODOT_VELOCIDADE')];
const js = [r.out[0], r.out[1]];
let pior = 0;
for (let i = 0; i < 2; i++) {
  const d = Math.abs(godot[i] - js[i]);
  pior = Math.max(pior, d);
  console.log('diff[' + i + '] = ' + d.toExponential(3));
}
console.log('pior_diff = ' + pior.toExponential(3));
const ok = pior <= 1e-6;
console.log(ok ? 'GATE_ML_OK' : 'GATE_ML_FALHOU');
process.exit(ok ? 0 : 1);
