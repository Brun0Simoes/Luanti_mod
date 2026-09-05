-- A paleta de tintas do Lumo.
--
-- Cem blocos de cor gerados por programa, sem um único arquivo de arte novo:
-- cada um é `wool_white.png` passado por `^[colorize:` com um hexadecimal que
-- nós escolhemos. A base é branca de propósito -- colorizar sobre madeira ou
-- pedra puxaria toda a paleta para o marrom ou o cinza.
--
-- Isso tem uma consequência que vale escrever: como somos nós que definimos o
-- hexadecimal, **a cor de cada bloco é conhecida com exatidão**. O
-- lumo_canvas não precisa adivinhar nem decodificar textura nenhuma para
-- casar um pixel com um bloco -- ele compara com o número que está aqui.
--
-- A paleta é organizada por matiz, luminosidade e saturação em vez de por
-- nomes bonitos, porque o que importa para desenhar é cobrir o espaço de cor
-- de maneira uniforme. Uma paleta de nomes ("vermelho", "azul") deixa buracos
-- justamente onde a pele, o céu e as sombras vivem.

local MOD = core.get_current_modname()

-- 12 matizes × 4 luminosidades × 3 saturações = 144, mais 12 cinzas.
--
-- Foram duas saturações a princípio, e o teste de cobertura reprovou: um
-- amarelo vivo (250,205,70) casava com um pêssego pálido, e a pior lacuna do
-- espaço de cor chegava a 61 unidades. O motivo era o vão entre uma saturação
-- baixa e uma altíssima, justamente onde mora a maior parte das cores reais --
-- pele, céu, folhagem. A terceira saturação fecha esse vão.
local HUES = {
	{   0, "Vermelha"  }, {  30, "Laranja"   }, {  60, "Amarela"  },
	{  90, "Lima"      }, { 120, "Verde"     }, { 150, "Esmeralda"},
	{ 180, "Ciano"     }, { 210, "Celeste"   }, { 240, "Azul"     },
	{ 270, "Violeta"   }, { 300, "Magenta"   }, { 330, "Rosa"     },
}
local VALUES = { {0.30, "Escura"}, {0.52, "Média"}, {0.74, "Clara"}, {0.93, "Bem clara"} }
local SATS   = { {0.35, "Suave"}, {0.68, "Média"}, {1.00, "Viva"} }

local GREYS = {
	{0.00, "Preta"}, {0.09, "Quase preta"}, {0.18, "Carvão"},
	{0.27, "Grafite"}, {0.36, "Chumbo"}, {0.45, "Cinza"},
	{0.55, "Cinza clara"}, {0.64, "Prata"}, {0.73, "Névoa"},
	{0.82, "Cinza pálida"}, {0.91, "Quase branca"}, {1.00, "Branca"},
}

--- HSV para RGB. h em graus, s e v em 0..1.
local function hsv_to_rgb(h, s, v)
	local c = v * s
	local x = c * (1 - math.abs(((h / 60) % 2) - 1))
	local m = v - c
	local r, g, b
	if     h <  60 then r, g, b = c, x, 0
	elseif h < 120 then r, g, b = x, c, 0
	elseif h < 180 then r, g, b = 0, c, x
	elseif h < 240 then r, g, b = 0, x, c
	elseif h < 300 then r, g, b = x, 0, c
	else                r, g, b = c, 0, x
	end
	return math.floor((r + m) * 255 + 0.5),
	       math.floor((g + m) * 255 + 0.5),
	       math.floor((b + m) * 255 + 0.5)
end

local function hex(r, g, b)
	return ("#%02x%02x%02x"):format(r, g, b)
end

--- Todas as tintas, na ordem de registro.
--- Cada entrada: { name = "lumo_blocks:tinta_NN", r =, g =, b = }
lumo.blocks.paint = {}

local n = 0

local function register_paint(r, g, b, description)
	n = n + 1
	local name = ("lumo_blocks:tinta_%03d"):format(n)

	core.register_node(name, {
		description = description,
		-- Proporção 255: a cor substitui a textura por completo, em vez de se
		-- misturar a ela.
		--
		-- Com uma proporção menor sobrava um resto da lã branca em toda a
		-- paleta, e como a base é branca isso clareava *tudo* -- um amarelo
		-- (250,205,70) chegava na tela como pêssego. Pior que feio: a cor
		-- exibida deixava de ser a cor que a paleta declara, e é justamente
		-- essa igualdade que faz o casamento do lumo_canvas valer alguma coisa.
		--
		-- O bloco fica liso. Para tinta é o que se espera, e para pixel art é o
		-- que se quer: o que a criança vê é a cor que estava na imagem dela.
		tiles = { ("wool_white.png^[colorize:%s:255"):format(hex(r, g, b)) },
		is_ground_content = false,
		groups = {
			snappy = 2, choppy = 2, oddly_breakable_by_hand = 3,
			flammable = 1, lumo_tinta = 1,
		},
		sounds = default.node_sound_defaults(),
	})

	lumo.blocks.paint[#lumo.blocks.paint + 1] = { name = name, r = r, g = g, b = b }
end

for _, hue in ipairs(HUES) do
	for _, val in ipairs(VALUES) do
		for _, sat in ipairs(SATS) do
			local r, g, b = hsv_to_rgb(hue[1], sat[1], val[1])
			register_paint(r, g, b, ("Tinta %s %s %s"):format(hue[2], val[2], sat[2]))
		end
	end
end

for _, grey in ipairs(GREYS) do
	local v = math.floor(grey[1] * 255 + 0.5)
	register_paint(v, v, v, ("Tinta %s"):format(grey[2]))
end

-- Uma receita só, genérica: lã branca mais qualquer corante devolve a tinta
-- mais próxima daquele corante. Cem receitas distintas seriam ilegíveis no
-- guia, e a criança não escolhe cor por receita -- escolhe olhando.
for _, row in ipairs(dye.dyes) do
	local dye_name = row[1]
	local target = lumo.blocks.HEX and lumo.blocks.HEX[dye_name]
	if target then
		local tr = tonumber(target:sub(2, 3), 16)
		local tg = tonumber(target:sub(4, 5), 16)
		local tb = tonumber(target:sub(6, 7), 16)
		local best, best_d
		for _, p in ipairs(lumo.blocks.paint) do
			local d = (p.r - tr) ^ 2 + (p.g - tg) ^ 2 + (p.b - tb) ^ 2
			if not best_d or d < best_d then
				best, best_d = p, d
			end
		end
		if best then
			core.register_craft({
				output = best.name .. " 8",
				recipe = {
					{"group:wool", "group:wool", "group:wool"},
					{"group:wool", "dye:" .. dye_name, "group:wool"},
					{"group:wool", "group:wool", "group:wool"},
				},
			})
		end
	end
end

core.log("action", ("[%s] paleta de %d tintas registrada"):format(MOD, #lumo.blocks.paint))
