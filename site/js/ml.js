/* Estacionamento Autônomo — playground da rede neural (imitação de comportamento).
 *
 * Este arquivo tem DUAS camadas e UMA matemática:
 *   1. núcleo puro (MlpNet) — espelha EXATAMENTE scripts/CerebroML.gd
 *      (float64, w[i][o], piso de sigma em 1e-8, tanh nas 2 ocultas,
 *      saída linear). É o mesmo passo de frente de ml/treinar.py.
 *   2. UI — 22 sliders, saídas ao vivo, matrizes de pesos. Só roda se
 *      existir `document`.
 *
 * O núcleo é exportado em Node (module.exports) para que o gate numérico
 * rode ESTE arquivo — e não uma cópia paralela da matemática.
 */
'use strict';

var MlPlayground = (function () {
	var CHAVES = ['w1', 'b1', 'w2', 'b2', 'b3', 'x_mean', 'x_std'];
	var PISO_SIGMA = 1e-8; // CerebroML.gd: maxf(std, 1e-8)

	/* ---------------------------------------------------------------- núcleo */

	function MlpNet(json) {
		if (!json) throw new Error('MlpNet: modelo vazio');
		for (var k = 0; k < CHAVES.length; k++) {
			if (!json[CHAVES[k]]) throw new Error('MlpNet: chave ausente "' + CHAVES[k] + '"');
		}
		this.w1 = json.w1;
		this.b1 = json.b1;
		this.w2 = json.w2;
		this.b2 = json.b2;
		this.w3 = json.w3;
		this.b3 = json.b3;
		this.x_mean = json.x_mean;
		this.x_std = json.x_std;
		this.arquitetura = json.arquitetura || [
			this.x_mean.length, this.w1[0].length, this.w2[0].length, this.w3[0].length,
		];
		this.val_mse = typeof json.val_mse === 'number' ? json.val_mse : null;
	}

	/* Normaliza com a MESMA média/desvio do treino (CerebroML.inferir). */
	MlpNet.prototype.zScore = function (valores) {
		var n = this.x_mean.length;
		if (valores.length !== n) {
			throw new Error('MlpNet: esperava ' + n + ' entradas, recebeu ' + valores.length);
		}
		var z = new Array(n);
		for (var i = 0; i < n; i++) {
			var sigma = this.x_std[i] > PISO_SIGMA ? this.x_std[i] : PISO_SIGMA;
			z[i] = (valores[i] - this.x_mean[i]) / sigma;
		}
		return z;
	};

	/* w veio do numpy com shape (n_entradas, n_saidas): w[i][o].
	 * A ordem da soma é a mesma do GDScript (bias primeiro, depois i). */
	MlpNet.prototype.camada = function (entrada, w, b, ativa_tanh) {
		var n_out = w[0].length;
		var saida = new Array(n_out);
		for (var o = 0; o < n_out; o++) {
			var soma = b[o];
			for (var i = 0; i < entrada.length; i++) soma += entrada[i] * w[i][o];
			saida[o] = ativa_tanh ? Math.tanh(soma) : soma;
		}
		return saida;
	};

	/* h1 = tanh(x@w1+b1); h2 = tanh(h1@w2+b2); out = h2@w3+b3 */
	MlpNet.prototype.forward = function (valores) {
		var z = this.zScore(valores);
		var h1 = this.camada(z, this.w1, this.b1, true);
		var h2 = this.camada(h1, this.w2, this.b2, true);
		var out = this.camada(h2, this.w3, this.b3, false);
		return { z: z, h1: h1, h2: h2, out: out };
	};

	function fromJSON(json) {
		return new MlpNet(json);
	}

	function loadWeights(url) {
		if (typeof fetch !== 'function') {
			return Promise.reject(new Error('sem fetch neste ambiente'));
		}
		return fetch(url, { cache: 'no-cache' })
			.then(function (r) {
				if (!r.ok) throw new Error('HTTP ' + r.status + ' em ' + url);
				return r.json();
			})
			.then(fromJSON);
	}

	/* ------------------------------------------------ contrato v2 (22 slots)
	 * Ordem e normalização espelham Carro._ml_features() (scripts/Carro.gd:2420)
	 * e o cabeçalho de src/vehicle/DatasetRecorder.gd. `morta` marca slot que
	 * o dataset v2 nunca varia — o z-score dele é literalmente (v - mu) / 1.
	 */
	var CONTRATO = [
		{ rotulo: 'Raio frente — centro', sensor: 'RayFrenteCentro', min: 0, max: 1 },
		{ rotulo: 'Raio frente — esquerda', sensor: 'RayFrenteEsq', min: 0, max: 1 },
		{ rotulo: 'Raio frente — direita', sensor: 'RayFrenteDir', min: 0, max: 1 },
		{ rotulo: 'Raio lateral — esquerda', sensor: 'RayEsquerda', min: 0, max: 1 },
		{ rotulo: 'Raio lateral — direita', sensor: 'RayDireita', min: 0, max: 1 },
		{ rotulo: 'Raio traseiro', sensor: 'RayTras', min: 0, max: 1 },
		{ rotulo: 'Raio longo — centro', sensor: 'RayFrenteLongo', min: 0, max: 1 },
		{ rotulo: 'Raio longo — esquerda', sensor: 'RayFrenteLongoEsq', min: 0, max: 1 },
		{ rotulo: 'Raio longo — direita', sensor: 'RayFrenteLongoDir', min: 0, max: 1 },
		{ rotulo: 'Raio varredura — esquerda', sensor: 'RayLateralEsq', min: 0, max: 1 },
		{ rotulo: 'Raio varredura — direita', sensor: 'RayLateralDir', min: 0, max: 1 },
		{ rotulo: 'Velocidade atual (÷ máx., ré é negativo)', sensor: 'velocidade_atual / velocidade_maxima', min: -1, max: 1 },
		{ rotulo: 'Distância até a vaga (÷ 2500 px)', sensor: 'dist_vaga / 2500', min: 0, max: 1 },
		{ rotulo: 'sen(erro até a vaga)', sensor: 'sin(erro_vaga)', min: -1, max: 1 },
		{ rotulo: 'cos(erro até a vaga)', sensor: 'cos(erro_vaga)', min: -1, max: 1 },
		{ rotulo: 'Seta 0 — slot MORTO (sempre 0 no dataset)', sensor: 'seta_0', min: 0, max: 1, morta: true },
		{ rotulo: 'Seta 1 — slot MORTO (sempre 0 no dataset)', sensor: 'seta_1', min: 0, max: 1, morta: true },
		{ rotulo: 'Seta 2 — slot MORTO (sempre 0 no dataset)', sensor: 'seta_2', min: 0, max: 1, morta: true },
		{ rotulo: 'Erro de rumo vs. rumo da vaga (÷ π)', sensor: 'yaw_error / PI', min: -1, max: 1 },
		{ rotulo: 'Largura do corredor (÷ 2000 px)', sensor: 'largura_corredor / 2000', min: 0, max: 1 },
		{ rotulo: 'Carro que cruza (1,0 = nenhum no dataset)', sensor: 'crosser_dist / 2500', min: 0, max: 1, morta: true },
		{ rotulo: 'Tempo parado (÷ 10 s)', sensor: 'tempo_parado / 10', min: 0, max: 1 },
	];

	/* Vetores de 22 valores coerentes com _ml_features(): 11 raios (0 colado,
	 * 1 livre), estercamento > 0 = direita (rotation += v/entre_eixos*tan(δ)).
	 */
	var PRESETS = [
		{
			nome: 'Parado no corredor',
			valores: [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0.35, 0, 1, 0, 0, 0, 0, 0.45, 1, 0],
		},
		{
			nome: 'Curva à direita',
			valores: [0.9, 0.95, 1, 0.8, 0.95, 1, 1, 1, 1, 0.85, 0.95, 0.5, 0.5, 0.6, 0.8, 0, 0, 0, 0.3, 0.4, 1, 0],
		},
		{
			nome: 'Desvio de obstáculo',
			valores: [0.12, 0.3, 0.9, 0.2, 0.95, 1, 0.9, 0.5, 1, 0.25, 0.95, 0.4, 0.6, 0.2, 0.98, 0, 0, 0, 0.1, 0.35, 1, 0.3],
		},
		{
			nome: 'Entrando na vaga',
			valores: [0.7, 0.8, 0.6, 0.9, 0.9, 0.9, 0.8, 0.8, 0.8, 0.8, 0.8, 0.05, 0.04, 0.05, 0.999, 0, 0, 0, 0.02, 0.3, 1, 0.6],
		},
	];

	/* -------------------------------------------------------------------- UI */

	function el(tag, props, filhos) {
		var n = document.createElement(tag);
		if (props) {
			for (var k in props) {
				if (!Object.prototype.hasOwnProperty.call(props, k)) continue;
				if (k === 'texto') n.textContent = props[k];
				else if (k === 'html') n.innerHTML = props[k];
				else if (k.slice(0, 2) === 'on') n.addEventListener(k.slice(2), props[k]);
				else n.setAttribute(k, props[k]);
			}
		}
		(filhos || []).forEach(function (f) {
			n.appendChild(typeof f === 'string' ? document.createTextNode(f) : f);
		});
		return n;
	}

	function fmt(v, casas) {
		return (v < 0 ? '' : ' ') + v.toFixed(casas === undefined ? 6 : casas);
	}

	function bgSinal(v, escala, positivo, negativo) {
		var a = Math.min(0.92, Math.abs(v) / escala * 0.9);
		if (a < 0.02) return 'rgba(255,255,255,.04)';
		return v >= 0
			? 'rgba(' + positivo + ',' + a.toFixed(3) + ')'
			: 'rgba(' + negativo + ',' + a.toFixed(3) + ')';
	}

	var POS = '0,229,255';
	var NEG = '247,201,72';
	var ESCALA_PESO = 0.45;

	/* Slots que o gravador v2 nunca variou: sigma cai no piso 1.0 de
	 * treinar.py, logo (mu, sigma) == (0, 1) ou (1, 1) => coluna constante. */
	function slotsConstantes(rede) {
		var out = [];
		for (var i = 0; i < rede.x_mean.length; i++) {
			if (rede.x_std[i] === 1.0 && (rede.x_mean[i] === 0.0 || rede.x_mean[i] === 1.0)) out.push(i);
		}
		return out;
	}

	function montarUI(rede) {
		var raiz = document.getElementById('ml-playground');
		if (!raiz) return;
		raiz.textContent = '';

		var constantes = slotsConstantes(rede);
		var valores = PRESETS[0].valores.slice();
		var slots = [];
		var saidas = { texto: [], barra: [], z: [], valor: [] };
		var celulas_ativacao = { h1: [], h2: [], out: [] };
		var colunas = {};
		var agendado = false;

		raiz.appendChild(el('p', { class: 'ml-nota', texto:
			'Rede carregada de data/pesos.json — arquitetura ' + rede.arquitetura.join('-') +
			', erro de validação ' + (rede.val_mse === null ? '?' : rede.val_mse.toExponential(2)) +
			'. É o MESMO pesos.json que a engine carrega em CerebroML.gd; este parágrafo ' +
			'não é uma reimplementação.' }));

		/* --- presets --- */
		var botoes = [];
		PRESETS.forEach(function (p) {
			botoes.push(el('button', {
				class: 'ml-btn', type: 'button', texto: p.nome,
				onclick: function () { aplicar(p.valores); },
			}));
		});
		botoes.push(el('button', {
			class: 'ml-btn', type: 'button', texto: 'Zerar tudo',
			onclick: function () { aplicar(new Array(22).fill(0)); },
		}));
		botoes.push(el('button', {
			class: 'ml-btn', type: 'button', texto: 'Aleatório',
			onclick: function () {
				var v = [];
				for (var i = 0; i < 22; i++) {
					var s = CONTRATO[i];
					v.push(s.min + Math.random() * (s.max - s.min));
				}
				aplicar(v);
			},
		}));
		raiz.appendChild(el('div', { class: 'ml-presets' }, botoes));

		/* --- layout: entradas | saídas --- */
		var lista = el('div', { class: 'ml-entradas' });
		CONTRATO.forEach(function (slot, i) {
			var fixo = constantes.indexOf(i) >= 0;
			var bruto = el('span', { class: 'ml-bruto' });
			var zc = el('span', { class: 'ml-z' });
			var input = el('input', {
				type: 'range', min: slot.min, max: slot.max, step: '0.01',
				value: valores[i], 'aria-label': slot.rotulo,
			});
			input.addEventListener('input', function () {
				valores[i] = parseFloat(input.value);
				agendar();
			});
			saidas.texto.push(bruto);
			saidas.z.push(zc);
			slots.push(input);
			var topo = [
				el('span', { class: 'ml-num', texto: String(i) }),
				el('span', { class: 'ml-rot', texto: slot.rotulo }),
				el('code', { texto: slot.sensor }),
			];
			if (fixo) topo.push(el('span', {
				class: 'ml-badge',
				texto: 'constante: mu=' + rede.x_mean[i] + ', sigma=' + rede.x_std[i],
			}));
			lista.appendChild(el('div', { class: 'ml-linha' + (slot.morta || fixo ? ' morta' : '') }, [
				el('div', { class: 'ml-linha-topo' }, topo),
				el('div', { class: 'ml-linha-base' }, [input, bruto, zc]),
			]));
		});

		var painel = el('div', { class: 'ml-painel' });
		['estercamento', 'velocidade'].forEach(function (nome, k) {
			var barra = el('i');
			var valor = el('strong', { class: 'ml-out-valor' });
			saidas.barra.push(barra);
			saidas.valor.push(valor);
			painel.appendChild(el('div', { class: 'ml-out' }, [
				el('div', { class: 'ml-out-topo' }, [
					el('span', { texto: nome === 'estercamento' ? 'estercamento (−1 esquerda · +1 direita)' : 'velocidade desejada (0 parado · 1 cheia)' }),
					valor,
				]),
				el('div', { class: 'ml-barra' }, [barra]),
			]));
		});
		['h1 (32 · tanh)', 'h2 (16 · tanh)', 'saída (2 · linear)'].forEach(function (rotulo, k) {
			var chave = k === 0 ? 'h1' : (k === 1 ? 'h2' : 'out');
			var n = chave === 'h1' ? rede.arquitetura[1] : (chave === 'h2' ? rede.arquitetura[2] : rede.arquitetura[3]);
			var grade = el('div', { class: 'ml-ativ' });
			for (var i = 0; i < n; i++) {
				var c = el('i', { title: chave + '[' + i + ']' });
				celulas_ativacao[chave].push(c);
				grade.appendChild(c);
			}
			painel.appendChild(el('div', { class: 'ml-bloco' }, [
				el('h4', { texto: 'Ativações ' + rotulo }),
				grade,
				el('p', { class: 'ml-legenda', texto: 'ciano = sinal positivo · amarelo = negativo' }),
			]));
		});

		raiz.appendChild(el('p', { class: 'ml-constantes', texto:
			'Derivação do dataset v2: ' + constantes.length + ' das 22 entradas são ' +
			'CONSTANTES (sigma no piso 1.0 de treinar.py) — slots ' + constantes.join(', ') +
			'. Os 3 slots de seta e o do carro que cruza nunca tiveram dado, então a rede ' +
			've um sinal quase plano; é exatamente por isso que o estacionamento ainda ' +
			'confia no fallback da FSM.' }));

		raiz.appendChild(el('div', { class: 'ml-duas' }, [lista, painel]));

		/* --- matrizes de pesos --- */
		var specs = [
			{ chave: 'w1', rotulo: 'w1 — entrada 22 × h1 32', linhas: CONTRATO.map(function (s, i) { return i + ' ' + s.sensor; }), alvo: 'h1' },
			{ chave: 'w2', rotulo: 'w2 — h1 32 × h2 16', linhas: null, alvo: 'h2' },
			{ chave: 'w3', rotulo: 'w3 — h2 16 × saída 2', linhas: null, alvo: 'out' },
		];
		specs.forEach(function (spec) {
			var w = rede[spec.chave];
			var grade = el('div', { class: 'matriz' });
			grade.style.gridTemplateColumns = '92px repeat(' + w[0].length + ', minmax(6px, 1fr))';
			grade.appendChild(el('span', { class: 'matriz-canto', texto: spec.rotulo }));
			for (var o = 0; o < w[0].length; o++) grade.appendChild(el('span', { class: 'matriz-col', texto: String(o) }));
			for (var i = 0; i < w.length; i++) {
				grade.appendChild(el('span', {
					class: 'matriz-linha',
					texto: spec.linhas ? spec.linhas[i] : spec.chave[1] + '[' + i + ']',
				}));
				for (o = 0; o < w[i].length; o++) {
					(function (i2, o2) {
						var peso = w[i2][o2];
						var c = el('i', { title: spec.chave + '[' + i2 + '][' + o2 + '] = ' + fmt(peso, 4) });
						// painted once: weights do not change while the page is open
						c.style.background = bgSinal(peso, ESCALA_PESO, POS, NEG);
						var id = spec.chave + ':' + o2;
						(colunas[id] = colunas[id] || []).push(c);
						c.addEventListener('mouseenter', function () { marcarColuna(id, spec.alvo, o2); });
						c.addEventListener('mouseleave', function () { marcarColuna(null); });
						grade.appendChild(c);
					})(i, o);
				}
			}
			raiz.appendChild(el('div', { class: 'ml-bloco' }, [grade]));
		});

		function marcarColuna(id, alvo, indice) {
			for (var k in colunas) {
				if (id !== null && k !== id) continue;
				var on = id !== null;
				colunas[k].forEach(function (c) { c.classList.toggle('aceso', on); });
			}
			if (alvo) {
				celulas_ativacao[alvo].forEach(function (c, i) {
					c.classList.toggle('realce', i === indice);
				});
			} else {
				['h1', 'h2', 'out'].forEach(function (ch) {
					celulas_ativacao[ch].forEach(function (c) { c.classList.remove('realce'); });
				});
			}
		}

		function aplicar(v) {
			for (var i = 0; i < 22; i++) {
				valores[i] = Math.min(CONTRATO[i].max, Math.max(CONTRATO[i].min, v[i]));
				slots[i].value = valores[i];
			}
			agendar();
		}

		function atualizar() {
			agendado = false;
			var r = rede.forward(valores);
			for (var i = 0; i < 22; i++) {
				saidas.texto[i].textContent = fmt(valores[i], 4);
				var z = r.z[i];
				saidas.z[i].textContent = 'z ' + (z >= 0 ? '+' : '') + z.toFixed(2);
				saidas.z[i].style.background = bgSinal(z, 3, POS, NEG);
			}
			['h1', 'h2'].forEach(function (ch) {
				r[ch].forEach(function (v, i) {
					var c = celulas_ativacao[ch][i];
					c.style.background = bgSinal(v, 1, POS, NEG);
					c.title = ch + '[' + i + '] = ' + fmt(v, 6);
				});
			});
			r.out.forEach(function (v, i) {
				var c = celulas_ativacao.out[i];
				c.style.background = bgSinal(v, 1, POS, NEG);
				c.title = (i === 0 ? 'estercamento' : 'velocidade') + ' = ' + fmt(v, 6);
			});
			saidas.valor[0].textContent = fmt(r.out[0]);
			saidas.valor[1].textContent = fmt(r.out[1]);
			saidas.barra[0].style.width = ((r.out[0] + 1) / 2 * 100).toFixed(2) + '%';
			saidas.barra[1].style.width = (Math.min(1, Math.max(0, r.out[1])) * 100).toFixed(2) + '%';
		}

		function agendar() {
			if (agendado) return;
			agendado = true;
			if (typeof requestAnimationFrame === 'function') requestAnimationFrame(atualizar);
			else setTimeout(atualizar, 16);
		}

		atualizar();
		raiz.mlPlayground = { rede: rede, valores: valores, atualizar: atualizar };	}

	/* -------------------------------------------------------------- bootstrap */

	function init(url) {
		return loadWeights(url || 'data/pesos.json').then(function (rede) {
			montarUI(rede);
			return rede;
		});
	}

	var api = {
		MlpNet: MlpNet,
		fromJSON: fromJSON,
		loadWeights: loadWeights,
		contrato: CONTRATO,
		presets: PRESETS,
		init: init,
	};

	if (typeof module !== 'undefined' && module.exports) module.exports = api;
	if (typeof window !== 'undefined') window.MlPlayground = api;
	if (typeof document !== 'undefined') {
		if (document.readyState === 'loading') {
			document.addEventListener('DOMContentLoaded', function () {
				init().catch(function (e) {
					var raiz = document.getElementById('ml-playground');
					if (raiz) raiz.textContent = 'não foi possível carregar data/pesos.json: ' + e.message;
				});
			});
		} else {
			init().catch(function () { /* playground ausente: ignora */ });
		}
	}

	return api;
})();
