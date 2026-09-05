-- Decodificador de PNG em Lua puro.
--
-- A engine sabe *escrever* PNG (`core.encode_png`) mas não sabe ler. O que ela
-- oferece, e que resolve o problema, é `core.decompress(dados, "deflate")` --
-- e o bloco IDAT de um PNG é exatamente deflate com envelope zlib. Feita a
-- descompressão em C++, o que sobra em Lua é barato: separar os pedaços do
-- arquivo e desfazer o filtro de cada linha.
--
-- Escopo deliberadamente estreito. Aceitamos profundidade de 8 bits, sem
-- entrelaçamento, nos tipos de cor que qualquer editor produz. O resto é
-- recusado com uma frase que diz o que fazer, em vez de meio decodificado.
--
-- JPEG está fora de questão: exigiria transformada discreta de cosseno e
-- decodificação de Huffman em Lua, para um ganho que um "salve como PNG"
-- entrega de graça.

lumo.png = {}

local SIGNATURE = "\137PNG\r\n\26\n"

-- Canais por tipo de cor (tabela 11.1 da especificação PNG).
local CHANNELS = {
	[0] = 1,   -- tons de cinza
	[2] = 3,   -- RGB
	[3] = 1,   -- indexado (usa a PLTE)
	[4] = 2,   -- cinza + alfa
	[6] = 4,   -- RGBA
}

-- Teto de trabalho. A remoção de filtro é um laço em Lua sobre cada byte de
-- cada linha, e ele roda dentro de um passo do servidor. Um PNG de 2000×2000
-- são dezesseis milhões de iterações -- o servidor congelaria. Recusar com uma
-- instrução clara é melhor do que travar o mundo da criança.
local MAX_PIXELS = 256 * 256

local function u32(s, i)
	local a, b, c, d = s:byte(i, i + 3)
	return ((a * 256 + b) * 256 + c) * 256 + d
end

--- Lê um PNG e devolve { width, height, get(x, y) -> r, g, b }.
--- Em caso de recusa devolve nil e uma frase explicando por quê.
function lumo.png.decode(bytes)
	if type(bytes) ~= "string" or #bytes < 8 or bytes:sub(1, 8) ~= SIGNATURE then
		return nil, "Esse arquivo não é um PNG."
	end

	local pos = 9
	local width, height, depth, ctype, interlace
	local idat, palette = {}, nil

	while pos + 7 <= #bytes do
		local length = u32(bytes, pos)
		local kind = bytes:sub(pos + 4, pos + 7)
		local data = bytes:sub(pos + 8, pos + 7 + length)
		pos = pos + 12 + length   -- tamanho + tipo + dados + CRC

		if kind == "IHDR" then
			width, height = u32(data, 1), u32(data, 5)
			depth, ctype = data:byte(9), data:byte(10)
			interlace = data:byte(13)
		elseif kind == "PLTE" then
			palette = data
		elseif kind == "IDAT" then
			idat[#idat + 1] = data
		elseif kind == "IEND" then
			break
		end
	end

	if not width or width == 0 or height == 0 then
		return nil, "PNG sem cabeçalho legível."
	end
	if depth ~= 8 then
		return nil, ("Este PNG tem %d bits por canal; só sei ler 8. Salve de novo como PNG de 8 bits.")
			:format(depth or 0)
	end
	if interlace ~= 0 then
		return nil, "Este PNG é entrelaçado. Salve de novo sem entrelaçamento (Interlace: none)."
	end
	local channels = CHANNELS[ctype]
	if not channels then
		return nil, ("Tipo de cor %s não suportado."):format(tostring(ctype))
	end
	if ctype == 3 and not palette then
		return nil, "PNG indexado sem tabela de cores."
	end
	if width * height > MAX_PIXELS then
		return nil, ("Imagem grande demais (%d×%d). Reduza para no máximo %d×%d pixels.")
			:format(width, height, 256, 256)
	end
	if #idat == 0 then
		return nil, "PNG sem dados de imagem."
	end

	local ok, raw = pcall(core.decompress, table.concat(idat), "deflate")
	if not ok or type(raw) ~= "string" then
		return nil, "Não consegui descomprimir a imagem."
	end

	-- ------------------------------------------------------------------
	-- Remoção de filtro
	-- ------------------------------------------------------------------
	-- Cada linha do PNG começa com um byte dizendo qual dos cinco filtros foi
	-- aplicado a ela. Todos se desfazem somando bytes já reconstruídos: `a` é o
	-- pixel à esquerda, `b` o de cima, `c` o da diagonal superior esquerda.

	local stride = width * channels
	if #raw < (stride + 1) * height then
		return nil, "Dados de imagem incompletos."
	end

	local rows = {}
	local prev = {}
	for i = 1, stride do
		prev[i] = 0
	end

	local p = 1
	local abs, floor = math.abs, math.floor

	for y = 1, height do
		local filter = raw:byte(p)
		p = p + 1
		local cur = {}

		for i = 1, stride do
			local x = raw:byte(p)
			p = p + 1
			local a = (i > channels) and cur[i - channels] or 0
			local b = prev[i]
			local v

			if filter == 0 then
				v = x
			elseif filter == 1 then
				v = (x + a) % 256
			elseif filter == 2 then
				v = (x + b) % 256
			elseif filter == 3 then
				v = (x + floor((a + b) / 2)) % 256
			elseif filter == 4 then
				-- Paeth: escolhe o vizinho que melhor prevê o valor.
				local c = (i > channels) and prev[i - channels] or 0
				local pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
				local pred
				if pa <= pb and pa <= pc then
					pred = a
				elseif pb <= pc then
					pred = b
				else
					pred = c
				end
				v = (x + pred) % 256
			else
				return nil, ("Filtro de linha desconhecido (%s)."):format(tostring(filter))
			end

			cur[i] = v
		end

		rows[y] = cur
		prev = cur
	end

	-- ------------------------------------------------------------------
	-- Leitura de pixel
	-- ------------------------------------------------------------------
	-- Devolve r, g, b e o alfa. Quem chama decide o que fazer com transparência
	-- -- aqui não inventamos um fundo.

	local get
	if ctype == 3 then
		get = function(x, y)
			local idx = rows[y + 1][x + 1]
			local o = idx * 3
			return palette:byte(o + 1) or 0, palette:byte(o + 2) or 0,
			       palette:byte(o + 3) or 0, 255
		end
	elseif ctype == 0 then
		get = function(x, y)
			local v = rows[y + 1][x + 1]
			return v, v, v, 255
		end
	elseif ctype == 4 then
		get = function(x, y)
			local row, i = rows[y + 1], x * 2 + 1
			local v = row[i]
			return v, v, v, row[i + 1]
		end
	elseif ctype == 2 then
		get = function(x, y)
			local row, i = rows[y + 1], x * 3 + 1
			return row[i], row[i + 1], row[i + 2], 255
		end
	else   -- 6, RGBA
		get = function(x, y)
			local row, i = rows[y + 1], x * 4 + 1
			return row[i], row[i + 1], row[i + 2], row[i + 3]
		end
	end

	return { width = width, height = height, get = get }
end
