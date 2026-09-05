-- Testes da paleta e do casamento de cor, fora da engine.
--
-- A paleta é gerada por programa e o casamento é puramente aritmético, então
-- os dois rodam num Lua comum com `core.register_node` substituído por um
-- dublê. Vale testar porque um erro aqui não quebra nada: só produz um desenho
-- com as cores erradas, e "erradas" é difícil de julgar olhando de longe uma
-- parede de blocos atrás de uma árvore.
--
-- Uso:  lua utils/test_paleta.lua

local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."

local registered = {}

core = {
	log = function() end,
	get_current_modname = function() return "lumo_blocks" end,
	get_modpath = function() return here .. "/../mods/lumo_blocks" end,
	register_node = function(name, def) registered[name] = def end,
	register_craft = function() end,
}

lumo = { blocks = {} }
-- `dye.dyes` é do Minetest Game; aqui só precisamos dos nomes.
dye = { dyes = { {"white"}, {"red"}, {"blue"} } }
default = { node_sound_defaults = function() return {} end }
lumo.blocks.HEX = { white = "#ffffff", red = "#cc2f2f", blue = "#3a53c8" }

dofile(here .. "/../mods/lumo_blocks/paleta.lua")

-- O casamento de cor vive no lumo_canvas; carregamos só a função.
local function color_distance(r1, g1, b1, r2, g2, b2)
	local rmean = (r1 + r2) * 0.5
	local dr, dg, db = r1 - r2, g1 - g2, b1 - b2
	return (2 + rmean / 256) * dr * dr + 4 * dg * dg + (2 + (255 - rmean) / 256) * db * db
end

local function nearest(r, g, b)
	local best, best_d
	for _, p in ipairs(lumo.blocks.paint) do
		local d = color_distance(r, g, b, p.r, p.g, p.b)
		if not best_d or d < best_d then
			best, best_d = p, d
		end
	end
	return best
end

local passed, failed = 0, 0
local function check(name, ok, detail)
	if ok then
		passed = passed + 1
		print(("  ok    %s"):format(name))
	else
		failed = failed + 1
		print(("  FALHA %s%s"):format(name, detail and ("  -- " .. detail) or ""))
	end
end

local function describe(p)
	return ("%s rgb(%d,%d,%d)"):format(p.name, p.r, p.g, p.b)
end

print("paleta:")

-- 12 matizes × 4 luminosidades × 3 saturações + 12 cinzas.
check("registrou 156 tintas", #lumo.blocks.paint == 156, tostring(#lumo.blocks.paint))
check("todas viraram node de verdade", (function()
	for _, p in ipairs(lumo.blocks.paint) do
		if not registered[p.name] then return false end
	end
	return true
end)())

-- A textura precisa carregar o hexadecimal exato da entrada da paleta, senão o
-- bloco colocado não é da cor que o casamento escolheu.
do
	local p = lumo.blocks.paint[1]
	local expected = ("#%02x%02x%02x"):format(p.r, p.g, p.b)
	local tile = registered[p.name].tiles[1]
	check("a textura usa o hexadecimal da paleta",
		tile:find(expected, 1, true) ~= nil, tile)
end

print()
print("casamento de cor:")

-- Cada caso: cor de entrada, e em que faixa o resultado tem de cair.
-- Testamos o *comportamento* ("amarelo vai para um bloco amarelo"), não o nome
-- exato do node -- este pode mudar se a paleta crescer.
local function dominant(p)
	if p.r > p.g and p.r > p.b then return "r" end
	if p.g > p.r and p.g > p.b then return "g" end
	if p.b > p.r and p.b > p.g then return "b" end
	return "="
end

local cases = {
	{ "amarelo vivo",   250, 205,  70, function(p) return p.r > 180 and p.g > 140 and p.b < 130 end },
	{ "vermelho",       200,  40,  60, function(p) return dominant(p) == "r" and p.g < 110 end },
	{ "azul céu",        90, 160, 235, function(p) return dominant(p) == "b" end },
	{ "verde folha",     60, 140,  60, function(p) return dominant(p) == "g" end },
	{ "quase preto",     30,  30,  40, function(p) return p.r < 70 and p.g < 70 and p.b < 80 end },
	{ "branco",         250, 250, 250, function(p) return p.r > 200 and p.g > 200 and p.b > 200 end },
	{ "cinza médio",    128, 128, 128, function(p) return math.abs(p.r - p.g) < 30 and math.abs(p.g - p.b) < 30 end },
	{ "pele clara",     240, 200, 170, function(p) return p.r >= p.g and p.g >= p.b end },
	{ "magenta",        200,  40, 190, function(p) return p.r > 120 and p.b > 120 and p.g < 120 end },
}

for _, c in ipairs(cases) do
	local p = nearest(c[2], c[3], c[4])
	check(("%s -> cor plausível"):format(c[1]), p and c[5](p), p and describe(p) or "nil")
end

-- Uma cor que já está na paleta tem de voltar exatamente ela mesma.
do
	local target = lumo.blocks.paint[40]
	local p = nearest(target.r, target.g, target.b)
	check("cor exata da paleta volta ela mesma", p.name == target.name,
		("%s vs %s"):format(p.name, target.name))
end

-- E a paleta precisa cobrir o espaço: nenhuma cor razoável pode ficar muito
-- longe do bloco mais próximo, senão o desenho sai chapado.
do
	local worst, worst_at = 0, nil
	for r = 0, 255, 51 do
		for g = 0, 255, 51 do
			for b = 0, 255, 51 do
				local p = nearest(r, g, b)
				local d = math.sqrt((p.r - r) ^ 2 + (p.g - g) ^ 2 + (p.b - b) ^ 2)
				if d > worst then
					worst, worst_at = d, ("rgb(%d,%d,%d) -> %s"):format(r, g, b, describe(p))
				end
			end
		end
	end
	print(("  info  pior distância de cobertura: %.1f  (%s)"):format(worst, worst_at))
	check("cobertura sem buraco grande", worst < 60, ("%.1f"):format(worst))
end

print()
print(("%d passou, %d falhou"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
