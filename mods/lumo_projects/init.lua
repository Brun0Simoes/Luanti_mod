-- Lumo - Projetos de construção.
--
-- Sugestões, nunca obrigações. Não existe cronômetro, não existe "MISSÃO
-- FALHOU" e um projeto nunca é retirado: ele simplesmente fica disponível até
-- a criança querer. Por isso não há estado "failed" em lugar nenhum deste
-- arquivo -- a ausência dele é a regra de design, não um esquecimento.
--
-- Um projeto também não diz *como* resolver. "Atravesse o rio" aceita uma
-- ponte reta, uma ponte torta, um aterro ou uma escada gigante. O que se
-- verifica é o resultado.
--
-- Publica: PROJECT_STARTED, PROJECT_COMPLETED
-- Consome: PLAYER_JOIN, PLAYER_LEAVE, BLOCK_PLACED, HEIGHT_REACHED,
--          DEPTH_REACHED, STRUCTURE_DETECTED, TICK

lumo.projects = {}

local MOD = core.get_current_modname()

local defs = {}       -- [id] = def
local order = {}      -- ids na ordem de registro
local by_event = {}   -- [evento] = { id, ... }; evita rodar toda checagem sempre

-- De quanto em quanto tempo o Lumo pode sugerir um projeto novo, quando a
-- criança não tem nenhum em aberto.
local OFFER_INTERVAL = 120
local last_offer = {}   -- [nome] = gametime da última sugestão

local function now()
	return core.get_gametime() or 0
end

-- ---------------------------------------------------------------------------
-- Registro
-- ---------------------------------------------------------------------------

--- Registra um projeto.
---
---     lumo.projects.register({
---         id = "atravessar_rio",
---         title = "Atravessar o rio",
---         prompt = "Será que conseguimos chegar ao outro lado?",
---         done_text = "Atravessamos!",
---         events = {"BLOCK_PLACED"},
---         check = function(name, data) return ... end,
---     })
---
--- `check` recebe o nome do jogador e os dados do evento, e devolve true
--- quando o projeto está cumprido. Ela roda dentro do event bus, ou seja,
--- protegida por pcall: um erro aqui não derruba os outros sistemas.
function lumo.projects.register(def)
	assert(type(def) == "table", "projects.register: def deve ser uma tabela")
	assert(type(def.id) == "string", "projects.register: id obrigatório")
	assert(type(def.check) == "function", "projects.register: check obrigatório")

	if defs[def.id] then
		core.log("warning", ("[%s] projeto %q registrado duas vezes"):format(MOD, def.id))
		return false
	end

	def.title = def.title or def.id
	def.events = def.events or {"TICK"}

	defs[def.id] = def
	order[#order + 1] = def.id
	for _, ev in ipairs(def.events) do
		by_event[ev] = by_event[ev] or {}
		table.insert(by_event[ev], def.id)
	end
	return true
end

function lumo.projects.get(id)
	return defs[id]
end

-- ---------------------------------------------------------------------------
-- Estado por jogador
-- ---------------------------------------------------------------------------

--- "available" | "started" | "done"
function lumo.projects.status(name, id)
	local st = lumo.player.get(name)
	if not st then
		return "available"
	end
	return st.projects[id] or "available"
end

local function set_status(name, id, status)
	local st = lumo.player.get(name)
	if st then
		st.projects[id] = status
	end
end

--- Todos os projetos com o estado atual da criança.
function lumo.projects.list(name)
	local out = {}
	for _, id in ipairs(order) do
		out[#out + 1] = {
			def = defs[id],
			status = lumo.projects.status(name, id),
		}
	end
	return out
end

-- ---------------------------------------------------------------------------
-- Ciclo de vida
-- ---------------------------------------------------------------------------

--- Oferece um projeto. Quem fala com a criança é o lumo_companion, reagindo ao
--- PROJECT_STARTED -- este módulo não conhece o Lumo nem a interface.
---
--- `auto` marca a oferta que partiu do jogo, e não da criança. O Lumo usa isso
--- para saber que essa fala pode ser engolida por quem pediu silêncio.
function lumo.projects.start(name, id, auto)
	local def = defs[id]
	if not def or lumo.projects.status(name, id) ~= "available" then
		return false
	end
	set_status(name, id, "started")
	last_offer[name] = now()
	lumo.events.emit("PROJECT_STARTED", {
		player = core.get_player_by_name(name),
		name = name,
		project = def,
		auto = auto and true or false,
	})
	return true
end

--- Marca como cumprido. Idempotente: chamar duas vezes não comemora duas vezes.
function lumo.projects.complete(name, id)
	local def = defs[id]
	if not def or lumo.projects.status(name, id) == "done" then
		return false
	end
	set_status(name, id, "done")
	lumo.events.emit("PROJECT_COMPLETED", {
		player = core.get_player_by_name(name),
		name = name,
		project = def,
	})
	return true
end

-- ---------------------------------------------------------------------------
-- Verificação
-- ---------------------------------------------------------------------------

--- Roda as checagens ligadas a um evento.
--- Um projeto pode ser cumprido sem nunca ter sido "iniciado": se a criança
--- construiu a ponte por conta própria antes de o Lumo sugerir, isso conta.
local function run_checks(event_name, name, data)
	if not name or not lumo.player.get(name) then
		return
	end
	local ids = by_event[event_name]
	if not ids then
		return
	end
	for _, id in ipairs(ids) do
		if lumo.projects.status(name, id) ~= "done" then
			if defs[id].check(name, data) then
				lumo.projects.complete(name, id)
			end
		end
	end
end

for _, ev in ipairs({"BLOCK_PLACED", "HEIGHT_REACHED", "DEPTH_REACHED", "STRUCTURE_DETECTED"}) do
	lumo.events.on(ev, function(data)
		run_checks(ev, data.name, data)
	end, 60)   -- depois do lumo_player (que atualiza as estatísticas usadas aqui)
end

lumo.events.on("PLAYER_JOIN", function(data)
	last_offer[data.name] = now()
end, 40)

lumo.events.on("PLAYER_LEAVE", function(data)
	last_offer[data.name] = nil
end)

lumo.events.on("TICK", function(data)
	local t = now()
	for _, player in ipairs(data.players) do
		local name = player:get_player_name()
		run_checks("TICK", name, data)

		-- Sugere um projeto novo, devagar, e só se a criança quiser projetos.
		--
		-- Quem pediu "o Lumo fala pouco" também não quer uma sugestão não
		-- solicitada a cada dois minutos. Sem esta checagem, a única saída
		-- dela seria desligar os projetos inteiros -- trocar um eixo da
		-- acessibilidade por outro. Os projetos continuam todos lá, na aba do
		-- Livro, para quando ela quiser ir buscar.
		local quiet = lumo.player.get_pref(name, "lumo_talk") == "pouco"
		if lumo.player.get_pref(name, "projects") and not quiet then
			local since = t - (last_offer[name] or 0)
			if since >= OFFER_INTERVAL then
				for _, id in ipairs(order) do
					if lumo.projects.status(name, id) == "available" then
						lumo.projects.start(name, id, true)
						break
					end
				end
				last_offer[name] = t
			end
		end
	end
end)

-- ---------------------------------------------------------------------------
-- Os primeiros projetos
-- ---------------------------------------------------------------------------
-- Todos verificáveis com o que já existe hoje. Os que dependem de reconhecer
-- formas -- a ponte, a casa, o jardim -- entram quando o lumo_interactions
-- estiver de pé.

lumo.projects.register({
	id = "primeiros_blocos",
	title = "Construir alguma coisa",
	prompt = "Este lugar está meio vazio. Que tal a gente colocar uns blocos?",
	done_text = "Já dá para ver que tem alguém morando aqui.",
	events = {"BLOCK_PLACED"},
	check = function(name)
		return lumo.player.get_stat(name, "blocks_placed") >= 20
	end,
})

-- Este projeto media a *altitude do jogador*, e não uma construção. Mesmo com
-- a origem correta, subir um morro a pé o cumpriria -- o que contraria a regra
-- de reconhecer a intenção: "construir algo alto" é sobre o que ela ergueu, não
-- sobre onde ela está. O detector de torre já responde exatamente isso.
lumo.projects.register({
	id = "bem_alto",
	title = "Construir algo muito alto",
	prompt = "Será que a gente consegue chegar bem alto daqui?",
	done_text = "Olha o tamanho disso!",
	events = {"STRUCTURE_DETECTED"},
	check = function(_, data)
		return data.kind == "tower" and data.size >= 12
	end,
})

lumo.projects.register({
	id = "mundo_colorido",
	title = "Fazer algo com pelo menos cinco cores",
	prompt = "E se a gente usasse um monte de cores diferentes?",
	done_text = "Ficou colorido de verdade.",
	events = {"BLOCK_PLACED"},
	check = function(name)
		return lumo.player.count_distinct_placed(name, "^wool:") >= 5
	end,
})

lumo.projects.register({
	id = "la_no_fundo",
	title = "Alcançar uma caverna",
	prompt = "Tem alguma coisa lá embaixo. Vamos descobrir o quê?",
	done_text = "Que fundo que a gente chegou.",
	events = {"DEPTH_REACHED"},
	check = function(name)
		return lumo.player.get_relative_depth(name) >= 30
	end,
})

core.log("action", ("[%s] %d projetos registrados"):format(MOD, #order))
