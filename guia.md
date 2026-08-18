🚗 GUIA DO PROJETO: ESTACIONAMENTO AUTÔNOMO (Godot 2D)
Objetivo: Criar uma simulação 2D (vista de cima) onde um carro se estaciona sozinho em uma vaga, desviando de obstáculos usando "sensores".
Prazo: Curto. Foco em funcionalidade, não em gráficos de AAA.


🛠️ REGRAS DE OURO DA EQUIPE
Não editem a mesma Cena (.tscn) ao mesmo tempo. O Godot não lida bem com isso. Se o Murilo está mexendo no Carro, o Matheus mexe no Mundo.
Comunicação de Assets: Gian deve nomear os arquivos de forma clara (ex: carro_vermelho.png, vaga_livre.png) e entregar em pastas organizadas.
Git: Sempre façam pull antes de começar a codar e push assim que terminarem uma funcionalidade.


🎨 1. GIAN (Designer / Artista)
Sua missão: Criar os visuais do jogo. Como o prazo é curto, vamos no estilo "Clean / Minimalista" (formas geométricas bem feitas).
O que você precisa criar (Exportar em PNG com fundo transparente):
O Carro:
Vista de cima (top-down).
Dica: Um retângulo com um "para-brisa" na frente para sabermos qual é a frente do carro.
A Vaga de Estacionamento:
Precisamos de 2 versões (ou você pode fazer um retângulo tracejado e o código muda a cor):
vaga_livre.png (ex: tracejado verde ou branco).
vaga_ocupada.png (ex: tracejado vermelho).
Obstáculos:
Outros carros estacionados (pode ser o mesmo sprite do carro, só mudar a cor).
Paredes ou blocos de concreto (retângulos cinzas).
Interface (UI) - Opcional mas recomendado:
Um painel simples no topo da tela com textos: "STATUS: [Buscando Vaga]" e "SENSOR: [Livre]".
️ Importante para o Godot: Tente manter todos os sprites na mesma escala (ex: todos com 64x64 pixels ou 128x128 pixels) para facilitar a vida dos programadores.


💻 2. MURILO (Programador - O Cérebro do Carro)
Sua missão: Criar a lógica do carro e a "Inteligência" (Máquina de Estados). Você vai trabalhar quase exclusivamente na cena Carro.tscn e no script Carro.gd.
Suas Tarefas:
Física Básica: Fazer o CharacterBody2D do carro andar para frente, trás e virar.
Os Sensores (Raycast2D):
Adicionar 3 Raycasts no carro (Frente, Esquerda, Direita).
Fazer o código detectar quando o Raycast bate em algo (usando is_colliding()).
Efeito visual: Fazer uma linha vermelha aparecer no Godot quando o sensor detectar um obstáculo (isso brilha os olhos do professor).
A Máquina de Estados (FSM):
Criar as variáveis de estado: BUSCANDO, DESVIANDO, ALINHANDO.
Lógica BUSCANDO: O carro acelera e vira suavemente em direção a um ponto alvo (Waypoint).
Lógica DESVIANDO: Se o Raycast da frente bater, o carro para de ir para frente e vira o volante para o lado até o sensor limpar.
Lógica ALINHANDO: Quando chegar perto da vaga, o carro para de andar e só gira no próprio eixo até ficar com a rotação correta.


3. MATHEUS (Programador - O Mundo e a Interação)
Sua missão: Montar o cenário, a lógica das vagas e a Interface. Você vai trabalhar na cena Mundo.tscn, Vaga.tscn e na UI.
Suas Tarefas:
Cenário (Mundo.tscn):
Criar o chão (um ColorRect grande ou TileMap simples).
Colocar as paredes (usar StaticBody2D + CollisionShape2D).
Posicionar os "Waypoints" (nós Marker2D invisíveis) que o Murilo vai usar para guiar o carro.
Lógica da Vaga (Vaga.tscn):
Criar a vaga como um Area2D.
Fazer o código detectar quando o carro entra nela (body_entered).
Quando o carro entrar, mudar a cor da vaga (ou trocar o sprite do Gian) e avisar o carro para entrar no estado ALINHANDO.
Interface (UI):
Criar as Label na tela.
Conectar os sinais: Quando o Murilo mudar o estado do carro para "DESVIANDO", a sua UI deve atualizar o texto na tela para "Desviando de obstáculo!".


🤝 COMO JUNTAR TUDO (Integração)
Gian entrega os PNGs na pasta res://assets/sprites/.
Matheus monta o Mundo.tscn, coloca as paredes, as vagas e os waypoints. Ele instancia a cena do carro no início.
Murilo pega a cena do carro, coloca os sprites do Gian e conecta os Raycasts nas paredes/obstáculos que o Matheus criou.
Teste Final: Rodam o jogo. O carro sai do ponto A, segue os waypoints do Matheus, usa os sensores do Murilo para não bater, e para na vaga do Matheus.


🎤 O DISCURSO PARA O PROFESSOR (Todos devem saber)
Quando o professor chegar na bancada, um de vocês diz:
"Prof, nosso projeto simula um robô autônomo. O carro não segue um script fixo; ele usa sensores (Raycast) para coletar dados do ambiente em tempo real. O código é baseado em uma Máquina de Estados: ele decide sozinho quando buscar a vaga, quando desviar de um risco e quando alinhar para estacionar. É a aplicação prática de tomada de decisão autônoma que vimos em aula."
