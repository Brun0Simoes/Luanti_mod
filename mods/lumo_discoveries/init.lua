-- Lumo - Descobertas secretas.
--
-- Uma descoberta não é uma tarefa: ela não é anunciada de antemão, não aparece
-- numa lista de pendências e não pode ser "perdida". Ela simplesmente
-- acontece, e é essa a graça -- a criança começa a pensar "será que acontece
-- alguma coisa se eu fizer isso?".
--
-- Por isso o contador só existe depois da primeira. Mostrar "0 / 25" na
-- primeira tela transformaria um convite à curiosidade numa lista de deveres.
--
-- Publica: DISCOVERY_FOUND
-- Consome: BLOCK_PLACED, HEIGHT_REACHED, DEPTH_REACHED, STRUCTURE_DETECTED,
--          PLAYER_MOVE_REGION, PLAYER_LEAVE, TICK

lumo.discoveries = {}

local MOD = core.get_current_modname()

local defs = {}
local order = {}
local by_event = {}

-- ---------------------------------------------------------------------------
-- Registro
-- ---------------------------------------------------------------------------

function lumo.discoveries.register(def)
	assert(type(def) == "table", "discoveries.register: def deve ser uma tabela")
	assert(type(def.id) == "string", "discoveries.register: id obrigatório")
	assert(type(def.check) == "function", "discoveries.register: check obrigatório")

	if defs[def.id] then
		core.log("warning", ("[%s] descoberta %q registrada duas vezes"):format(MOD, def.id))
		return false
	end

	def.title = def.title or def.id
	def.icon = def.icon or "*"
	def.events = def.events or {"TICK"}

	defs[def.id] = def
	order[#order + 1] = def.id
	for _, ev in ipairs(def.events) do
		by_event[ev] = by_event[ev] or {}
		table.insert(by_event[ev], def.id)
	end
	return true
end

function lumo.discoveries.get(id)
	return defs[id]
end

function lumo.discoveries.total()
	return #order
end

--- Já foi encontrada por este jogador?
function lumo.discoveries.found(name, id)
	local st = lumo.player.get(name)
	return st and st.discoveries[id] ~= nil
end

--- Quantas esta criança já achou.
function lumo.discoveries.count(name)
	local st = lumo.player.get(name)
	if not st then
		return 0
	end
	local n = 0
	for _ in pairs(st.discoveries) do
		n = n + 1
	end
	return n
end

--- Lista, na ordem de registro, apenas as já encontradas. As não encontradas
--- não vazam para a interface: uma descoberta revelada deixa de ser uma.
function lumo.discoveries.list_found(name)
	local st = lumo.player.get(name)
	if not st then
		return {}
	end
	local out = {}
	for _, id in ipairs(order) do
		if st.discoveries[id] then
			out[#out + 1] = { def = defs[id], at = st.discoveries[id] }
		end
	end
	return out
end

--- Marca como encontrada. Idempotente.
function lumo.discoveries.award(name, id)
	local st = lumo.player.get(name)
	local def = defs[id]
	if not st or not def or st.discoveries[id] then
		return false
	end
	st.discoveries[id] = os.time()
	lumo.events.emit("DISCOVERY_FOUND", {
		player = core.get_player_by_name(name),
		name = name,
		discovery = def,
	})
	return true
end

-- ---------------------------------------------------------------------------
-- Verificação
-- ---------------------------------------------------------------------------

local function run_checks(event_name, name, data)
	if not name or not lumo.player.get(name) then
		return
	end
	local ids = by_event[event_name]
	if not ids then
		return
	end
	for _, id in ipairs(ids) do
		if not lumo.discoveries.found(name, id) then
			if defs[id].check(name, data) then
				lumo.discoveries.award(name, id)
			end
		end
	end
end

for _, ev in ipairs({"BLOCK_PLACED", "HEIGHT_REACHED", "DEPTH_REACHED",
                     "STRUCTURE_DETECTED", "PLAYER_MOVE_REGION"}) do
	lumo.events.on(ev, function(data)
		run_checks(ev, data.name, data)
	end, 75)
end

-- Um "momento tranquilo" precisa de alguém parado, e parado só se percebe com
-- o tempo passando. O TICK é o único lugar onde isso dá para observar.
local still = {}   -- [nome] = { pos, seconds }

lumo.events.on("TICK", function(data)
	for _, player in ipairs(data.players) do
		local name = player:get_player_name()
		local pos = player:get_pos()
		local s = still[name]
		if s and vector.distance(s.pos, pos) < 0.5 then
			s.seconds = s.seconds + data.dtime
		else
			still[name] = { pos = pos, seconds = 0 }
		end
		run_checks("TICK", name, {
			name = name,
			player = player,
			still_for = still[name].seconds,
		})
	end
end)

lumo.events.on("PLAYER_LEAVE", function(data)
	still[data.name] = nil
end)

-- ---------------------------------------------------------------------------
-- As descobertas
-- ---------------------------------------------------------------------------
-- Algumas são amplas ("construa alto"), outras bem específicas. A mistura é
-- proposital: são as específicas que fazem a criança suspeitar que o mundo
-- está prestando atenção.

local function is_night()
	local t = core.get_timeofday()
	return t and (t < 0.20 or t > 0.80)
end

--- Aplica a preferência "Surpresas" a um limiar numérico.
---
--- "poucas" não desliga descoberta nenhuma -- só espaça: exige o dobro. E
--- "muitas" aproxima, exigindo dois terços. É assim que a opção do menu vira
--- comportamento em vez de ficar guardada sem efeito.
local function threshold(name, base)
	local scale = lumo.accessibility.surprise_scale(name)
	return math.max(1, math.floor(base / scale))
end

lumo.discoveries.register({
	id = "acima_das_nuvens", title = "Acima das Nuvens", icon = "~",
	events = {"HEIGHT_REACHED"},
	check = function(name)
		return lumo.player.get_relative_height(name) >= threshold(name, 40)
	end,
})

lumo.discoveries.register({
	id = "la_embaixo", title = "O que existe lá embaixo?", icon = "v",
	events = {"DEPTH_REACHED"},
	check = function(name)
		return lumo.player.get_relative_depth(name) >= threshold(name, 50)
	end,
})

lumo.discoveries.register({
	id = "construtor_das_nuvens", title = "Construtor das Nuvens", icon = "^",
	events = {"STRUCTURE_DETECTED"},
	check = function(name, data)
		return data.kind == "tower" and data.size >= threshold(name, 20)
	end,
})

lumo.discoveries.register({
	id = "um_lugar_para_chamar_de_lar", title = "Um lugar para chamar de lar", icon = "#",
	events = {"STRUCTURE_DETECTED"},
	check = function(_, data)
		return data.kind == "house"
	end,
})

lumo.discoveries.register({
	id = "do_outro_lado", title = "Do outro lado", icon = "=",
	events = {"STRUCTURE_DETECTED"},
	check = function(_, data)
		return data.kind == "bridge"
	end,
})

lumo.discoveries.register({
	id = "jardineiro", title = "Jardineiro", icon = "*",
	events = {"STRUCTURE_DETECTED"},
	check = function(_, data)
		return data.kind == "garden"
	end,
})

lumo.discoveries.register({
	id = "mundo_colorido", title = "Mundo Colorido", icon = "%",
	events = {"BLOCK_PLACED"},
	check = function(name)
		return lumo.player.count_distinct_placed(name, "^wool:") >= threshold(name, 8)
	end,
})

lumo.discoveries.register({
	id = "construtor_noturno", title = "Construtor Noturno", icon = "(",
	events = {"BLOCK_PLACED"},
	check = function(name)
		return is_night() and lumo.player.get_stat(name, "blocks_placed") >= threshold(name, 30)
	end,
})

lumo.discoveries.register({
	id = "momento_tranquilo", title = "Um momento tranquilo", icon = ".",
	events = {"TICK"},
	check = function(_, data)
		-- Parado por meio minuto, ao entardecer. Não há como "tentar" isto de
		-- propósito sem, de fato, parar e olhar.
		local t = core.get_timeofday()
		return (data.still_for or 0) >= 30 and t and t > 0.70 and t < 0.85
	end,
})

lumo.discoveries.register({
	id = "explorador", title = "Explorador", icon = "?",
	events = {"PLAYER_MOVE_REGION"},
	-- Quem sabe onde a criança já esteve é o lumo_world. Antes esta checagem
	-- gravava a resposta na memória do Lumo por conta própria, o que furava a
	-- API do lumo_companion e criava uma segunda cópia de um dado que já tinha
	-- dono. Agora ela só pergunta.
	check = function(name)
		return lumo.world.visited_count(name) >= threshold(name, 4)
	end,
})

lumo.discoveries.register({
	id = "mao_na_massa", title = "Mão na massa", icon = "+",
	events = {"BLOCK_PLACED"},
	check = function(name)
		return lumo.player.get_stat(name, "blocks_placed") >= threshold(name, 500)
	end,
})

lumo.discoveries.register({
	id = "primeiro_passo", title = "O primeiro bloco", icon = "1",
	events = {"BLOCK_PLACED"},
	check = function(name)
		return lumo.player.get_stat(name, "blocks_placed") >= 1
	end,
})

core.log("action", ("[%s] %d descobertas registradas"):format(MOD, #order))
