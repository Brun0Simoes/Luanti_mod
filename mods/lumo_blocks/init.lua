-- Lumo - Blocos e objetos próprios.
--
-- Nenhum destes blocos traz textura nova. Eles são gerados a partir das
-- texturas do Minetest Game com modificadores da própria engine
-- (`^[colorize:`), o que significa zero arquivo de arte novo para manter e
-- zero risco de licença mal atribuída.
--
-- Isso também é uma decisão de projeto, não só de conveniência: a política do
-- Luanti proíbe arte gerada por máquina no engine, e o Lumo não vai começar a
-- vida com um passivo de mídia de origem duvidosa. Quando houver arte de
-- verdade, feita por uma pessoa, ela substitui isto aqui.
--
-- As cores seguem exatamente a paleta de `dye.dyes` do MTG, para que os blocos
-- do Lumo combinem com a lã, os corantes e tudo mais que já existe.
--
-- Publica: —
-- Consome: —

-- Os nodes usam o prefixo `lumo_blocks:` e não `lumo:` porque a engine exige
-- que todo item registrado carregue o nome do mod que o registrou
-- (builtin/game/register.lua:67). Existe um escape com `:` na frente, mas ele
-- é para casos de compatibilidade, não para deixar o nome mais bonito.
lumo.blocks = {}

local MOD = core.get_current_modname()

-- Os nomes vêm de dye.dyes; os valores hexadecimais são nossos, escolhidos
-- para casar visualmente com as texturas de lã correspondentes.
-- Exposto porque a paleta (paleta.lua) precisa destes valores para escolher a
-- tinta mais próxima de cada corante ao montar as receitas.
lumo.blocks.HEX = {
	white      = "#ffffff",
	grey       = "#9a9a9a",
	dark_grey  = "#5a5a5a",
	black      = "#2b2b2b",
	violet     = "#7f3ecb",
	blue       = "#3a53c8",
	cyan       = "#22b7c4",
	dark_green = "#2f7a2f",
	green      = "#5ec44a",
	yellow     = "#e8d442",
	brown      = "#7a4a24",
	orange     = "#e2861f",
	red        = "#cc2f2f",
	magenta    = "#c53fa6",
	pink       = "#f09ec0",
}

local PT = {
	white = "Branco", grey = "Cinza", dark_grey = "Cinza-escuro", black = "Preto",
	violet = "Violeta", blue = "Azul", cyan = "Ciano", dark_green = "Verde-escuro",
	green = "Verde", yellow = "Amarelo", brown = "Marrom", orange = "Laranja",
	red = "Vermelho", magenta = "Magenta", pink = "Rosa",
}

lumo.blocks.colors = {}

for _, row in ipairs(dye.dyes) do
	local name = row[1]
	local hex = lumo.blocks.HEX[name]
	local pt = PT[name] or name

	if not hex then
		-- Uma cor nova no MTG que ainda não mapeamos: melhor avisar do que
		-- gerar um bloco com textura quebrada em silêncio.
		core.log("warning", ("[%s] cor %q de dye.dyes sem hexadecimal mapeado; pulando")
			:format(MOD, name))
	else
		lumo.blocks.colors[#lumo.blocks.colors + 1] = name

		-- Tábua pintada: o bloco de construção do dia a dia.
		core.register_node("lumo_blocks:plank_" .. name, {
			description = "Tábua " .. pt,
			tiles = { ("default_wood.png^[colorize:%s:150"):format(hex) },
			is_ground_content = false,
			groups = {
				choppy = 2, oddly_breakable_by_hand = 2, flammable = 2,
				lumo_plank = 1, ["color_" .. name] = 1,
			},
			sounds = default.node_sound_wood_defaults(),
		})

		core.register_craft({
			output = "lumo_blocks:plank_" .. name .. " 4",
			recipe = {
				{"group:wood", "group:wood"},
				{"group:wood", "dye:" .. name},
			},
		})

		-- Luminária: a criança consegue iluminar sem depender de tocha, que
		-- some na chuva e não combina com decoração.
		core.register_node("lumo_blocks:lamp_" .. name, {
			description = "Luminária " .. pt,
			drawtype = "glasslike",
			tiles = { ("default_glass.png^[colorize:%s:120"):format(hex) },
			paramtype = "light",
			light_source = 12,
			sunlight_propagates = true,
			is_ground_content = false,
			groups = {
				cracky = 3, oddly_breakable_by_hand = 3,
				lumo_lamp = 1, ["color_" .. name] = 1,
			},
			sounds = default.node_sound_glass_defaults(),
		})

		core.register_craft({
			output = "lumo_blocks:lamp_" .. name,
			-- `default:glass` explícito, e não `group:glass`: esse grupo não
			-- existe no Minetest Game (default/nodes.lua registra o vidro sem
			-- ele). Uma receita com grupo inexistente registra sem erro e
			-- simplesmente nunca casa -- as quinze luminárias e a nuvem eram
			-- incraftáveis em silêncio.
			recipe = {
				{"", "default:glass", ""},
				{"default:glass", "dye:" .. name, "default:glass"},
				{"", "default:torch", ""},
			},
		})
	end
end

-- Bloco de nuvem: macio de aparência, para quem constrói lá em cima.
core.register_node("lumo_blocks:cloud", {
	description = "Bloco de Nuvem",
	drawtype = "glasslike",
	tiles = { "default_glass.png^[colorize:#eaf4ff:200" },
	paramtype = "light",
	sunlight_propagates = true,
	is_ground_content = false,
	groups = { snappy = 3, oddly_breakable_by_hand = 3, lumo_cloud = 1 },
	sounds = default.node_sound_defaults(),
})

core.register_craft({
	output = "lumo_blocks:cloud 4",
	recipe = {
		{"default:glass", "dye:white"},
		{"dye:white", "default:glass"},
	},
})

core.log("action", ("[%s] %d cores registradas (%d nodes)")
	:format(MOD, #lumo.blocks.colors, #lumo.blocks.colors * 2 + 1))

-- A paleta de cem tintas vive num arquivo à parte: ela é gerada por programa e
-- não tem nada a ver com os blocos escolhidos à mão aqui de cima.
dofile(core.get_modpath(MOD) .. "/paleta.lua")
