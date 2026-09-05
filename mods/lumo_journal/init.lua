-- Lumo - O Livro das Criações.
--
-- A diferença entre este registro e uma lista de conquistas é de quem é o
-- mérito. Uma lista de conquistas guarda o que o jogo entregou à criança; o
-- Livro guarda o que ela fez. Por isso cada entrada tem nome editável: a
-- criação é dela, inclusive para batizar.
--
-- O Livro escuta o jogo inteiro por evento e não precisa conhecer ninguém.
-- Ele já foi o `last_mod` do jogo, mas isso foi desfeito: a ordem de carga não
-- muda nada para quem só assina eventos, e em troca proibia o lumo_ui de
-- declarar a dependência real que tem daqui.
--
-- Publica: CREATION_RECORDED
-- Consome: STRUCTURE_DETECTED, PROJECT_COMPLETED

lumo.journal = {}

local MOD = core.get_current_modname()
local MAX_ENTRIES = 200   -- teto de segurança; ver prune()

-- Nomes iniciais. A criança pode trocar qualquer um.
local DEFAULT_TITLES = {
	house   = "Minha casa",
	bridge  = "Minha ponte",
	tower   = "Minha torre",
	garden  = "Meu jardim",
	project = "Meu projeto",
}

local function describe(kind, size)
	if kind == "house" then
		return ("%d blocos de espaço por dentro"):format(size or 0)
	elseif kind == "tower" then
		return ("%d blocos de altura"):format(size or 0)
	elseif kind == "bridge" then
		return ("%d blocos suspensos"):format(size or 0)
	elseif kind == "garden" then
		return ("%d flores por perto"):format(size or 0)
	end
	return nil
end

--- O Livro é serializado junto com o progresso do jogador, então algum teto
--- precisa existir. Mas o Livro é autoria da criança, e apagar uma criação que
--- ela batizou quebra a promessa de que nada se perde.
---
--- Então o corte só remove entradas que ela nunca tocou: sem nome próprio e
--- sem recado. Se ela batizou todas, o Livro cresce além do teto -- a promessa
--- vale mais que o limite.
local function prune(creations)
	if #creations <= MAX_ENTRIES then
		return
	end
	local i = 1
	while #creations > MAX_ENTRIES and i <= #creations do
		local c = creations[i]
		if not c.named and not c.note then
			table.remove(creations, i)
		else
			i = i + 1
		end
	end
end

-- ---------------------------------------------------------------------------
-- API
-- ---------------------------------------------------------------------------

function lumo.journal.list(name)
	local st = lumo.player.get(name)
	return st and st.creations or {}
end

function lumo.journal.count(name)
	return #lumo.journal.list(name)
end

--- Registra uma criação. Devolve a entrada, ou nil se foi ignorada.
function lumo.journal.record(name, entry)
	local st = lumo.player.get(name)
	if not st then
		return nil
	end

	-- Um id estável por criação. Sem ele, renomear usava a posição na lista --
	-- e se a lista mudasse entre a tela e o clique (uma criação nova, um corte),
	-- a criança batizava a entrada errada. Nome é autoria: tem de acertar.
	st.next_creation_id = (st.next_creation_id or 0) + 1

	local creation = {
		id = st.next_creation_id,
		kind = entry.kind or "project",
		title = entry.title or DEFAULT_TITLES[entry.kind] or "Minha criação",
		detail = entry.detail,
		at = os.time(),
		pos = entry.pos and { x = entry.pos.x, y = entry.pos.y, z = entry.pos.z } or nil,
		blocks = lumo.player.get_stat(name, "blocks_placed"),
		note = nil,
	}

	st.creations[#st.creations + 1] = creation
	prune(st.creations)

	lumo.events.emit("CREATION_RECORDED", {
		player = core.get_player_by_name(name),
		name = name,
		creation = creation,
	})
	return creation
end

--- Renomeia uma entrada. É o único ponto do jogo onde a criança escreve texto,
--- então o tamanho é limitado e quebras de linha somem.
--- A entrada com este id, ou nil.
function lumo.journal.by_id(name, id)
	for _, c in ipairs(lumo.journal.list(name)) do
		if c.id == id then
			return c
		end
	end
	return nil
end

function lumo.journal.rename(name, id, new_title)
	local entry = lumo.journal.by_id(name, id)
	if not entry or type(new_title) ~= "string" then
		return false
	end
	-- Corta primeiro, varre depois. O campo vem do cliente e pode ter
	-- centenas de KB (a engine só recusa o pacote perto de 640 KB); varrer
	-- tudo para então descartar é trabalho a mando de quem enviou.
	new_title = new_title:sub(1, 200):gsub("[%c]", " "):sub(1, 60):trim()
	if new_title == "" then
		return false
	end
	entry.title = new_title
	-- A partir daqui esta entrada é autoria dela, e o prune não pode tocá-la.
	entry.named = true
	return true
end

function lumo.journal.set_note(name, id, note)
	local entry = lumo.journal.by_id(name, id)
	if not entry or type(note) ~= "string" then
		return false
	end
	entry.note = note:sub(1, 400):gsub("[%c]", " "):sub(1, 140):trim()
	if entry.note == "" then
		entry.note = nil
	end
	return true
end

-- ---------------------------------------------------------------------------
-- Reação aos eventos
-- ---------------------------------------------------------------------------

-- Uma construção reconhecida entra no Livro uma vez por tipo. O
-- lumo_interactions já tem o seu próprio silêncio entre detecções; aqui a
-- regra é mais forte: não queremos vinte "Minha torre" porque a criança
-- continuou empilhando.
--
-- A checagem consulta o que está salvo, e não uma tabela em memória, porque
-- senão bastaria sair e voltar para a duplicata aparecer.
local function already_recorded(name, kind)
	for _, c in ipairs(lumo.journal.list(name)) do
		if c.kind == kind then
			return true
		end
	end
	return false
end

lumo.events.on("STRUCTURE_DETECTED", function(data)
	if already_recorded(data.name, data.kind) then
		return
	end
	lumo.journal.record(data.name, {
		kind = data.kind,
		detail = describe(data.kind, data.size),
		pos = data.pos,
	})
end, 80)

lumo.events.on("PROJECT_COMPLETED", function(data)
	local def = data.project
	lumo.journal.record(data.name, {
		kind = "project",
		title = def and def.title or nil,
		detail = def and def.done_text or nil,
		pos = data.player and data.player:get_pos() or nil,
	})
end, 80)

core.log("action", ("[%s] Livro das Criações pronto"):format(MOD))
