-- Lumo - Pixel art a partir de uma imagem.
--
-- A criança larga um PNG numa pasta, digita `/desenhar`, e o Lumo ergue a
-- imagem na frente dela, bloco por bloco, com a cor de cada pixel.
--
-- Três coisas que valem explicar, porque são decisões e não acidentes.
--
-- **Não existe upload de dentro do jogo.** A engine não oferece isso, e não há
-- contorno honesto. O arquivo vai para `<mundo>/lumo_imagens/`, que é o único
-- lugar onde um mod pode ler e escrever (src/script/cpp_api/s_security.cpp:932).
-- O comando sem argumento lista o que estiver lá, para ela não precisar
-- decorar nome de arquivo.
--
-- **A cor é exata, não estimada.** Os blocos da paleta são gerados por
-- `[colorize:` com hexadecimais que nós escolhemos, então sabemos a cor de cada
-- um com precisão -- sem decodificar textura, sem tabela mantida à mão que
-- envelhece. Acrescentar cores à paleta melhora o desenho sozinho.
--
-- **Este módulo não dispara BLOCK_PLACED por bloco.** Um desenho de 48×48 são
-- 2304 blocos; passá-los pela corrente de callbacks faria os detectores de
-- forma rodarem 2304 vezes, cada uma com o seu orçamento de leitura de nodes.
-- Seria minutos de servidor travado para reconhecer uma "torre" que é o braço
-- de um boneco. Em vez disso o módulo publica um único CANVAS_BUILT no fim, e
-- quem quiser reagir ao desenho reage a ele. É o mesmo event bus; o que muda é
-- a granularidade, e ela é escolhida.
--
-- Publica: CANVAS_BUILT
-- Consome: PLAYER_LEAVE

lumo.canvas = {}

local MOD = core.get_current_modname()

dofile(core.get_modpath(MOD) .. "/png.lua")

-- Limites. Um desenho grande é caro em nodes colocados e em tempo de servidor,
-- e uma criança vai tentar a maior imagem que encontrar.
local DEFAULT_WIDTH = 32
local MAX_WIDTH     = 96
local PER_STEP      = 24     -- blocos por passo, para dar de ver acontecendo
local STEP_DELAY    = 0.08
local MAX_DISTANCE  = 8      -- a que distância do jogador a tela é erguida
local ALPHA_CUTOFF  = 128    -- abaixo disso o pixel vira buraco, não bloco

local IMAGE_DIR = "lumo_imagens"

local building = {}   -- [nome] = true enquanto um desenho está sendo erguido

-- ---------------------------------------------------------------------------
-- Onde ficam as imagens
-- ---------------------------------------------------------------------------

local function image_dir()
	return core.get_worldpath() .. "/" .. IMAGE_DIR
end

--- Cria a pasta na primeira vez e deixa um bilhete explicando para que serve.
local function ensure_dir()
	local dir = image_dir()
	if core.mkdir then
		core.mkdir(dir)
	end
	local readme = dir .. "/LEIA-ME.txt"
	if not core.path_exists(readme) then
		local f = io.open(readme, "w")
		if f then
			f:write("Coloque aqui as imagens que o Lumo deve desenhar.\n\n")
			f:write("Precisa ser PNG, de no maximo 256x256 pixels, sem entrelacamento.\n")
			f:write("Dentro do jogo, digite /desenhar para ver a lista.\n")
			f:close()
		end
	end
	return dir
end

--- Os PNGs disponíveis, em ordem alfabética.
function lumo.canvas.list_images()
	local out = {}
	local entries = core.get_dir_list(image_dir(), false) or {}
	for _, entry in ipairs(entries) do
		if entry:lower():sub(-4) == ".png" then
			out[#out + 1] = entry
		end
	end
	table.sort(out)
	return out
end

-- ---------------------------------------------------------------------------
-- Casamento de cor
-- ---------------------------------------------------------------------------

--- Distância de cor "redmean".
---
--- Distância euclidiana crua em RGB erra feio onde o olho é exigente: ela troca
--- um tom de pele por um verde de brilho parecido. Esta aproximação pondera os
--- canais conforme o vermelho médio das duas cores e custa quase o mesmo -- é o
--- melhor negócio disponível sem converter tudo para um espaço perceptual.
local function color_distance(r1, g1, b1, r2, g2, b2)
	local rmean = (r1 + r2) * 0.5
	local dr, dg, db = r1 - r2, g1 - g2, b1 - b2
	return (2 + rmean / 256) * dr * dr
	     + 4 * dg * dg
	     + (2 + (255 - rmean) / 256) * db * db
end

--- O bloco da paleta mais próximo de uma cor. Devolve o nome do node.
function lumo.canvas.nearest_block(r, g, b)
	local palette = lumo.blocks.paint
	local best, best_d
	for i = 1, #palette do
		local p = palette[i]
		local d = color_distance(r, g, b, p.r, p.g, p.b)
		if not best_d or d < best_d then
			best, best_d = p.name, d
		end
	end
	return best
end

-- ---------------------------------------------------------------------------
-- Onde a tela é erguida
-- ---------------------------------------------------------------------------

--- Calcula a origem e os dois eixos da tela, a partir de onde o jogador olha.
--- A tela nasce em pé, de frente para ela, alguns blocos adiante.
local function canvas_frame(player)
	local pos = vector.round(player:get_pos())
	local look = player:get_look_horizontal()

	-- Arredonda a direção do olhar para a cardeal mais próxima: uma tela torta
	-- em relação à grade ficaria serrilhada.
	local dir, right
	local q = math.floor(((-look / (math.pi / 2)) % 4) + 0.5) % 4
	if q == 0 then
		dir, right = vector.new(0, 0, 1), vector.new(1, 0, 0)
	elseif q == 1 then
		dir, right = vector.new(1, 0, 0), vector.new(0, 0, -1)
	elseif q == 2 then
		dir, right = vector.new(0, 0, -1), vector.new(-1, 0, 0)
	else
		dir, right = vector.new(-1, 0, 0), vector.new(0, 0, 1)
	end

	local origin = vector.add(pos, vector.multiply(dir, MAX_DISTANCE))
	return origin, right, vector.new(0, 1, 0)
end

-- ---------------------------------------------------------------------------
-- Construção
-- ---------------------------------------------------------------------------

--- Reduz a imagem para a largura pedida, tirando a média de cada bloco de
--- pixels. Média e não amostragem: pegar um pixel só de cada região faz um
--- desenho cheio de ruído perder as formas.
local function sample(img, target_w, target_h)
	local sx = img.width / target_w
	local sy = img.height / target_h
	local grid = {}

	for ty = 0, target_h - 1 do
		local row = {}
		for tx = 0, target_w - 1 do
			local x0, x1 = math.floor(tx * sx), math.floor((tx + 1) * sx) - 1
			local y0, y1 = math.floor(ty * sy), math.floor((ty + 1) * sy) - 1
			if x1 < x0 then x1 = x0 end
			if y1 < y0 then y1 = y0 end

			local r, g, b, a, n = 0, 0, 0, 0, 0
			for y = y0, math.min(y1, img.height - 1) do
				for x = x0, math.min(x1, img.width - 1) do
					local pr, pg, pb, pa = img.get(x, y)
					r, g, b, a, n = r + pr, g + pg, b + pb, a + pa, n + 1
				end
			end
			if n > 0 then
				row[tx + 1] = { r / n, g / n, b / n, a / n }
			end
		end
		grid[ty + 1] = row
	end
	return grid
end

--- Ergue o desenho. `on_done` recebe a mensagem final.
function lumo.canvas.draw(name, filename, target_w, on_done)
	local player = core.get_player_by_name(name)
	if not player then
		return false
	end
	if building[name] then
		return false, "O Lumo ainda está desenhando a última imagem."
	end

	target_w = math.max(4, math.min(MAX_WIDTH, math.floor(tonumber(target_w) or DEFAULT_WIDTH)))

	-- O nome do arquivo vem da criança. Barra, contrabarra e ".." poderiam
	-- apontar para fora da pasta; a checagem da engine barraria, mas é melhor
	-- recusar aqui com uma frase que ela entenda.
	if filename:find("[/\\]") or filename:find("%.%.") then
		return false, "Use só o nome do arquivo, sem pastas."
	end

	local path = image_dir() .. "/" .. filename
	if not core.path_exists(path) then
		return false, ("Não achei %q na pasta das imagens."):format(filename)
	end

	local f = io.open(path, "rb")
	if not f then
		return false, "Não consegui abrir o arquivo."
	end
	local bytes = f:read("*a")
	f:close()

	local img, why = lumo.png.decode(bytes)
	if not img then
		return false, why
	end

	local target_h = math.max(1, math.floor(target_w * img.height / img.width + 0.5))
	local grid = sample(img, target_w, target_h)

	local origin, right, up = canvas_frame(player)
	-- Centraliza na horizontal e apoia a base na altura do jogador.
	local start = vector.subtract(origin, vector.multiply(right, math.floor(target_w / 2)))

	building[name] = true
	local placed, skipped = 0, 0
	local row, col = target_h, 1   -- de baixo para cima: o desenho se revela subindo

	local function finish(msg)
		building[name] = false
		if on_done then
			on_done(msg)
		end
	end

	local function step()
		if not building[name] then
			return
		end
		local budget = PER_STEP

		while budget > 0 do
			if row < 1 then
				lumo.events.emit("CANVAS_BUILT", {
					player = core.get_player_by_name(name),
					name = name,
					pos = origin,
					width = target_w,
					height = target_h,
					blocks = placed,
					filename = filename,
				})
				return finish(("Pronto! %d blocos, %d por %d.")
					:format(placed, target_w, target_h))
			end

			local px = grid[row] and grid[row][col]
			if px then
				local r, g, b, a = px[1], px[2], px[3], px[4]
				if a >= ALPHA_CUTOFF then
					-- A linha 1 da imagem é o topo, então invertemos para que o
					-- desenho não saia de cabeça para baixo.
					local offset = vector.add(
						vector.multiply(right, col - 1),
						vector.multiply(up, target_h - row))
					local p = vector.add(start, offset)

					if core.is_protected(p, name) then
						return finish("O Lumo não consegue desenhar aqui.")
					end
					local node = core.get_node_or_nil(p)
					local def = node and core.registered_nodes[node.name]
					if def and node.name ~= "ignore"
						and (def.buildable_to or node.name == "air") then
						core.set_node(p, { name = lumo.canvas.nearest_block(r, g, b) })
						placed = placed + 1
					else
						skipped = skipped + 1
					end
				end
			end

			col = col + 1
			if col > target_w then
				col = 1
				row = row - 1
			end
			budget = budget - 1
		end

		core.after(STEP_DELAY, step)
	end

	step()
	return true
end

function lumo.canvas.stop(name)
	building[name] = false
end

-- ---------------------------------------------------------------------------
-- Comando
-- ---------------------------------------------------------------------------

core.register_chatcommand("desenhar", {
	params = "[arquivo.png] [largura]",
	description = "O Lumo desenha uma imagem com blocos",
	func = function(name, param)
		if not lumo.player.get(name) then
			return false, "Seu progresso ainda não carregou. Tente de novo em um instante."
		end

		local file, width = param:match("^(%S+)%s+(%d+)$")
		if not file then
			file = param:match("^(%S+)$")
		end

		if not file or file == "" then
			local list = lumo.canvas.list_images()
			if #list == 0 then
				return true, ("Coloque um PNG em %s e digite /desenhar <arquivo>.")
					:format(image_dir())
			end
			return true, ("Imagens disponíveis: %s\nUse /desenhar <arquivo> [largura].")
				:format(table.concat(list, ", "))
		end

		local ok, why = lumo.canvas.draw(name, file, width, function(msg)
			core.chat_send_player(name, core.colorize("#7fd4ff", "Lumo: ") .. msg)
		end)
		if not ok then
			return false, why
		end
		return true, "O Lumo começou a desenhar."
	end,
})

lumo.events.on("PLAYER_LEAVE", function(data)
	building[data.name] = nil
end)

lumo.events.on("MODS_LOADED", function()
	ensure_dir()
end)

core.log("action", ("[%s] pronto; paleta com %d cores")
	:format(MOD, lumo.blocks.paint and #lumo.blocks.paint or 0))
