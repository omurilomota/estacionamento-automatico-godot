class_name RouteShape
extends RefCounted
## Geometria de rota: transforma uma polilinha de vertices duros numa curva
## tangente-continua.
##
## POR QUE (2026-09-26): a rota que o carro seguia tinha 8 vertices em 1900 px,
## cada um com angulo de 90 graus. O pure-pursuit mira um ponto a FRENTE, entao
## em cada vertice ele "corta" a quina por dentro — o usuario viu o carro cortando
## a rua e "andando torto". Arredondar o vertice (arco tangente aos dois trechos)
## da uma curvatura continua: o carro mantem a linha em vez de cortar.
##
## A ordem no pipeline importa: primeiro o A* crude, depois o deslocamento da
## faixa (LaneOffset, que precisa da polilinha JA decimada para as sondas), e so
## entao o arredondamento. Arredondar antes faria as curvas entrarem na parede.

## Limiar de "ja esta reto o bastante": entre duas direcoes, `u_in · u_out`
## vale `cos(180 - theta)`, entao um turning de 0 graus da -1. Acima de -0.90
## (isto e, curvatura > ~25 graus) o vertice e arredondado.
const RETO_MIN := -0.90

## Acima disso (curva > ~120 graus) o vertice e um hairpin e fica duro.
const CURVA_FECHADA_MIN := 0.5


## SUAVIZACAO DA ESCADARIA (2026-09-26). O A* sai como escadaria de celulas de
## 15 px; o `decimar` do planner (RDP tol. 18) reduzia isso a ~8 vertices, e o
## resultado era um caminho de verdade ruim: quinas de ~90 graus que o
## pure-pursuit corta, zigue-zague que a faixa da direita amplifica (cada vertice
## ia para a SUA parede). Arredondar essa polilinha nao dava certo — o
## arredondamento de um hairpin cria um laco, e o carro entrava em oscilacao de
## meia-volta (42 frames de RE).
##
## A solucao e suavizar ANTES de decimizar, com CHAIKIN: cortar o canto de cada
## segmento,repetidas, que e a unica forma de limpar a escadaria sem nunca criar laco
## (so encurta, e nunca sai do poligono original). A folga e devolvida no fim por
## `Carro._garantir_folga`.
static func smooth(rota: Array, iteracoes: int = 3, perda_max: float = 0.15) -> Array:
	if rota.size() < 3 or iteracoes < 1:
		return rota.duplicate()
	var original := _comprimento(rota)
	var n_iter: int = clampi(iteracoes, 1, 6)
	# AUTO-LIMITE: Chaikin so encurta, e num caminho limpo encurta poucos por
	# cento. Perto do spawn o A* faz um hairpin, e la cada iteracao come o laco
	# quase inteiro — o caminho encurta de mais e o carro entra em oscilacao de
	# meia-volta (40 frames de RE). Entao reduz as iteracoes ate o
	# encurtamento caber no orcamento.
	while n_iter >= 1:
		var atual: Array = _chaikin(rota, n_iter)
		if original <= 0.0 or (1.0 - _comprimento(atual) / original) <= perda_max:
			return atual
		n_iter -= 1
	return _chaikin(rota, 1)


static func _chaikin(rota: Array, iteracoes: int) -> Array:
	var atual: Array = rota.duplicate()
	for _i in range(iteracoes):
		if atual.size() < 3:
			return atual
		var prox: Array = [atual[0]]
		for k in range(1, atual.size()):
			var a: Vector2 = atual[k - 1] as Vector2
			var b: Vector2 = atual[k] as Vector2
			prox.append(a * 0.75 + b * 0.25)
			prox.append(a * 0.25 + b * 0.75)
		prox.append(atual[atual.size() - 1])
		atual = prox
	return atual


static func _comprimento(p: Array) -> float:
	var t := 0.0
	for i in range(1, p.size()):
		t += (p[i] as Vector2).distance_to(p[i - 1] as Vector2)
	return t


## Reamostra a polilinha em espacamento constante, para a lista de waypoints nao
## crescer com a densidade da grade (o carro nao precisa de um ponto por celula).
static func resample(rota: Array, passo: float = 40.0) -> Array:
	if rota.size() < 2 or passo <= 1.0:
		return rota.duplicate()
	var saida: Array = [rota[0] as Vector2]
	var n := rota.size()
	var acumulado: float = 0.0   # quanto ja foi andado desde o ultimo ponto
	for i in range(1, n):
		var a: Vector2 = rota[i - 1] as Vector2
		var b: Vector2 = rota[i] as Vector2
		var d: float = a.distance_to(b)
		if d < 0.0001:
			continue
		var u: Vector2 = (b - a) / d
		var andado: float = 0.0
		while acumulado + (d - andado) >= passo:
			andado += passo - acumulado
			acumulado = 0.0
			saida.append(a + u * andado)
		acumulado += d - andado
	saida.append(rota[n - 1] as Vector2)
	return saida


## Arredonda os vertices da rota. Os extremos ficam intactos: o primeiro e onde
## o carro esta agora, o ultimo e o ponto de preparacao da vaga (AGENTS #18: o
## deslocamento de faixa e' 0 nos dois, e a manobra nao pode ser arrastada).
##
## route: Array[Vector2] (a polilinha ja deslocada para a faixa da direita).
## raio: raio maximo do arredondamento, em px.
## passo: espacamento desejado entre pontos gerados, em px.
static func round_corners(route: Array, raio: float = 90.0, passo: float = 45.0) -> Array:
	var n := route.size()
	if n < 3 or raio <= 1.0 or passo <= 1.0:
		return route.duplicate()
	var saida: Array[Vector2] = [(route[0] as Vector2)]
	for i in range(1, n - 1):
		var a: Vector2 = route[i - 1] as Vector2
		var b: Vector2 = route[i] as Vector2
		var c: Vector2 = route[i + 1] as Vector2
		var v_in: Vector2 = b - a
		var v_out: Vector2 = c - b
		var l_in: float = v_in.length()
		var l_out: float = v_out.length()
		if l_in < 1.0 or l_out < 1.0:
			continue
		var u_in: Vector2 = v_in / l_in
		var u_out: Vector2 = v_out / l_out
		# Ja esta reto: o vertice E MANTIDO (a primeira versao o descartava e a
		# rota ficava com 2 pontos — o carro ia direto na parede).
		if u_in.dot(u_out) < RETO_MIN:
			saida.append(b)
			continue
		# O raio nao pode passar da metade do trecho: senao as curvas de
		# vertices vizinhos se sobrepoem e a linha fica ondulada.
		var d: float = minf(raio, minf(l_in, l_out) * 0.5)
		var p: Vector2 = b - u_in * d
		var q: Vector2 = b + u_out * d
		saida.append(p)
		var passos: int = maxi(2, int(ceil(d * 1.4 / passo)))
		for k in range(1, passos + 1):
			var t: float = float(k) / float(passos)
			saida.append(_bezier_quadratica(p, b, q, t))
	saida.append((route[n - 1] as Vector2))
	return saida


## Bezier quadratica de P a Q com controle C.
static func _bezier_quadratica(p: Vector2, c: Vector2, q: Vector2, t: float) -> Vector2:
	var u: float = 1.0 - t
	return p * (u * u) + c * (2.0 * u * t) + q * (t * t)
