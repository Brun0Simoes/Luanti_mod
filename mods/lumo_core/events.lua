-- Event bus do Lumo.
--
-- A regra do projeto: um sistema não observa o jogador nem registra callbacks
-- globais próprios. Ele assina um evento aqui. O lumo_core é o único lugar do
-- jogo que conversa com os callbacks da engine.
--
-- Isso é o que permite responder "onde está o bug?" olhando para um módulo só.

local subscribers = {}  -- [evento] = lista já ordenada de assinantes
local declared = {}     -- [evento] = mod que declarou o evento
local seq = 0           -- desempate estável entre assinantes de mesma prioridade

lumo.events = {}

local DEFAULT_PRIORITY = 50

--- Declara um evento. Emitir ou assinar um evento não declarado ainda funciona,
--- mas registra um aviso no log -- é assim que um erro de digitação aparece no
--- primeiro uso em vez de virar um sistema que silenciosamente nunca reage.
function lumo.events.declare(name, doc)
	assert(type(name) == "string", "lumo.events.declare: o nome do evento deve ser uma string")
	local owner = core.get_current_modname() or "?"
	if declared[name] then
		core.log("warning", ("[lumo_core] evento %q redeclarado por %s (já pertencia a %s)")
			:format(name, owner, declared[name]))
		return
	end
	declared[name] = owner
	lumo.events._docs[name] = doc
end

lumo.events._docs = {}

--- Assina um evento.
--- `priority` menor roda antes; o padrão é 50. Assinantes de mesma prioridade
--- rodam na ordem em que foram registrados, o que segue a ordem de carga dos mods.
function lumo.events.on(name, fn, priority)
	assert(type(name) == "string", "lumo.events.on: o nome do evento deve ser uma string")
	assert(type(fn) == "function", "lumo.events.on: o handler deve ser uma função")

	local owner = core.get_current_modname() or "?"
	if not declared[name] then
		core.log("warning", ("[lumo_core] %s assinou o evento não declarado %q")
			:format(owner, name))
	end

	seq = seq + 1
	local list = subscribers[name]
	if not list then
		list = {}
		subscribers[name] = list
	end
	list[#list + 1] = {
		fn = fn,
		priority = priority or DEFAULT_PRIORITY,
		owner = owner,
		seq = seq,
	}
	table.sort(list, function(a, b)
		if a.priority ~= b.priority then
			return a.priority < b.priority
		end
		return a.seq < b.seq
	end)
end

--- Publica um evento para todos os assinantes.
---
--- Cada handler roda isolado: se um deles falhar, o erro vai para o log com o
--- nome do mod culpado e os outros continuam rodando. Um bug no lumo_companion
--- não pode impedir o lumo_journal de registrar a criação da criança.
---
--- Não existe interrupção de propagação por design: todos os interessados veem
--- todo evento. É o modelo de leque descrito no README.
function lumo.events.emit(name, data)
	if not declared[name] then
		core.log("warning", ("[lumo_core] emissão do evento não declarado %q"):format(tostring(name)))
	end

	local list = subscribers[name]
	if not list then
		return
	end

	for i = 1, #list do
		local sub = list[i]
		local ok, err = pcall(sub.fn, data)
		if not ok then
			core.log("error", ("[lumo_core] assinante de %q vindo de %s falhou: %s")
				:format(name, sub.owner, tostring(err)))
		end
	end
end

--- Diagnóstico: quem está ouvindo o quê. Útil no console do servidor.
function lumo.events.dump()
	local out = {}
	local names = {}
	for name in pairs(declared) do
		names[#names + 1] = name
	end
	table.sort(names)
	for _, name in ipairs(names) do
		local list = subscribers[name] or {}
		local owners = {}
		for _, sub in ipairs(list) do
			owners[#owners + 1] = sub.owner
		end
		out[#out + 1] = ("%-20s %d assinante(s)%s"):format(
			name, #list, #owners > 0 and (": " .. table.concat(owners, ", ")) or "")
	end
	return table.concat(out, "\n")
end

-- ---------------------------------------------------------------------------
-- Catálogo de eventos
-- ---------------------------------------------------------------------------
-- Publicados pelo próprio lumo_core, a partir dos callbacks da engine:
lumo.events.declare("TICK",          "pulso de 1s; data = {dtime, players}")
lumo.events.declare("PLAYER_JOIN",   "data = {player, name, last_login}")
lumo.events.declare("PLAYER_LEAVE",  "data = {player, name, timed_out}")
lumo.events.declare("BLOCK_PLACED",  "data = {pos, node, oldnode, player, name}")
lumo.events.declare("BLOCK_REMOVED", "data = {pos, node, player, name}")
lumo.events.declare("ITEM_CRAFTED",  "data = {stack, player, name}")
lumo.events.declare("SHUTDOWN",     "servidor encerrando; última chance de salvar; data = {}")
lumo.events.declare("MODS_LOADED",  "todos os mods carregaram; hora de montar o mundo; data = {}")

-- Publicados pelos outros módulos. Declarados aqui de propósito, para que o
-- catálogo inteiro do jogo caiba em uma tela só.
lumo.events.declare("PLAYER_MOVE_REGION", "lumo_world; data = {player, name, from, to}")
lumo.events.declare("HEIGHT_REACHED",     "lumo_player; data = {player, name, y, record}")
lumo.events.declare("DEPTH_REACHED",      "lumo_player; data = {player, name, y, record}")
lumo.events.declare("PROJECT_STARTED",    "lumo_projects; data = {player, name, project}")
lumo.events.declare("PROJECT_COMPLETED",  "lumo_projects; data = {player, name, project}")
lumo.events.declare("DISCOVERY_FOUND",    "lumo_discoveries; data = {player, name, discovery}")
lumo.events.declare("LUMO_INTERACTION",   "lumo_companion; data = {player, name, kind, state, reason}; sem assinantes hoje -- existe para quem quiser reagir ao humor do Lumo")
lumo.events.declare("STRUCTURE_DETECTED", "lumo_interactions; data = {player, name, kind, pos, size}")
lumo.events.declare("CREATION_RECORDED",  "lumo_journal; data = {player, name, creation}")
lumo.events.declare("CANVAS_BUILT",      "lumo_canvas; data = {player, name, pos, width, height, blocks, filename}")
