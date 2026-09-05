-- Lumo - Regiões, Oficina, ilhas e locais especiais.
--
-- Define os lugares com nome do mundo e avisa quando o jogador passa de um
-- para outro. As regiões são a camada feita à mão; fora delas continua o mundo
-- procedural da engine, que segue infinito e sem interrupção.
--
-- Publica: PLAYER_MOVE_REGION
-- Consome: MODS_LOADED, PLAYER_JOIN, PLAYER_LEAVE, TICK

lumo.world = {}

local MOD = core.get_current_modname()
local storage = core.get_mod_storage()

local regions = {}       -- lista, ordenada por prioridade decrescente
local current = {}       -- [nome do jogador] = id da região onde ele está

-- ---------------------------------------------------------------------------
-- Registro de regiões
-- ---------------------------------------------------------------------------

--- Registra uma região.
---
---     lumo.world.register_region({
---         id = "oficina",
---         title = "Oficina",
---         min = {x = -32, y = -16, z = -32},
---         max = {x =  32, y =  48, z =  32},
---         priority = 100,   -- opcional; maior ganha em caso de sobreposição
---     })
---
--- Regiões podem se sobrepor de propósito: a Oficina fica dentro do Bosque, e
--- quem estiver na Oficina deve ser reconhecido como estando na Oficina.
function lumo.world.register_region(def)
	assert(type(def) == "table", "register_region: def deve ser uma tabela")
	assert(type(def.id) == "string", "register_region: id obrigatório")
	assert(def.min and def.max, "register_region: min e max obrigatórios")

	for _, r in ipairs(regions) do
		if r.id == def.id then
			core.log("warning", ("[%s] região %q registrada duas vezes"):format(MOD, def.id))
			return false
		end
	end

	regions[#regions + 1] = {
		id = def.id,
		title = def.title or def.id,
		-- Componente a componente de propósito: aceita tanto um vector quanto
		-- uma tabela {x=,y=,z=} crua, e evita o vector.new(v) depreciado
		-- (doc/lua_api.md:4472).
		min = vector.new(def.min.x, def.min.y, def.min.z),
		max = vector.new(def.max.x, def.max.y, def.max.z),
		priority = def.priority or 0,
	}
	table.sort(regions, function(a, b) return a.priority > b.priority end)
	return true
end

--- A região em uma posição, ou nil se for mundo livre.
function lumo.world.region_at(pos)
	for _, r in ipairs(regions) do
		if pos.x >= r.min.x and pos.x <= r.max.x
			and pos.y >= r.min.y and pos.y <= r.max.y
			and pos.z >= r.min.z and pos.z <= r.max.z then
			return r
		end
	end
	return nil
end

--- Em que região o jogador está agora. nil = mundo livre.
function lumo.world.region_of(name)
	local id = current[name]
	if not id then
		return nil
	end
	for _, r in ipairs(regions) do
		if r.id == id then
			return r
		end
	end
	return nil
end

function lumo.world.get_regions()
	return regions
end

-- ---------------------------------------------------------------------------
-- Onde a criança já esteve
-- ---------------------------------------------------------------------------
-- Quem é dono do conceito "região" é este módulo, então também é ele que
-- registra por onde a criança já passou. Os dados moram no lumo_player, que é
-- a fonte única de progresso -- este módulo é o único que escreve neles.

local function mark_visited(name)
	local st = lumo.player.get(name)
	local id = current[name]
	if not st or not id then
		return
	end
	st.visited_regions[id] = true
end

--- Ela já esteve nesta região?
function lumo.world.has_visited(name, region_id)
	local st = lumo.player.get(name)
	if not st then
		return false   -- e não nil: isto é um predicado
	end
	return st.visited_regions[region_id] == true
end

--- Quantas regiões distintas ela já conheceu.
function lumo.world.visited_count(name)
	local st = lumo.player.get(name)
	if not st then
		return 0
	end
	local n = 0
	for _ in pairs(st.visited_regions) do
		n = n + 1
	end
	return n
end

-- ---------------------------------------------------------------------------
-- A Oficina
-- ---------------------------------------------------------------------------
-- A Oficina é o centro: a criança sempre pode voltar para ela e nunca precisa
-- ter medo de estar longe demais de casa.
--
-- A intenção é construí-la dentro do próprio jogo e exportar como schematic,
-- em vez de descrever bloco a bloco em Lua. Enquanto o arquivo não existe, a
-- colocação é um no-op que diz o que está faltando -- e não um erro que impede
-- o mundo de carregar.

lumo.world.WORKSHOP_CENTER = vector.new(0, 8, 0)

local SCHEMATIC_DIR = core.get_modpath(MOD) .. "/schematics"
local SCHEMATIC_FILE = "oficina.mts"

--- Existe o arquivo da Oficina?
--- `core.path_exists` em vez de io.open: num mod, io.open passa pela checagem
--- de caminho do sandbox da engine (src/script/cpp_api/s_security.cpp:278) e
--- não vale arriscar a diferença.
local function schematic_exists()
	return core.path_exists(SCHEMATIC_DIR .. "/" .. SCHEMATIC_FILE) == true
end

local function place_workshop()
	if storage:get_string("workshop_placed") == "1" then
		return false
	end

	if not schematic_exists() then
		core.log("action", ("[%s] schematic da Oficina ainda não existe (%s/%s); mundo começa sem ela")
			:format(MOD, SCHEMATIC_DIR, SCHEMATIC_FILE))
		return false
	end

	-- force_placement = true: a Oficina sobrescreve o terreno gerado.
	local ok = core.place_schematic(lumo.world.WORKSHOP_CENTER,
		SCHEMATIC_DIR .. "/" .. SCHEMATIC_FILE, "0", nil, true)

	-- E a flag só depois de confirmar. Marcá-la incondicionalmente tornava
	-- qualquer falha permanente: a Oficina ficaria registrada como colocada e
	-- nunca mais seria tentada, em nenhuma inicialização.
	if ok == nil then
		core.log("error", ("[%s] não consegui colocar a Oficina; tentarei de novo na próxima vez")
			:format(MOD))
		return false
	end

	storage:set_string("workshop_placed", "1")
	core.log("action", ("[%s] Oficina colocada em %s")
		:format(MOD, core.pos_to_string(lumo.world.WORKSHOP_CENTER)))
	return true
end

-- ---------------------------------------------------------------------------
-- Regiões iniciais
-- ---------------------------------------------------------------------------
-- Provisórias: os limites reais saem do mapa quando a Oficina for construída
-- de verdade. O que importa agora é que a mecânica de transição funcione.

lumo.world.register_region({
	id = "oficina", title = "Oficina", priority = 100,
	min = {x = -32, y = -16, z = -32}, max = {x = 32, y = 48, z = 32},
})
lumo.world.register_region({
	id = "bosque", title = "Bosque", priority = 10,
	min = {x = -160, y = -32, z = -32}, max = {x = -32, y = 96, z = 96},
})
lumo.world.register_region({
	id = "pedreiras", title = "Pedreiras", priority = 10,
	min = {x = 32, y = -64, z = -32}, max = {x = 160, y = 96, z = 96},
})
lumo.world.register_region({
	id = "rio", title = "Rio", priority = 20,
	min = {x = -160, y = -16, z = 32}, max = {x = 160, y = 32, z = 64},
})
lumo.world.register_region({
	id = "campo", title = "Campo", priority = 10,
	min = {x = -160, y = -16, z = 64}, max = {x = 160, y = 96, z = 192},
})

-- ---------------------------------------------------------------------------
-- Reação aos eventos
-- ---------------------------------------------------------------------------

lumo.events.on("MODS_LOADED", function()
	-- `core.after(0, ...)` e não a chamada direta: MODS_LOADED dispara dentro
	-- de `loadMods` (src/server.cpp:534), e o ServerEnvironment só nasce
	-- trinta linhas depois (src/server.cpp:566-585). Chamar
	-- `core.place_schematic` antes disso não coloca nada -- só registra um
	-- aviso de "chamada durante a inicialização" e segue em frente. Um passo
	-- de servidor depois, o ambiente existe.
	-- Dentro de pcall: `core.after` invoca o trabalho sem proteção
	-- (builtin/common/after.lua), e um erro escapando de um globalstep vira
	-- `setAsyncFatalError` -- ou seja, servidor fora do ar. Antes o `emit` do
	-- event bus protegia esta chamada; ao movê-la para cá, essa rede sumiu.
	-- O comentário lá em cima promete que a ausência do schematic é um no-op e
	-- não um erro que impede o mundo de carregar; isto sustenta a promessa.
	core.after(0, function()
		local ok, err = pcall(place_workshop)
		if not ok then
			core.log("error", ("[%s] falha ao colocar a Oficina: %s"):format(MOD, tostring(err)))
		end
	end)
end)

lumo.events.on("PLAYER_JOIN", function(data)
	-- Entra já sabendo onde está, sem disparar transição: acabar de conectar
	-- não é "ter atravessado" para lugar nenhum.
	local r = lumo.world.region_at(data.player:get_pos())
	current[data.name] = r and r.id or nil
	mark_visited(data.name)
end, 20)

lumo.events.on("PLAYER_LEAVE", function(data)
	current[data.name] = nil
end)

lumo.events.on("TICK", function(data)
	for _, player in ipairs(data.players) do
		local name = player:get_player_name()
		local from = current[name]
		local r = lumo.world.region_at(player:get_pos())
		local to = r and r.id or nil

		if from ~= to then
			current[name] = to
			mark_visited(name)
			lumo.events.emit("PLAYER_MOVE_REGION", {
				player = player,
				name = name,
				from = from,   -- nil = veio do mundo livre
				to = to,       -- nil = saiu para o mundo livre
			})
		end
	end
end)
