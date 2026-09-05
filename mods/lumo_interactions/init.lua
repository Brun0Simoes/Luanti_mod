-- Lumo - Coisas que reagem às construções.
--
-- Aqui mora a pergunta mais interessante do jogo: "o que a criança acabou de
-- construir?". A resposta não vem de comparar com um projeto exato -- vem de
-- olhar os blocos e reconhecer a *intenção*.
--
-- Uma casa é qualquer coisa com interior fechado. Uma cabana, um iglu, um
-- castelo e uma casa na árvore passam todas; não existe bloco obrigatório, nem
-- porta. Uma ponte é qualquer caminho caminhável suspenso sobre o vazio --
-- reta, torta ou decorada. Uma criança que resolveu o problema de um jeito
-- torto resolveu o problema.
--
-- Publica: STRUCTURE_DETECTED
-- Consome: BLOCK_PLACED, PLAYER_LEAVE, TICK

lumo.interactions = {}

local MOD = core.get_current_modname()

-- ---------------------------------------------------------------------------
-- Orçamento
-- ---------------------------------------------------------------------------
-- Estes detectores rodam dentro do callback de colocar bloco, que é o caminho
-- mais quente do jogo: ele dispara para cada bloco de cada jogador, e o ritmo
-- é ditado pelo cliente -- um cliente modificado não tem limite nenhum.
--
-- Por isso o teto NÃO é por função. Cada varredura tinha o seu próprio limite,
-- e eles se multiplicavam: cinco sondas de interior, cada uma com 2048 nós
-- visitados, cada visita lendo seis vizinhos, davam mais de trezentos mil
-- `core.get_node` para um único bloco assentado. Agora existe um orçamento
-- único por evento, compartilhado por todos os detectores, e uma memória de
-- uma passagem para que a mesma posição nunca seja lida duas vezes.
--
-- Quando o orçamento acaba, `is_solid` passa a responder "não sei", e é assim
-- que as varreduras param sozinhas. Elas já sabiam lidar com essa resposta,
-- porque é a mesma que dão para área não carregada.

local PASS_BUDGET = 1500   -- leituras de node por BLOCK_PLACED, no total
local MAX_FILL    = 512    -- nós de ar num interior antes de desistir
local MAX_SPAN    = 128    -- nós visitados procurando ponte
local MAX_COLUMN  = 64     -- altura máxima medida numa torre

-- Limiares do que conta como cada coisa.
local MIN_ROOM    = 8
local MIN_TOWER   = 12
local MIN_BRIDGE  = 5
local MIN_GARDEN  = 8
local GARDEN_RADIUS = 6

-- Evita reemitir a mesma descoberta a cada bloco colocado.
local COOLDOWN = 15
local last_emit = {}   -- [nome .. ":" .. kind] = gametime
local last_size = {}   -- [mesma chave] = tamanho do último anúncio

-- A varredura de interior é a mais cara que temos, então não roda a cada bloco.
-- Uma casa não fica pronta entre duas colocações consecutivas.
local SCAN_INTERVAL = 3
local MAX_DOORS = 4
local last_scan = {}
local doors = {}
local pending = {}   -- [nome] = posição de uma colocação que o intervalo engoliu

local SIDES = {
	vector.new( 1, 0, 0), vector.new(-1, 0, 0),
	vector.new( 0, 0, 1), vector.new( 0, 0,-1),
}
local ALL_DIRS = {
	vector.new( 1, 0, 0), vector.new(-1, 0, 0),
	vector.new( 0, 1, 0), vector.new( 0,-1, 0),
	vector.new( 0, 0, 1), vector.new( 0, 0,-1),
}

local function now()
	return core.get_gametime() or 0
end

local function pkey(p)
	return p.x .. "," .. p.y .. "," .. p.z
end

local budget = 0
local memo = nil

local function begin_pass()
	budget = PASS_BUDGET
	memo = {}
end

local function end_pass()
	memo = nil
end

--- Um node é sólido o bastante para formar parede ou piso?
--- true = sim, false = não, nil = não sei (área não carregada, node
--- desconhecido, ou orçamento da passagem esgotado).
local function is_solid(pos)
	local key = pkey(pos)

	if memo then
		local cached = memo[key]
		if cached ~= nil then
			if cached == 1 then return true end
			if cached == 0 then return false end
			return nil
		end
		if budget <= 0 then
			return nil
		end
		budget = budget - 1
	end

	local result
	local node = core.get_node(pos)
	if node.name == "ignore" then
		result = nil   -- área não carregada
	else
		local def = core.registered_nodes[node.name]
		if def == nil then
			result = nil   -- node desconhecido: não dá para afirmar nada
		else
			result = (def.walkable == true)
		end
	end

	if memo then
		memo[key] = (result == true and 1) or (result == false and 0) or -1
	end
	return result
end

-- ---------------------------------------------------------------------------
-- Detector de interior fechado (casa)
-- ---------------------------------------------------------------------------

--- Varre o espaço vazio a partir de `start` e devolve o volume, se ele for
--- fechado. Devolve nil se o espaço escapa, se é grande demais, se esbarra em
--- área não carregada ou se o orçamento acabou -- em todos esses casos a
--- resposta honesta é "não sei", e não "não é uma casa".
local function enclosed_volume(start)
	local first = is_solid(start)
	if first == nil or first == true then
		return nil
	end

	local queue, seen = { start }, { [pkey(start)] = true }
	local head, count = 1, 0

	while head <= #queue do
		local p = queue[head]
		head = head + 1
		count = count + 1
		if count > MAX_FILL then
			return nil   -- não é um cômodo, é o mundo aberto
		end

		for _, d in ipairs(ALL_DIRS) do
			local np = vector.add(p, d)
			local k = pkey(np)
			if not seen[k] then
				seen[k] = true
				local solid = is_solid(np)
				if solid == nil then
					return nil
				elseif not solid then
					queue[#queue + 1] = np
				end
			end
		end
	end

	return count
end

--- Existe um cômodo fechado encostado em `pos`? Testa os quatro lados e o
--- espaço acima, e fica com o menor volume fechado -- o lado de fora, quando
--- fecha, costuma ser bem maior ou não fechar de todo.
---
--- Repare que nada aqui exige porta. A porta é um bom *palpite* de onde
--- procurar, nunca um requisito.
function lumo.interactions.room_near(pos)
	local best
	local probes = { vector.new(0, 1, 0) }
	for _, d in ipairs(SIDES) do
		probes[#probes + 1] = d
	end
	for _, d in ipairs(probes) do
		if budget <= 0 then
			break
		end
		local vol = enclosed_volume(vector.add(pos, d))
		if vol and vol >= MIN_ROOM and (not best or vol < best) then
			best = vol
		end
	end
	return best
end

-- ---------------------------------------------------------------------------
-- Detector de coluna (torre)
-- ---------------------------------------------------------------------------

--- Um node com pelo menos três lados no ar está numa coluna, não no chão.
--- É isto que separa "torre" de "terreno": o terreno é cercado por terreno.
local function is_exposed(p)
	local open = 0
	for _, d in ipairs(SIDES) do
		if is_solid(vector.add(p, d)) == false then
			open = open + 1
		end
	end
	return open >= 3
end

--- Altura da coluna exposta que termina em `pos`.
---
--- Duas coisas que a versão ingênua errava. Ela descia pelo terreno, então
--- *qualquer* bloco assentado no chão media 12+ e virava torre na hora. E
--- exigia coluna perfeitamente reta, reprovando torre em espiral ou que afina.
function lumo.interactions.column_height(pos)
	local height = 0
	local p = vector.new(pos.x, pos.y, pos.z)

	for _ = 1, MAX_COLUMN do
		if is_solid(p) ~= true or not is_exposed(p) then
			break
		end
		height = height + 1

		local below = vector.new(p.x, p.y - 1, p.z)
		if is_solid(below) ~= true then
			-- A coluna continua torta: procura a sequência um nível abaixo,
			-- nos vizinhos. Quem subiu em espiral construiu uma torre.
			local found
			for _, d in ipairs(SIDES) do
				local cand = vector.new(p.x + d.x, p.y - 1, p.z + d.z)
				if is_solid(cand) == true and is_exposed(cand) then
					found = cand
					break
				end
			end
			if not found then
				break
			end
			below = found
		end
		p = below
	end

	return height
end

-- ---------------------------------------------------------------------------
-- Detector de vão (ponte)
-- ---------------------------------------------------------------------------

--- Quantos nodes caminháveis conectados a `pos` estão suspensos sobre o vazio.
--- Varre em largura em vez de escanear um eixo, de propósito: uma ponte em L,
--- em curva ou em ziguezague precisa contar igual a uma reta.
function lumo.interactions.suspended_run(pos)
	if is_solid(pos) ~= true then
		return 0
	end

	local queue, seen = { pos }, { [pkey(pos)] = true }
	local head, visited, suspended = 1, 0, 0

	while head <= #queue do
		local p = queue[head]
		head = head + 1
		visited = visited + 1
		if visited > MAX_SPAN or budget <= 0 then
			break
		end

		if is_solid(vector.new(p.x, p.y - 1, p.z)) == false then
			suspended = suspended + 1
		end

		-- Só anda na horizontal, com tolerância de um degrau: uma ponte pode
		-- subir e descer, mas não é a mesma coisa que uma parede.
		for _, d in ipairs(SIDES) do
			for _, dy in ipairs({0, 1, -1}) do
				local np = vector.new(p.x + d.x, p.y + dy, p.z + d.z)
				local k = pkey(np)
				if not seen[k] then
					seen[k] = true
					if is_solid(np) == true then
						queue[#queue + 1] = np
					end
				end
			end
		end
	end

	return suspended
end

-- ---------------------------------------------------------------------------
-- Detector de jardim
-- ---------------------------------------------------------------------------

function lumo.interactions.flowers_around(pos, radius)
	radius = radius or GARDEN_RADIUS
	local min = vector.new(pos.x - radius, pos.y - 3, pos.z - radius)
	local max = vector.new(pos.x + radius, pos.y + 3, pos.z + radius)
	local found = core.find_nodes_in_area(min, max, {"group:flower"})
	return found and #found or 0
end

-- ---------------------------------------------------------------------------
-- Publicação
-- ---------------------------------------------------------------------------

local function scan_due(name)
	local t = now()
	if (t - (last_scan[name] or -math.huge)) < SCAN_INTERVAL then
		return false
	end
	last_scan[name] = t
	return true
end

local function remember_door(name, pos)
	local list = doors[name]
	if not list then
		list = {}
		doors[name] = list
	end
	for _, p in ipairs(list) do
		if p.x == pos.x and p.y == pos.y and p.z == pos.z then
			return
		end
	end
	table.insert(list, 1, vector.new(pos.x, pos.y, pos.z))
	while #list > MAX_DOORS do
		table.remove(list)
	end
end

--- Publica uma detecção, com silêncio entre repetições.
---
--- O silêncio simples de 15s tinha um efeito ruim: a torre anunciava com
--- altura 12, e quando a criança chegava a 20 -- o limiar da descoberta
--- "Construtor das Nuvens" -- o anúncio era engolido e o evento com o tamanho
--- novo nunca saía. Se ela parasse ali, perdia a descoberta por completo.
---
--- Então uma estrutura que *cresceu* pode reanunciar antes, respeitado um
--- intervalo curto para não virar enxurrada.
local REANNOUNCE = 3

local function announce(name, player, kind, pos, size)
	local key = name .. ":" .. kind
	local t = now()
	local prev = last_emit[key]

	if prev then
		local elapsed = t - prev
		local grew = size and last_size[key] and size > last_size[key]
		if elapsed < REANNOUNCE then
			return false
		end
		if elapsed < COOLDOWN and not grew then
			return false
		end
	end

	last_emit[key] = t
	last_size[key] = size
	lumo.events.emit("STRUCTURE_DETECTED", {
		player = player,
		name = name,
		kind = kind,
		pos = pos,
		size = size,
	})
	return true
end

--- Procura um cômodo fechado: primeiro nas portas que a criança colocou,
--- depois em volta do bloco novo -- este segundo caso é o que reconhece um
--- iglu, que fecha sem porta nenhuma.
local function scan_for_house(name, player, pos)
	local hit_pos, volume
	for _, dpos in ipairs(doors[name] or {}) do
		volume = lumo.interactions.room_near(dpos)
		if volume then
			hit_pos = dpos
			break
		end
	end
	if not volume then
		volume = lumo.interactions.room_near(pos)
		hit_pos = pos
	end
	if volume then
		announce(name, player, "house", hit_pos, volume)
	end
end

lumo.events.on("PLAYER_LEAVE", function(data)
	for key in pairs(last_emit) do
		if key:sub(1, #data.name + 1) == data.name .. ":" then
			last_emit[key] = nil
		end
	end
	last_scan[data.name] = nil
	doors[data.name] = nil
	pending[data.name] = nil
	for key in pairs(last_size) do
		if key:sub(1, #data.name + 1) == data.name .. ":" then
			last_size[key] = nil
		end
	end
end)

-- Prioridade 70: depois do lumo_player e do lumo_projects, para que as
-- estatísticas já estejam atualizadas quando o detector rodar.
lumo.events.on("BLOCK_PLACED", function(data)
	if not data.name or not data.pos or not data.node then
		return
	end

	begin_pass()

	-- Os detectores baratos primeiro, para que uma varredura de interior não
	-- consuma o orçamento antes de eles rodarem.
	local node_name = data.node.name

	if core.get_item_group(node_name, "flower") > 0 then
		local n = lumo.interactions.flowers_around(data.pos)
		if n >= MIN_GARDEN then
			announce(data.name, data.player, "garden", data.pos, n)
		end
	end

	if is_solid(data.pos) == true then
		local height = lumo.interactions.column_height(data.pos)
		if height >= MIN_TOWER then
			announce(data.name, data.player, "tower", data.pos, height)
		end

		if is_solid(vector.new(data.pos.x, data.pos.y - 1, data.pos.z)) == false then
			local run = lumo.interactions.suspended_run(data.pos)
			if run >= MIN_BRIDGE then
				announce(data.name, data.player, "bridge", data.pos, run)
			end
		end
	end

	-- Casa. Uma porta é um palpite forte de onde há um cômodo, então guardamos
	-- onde ela colocou. Mas a ordem mais comum de uma criança é a outra --
	-- encaixar a porta e *depois* levantar o resto -- e nesse instante a
	-- varredura escaparia para o céu aberto. Por isso a reexaminamos depois.
	--
	-- A varredura é sempre estrangulada, inclusive no caminho da porta: antes
	-- só o outro ramo era, e alternar porta/bloco pagava o custo cheio sem
	-- nunca gastar o intervalo.
	if core.get_item_group(node_name, "door") > 0 then
		remember_door(data.name, data.pos)
	end

	if scan_due(data.name) then
		pending[data.name] = nil
		scan_for_house(data.name, data.player, data.pos)
	else
		-- O intervalo engoliu esta colocação. Guardamos onde foi para o TICK
		-- tentar depois: sem isto, uma criança que fecha o iglu e *para de
		-- construir* nunca teria a casa reconhecida, porque a varredura só
		-- acontecia na próxima colocação -- que não viria.
		pending[data.name] = vector.new(data.pos.x, data.pos.y, data.pos.z)
	end

	end_pass()
end, 70)

lumo.events.on("TICK", function(data)
	for _, player in ipairs(data.players) do
		local name = player:get_player_name()
		local pos = pending[name]
		if pos and scan_due(name) then
			pending[name] = nil
			begin_pass()
			scan_for_house(name, player, pos)
			end_pass()
		end
	end
end)

core.log("action", ("[%s] detectores de forma prontos"):format(MOD))
