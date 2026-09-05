-- Ponte entre os callbacks globais da engine e o event bus.
--
-- Regra: tudo que é *acontecimento do mundo* -- alguém entrou, um bloco mudou,
-- o tempo passou -- entra no jogo por aqui e só por aqui. Um sistema novo
-- assina o evento correspondente em vez de registrar o seu próprio callback,
-- e é isso que mantém "quem reage a quê" legível num lugar só.
--
-- A regra não cobre plumbing de interface. Um formspec devolve campos para
-- quem o abriu, e transformar isso num evento global só acrescentaria
-- indireção: o lumo_ui trata os seus próprios campos.

-- ---------------------------------------------------------------------------
-- Política: aqui ninguém se machuca
-- ---------------------------------------------------------------------------
-- `enable_damage = false` no minetest.conf é apenas um *padrão*: quem cria o
-- mundo pode marcar a caixa, e os mods herdados do Minetest Game que causam
-- dano continuam instalados. Num jogo para criança, "ninguém se machuca" não
-- deveria depender de um adulto lembrar de deixar uma opção desmarcada.
--
-- Como modificador (segundo argumento `true`), o retorno substitui a variação
-- de vida (doc/lua_api.md:6658). Curar continua funcionando; ferir, não.
core.register_on_player_hpchange(function(_, hp_change)
	if hp_change > 0 then
		return hp_change
	end
	return 0
end, true)

core.register_on_joinplayer(function(player, last_login)
	lumo.events.emit("PLAYER_JOIN", {
		player = player,
		name = player:get_player_name(),
		last_login = last_login,
	})
end)

core.register_on_leaveplayer(function(player, timed_out)
	lumo.events.emit("PLAYER_LEAVE", {
		player = player,
		name = player:get_player_name(),
		timed_out = timed_out,
	})
end)

core.register_on_placenode(function(pos, newnode, placer, oldnode, itemstack, pointed_thing)
	-- `placer` pode ser nil ou uma entidade: nem todo bloco é colocado por gente.
	local name
	if placer and placer:is_player() then
		name = placer:get_player_name()
	end

	-- Cópias pelo mesmo motivo: o payload é compartilhado por todos os
	-- assinantes, e a engine reutiliza estas tabelas depois.
	lumo.events.emit("BLOCK_PLACED", {
		pos = vector.copy(pos),
		node = table.copy(newnode),
		oldnode = oldnode and table.copy(oldnode) or nil,
		player = placer,
		name = name,
	})

	-- Não retorne nada daqui. Retornar `true` faz a engine não consumir o item
	-- do inventário do jogador (doc/lua_api.md:6612) -- blocos infinitos por
	-- acidente.
end)

-- A documentação marca register_on_dignode como "not recommended", preferindo
-- on_destruct/after_dig_node na definição de cada node (doc/lua_api.md:6618).
-- Aqui a escolha é deliberada: queremos saber de *qualquer* bloco removido,
-- inclusive dos ~190 nodes herdados do Minetest Game (mais os que forem gerados
-- por variação, como escadas e lajes), e não vamos reescrever a
-- definição de cada um deles para conseguir isso.
core.register_on_dignode(function(pos, oldnode, digger)
	local name
	if digger and digger:is_player() then
		name = digger:get_player_name()
	end

	lumo.events.emit("BLOCK_REMOVED", {
		pos = vector.copy(pos),
		node = table.copy(oldnode),
		player = digger,
		name = name,
	})
end)

core.register_on_craft(function(itemstack, player, old_craft_grid, craft_inv)
	lumo.events.emit("ITEM_CRAFTED", {
		-- Uma cópia, e não o ItemStack vivo. O bus entrega o mesmo payload a
		-- todos os assinantes; um deles mexendo aqui mudaria o que a criança
		-- de fato recebe do craft.
		stack = ItemStack(itemstack),
		player = player,
		name = player and player:get_player_name() or nil,
	})

	-- Não retorne nada daqui. Um ItemStack retornado substituiria o resultado
	-- do craft (doc/lua_api.md:6758).
end)

-- Último momento em que dá para persistir estado. Os módulos que guardam
-- progresso assinam SHUTDOWN em vez de registrarem o seu próprio
-- core.register_on_shutdown.
core.register_on_shutdown(function()
	lumo.events.emit("SHUTDOWN", {})
end)

-- Todos os mods já se registraram. É o momento de montar o que depende do
-- jogo inteiro estar no ar -- colocar a Oficina, por exemplo.
core.register_on_mods_loaded(function()
	lumo.events.emit("MODS_LOADED", {})
end)
