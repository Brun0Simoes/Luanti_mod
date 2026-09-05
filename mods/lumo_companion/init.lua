-- Lumo - O personagem Lumo.
--
-- Uma máquina de estados e uma memória simples. Nada de IA generativa: o Lumo
-- não inventa frases, ele reconhece situações. Para a criança o efeito é o
-- mesmo -- parece que ele está reparando no que ela faz -- mas o comportamento
-- é previsível, testável e nunca diz nada que não tenha sido escrito por uma
-- pessoa.
--
-- Publica: LUMO_INTERACTION
-- Consome: PLAYER_JOIN, PLAYER_LEAVE, BLOCK_PLACED, HEIGHT_REACHED, DEPTH_REACHED,
--          PLAYER_MOVE_REGION, STRUCTURE_DETECTED, PROJECT_STARTED,
--          PROJECT_COMPLETED,
--          DISCOVERY_FOUND, TICK

lumo.companion = {}

local MOD = core.get_current_modname()

-- Estados possíveis do Lumo.
local S = {
	IDLE         = "IDLE",
	FOLLOW       = "FOLLOW_PLAYER",
	OBSERVING    = "OBSERVING",
	CURIOUS      = "CURIOUS",
	EXCITED      = "EXCITED",
	PROJECT_HELP = "PROJECT_HELP",
}
lumo.companion.STATES = S

-- Quanto tempo o Lumo fica em silêncio entre uma fala e outra, conforme a
-- preferência "Lumo fala" do menu Meu jeito de jogar.
local COOLDOWN = { muito = 8, normal = 22, pouco = 75 }

-- Quanto tempo um estado animado dura antes de voltar para IDLE.
local STATE_DECAY = 20

-- Janela deslizante para decidir "isso está virando uma construção".
local BUILD_WINDOW = 30   -- segundos
local BUILD_TRIGGER = 12  -- blocos dentro da janela

-- Estado em memória, só enquanto conectado.
local rt = {}   -- [nome] = { state, state_since, last_speech, ring, ring_next, ring_count }

local function now()
	return core.get_gametime() or 0
end

-- ---------------------------------------------------------------------------
-- Fala
-- ---------------------------------------------------------------------------

--- Faz o Lumo dizer algo, respeitando o silêncio pedido pela criança.
--- `important` fura o cooldown -- use só para o que ela está esperando ouvir,
--- como a conclusão de um projeto.
--- Retorna true se falou de fato.
function lumo.companion.say(name, text, important)
	local r = rt[name]
	if not r then
		return false
	end

	local talk = lumo.player.get_pref(name, "lumo_talk")
	if talk == "pouco" and not important then
		-- Em "pouco" o Lumo só se manifesta no que realmente importa.
		return false
	end

	local t = now()
	if not important and (t - r.last_speech) < (COOLDOWN[talk] or COOLDOWN.normal) then
		return false
	end

	r.last_speech = t
	core.chat_send_player(name, core.colorize("#7fd4ff", "Lumo: ") .. text)
	return true
end

-- ---------------------------------------------------------------------------
-- Estados
-- ---------------------------------------------------------------------------

function lumo.companion.get_state(name)
	local r = rt[name]
	return r and r.state or S.IDLE
end

function lumo.companion.set_state(name, state, reason)
	local r = rt[name]
	if not r or r.state == state then
		return false
	end
	r.state = state
	r.state_since = now()
	lumo.events.emit("LUMO_INTERACTION", {
		player = core.get_player_by_name(name),
		name = name,
		kind = "state",
		state = state,
		reason = reason,
	})
	return true
end

-- ---------------------------------------------------------------------------
-- Memória
-- ---------------------------------------------------------------------------
-- Guardada dentro do estado do lumo_player, então sobrevive entre sessões: o
-- Lumo lembra da casa que a criança construiu semana passada.

-- O que entra na memória vai para core.serialize no save do jogador. Um
-- ObjectRef ou uma função aqui não corromperiam só a lembrança: levariam junto
-- todo o progresso da criança. Então a porta é estreita de propósito.
local SERIALIZABLE = { boolean = true, number = true, string = true, table = true }

function lumo.companion.remember(name, key, value)
	local st = lumo.player.get(name)
	if not st then
		return false
	end
	if value == nil then
		value = true
	end
	if not SERIALIZABLE[type(value)] then
		core.log("warning", ("[%s] memória %q ignorada: %s não é serializável")
			:format(MOD, tostring(key), type(value)))
		return false
	end
	st.memory[key] = value
	return true
end

function lumo.companion.recall(name, key)
	local st = lumo.player.get(name)
	if not st then
		return nil
	end
	-- Sem `and/or` aqui: `remember` aceita booleanos, e o idioma colapsaria um
	-- `false` guardado em nil -- indistinguível de "nunca lembrado".
	return st.memory[key]
end

--- Diz algo apenas na primeira vez que aquilo acontece com aquela criança.
local function say_once(name, key, text, important)
	if lumo.companion.recall(name, key) then
		return false
	end
	if lumo.companion.say(name, text, important) then
		lumo.companion.remember(name, key, true)
		return true
	end
	return false
end
lumo.companion.say_once = say_once

-- ---------------------------------------------------------------------------
-- Reação aos eventos
-- ---------------------------------------------------------------------------

-- Prioridade 30: depois do lumo_player (10) e do lumo_world (20), para que o
-- estado e a região já estejam prontos quando o Lumo for cumprimentar.
lumo.events.on("PLAYER_JOIN", function(data)
	rt[data.name] = {
		state = S.IDLE,
		state_since = now(),
		last_speech = 0,
		-- Anel de tamanho fixo com os instantes das últimas colocações.
		ring = {},
		ring_next = 1,
		ring_count = 0,
	}

	local first_time = data.last_login == nil
	core.after(2.0, function()
		if not rt[data.name] then
			return   -- saiu antes de o Lumo abrir a boca
		end
		if first_time then
			lumo.companion.say(data.name,
				"Oi! Eu sou o Lumo. Este lugar está meio vazio. Quer construir alguma coisa comigo?",
				true)
		else
			lumo.companion.say(data.name, "Você voltou! Vamos continuar?", true)
		end
		lumo.companion.set_state(data.name, S.FOLLOW, "join")
	end)
end, 30)

lumo.events.on("PLAYER_LEAVE", function(data)
	rt[data.name] = nil
end)

lumo.events.on("BLOCK_PLACED", function(data)
	local r = data.name and rt[data.name]
	if not r then
		return
	end

	-- A pergunta é só uma: as últimas BUILD_TRIGGER colocações couberam na
	-- janela? Um anel de BUILD_TRIGGER posições responde isso em O(1).
	--
	-- Antes isto reconstruía, a cada bloco, uma lista com tudo dos últimos 30
	-- segundos -- ou seja, trabalho quadrático no ritmo de construção. Com um
	-- cliente modificado colocando 100 blocos por segundo, eram 3.000 entradas
	-- reconstruídas 100 vezes por segundo, no callback mais quente do jogo.
	local t = now()
	r.ring[r.ring_next] = t
	local oldest = r.ring[(r.ring_next % BUILD_TRIGGER) + 1]
	r.ring_next = (r.ring_next % BUILD_TRIGGER) + 1
	if r.ring_count < BUILD_TRIGGER then
		r.ring_count = r.ring_count + 1
	end

	local burst = r.ring_count >= BUILD_TRIGGER
		and oldest and (t - oldest) <= BUILD_WINDOW

	if burst and r.state ~= S.CURIOUS then
		lumo.companion.set_state(data.name, S.CURIOUS, "building")
		lumo.companion.say(data.name, "Hmm... isso está começando a parecer uma construção!")
	end

	-- Uma porta muda a leitura da cena: deixou de ser um monte de blocos.
	local node_name = data.node and data.node.name or ""
	if node_name:find("doors:") then
		say_once(data.name, "saw_door", "Uma porta! Será que isso vai virar uma casa?")
	end
end)

lumo.events.on("HEIGHT_REACHED", function(data)
	if data.y >= 60 then
		say_once(data.name, "high_60", "Estamos ficando bem altos...")
	end
end)

lumo.events.on("DEPTH_REACHED", function(data)
	if data.y <= -20 then
		say_once(data.name, "deep_20", "Está escuro aqui embaixo. O que será que tem mais fundo?")
	end
end)

lumo.events.on("PLAYER_MOVE_REGION", function(data)
	if not data.to then
		return   -- saiu para o mundo livre; ali o Lumo não interrompe
	end
	local region = lumo.world.region_of(data.name)
	if region then
		say_once(data.name, "region_" .. data.to,
			("Nunca tínhamos vindo aqui. Isto é %s."):format(region.title))
	end
end)

-- Quem decide que existe um projeto é o lumo_projects; quem conta para a
-- criança é o Lumo. Por isso o convite vem daqui e não de lá.
lumo.events.on("PROJECT_STARTED", function(data)
	local def = data.project
	if not def then
		return
	end
	lumo.companion.set_state(data.name, S.PROJECT_HELP, "project")
	-- Uma oferta automática não fura o silêncio; uma que a criança pediu, sim.
	lumo.companion.say(data.name,
		("%s %s"):format(def.prompt or "", "(" .. def.title .. ")"), not data.auto)
end)

lumo.events.on("PROJECT_COMPLETED", function(data)
	lumo.companion.set_state(data.name, S.EXCITED, "project")
	lumo.companion.say(data.name,
		("Você conseguiu! %s"):format(data.project and data.project.done_text or "Ficou ótimo."),
		true)
end)

lumo.events.on("DISCOVERY_FOUND", function(data)
	lumo.companion.set_state(data.name, S.EXCITED, "discovery")
	local d = data.discovery
	if d then
		-- Importante: descoberta é o que a criança está esperando ouvir, então
		-- fura o silêncio. Mas o nome vem primeiro e sozinho -- a graça é ela
		-- ler "Acima das Nuvens" e entender por que ganhou aquilo.
		lumo.companion.say(data.name,
			("Descoberta! %s"):format(d.title), true)
	end
end)

-- Uma construção reconhecida merece uma reação diferente de um projeto
-- cumprido: aqui ninguém pediu nada, ela fez porque quis.
lumo.events.on("STRUCTURE_DETECTED", function(data)
	local falas = {
		house  = "Você fez uma casa! Posso escolher meu quarto?",
		bridge = "Dá para atravessar agora. Vou passar!",
		tower  = "Uau! Estamos ficando bem altos...",
		garden = "Olha, apareceram borboletas perto das flores.",
	}
	local fala = falas[data.kind]
	if fala then
		lumo.companion.set_state(data.name, S.EXCITED, "structure")
		say_once(data.name, "structure_" .. data.kind, fala, true)
	end
end)

lumo.events.on("TICK", function(data)
	local t = now()
	for _, player in ipairs(data.players) do
		local r = rt[player:get_player_name()]
		-- Estados animados são temporários: o Lumo se acalma sozinho.
		if r and r.state ~= S.IDLE and r.state ~= S.FOLLOW
			and (t - r.state_since) > STATE_DECAY then
			r.state = S.FOLLOW
			r.state_since = t
		end
	end
end)

core.log("action", ("[%s] Lumo acordou"):format(MOD))
