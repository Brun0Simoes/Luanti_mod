-- Testes do decodificador de PNG, fora da engine.
--
-- O único pedaço que a engine fornece é `core.decompress`, e aqui ele é
-- substituído pelos bytes já descomprimidos que o gerador do fixture guardou.
-- Assim o teste exercita exatamente o que é nosso: separar os pedaços do
-- arquivo, desfazer os cinco filtros de linha e ler os pixels.
--
-- O fixture (utils/fixtures/) é gerado por utils/gerar_fixture_png.py e usa um
-- filtro diferente em cada linha de propósito -- Paeth e Average são os que
-- silenciosamente devolvem imagem quase certa quando implementados errado.
--
-- Uso:  lua utils/test_png.lua

local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local fixtures = here .. "/fixtures"

local function read_file(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local data = f:read("*a")
	f:close()
	return data
end

local raw_expected = read_file(fixtures .. "/teste.raw")

core = {
	log = function() end,
	get_current_modname = function() return "test" end,
	-- Dublê: em jogo isto é zlib em C++. Aqui devolvemos o resultado conhecido,
	-- porque descomprimir não é o que estamos testando.
	decompress = function()
		return raw_expected
	end,
}

lumo = {}
dofile(here .. "/../mods/lumo_canvas/png.lua")

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

print("png:")

local bytes = read_file(fixtures .. "/teste.png")
if not bytes then
	print("  FALHA fixture ausente; rode utils/gerar_fixture_png.py")
	os.exit(1)
end

local img, err = lumo.png.decode(bytes)
check("decodifica o PNG de teste", img ~= nil, err)

if img then
	check("dimensões corretas", img.width == 9 and img.height == 7,
		("%dx%d"):format(img.width or 0, img.height or 0))

	-- Compara pixel a pixel com o que o gerador anotou.
	local wrong, total, first = 0, 0, nil
	for line in io.lines(fixtures .. "/teste.esperado.txt") do
		local x, y, r, g, b = line:match("^(%d+) (%d+) (%d+) (%d+) (%d+)$")
		if x then
			total = total + 1
			local gr, gg, gb = img.get(tonumber(x), tonumber(y))
			if gr ~= tonumber(r) or gg ~= tonumber(g) or gb ~= tonumber(b) then
				wrong = wrong + 1
				first = first or ("(%s,%s) esperado %s,%s,%s obtido %s,%s,%s")
					:format(x, y, r, g, b, gr, gg, gb)
			end
		end
	end
	check(("todos os %d pixels conferem (5 filtros)"):format(total),
		total > 0 and wrong == 0, first)
end

-- Recusas: cada uma tem de explicar o que fazer, não só falhar.
do
	local nope, why = lumo.png.decode("isto nao e um png")
	check("recusa arquivo que não é PNG", nope == nil and why ~= nil, why)
end

do
	local nope, why = lumo.png.decode(nil)
	check("recusa entrada nula sem estourar", nope == nil and why ~= nil)
end

do
	-- Cabeçalho válido, mas entrelaçado: tem de recusar em vez de entregar lixo.
	--
	-- O byte de entrelaçamento é o 13º dos dados do IHDR: 8 da assinatura + 4 do
	-- tamanho + 4 do tipo + 12 = posição 29. O CRC fica errado, e não faz mal --
	-- não o verificamos, e o que está sob teste é a recusa.
	local interlaced = bytes:sub(1, 28) .. string.char(1) .. bytes:sub(30)
	local nope, why = lumo.png.decode(interlaced)
	check("recusa PNG entrelaçado com instrução", nope == nil and why:find("ntrela") ~= nil, why)
end

do
	-- Truncado no meio dos dados.
	local nope, why = lumo.png.decode(bytes:sub(1, 40))
	check("recusa PNG truncado", nope == nil and why ~= nil, why)
end

print()
print(("%d passou, %d falhou"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
