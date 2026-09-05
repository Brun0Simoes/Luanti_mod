-- Lumo - Opções sensoriais e de ritmo.
--
-- O menu "Meu jeito de jogar". A ideia por trás dele é que nem toda criança
-- quer o mesmo jogo: uma quer o Lumo conversando o tempo todo, outra quer
-- silêncio; uma acha a noite emocionante, outra acha assustadora. Nenhuma das
-- duas está errada, e nenhuma delas deveria ter que aguentar a preferência da
-- outra para poder jogar.
--
-- As opções ficam dentro do jogo, não numa tela de configurações da engine,
-- porque quem precisa delas é a criança e não o adulto que instalou o jogo.
--
-- Publica: —
-- Consome: PLAYER_JOIN, DISCOVERY_FOUND, STRUCTURE_DETECTED

lumo.accessibility = {}

local MOD = core.get_current_modname()
local FORM = "lumo:prefs"

-- Cada opção: a pergunta como a criança lê, e as escolhas possíveis.
local OPTIONS = {
	{
		key = "lumo_talk", label = "O Lumo fala",
		choices = {"muito", "normal", "pouco"},
		labels  = {"bastante", "normal", "pouco"},
	},
	{
		key = "hints", label = "Dicas",
		choices = {"on_request", "auto", "off"},
		labels  = {"quando eu pedir", "automáticas", "desligadas"},
	},
	{
		key = "particles", label = "Partículas",
		choices = {"normal", "reduzidas", "off"},
		labels  = {"normais", "reduzidas", "desligadas"},
	},
	{
		key = "night", label = "Noite",
		choices = {true, false},
		labels  = {"ligada", "desligada"},
	},
	{
		key = "weather", label = "Clima",
		choices = {true, false},
		labels  = {"ligado", "desligado"},
	},
	{
		key = "projects", label = "Projetos",
		choices = {true, false},
		labels  = {"ligados", "desligados"},
	},
	{
		key = "surprises", label = "Surpresas",
		choices = {"muitas", "normal", "poucas"},
		labels  = {"muitas", "normais", "poucas"},
	},
}

-- ---------------------------------------------------------------------------
-- Aplicação
-- ---------------------------------------------------------------------------
-- Algumas preferências são só um valor que outro módulo consulta (o
-- `lumo_talk` que o lumo_companion lê). Outras precisam mexer no jogador de
-- verdade -- estas ficam aqui.

--- Aplica ao jogador o que depende da engine.
function lumo.accessibility.apply(name)
	local player = core.get_player_by_name(name)
	if not player then
		return false
	end

	-- Noite desligada: o mundo continua tendo ciclo de dia, mas para esta
	-- criança a luz nunca cai. É por jogador, então não atrapalha ninguém
	-- que esteja jogando junto.
	if lumo.player.get_pref(name, "night") then
		player:override_day_night_ratio(nil)
	else
		player:override_day_night_ratio(0.95)
	end

	return true
end

-- ---------------------------------------------------------------------------
-- Clima
-- ---------------------------------------------------------------------------
-- O mod de clima do Minetest Game é por jogador: ele chama `weather.get(player)`
-- num ciclo e aplica o resultado só àquela pessoa. Isso permite honrar o
-- "Clima: desligado" de verdade, e não só guardar a preferência -- inclusive
-- com duas crianças no mesmo mundo, cada uma com o seu céu.
--
-- O envelope precisa acontecer depois de o mod weather definir a sua versão,
-- por isso o `optional_depends = weather` no mod.conf.

-- Também precisa de `lighting`: o mod de clima aplica nuvens e iluminação
-- separadamente, então devolver só nuvens deixaria a sombra da última
-- tempestade grudada na criança que acabou de pedir clima desligado.
local CALM_SKY = {
	clouds = {
		density = 0.25,
		thickness = 10,
		speed = { x = 0, z = 0 },   -- nuvens paradas: nada se mexe sozinho
	},
	lighting = {
		shadows = { intensity = 0.33 },
		bloom = { intensity = 0.05 },
		volumetric_light = { strength = 0.2 },
	},
}

if core.global_exists("weather") and type(weather.get) == "function" then
	local upstream_get = weather.get
	weather.get = function(player)
		-- A versão de cima tolera ser chamada sem jogador; a nossa também tem de.
		if not player or not player.get_player_name then
			return upstream_get(player)
		end
		local name = player:get_player_name()
		local params = upstream_get(player)
		-- Se a versão de cima não está mexendo em nuvens (mod desativado,
		-- mapgen v6 ou singlenode), não há clima para desligar -- e empurrar
		-- CALM_SKY aqui inverteria a opção: "desligado" mudaria o céu e
		-- "ligado" não mudaria nada.
		if not (params and params.clouds) then
			return params
		end
		if lumo.player.get(name) and not lumo.player.get_pref(name, "weather") then
			-- Cópia nova a cada chamada: a versão de cima devolve tabela
			-- fresca, e entregar a mesma por referência a todo mundo deixaria
			-- um consumidor distraído corromper o céu de todos.
			return table.copy(CALM_SKY)
		end
		return params
	end
end

--- O multiplicador de partículas que os outros módulos devem respeitar ao
--- decidir quantas emitir. Fica aqui para que a regra exista num lugar só.
function lumo.accessibility.particle_scale(name)
	local p = lumo.player.get_pref(name, "particles")
	if p == "off" then
		return 0
	elseif p == "reduzidas" then
		return 0.35
	end
	return 1
end

--- Idem para as descobertas: "surpresas: poucas" não deve desligá-las, só
--- espaçá-las. Consumido pelo lumo_discoveries via `threshold()`.
function lumo.accessibility.surprise_scale(name)
	local s = lumo.player.get_pref(name, "surprises")
	if s == "poucas" then
		return 0.5
	elseif s == "muitas" then
		return 1.5
	end
	return 1
end

--- Um pequeno brilho onde algo aconteceu. Existe para que "Partículas:
--- desligadas" seja uma opção com efeito, e não um botão decorativo: com a
--- escala em 0 esta função não emite nada.
function lumo.accessibility.sparkle(name, pos, amount)
	local scale = lumo.accessibility.particle_scale(name)
	if scale <= 0 or not pos then
		return false
	end
	core.add_particlespawner({
		amount = math.max(1, math.floor((amount or 24) * scale)),
		time = 1.2,
		minpos = vector.new(pos.x - 1.2, pos.y - 0.2, pos.z - 1.2),
		maxpos = vector.new(pos.x + 1.2, pos.y + 2.0, pos.z + 1.2),
		minvel = vector.new(-0.2, 0.6, -0.2),
		maxvel = vector.new(0.2, 1.4, 0.2),
		minexptime = 0.8,
		maxexptime = 1.6,
		minsize = 0.7,
		maxsize = 1.6,
		texture = "default_item_smoke.png^[colorize:#ffe9a8:160",
		playername = name,   -- só quem descobriu vê
	})
	return true
end

--- O Lumo deve dar um empurrãozinho não solicitado agora?
--- É o que a opção "Dicas" controla: "quando eu pedir" cala as automáticas,
--- "desligadas" cala todas.
function lumo.accessibility.hints_allowed(name, unsolicited)
	local h = lumo.player.get_pref(name, "hints")
	if h == "off" then
		return false
	end
	if unsolicited and h ~= "auto" then
		return false
	end
	return true
end

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------

local function esc(s)
	return core.formspec_escape(tostring(s))
end

function lumo.accessibility.show(name)
	local rows = { "formspec_version[6]", "size[9,10]",
		"label[0.5,0.6;Meu jeito de jogar]" }

	local y = 1.4
	for i, opt in ipairs(OPTIONS) do
		local current = lumo.player.get_pref(name, opt.key)
		local sel = 1
		for j, c in ipairs(opt.choices) do
			if c == current then
				sel = j
			end
		end
		-- Escapar CADA rótulo e só então juntar com vírgulas.
		--
		-- Ao contrário: `core.formspec_escape` converte "," em "\," (ver
		-- builtin/common/misc_helpers.lua), de modo que escapar a lista já
		-- unida destruía os próprios separadores. O dropdown virava um único
		-- item "bastante,normal,pouco", o cliente devolvia essa string inteira,
		-- ela não casava com rótulo nenhum, e *nenhuma* preferência do menu
		-- podia ser alterada -- o menu inteiro parecia funcionar e não fazia
		-- nada.
		rows[#rows + 1] = ("label[0.5,%f;%s]"):format(y, esc(opt.label))
		rows[#rows + 1] = ("dropdown[4.2,%f;4.3,0.7;opt_%d;%s;%d;false]")
			:format(y - 0.3, i, lumo.fs.list(opt.labels), sel)
		y = y + 1.1
	end

	rows[#rows + 1] = "button_exit[0.5,9.0;3.5,0.8;close;Pronto]"
	rows[#rows + 1] = "label[4.5,9.4;Dá para mudar isso quando quiser.]"
	core.show_formspec(name, FORM, table.concat(rows))
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= FORM then
		return
	end
	local name = player:get_player_name()
	local changed = false

	for i, opt in ipairs(OPTIONS) do
		local value = fields["opt_" .. i]
		if value then
			-- O dropdown devolve o rótulo que a criança leu; traduzimos de
			-- volta para o valor guardado.
			for j, label in ipairs(opt.labels) do
				if label == value then
					if lumo.player.get_pref(name, opt.key) ~= opt.choices[j] then
						lumo.player.set_pref(name, opt.key, opt.choices[j])
						changed = true
					end
					break
				end
			end
		end
	end

	if changed then
		lumo.accessibility.apply(name)
		lumo.player.save(name)
	end
	return true
end)

core.register_chatcommand("meujeito", {
	description = "Abre as opções de Meu jeito de jogar",
	func = function(name)
		if not lumo.player.get(name) then
			return false, "Seu progresso ainda não carregou. Tente de novo em um instante."
		end
		lumo.accessibility.show(name)
		return true
	end,
})

-- ---------------------------------------------------------------------------
-- Reação aos eventos
-- ---------------------------------------------------------------------------

-- O brilho de uma descoberta mora aqui, e não na interface, porque quem é dono
-- da opção "Partículas" deve ser dono do efeito que ela controla. Assim não
-- existe caminho pelo qual uma partícula escape da preferência da criança.
lumo.events.on("DISCOVERY_FOUND", function(data)
	local player = data.player or core.get_player_by_name(data.name)
	if player then
		lumo.accessibility.sparkle(data.name, player:get_pos(), 30)
	end
end, 96)

lumo.events.on("STRUCTURE_DETECTED", function(data)
	lumo.accessibility.sparkle(data.name, data.pos, 18)
end, 96)

-- Prioridade 50: o lumo_player (10) já carregou as preferências salvas.
lumo.events.on("PLAYER_JOIN", function(data)
	core.after(0.5, function()
		if core.get_player_by_name(data.name) then
			lumo.accessibility.apply(data.name)
		end
	end)
end, 50)

core.log("action", ("[%s] opções de acessibilidade prontas"):format(MOD))
