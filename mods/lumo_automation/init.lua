-- Lumo - Robôs e máquinas programáveis.
--
-- Isto é programação, mas o jogo nunca diz isso. A criança está ensinando o
-- Lumo a construir; que ela esteja aprendendo sequência, repetição e condição
-- de quebra é assunto nosso, não dela.
--
-- A escada é: primeiro uma lista de passos, depois repetição, depois condição,
-- e só no fim -- para quem quiser -- Lua de verdade, pela mesma API que a
-- interface usa. Quem nunca quiser tocar em programação continua com o jogo
-- inteiro disponível; nada aqui é obrigatório.
--
-- Publica: —
-- Consome: PLAYER_LEAVE

lumo.automation = {}

local MOD = core.get_current_modname()
local FORM = "lumo:program"

-- Limites duros. Um programa é escrito por uma criança experimentando, então
-- ele *vai* ter laço grande demais e condição que nunca fecha. Isso não pode
-- travar o servidor nem entulhar o mundo longe dela.
local MAX_STEPS    = 256   -- instruções executadas por rodada
local MAX_DISTANCE = 32    -- blocos de distância do ponto de partida
local MAX_PROGRAM  = 40    -- instruções que cabem num programa
local STEP_DELAY   = 0.12  -- segundos entre um passo e outro, para dar de ver

-- ---------------------------------------------------------------------------
-- Instruções
-- ---------------------------------------------------------------------------

local ACTIONS = {
	{ id = "forward", label = "AVANÇAR" },
	{ id = "left",    label = "VIRAR À ESQUERDA" },
	{ id = "right",   label = "VIRAR À DIREITA" },
	{ id = "up",      label = "SUBIR" },
	{ id = "down",    label = "DESCER" },
	{ id = "place",   label = "COLOCAR BLOCO" },
	{ id = "skip_if_block", label = "SE HOUVER BLOCO, PULAR 1" },
}

local ACTION_BY_ID = {}
for _, a in ipairs(ACTIONS) do
	ACTION_BY_ID[a.id] = a
end

-- Direções cardeais, em ordem de giro à direita.
local FACINGS = {
	vector.new( 0, 0, 1),   -- norte
	vector.new( 1, 0, 0),   -- leste
	vector.new( 0, 0,-1),   -- sul
	vector.new(-1, 0, 0),   -- oeste
}

--- Para qual das quatro direções o jogador está olhando.
local function facing_index(player)
	local yaw = player:get_look_horizontal()
	-- yaw 0 = norte (+z), crescendo no sentido anti-horário na engine.
    local i = math.floor(((-yaw / (math.pi / 2)) % 4) + 0.5) % 4
	return i + 1
end

-- ---------------------------------------------------------------------------
-- Programa
-- ---------------------------------------------------------------------------

function lumo.automation.get_program(name)
	local st = lumo.player.get(name)
	return st and st.program or {}
end

function lumo.automation.add(name, action_id, count)
	local st = lumo.player.get(name)
	if not st or not ACTION_BY_ID[action_id] then
		return false
	end
	if #st.program >= MAX_PROGRAM then
		return false, ("O programa já tem %d passos. Apague algum para caber mais."):format(MAX_PROGRAM)
	end
	st.program[#st.program + 1] = {
		action = action_id,
		count = math.max(1, math.min(20, tonumber(count) or 1)),
	}
	return true
end

function lumo.automation.remove(name, index)
	local st = lumo.player.get(name)
	if not st or not st.program[index] then
		return false
	end
	table.remove(st.program, index)
	return true
end

function lumo.automation.clear(name)
	local st = lumo.player.get(name)
	if st then
		st.program = {}
	end
end

-- ---------------------------------------------------------------------------
-- Execução
-- ---------------------------------------------------------------------------

local running = {}   -- [nome] = true enquanto um programa roda

-- `core.after` não dá para cancelar. Sem um número de geração, um `stop()`
-- seguido de `run()` dentro de STEP_DELAY deixava a continuação antiga viva: o
-- flag voltava a ser verdadeiro e dois cursores passavam a construir ao mesmo
-- tempo, cada um achando que era o único.
local generation = {}   -- [nome] = número da execução atual

--- O bloco que o Lumo vai colocar.
---
--- Primeiro o que a criança está segurando: é a única forma de ela dizer "use
--- este". Antes isto pegava o primeiro node que achasse no inventário, o que
--- emparedava o baú que estivesse no slot 1 e ignorava por completo a escolha
--- dela. O resto do inventário é só reserva, para o programa não parar no meio.
local function take_block(player, name)
	local free = core.is_creative_enabled(name)

	local wielded = player:get_wielded_item()
	local wname = wielded:get_name()
	if wname ~= "" and core.registered_nodes[wname] then
		if not free then
			wielded:take_item(1)
			player:set_wielded_item(wielded)
		end
		return wname
	end

	local inv = player:get_inventory()
	for i, stack in ipairs(inv:get_list("main") or {}) do
		local iname = stack:get_name()
		if iname ~= "" and core.registered_nodes[iname] then
			if not free then
				stack:take_item(1)
				inv:set_stack("main", i, stack)
			end
			return iname
		end
	end
	return nil
end

--- Coloca um bloco e conta ao resto do jogo que isso aconteceu.
---
--- `core.set_node` não dispara os callbacks de colocação. Sem este despacho,
--- nada saberia do que o Lumo construiu: as estatísticas não subiriam, os
--- projetos não avançariam e os detectores de forma nunca veriam a torre. Seria
--- justamente o ato mais deliberado do jogo -- ensinar o Lumo a construir -- o
--- único que o mundo não enxerga.
---
--- O Minetest Game faz o mesmo despacho manual pelo mesmo motivo
--- (mods/doors/init.lua:196).
local function set_node_and_announce(pos, node, player)
	local oldnode = core.get_node(pos)
	if not core.set_node(pos, node) then
		-- `core.set_node` devolve false quando o bloco de mapa não está
		-- carregado (src/script/lua_api/l_env.cpp:178). Antes o retorno era
		-- ignorado, e o jogo anunciava uma colocação que não aconteceu.
		return false
	end

	-- Um pointed_thing sintético e um ItemStack de verdade, porque é isso que
	-- a engine passa (builtin/game/item.lua:310) e é o que qualquer mod de
	-- terceiro espera encontrar. Passar nil aqui é um contrato quebrado
	-- esperando por um mod que leia esses campos.
	local stack = ItemStack(node.name)
	local pointed = {
		type = "node",
		above = vector.copy(pos),
		under = vector.new(pos.x, pos.y - 1, pos.z),
	}

	for _, callback in ipairs(core.registered_on_placenodes) do
		-- Cópias: um callback pode alterar o que recebe, e o próximo da fila
		-- precisa ver o valor original.
		--
		-- E dentro de pcall porque isto roda numa continuação de `core.after`,
		-- que a engine invoca sem proteção (builtin/common/after.lua): um erro
		-- aqui viraria `setAsyncFatalError` e derrubaria o servidor. Estamos
		-- chamando callbacks de outros mods com `itemstack` e `pointed_thing`
		-- nil, coisa que a engine nunca faz -- qualquer mod que os acesse
		-- estouraria.
		local ok, err = pcall(callback, vector.copy(pos), table.copy(node),
			player, table.copy(oldnode), stack, table.copy(pointed))
		if not ok then
			core.log("error", ("[%s] on_placenode de terceiro falhou no despacho do Lumo: %s")
				:format(MOD, tostring(err)))
		end
	end
	return true
end

local function step_ok(name, cursor, origin)
	if vector.distance(cursor.pos, origin) > MAX_DISTANCE then
		return false, "O Lumo se afastou demais e parou."
	end
	if core.is_protected(cursor.pos, name) then
		return false, "O Lumo não consegue mexer aqui."
	end
	return true
end

--- Executa o programa da criança, um passo por vez, para que ela veja
--- acontecer. Devolve por callback a mensagem final.
function lumo.automation.run(name, on_done)
	local player = core.get_player_by_name(name)
	local program = lumo.automation.get_program(name)

	if not player then
		return false
	end
	if running[name] then
		return false, "O Lumo ainda está fazendo a última coisa que você pediu."
	end
	if #program == 0 then
		return false, "O programa está vazio. Ensine alguns passos ao Lumo primeiro."
	end

	local origin = vector.round(player:get_pos())
	local cursor = {
		pos = vector.new(origin.x, origin.y, origin.z),
		facing = facing_index(player),
	}

	-- A execução é achatada numa fila: cada instrução com `count` vira `count`
	-- passos. Isso mantém o interpretador trivial e o limite de passos honesto
	-- -- "repetir 20 vezes" custa 20, e não 1.
	local queue = {}
	for _, ins in ipairs(program) do
		for _ = 1, ins.count do
			queue[#queue + 1] = ins.action
			if #queue >= MAX_STEPS then
				break
			end
		end
		if #queue >= MAX_STEPS then
			break
		end
	end

	running[name] = true
	generation[name] = (generation[name] or 0) + 1
	local gen = generation[name]
	local i = 0
	local placed = 0

	local function finish(msg)
		if generation[name] ~= gen then
			return   -- outra execução assumiu; esta não fala mais
		end
		running[name] = false
		if on_done then
			on_done(msg)
		end
	end

	local function step()
		if not running[name] or generation[name] ~= gen then
			return   -- a criança saiu, pediu para parar, ou já mandou outra coisa
		end
		i = i + 1
		if i > #queue then
			return finish(("Pronto! O Lumo colocou %d bloco(s)."):format(placed))
		end

		local action = queue[i]
		local dir = FACINGS[cursor.facing]

		if action == "left" then
			cursor.facing = ((cursor.facing - 2) % 4) + 1
		elseif action == "right" then
			cursor.facing = (cursor.facing % 4) + 1
		elseif action == "forward" then
			cursor.pos = vector.add(cursor.pos, dir)
		elseif action == "up" then
			cursor.pos = vector.new(cursor.pos.x, cursor.pos.y + 1, cursor.pos.z)
		elseif action == "down" then
			cursor.pos = vector.new(cursor.pos.x, cursor.pos.y - 1, cursor.pos.z)
		elseif action == "skip_if_block" then
			local node = core.get_node(vector.add(cursor.pos, dir))
			local def = core.registered_nodes[node.name]
			if def and def.walkable then
				i = i + 1   -- há bloco à frente: pula a próxima instrução
			end
		elseif action == "place" then
			local ok, why = step_ok(name, cursor, origin)
			if not ok then
				return finish(why)
			end
			-- `core.get_node` devolve `ignore` em área não carregada, e
			-- `ignore` tem `buildable_to = true` (builtin/game/register.lua).
			-- Sem esta recusa, o Lumo consumia um bloco do inventário, não
			-- colocava nada, e ainda assim anunciava a colocação.
			local node = core.get_node_or_nil(cursor.pos)
			local def = node and core.registered_nodes[node.name]
			if def and node.name ~= "ignore"
				and (def.buildable_to or node.name == "air") then

				local item = take_block(player, name)
				if not item then
					return finish("O Lumo ficou sem blocos para colocar.")
				end
				if set_node_and_announce(cursor.pos, { name = item, param1 = 0, param2 = 0 }, player) then
					placed = placed + 1
				end
			end
		end

		local ok, why = step_ok(name, cursor, origin)
		if not ok then
			return finish(why)
		end

		core.after(STEP_DELAY, step)
	end

	step()
	return true
end

function lumo.automation.stop(name)
	running[name] = false
	-- Invalida a continuação pendente: ela vai acordar, ver que a geração
	-- mudou e desistir sozinha.
	generation[name] = (generation[name] or 0) + 1
end

-- ---------------------------------------------------------------------------
-- Interface
-- ---------------------------------------------------------------------------

local function esc(s)
	return core.formspec_escape(tostring(s))
end

function lumo.automation.show(name)
	local program = lumo.automation.get_program(name)

	local rows = {}
	for i, ins in ipairs(program) do
		local a = ACTION_BY_ID[ins.action]
		local label = a and a.label or ins.action
		if ins.count > 1 then
			label = ("%s  x%d"):format(label, ins.count)
		end
		rows[#rows + 1] = esc(("%2d. %s"):format(i, label))
	end

	local buttons = {}
	local y = 1.2
	for i, a in ipairs(ACTIONS) do
		buttons[#buttons + 1] = ("button[7.0,%f;4.6,0.7;add_%d;%s]"):format(y, i, esc(a.label))
		y = y + 0.85
	end

	local fs = table.concat({
		"formspec_version[6]",
		"size[12,10]",
		"label[0.5,0.6;Ensinar o Lumo]",
		"label[7.0,0.6;Passos que ele conhece]",
		("textlist[0.5,1.2;6,6.2;steps;%s;0;false]"):format(table.concat(rows, ",")),
		table.concat(buttons),
		"field[0.5,7.8;1.6,0.8;count;Quantas vezes;1]",
		"button[2.3,7.8;2.0,0.8;remove;Apagar passo]",
		"button[4.5,7.8;2.0,0.8;clear;Limpar tudo]",
		"button[0.5,8.9;5.5,0.9;run;EXECUTAR]",
		"button_exit[7.0,8.9;4.6,0.9;close;Fechar]",
		("label[0.5,7.4;%d de %d passos]"):format(#program, MAX_PROGRAM),
	})
	core.show_formspec(name, FORM, fs)
end

local sel_step = {}   -- [nome] = passo selecionado na lista

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= FORM then
		return
	end
	local name = player:get_player_name()
	local count = tonumber(fields.count) or 1

	if fields.steps then
		local ev = core.explode_textlist_event(fields.steps)
		if ev.type == "CHG" or ev.type == "DCL" then
			sel_step[name] = ev.index
		end
		return true
	end

	for i in pairs(ACTIONS) do
		if fields["add_" .. i] then
			local ok, why = lumo.automation.add(name, ACTIONS[i].id, count)
			if not ok and why then
				core.chat_send_player(name, why)
			end
			lumo.automation.show(name)
			return true
		end
	end

	if fields.remove then
		lumo.automation.remove(name, sel_step[name] or #lumo.automation.get_program(name))
		lumo.automation.show(name)
		return true
	end

	if fields.clear then
		lumo.automation.clear(name)
		sel_step[name] = nil
		lumo.automation.show(name)
		return true
	end

	if fields.run then
		core.close_formspec(name, FORM)
		local ok, why = lumo.automation.run(name, function(msg)
			core.chat_send_player(name, msg)
		end)
		if not ok and why then
			core.chat_send_player(name, why)
		end
		return true
	end

	return true
end)

core.register_chatcommand("ensinar", {
	description = "Abre o painel para ensinar passos ao Lumo",
	func = function(name)
		if not lumo.player.get(name) then
			return false, "Seu progresso ainda não carregou. Tente de novo em um instante."
		end
		lumo.automation.show(name)
		return true
	end,
})

lumo.events.on("PLAYER_LEAVE", function(data)
	running[data.name] = nil
	generation[data.name] = nil
	sel_step[data.name] = nil
end)

core.log("action", ("[%s] %d instruções disponíveis"):format(MOD, #ACTIONS))
