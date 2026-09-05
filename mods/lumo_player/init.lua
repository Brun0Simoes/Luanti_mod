-- Lumo - Progresso e preferências do jogador.
--
-- Guarda o que cada criança já fez e como ela prefere jogar. É a única fonte
-- de verdade sobre progresso: os outros módulos leem daqui em vez de manterem
-- cada um a sua cópia.
--
-- Publica: HEIGHT_REACHED, DEPTH_REACHED
-- Consome: PLAYER_JOIN, PLAYER_LEAVE, BLOCK_PLACED, BLOCK_REMOVED,
--          ITEM_CRAFTED, CANVAS_BUILT, TICK, SHUTDOWN

lumo.player = {}

local MOD = core.get_current_modname()
local META_KEY = "lumo"
local FORMAT = 1          -- versão do formato salvo; ver migrate()
local AUTOSAVE = 60       -- segundos

-- Quanto esperamos antes de fixar a altura de origem.
--
-- A engine ainda está resolvendo o ponto de nascimento nos primeiros segundos:
-- o jogador aparece no ar, cai até o chão, e às vezes é reposicionado. Medir
-- nesse intervalo transformava a queda numa subida -- e um projeto de
-- *construção* era dado como cumprido antes de a criança colocar o primeiro
-- bloco. Vi isso acontecer: "Você conseguiu! Olha o tamanho disso!" cinco
-- segundos depois de entrar no mundo.
local SETTLE = 6          -- segundos

-- Estado em memória, indexado por nome de jogador. Só existe enquanto a pessoa
-- está conectada; a fonte durável é o meta do jogador.
local state = {}
local settling = {}   -- [nome] = segundos restantes até fixar a origem
local since_save = 0

-- ---------------------------------------------------------------------------
-- Preferências ("Meu jeito de jogar")
-- ---------------------------------------------------------------------------
-- O menu que edita isto pertence ao lumo_accessibility. O armazenamento fica
-- aqui porque é progresso do jogador, não uma configuração do cliente.

local DEFAULT_PREFS = {
	lumo_talk  = "normal",      -- muito | normal | pouco
	hints      = "on_request",  -- on_request | auto | off
	particles  = "normal",      -- normal | reduzidas | off
	weather    = true,
	night      = true,
	projects   = true,
	surprises  = "normal",      -- muitas | normal | poucas
}

local function new_state()
	local prefs = {}
	for k, v in pairs(DEFAULT_PREFS) do
		prefs[k] = v
	end
	return {
		format = FORMAT,
		prefs = prefs,
		-- Records ficam nil até a primeira amostragem: assim o primeiro tick
		-- depois de entrar no mundo não dispara um "recorde" falso.
		--
		-- `origin` é a altura onde a criança começou, gravada uma única vez e
		-- para sempre. Alturas relativas a ela ("subiu 20 acima de onde
		-- começou") significam a mesma coisa em qualquer terreno; alturas
		-- absolutas não.
		records = { height = nil, depth = nil, origin = nil },
		stats = {
			blocks_placed = 0,
			blocks_removed = 0,
			items_crafted = 0,
			sessions = 0,
		},
		placed_by_node = {},  -- [nome do node] = quantas vezes foi colocado
		projects = {},        -- [id do projeto] = "started" | "done"
		discoveries = {},     -- [id da descoberta] = timestamp de quando achou
		creations = {},       -- o Livro das Criações; ver lumo_journal
		visited_regions = {}, -- onde ela já esteve; escrito só pelo lumo_world
		program = {},         -- instruções ensinadas ao Lumo; ver lumo_automation
		memory = {},          -- fatos que o Lumo lembra; ver lumo_companion
	}
end

--- Migra um estado salvo por uma versão anterior do jogo.
--- Enquanto FORMAT for 1 não há nada a fazer, mas o ponto de entrada precisa
--- existir antes de a primeira criança salvar progresso -- depois é tarde.
local function migrate(data)
	-- `type(data.format) ~= "number"` e não `== nil`: um format que fosse
	-- string ou booleano fazia a comparação abaixo levantar erro. Como isto roda
	-- dentro do pcall do event bus, o erro era engolido, `state[name]` nunca era
	-- atribuído, e a criança passava a sessão inteira sem progresso -- sem save,
	-- sem menu, e sem sequer o backup, porque a exceção acontecia antes dele.
	-- Toda sessão seguinte batia na mesma parede.
	if type(data) ~= "table" or type(data.format) ~= "number" then
		return nil
	end
	if data.format > FORMAT then
		core.log("warning", ("[%s] estado salvo em formato %d, mais novo que o suportado (%d); ignorando")
			:format(MOD, data.format, FORMAT))
		return nil
	end
	-- Completa campos que versões futuras podem ter adicionado.
	local fresh = new_state()
	for k, v in pairs(fresh) do
		if data[k] == nil then
			data[k] = v
		end
	end
	-- E também dentro das subtabelas. Sem isto, um campo novo em `stats` ou
	-- `records` chegava a jogador novo e nunca a quem já tinha save: `data.stats`
	-- existia, então a chave jamais era criada, e a primeira soma estourava
	-- dentro do pcall do bus -- ou seja, em silêncio, e para sempre.
	-- Os campos que são só coleções precisam ao menos ser tabelas: um valor
	-- estranho aqui só falharia mais tarde, num pairs() distante daqui.
	for _, key in ipairs({"placed_by_node", "projects", "discoveries",
	                      "creations", "visited_regions", "program", "memory"}) do
		if type(data[key]) ~= "table" then
			data[key] = {}
		end
	end

	for _, sub in ipairs({"prefs", "stats", "records"}) do
		if type(data[sub]) ~= "table" then
			data[sub] = fresh[sub]
		else
			for k, v in pairs(fresh[sub]) do
				if data[sub][k] == nil then
					data[sub][k] = v
				end
			end
		end
	end
	data.format = FORMAT
	return data
end

-- ---------------------------------------------------------------------------
-- Persistência
-- ---------------------------------------------------------------------------

local function load(player)
	local name = player:get_player_name()
	local raw = player:get_meta():get_string(META_KEY)
	local data

	if raw ~= "" then
		-- O segundo argumento liga o modo seguro: não executa código vindo
		-- do que estava salvo em disco.
		local ok, parsed = pcall(core.deserialize, raw, true)
		if ok then
			data = migrate(parsed)
		end
		if not data then
			-- Não conseguimos ler, mas não vamos destruir. Sem isto, o próximo
			-- autosave passaria por cima do original em até 60 segundos e as
			-- criações, descobertas e preferências da criança sumiriam sem
			-- recurso. Guardamos os bytes originais antes de seguir do zero.
			-- Só grava se ainda não houver backup. Sem esta condição, uma
			-- segunda leitura ilegível sobrescrevia o backup com lixo -- e é
			-- exatamente essa a situação para a qual ele existe, porque um
			-- problema de serialização tende a se repetir.
			local meta = player:get_meta()
			if meta:get_string(META_KEY .. "_recuperar") == "" then
				meta:set_string(META_KEY .. "_recuperar", raw)
				core.log("warning", ("[%s] progresso de %s ilegível; original guardado em %s_recuperar, começando do zero")
					:format(MOD, name, META_KEY))
			else
				core.log("warning", ("[%s] progresso de %s ilegível de novo; backup anterior preservado")
					:format(MOD, name))
			end
		end
	end

	state[name] = data or new_state()
	state[name].stats.sessions = (state[name].stats.sessions or 0) + 1
	return state[name]
end

local function save(name)
	local st = state[name]
	if not st then
		return
	end
	local player = core.get_player_by_name(name)
	if not player then
		return
	end
	player:get_meta():set_string(META_KEY, core.serialize(st))
end

local function save_all()
	for name in pairs(state) do
		save(name)
	end
end

-- ---------------------------------------------------------------------------
-- API pública
-- ---------------------------------------------------------------------------

--- Estado completo de um jogador conectado, ou nil.
function lumo.player.get(name)
	return state[name]
end

function lumo.player.get_pref(name, key)
	local st = state[name]
	if not st then
		return DEFAULT_PREFS[key]
	end
	local value = st.prefs[key]
	if value == nil then
		return DEFAULT_PREFS[key]
	end
	return value
end

function lumo.player.set_pref(name, key, value)
	if DEFAULT_PREFS[key] == nil then
		core.log("warning", ("[%s] preferência desconhecida: %s"):format(MOD, tostring(key)))
		return false
	end
	local st = state[name]
	if not st then
		return false
	end
	st.prefs[key] = value
	return true
end

--- Recorde de altura ou profundidade. Pode ser nil se ainda não houve amostra.
function lumo.player.get_record(name, key)
	local st = state[name]
	return st and st.records[key] or nil
end

--- Quanto a criança subiu (ou desceu, se negativo) em relação ao ponto onde
--- ela começou. É a medida que os projetos e as descobertas devem usar:
--- "alto" quer dizer alto para ela, não para o mapa.
function lumo.player.get_relative_height(name)
	local st = state[name]
	if not st or not st.records.origin or not st.records.height then
		return 0
	end
	return st.records.height - st.records.origin
end

function lumo.player.get_relative_depth(name)
	local st = state[name]
	if not st or not st.records.origin or not st.records.depth then
		return 0
	end
	return st.records.origin - st.records.depth
end

function lumo.player.get_stat(name, key)
	local st = state[name]
	return st and st.stats[key] or 0
end

--- Quantas vezes o jogador já colocou um node específico.
function lumo.player.count_placed(name, node_name)
	local st = state[name]
	return st and st.placed_by_node[node_name] or 0
end

--- Quantos nodes distintos que casam com um padrão Lua já foram colocados.
--- Usado por projetos do tipo "faça algo com pelo menos cinco cores".
function lumo.player.count_distinct_placed(name, pattern)
	local st = state[name]
	if not st then
		return 0
	end
	local n = 0
	for node_name in pairs(st.placed_by_node) do
		if not pattern or node_name:match(pattern) then
			n = n + 1
		end
	end
	return n
end

--- Salva agora. Útil antes de uma operação arriscada.
function lumo.player.save(name)
	save(name)
end

-- ---------------------------------------------------------------------------
-- Reação aos eventos
-- ---------------------------------------------------------------------------

-- Prioridade 10: o estado precisa existir antes de qualquer outro módulo
-- reagir ao mesmo PLAYER_JOIN.
lumo.events.on("PLAYER_JOIN", function(data)
	load(data.player)
	settling[data.name] = SETTLE
end, 10)

-- Prioridade 90: os outros já tiveram a chance de escrever algo no estado.
lumo.events.on("PLAYER_LEAVE", function(data)
	save(data.name)
	state[data.name] = nil
	settling[data.name] = nil
end, 90)

lumo.events.on("SHUTDOWN", function()
	save_all()
end)

lumo.events.on("BLOCK_PLACED", function(data)
	local st = data.name and state[data.name]
	if not st then
		return
	end
	st.stats.blocks_placed = st.stats.blocks_placed + 1
	local node_name = data.node and data.node.name
	if node_name then
		st.placed_by_node[node_name] = (st.placed_by_node[node_name] or 0) + 1
	end
end)

lumo.events.on("BLOCK_REMOVED", function(data)
	local st = data.name and state[data.name]
	if st then
		st.stats.blocks_removed = st.stats.blocks_removed + 1
	end
end)

-- O lumo_canvas coloca milhares de blocos sem passar pelos callbacks da
-- engine, de propósito. Então a contagem chega aqui de uma vez só -- senão o
-- desenho da criança não contaria como coisa construída.
lumo.events.on("CANVAS_BUILT", function(data)
	local st = data.name and state[data.name]
	if st and type(data.blocks) == "number" then
		st.stats.blocks_placed = st.stats.blocks_placed + data.blocks
	end
end)

lumo.events.on("ITEM_CRAFTED", function(data)
	local st = data.name and state[data.name]
	if st then
		st.stats.items_crafted = st.stats.items_crafted + 1
	end
end)

lumo.events.on("TICK", function(data)
	for _, player in ipairs(data.players) do
		local name = player:get_player_name()
		local st = state[name]
		if st then
			local y = math.floor(player:get_pos().y)
			local rec = st.records

			local left = settling[name]

			if left then
				-- Ainda assentando: não medimos nada. Ver o comentário de
				-- SETTLE -- é aqui que um projeto de construção era concluído
				-- pela queda do nascimento.
				left = left - data.dtime
				if left > 0 then
					settling[name] = left
				else
					settling[name] = nil
					if rec.origin == nil then
						rec.origin = y
					end
					-- Recordes são de vida inteira: só inicializamos se ainda
					-- não existirem, nunca reiniciamos.
					rec.height = rec.height or y
					rec.depth = rec.depth or y
				end
			elseif rec.height == nil then
				rec.height, rec.depth = y, y
				if rec.origin == nil then
					rec.origin = y
				end
			elseif y > rec.height then
				rec.height = y
				lumo.events.emit("HEIGHT_REACHED", {
					player = player, name = name, y = y, record = true,
				})
			elseif y < rec.depth then
				rec.depth = y
				lumo.events.emit("DEPTH_REACHED", {
					player = player, name = name, y = y, record = true,
				})
			end
		end
	end

	since_save = since_save + data.dtime
	if since_save >= AUTOSAVE then
		since_save = 0
		save_all()
	end
end)
