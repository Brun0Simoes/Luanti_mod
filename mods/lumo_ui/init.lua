-- Lumo - HUD, inventário e menus.
--
-- Duas regras de design mandam neste arquivo.
--
-- A primeira: o contador de descobertas só aparece depois da primeira. Mostrar
-- "0 / 12" na tela inicial transformaria curiosidade em lista de deveres.
--
-- A segunda: nada aqui bloqueia nada. Não existe aba trancada, item cinza ou
-- "desbloqueie para ver". A progressão do Lumo acrescenta coisas; ela nunca
-- tira a liberdade que a criança já tinha.
--
-- Publica: —
-- Consome: PLAYER_JOIN, PLAYER_LEAVE, DISCOVERY_FOUND, PROJECT_COMPLETED,
--          CREATION_RECORDED

lumo.ui = {}

local MOD = core.get_current_modname()
local FORM = "lumo:book"

local TABS = { "Projetos", "Descobertas", "Minhas Criações" }
local hud = {}       -- [nome] = id do elemento de HUD
local open_tab = {}  -- [nome] = índice da aba aberta
local selected = {}  -- [nome] = índice selecionado na lista de criações

local function esc(s)
	return core.formspec_escape(tostring(s or ""))
end

--- Índice de uma textlist, validado.
---
--- `core.explode_textlist_event` só faz `tonumber` no que veio depois dos dois
--- pontos (builtin/common/misc_helpers.lua), e o pacote de formspec é
--- inteiramente controlado pelo cliente. Um "CHG:0" forjado produzia índice 0,
--- `list[0]` era nil, e o erro subia por um caminho *sem* pcall
--- (builtin/common/register.lua chama os callbacks direto) até virar
--- `setAsyncFatalError` -- ou seja, um pacote derrubava o servidor.
---
--- Por isso nada que venha de uma textlist pode ser usado como índice sem
--- passar por aqui.
local function textlist_index(value, count)
	local ev = core.explode_textlist_event(value)
	if ev.type ~= "CHG" and ev.type ~= "DCL" then
		return nil
	end
	local i = tonumber(ev.index)
	if not i or i ~= math.floor(i) or i < 1 or i > count then
		return nil
	end
	return i
end

local function fmt_date(ts)
	if not ts then
		return ""
	end
	return os.date("%d/%m", ts)
end

-- ---------------------------------------------------------------------------
-- HUD
-- ---------------------------------------------------------------------------

local function hud_text(name)
	local found = lumo.discoveries.count(name)
	if found == 0 then
		return nil   -- ainda não há nada a contar, e é de propósito
	end
	return ("Descobertas: %d de %d"):format(found, lumo.discoveries.total())
end

local function refresh_hud(name)
	local player = core.get_player_by_name(name)
	if not player then
		return
	end
	local text = hud_text(name)

	if not text then
		if hud[name] then
			player:hud_remove(hud[name])
			hud[name] = nil
		end
		return
	end

	if hud[name] then
		player:hud_change(hud[name], "text", text)
	else
		hud[name] = player:hud_add({
			type = "text",
			position = {x = 1, y = 0},
			offset = {x = -12, y = 24},
			alignment = {x = -1, y = 0},
			-- Sem `scale`: a documentação diz explicitamente para não usar em
			-- elementos de texto, porque nunca funcionou (doc/lua_api.md,
			-- seção "text" do HUD).
			z_index = 100,
			text = text,
			number = 0xE8F4FF,
		})
	end
end

-- ---------------------------------------------------------------------------
-- Formspec
-- ---------------------------------------------------------------------------

local function page_projects(name)
	local rows = {}
	for _, item in ipairs(lumo.projects.list(name)) do
		local mark = item.status == "done" and "[feito]  "
			or (item.status == "started" and "[agora]  " or "         ")
		rows[#rows + 1] = esc(mark .. item.def.title)
	end
	if #rows == 0 then
		return "label[0.5,1.5;Nenhum projeto por enquanto.]"
	end
	return ("textlist[0.5,1.2;11,6.4;projects;%s;0;false]"):format(table.concat(rows, ","))
		.. "label[0.5,7.9;Projetos são convites. Nenhum deles expira, e nenhum pode ser perdido.]"
end

local function page_discoveries(name)
	local found = lumo.discoveries.list_found(name)
	if #found == 0 then
		return "label[0.5,1.5;Você ainda não encontrou nenhuma descoberta.]"
			.. "label[0.5,2.1;Elas não aparecem numa lista antes de acontecerem. Experimente coisas!]"
	end
	local rows = {}
	for _, item in ipairs(found) do
		rows[#rows + 1] = esc(("%s  %s   (%s)"):format(item.def.icon, item.def.title, fmt_date(item.at)))
	end
	-- As não encontradas não são listadas nem como "???": uma descoberta
	-- anunciada de antemão deixa de ser uma descoberta.
	return ("textlist[0.5,1.2;11,6.4;discoveries;%s;0;false]"):format(table.concat(rows, ","))
		.. ("label[0.5,7.9;%s de %s encontradas.]"):format(#found, lumo.discoveries.total())
end

local function page_journal(name)
	local list = lumo.journal.list(name)
	if #list == 0 then
		return "label[0.5,1.5;O Livro ainda está em branco.]"
			.. "label[0.5,2.1;Construa alguma coisa e ela aparece aqui.]"
	end

	local rows = {}
	for _, c in ipairs(list) do
		rows[#rows + 1] = esc(("%s   %s"):format(c.title, fmt_date(c.at)))
	end
	-- Encontra a linha correspondente ao id guardado. Se ele sumiu (ou nunca
	-- houve escolha), cai na primeira -- a renderização nunca indexa às cegas.
	local idx = 1
	for i, c in ipairs(list) do
		if c.id == selected[name] then
			idx = i
			break
		end
	end
	local cur = list[idx]

	local detail = {
		("label[6.8,1.6;%s]"):format(esc(cur.title)),
		("label[6.8,2.2;Criado em: %s]"):format(esc(fmt_date(cur.at))),
		("label[6.8,2.7;Blocos colocados até aqui: %s]"):format(esc(cur.blocks or 0)),
	}
	if cur.detail then
		detail[#detail + 1] = ("label[6.8,3.2;%s]"):format(esc(cur.detail))
	end
	if cur.note then
		detail[#detail + 1] = ("label[6.8,3.7;\"%s\"]"):format(esc(cur.note))
	end
	-- A criança batiza a própria criação. É o ponto do jogo em que ela escreve.
	detail[#detail + 1] = ("field[6.8,4.6;4.6,0.8;new_title;Dar outro nome;%s]"):format(esc(cur.title))
	detail[#detail + 1] = ("field[6.8,5.9;4.6,0.8;new_note;Escrever algo sobre ela;%s]"):format(esc(cur.note or ""))
	detail[#detail + 1] = "button[6.8,7.0;4.6,0.8;save_entry;Guardar]"

	return ("textlist[0.5,1.2;6,6.4;creations;%s;%d;false]"):format(table.concat(rows, ","), idx)
		.. table.concat(detail)
end

function lumo.ui.show(name, tab)
	open_tab[name] = tab or open_tab[name] or 1
	local idx = open_tab[name]

	local body
	if idx == 2 then
		body = page_discoveries(name)
	elseif idx == 3 then
		body = page_journal(name)
	else
		body = page_projects(name)
	end

	local fs = table.concat({
		"formspec_version[6]",
		"size[12,9]",
		("tabheader[0,0;11.9,0.8;tab;%s;%d;false;true]"):format(lumo.fs.list(TABS), idx),
		body,
	})
	core.show_formspec(name, FORM, fs)
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= FORM then
		return
	end
	local name = player:get_player_name()

	if fields.tab then
		-- Vem do cliente e acaba num "%d" na montagem do formspec. Um valor
		-- fracionário ou infinito ali é, no melhor caso, indefinido -- e um
		-- erro em receive_fields derruba o servidor.
		local tab = math.floor(tonumber(fields.tab) or 1)
		if tab ~= tab or tab < 1 or tab > #TABS then   -- tab ~= tab pega NaN
			tab = 1
		end
		lumo.ui.show(name, tab)
		return true
	end

	if fields.creations then
		local idx = textlist_index(fields.creations, lumo.journal.count(name))
		if idx then
			-- Guarda o id, não a linha: a lista pode mudar entre a escolha e o
			-- clique em Guardar, e é o id que identifica a criação.
			local entry = lumo.journal.list(name)[idx]
			selected[name] = entry and entry.id or nil
			lumo.ui.show(name, 3)
		end
		return true
	end

	if fields.save_entry then
		local id = selected[name]
		if lumo.journal.by_id(name, id) then
			if fields.new_title then
				lumo.journal.rename(name, id, fields.new_title)
			end
			if fields.new_note then
				lumo.journal.set_note(name, id, fields.new_note)
			end
		end
		lumo.ui.show(name, 3)
		return true
	end

	return true
end)

-- ---------------------------------------------------------------------------
-- Como abrir
-- ---------------------------------------------------------------------------

core.register_chatcommand("lumo", {
	description = "Abre o Livro das Criações, os projetos e as descobertas",
	func = function(name)
		if not lumo.player.get(name) then
			return false, "Seu progresso ainda não carregou. Tente de novo em um instante."
		end
		lumo.ui.show(name)
		return true
	end,
})

-- Uma aba no inventário, para não depender de a criança saber digitar comandos.
if core.global_exists("sfinv") then
	sfinv.register_page("lumo:book", {
		title = "Lumo",
		get = function(self, player, context)
			local name = player:get_player_name()
			local found = lumo.discoveries.count(name)
			local made = lumo.journal.count(name)
			local rows = {
				"label[0.2,0.2;O Livro das Criações]",
				("label[0.2,0.9;Coisas que você construiu: %d]"):format(made),
			}
			-- Mesma regra do HUD: nada de contador antes da primeira
			-- descoberta. Esta é a tela mais visível das três, porque não
			-- exige comando nenhum -- é justamente aqui que um "0 de 12"
			-- transformaria curiosidade em lista de deveres.
			if found > 0 then
				rows[#rows + 1] = ("label[0.2,1.4;Descobertas encontradas: %d]"):format(found)
			end
			rows[#rows + 1] = "button[0.2,2.1;3.5,0.8;open_book;Abrir o Livro]"
			return sfinv.make_formspec(player, context, table.concat(rows), false)
		end,
		on_player_receive_fields = function(self, player, context, fields)
			if fields.open_book then
				-- `core.close_formspec(name, "")` é o curinga que a
				-- documentação pede para usar só quando indispensável -- e aqui
				-- era redundante: mostrar o Livro já substitui o que estiver
				-- aberto.
				lumo.ui.show(player:get_player_name())
				return true
			end
		end,
	})
end

-- ---------------------------------------------------------------------------
-- Reação aos eventos
-- ---------------------------------------------------------------------------

-- Prioridade 95: o HUD é a última coisa a se atualizar, depois de o
-- lumo_discoveries e o lumo_journal já terem gravado o que aconteceu.
for _, ev in ipairs({"DISCOVERY_FOUND", "CREATION_RECORDED", "PROJECT_COMPLETED"}) do
	lumo.events.on(ev, function(data)
		refresh_hud(data.name)
	end, 95)
end

lumo.events.on("PLAYER_JOIN", function(data)
	-- O HUD não existe imediatamente ao conectar; um instante depois, sim.
	core.after(1.0, function()
		if core.get_player_by_name(data.name) then
			refresh_hud(data.name)
		end
	end)
end, 60)

lumo.events.on("PLAYER_LEAVE", function(data)
	hud[data.name] = nil
	open_tab[data.name] = nil
	selected[data.name] = nil
end)

core.log("action", ("[%s] interface pronta"):format(MOD))
