-- Lumo - núcleo.
--
-- Este mod é o `first_mod` declarado em game.conf: carrega antes de todos os
-- outros, inclusive antes do `default`. Em troca, a engine proíbe que ele tenha
-- qualquer dependência. Por isso o núcleo é Lua puro e não registra nenhum
-- node, item ou entidade.

lumo = {}
lumo.modpath = core.get_modpath(core.get_current_modname())

dofile(lumo.modpath .. "/formspec.lua")
dofile(lumo.modpath .. "/events.lua")
dofile(lumo.modpath .. "/hooks.lua")
dofile(lumo.modpath .. "/tick.lua")

core.log("action", "[lumo_core] event bus pronto")
