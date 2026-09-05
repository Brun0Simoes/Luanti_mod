-- Pulso lento do jogo.
--
-- A engine chama globalstep a cada passo do servidor, tipicamente 10x por
-- segundo (doc/lua_api.md:6600). Isso é caro demais para o tipo de pergunta que
-- os sistemas do Lumo fazem ("essa construção já virou uma casa?"), que
-- acontece na escala de segundos. Então agregamos num pulso único de 1s e
-- publicamos como TICK.
--
-- Se algum sistema precisar de resolução maior, ele deve dizer por quê.

local INTERVAL = 1.0
local accumulated = 0

core.register_globalstep(function(dtime)
	accumulated = accumulated + dtime
	if accumulated < INTERVAL then
		return
	end

	local elapsed = accumulated
	accumulated = 0

	local players = core.get_connected_players()
	if #players == 0 then
		return
	end

	lumo.events.emit("TICK", {
		dtime = elapsed,
		players = players,
	})
end)
