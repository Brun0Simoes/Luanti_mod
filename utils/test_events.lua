-- Testes do lumo_core, fora da engine.
--
-- O núcleo é Lua puro e quase não toca no Luanti, então dá para exercitá-lo num
-- interpretador Lua 5.1 comum. Vale a pena porque as garantias dele -- ordem
-- por prioridade, isolamento de erro, montagem de formspec -- são exatamente o
-- tipo de coisa que, quebrada, não falha: só para de funcionar em silêncio.
--
-- Uso:  lua utils/test_events.lua

-- ---------------------------------------------------------------------------
-- Dublê mínimo da engine
-- ---------------------------------------------------------------------------

local logged = {}
local current_mod = "test"

-- Reprodução fiel de core.formspec_escape (builtin/common/misc_helpers.lua).
-- É justamente o fato de a vírgula ser escapada que causou o bug testado lá
-- embaixo, então o dublê precisa escapar vírgula de verdade.
local ESCAPES = {
	["\\"] = "\\\\",
	["["]  = "\\[",
	["]"]  = "\\]",
	[";"]  = "\\;",
	[","]  = "\\,",
	["$"]  = "\\$",
}

core = {
	log = function(level, msg)
		logged[#logged + 1] = { level = level, msg = msg }
	end,
	get_current_modname = function()
		return current_mod
	end,
	formspec_escape = function(text)
		return text and string.gsub(text, "[\\%[%];,$]", ESCAPES)
	end,
}

lumo = {}

local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
dofile(here .. "/../mods/lumo_core/formspec.lua")
dofile(here .. "/../mods/lumo_core/events.lua")

-- ---------------------------------------------------------------------------
-- Mini framework
-- ---------------------------------------------------------------------------

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

local function last_log_matching(needle)
	for i = #logged, 1, -1 do
		if logged[i].msg:find(needle, 1, true) then
			return logged[i]
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Event bus
-- ---------------------------------------------------------------------------

print("event bus:")

check("catálogo declara os eventos do núcleo",
	lumo.events._docs["BLOCK_PLACED"] ~= nil and lumo.events._docs["TICK"] ~= nil)

do
	lumo.events.declare("T_BASIC")
	local got
	lumo.events.on("T_BASIC", function(data) got = data.v end)
	lumo.events.emit("T_BASIC", { v = 42 })
	check("emit entrega os dados ao assinante", got == 42, tostring(got))
end

do
	lumo.events.declare("T_EMPTY")
	local ok = pcall(lumo.events.emit, "T_EMPTY", {})
	check("emit sem assinantes é inofensivo", ok)
end

do
	lumo.events.declare("T_ORDER")
	local seq = {}
	lumo.events.on("T_ORDER", function() seq[#seq + 1] = "c" end, 90)
	lumo.events.on("T_ORDER", function() seq[#seq + 1] = "a" end, 10)
	lumo.events.on("T_ORDER", function() seq[#seq + 1] = "b" end, 50)
	lumo.events.emit("T_ORDER", {})
	check("prioridade menor roda primeiro",
		table.concat(seq) == "abc", table.concat(seq))
end

do
	lumo.events.declare("T_STABLE")
	local seq = {}
	for i = 1, 5 do
		lumo.events.on("T_STABLE", function() seq[#seq + 1] = i end)
	end
	lumo.events.emit("T_STABLE", {})
	check("empate de prioridade mantém ordem de registro",
		table.concat(seq, ",") == "1,2,3,4,5", table.concat(seq, ","))
end

-- A garantia central: um assinante que falha não derruba os outros.
do
	lumo.events.declare("T_ISOLATION")
	local reached_after = false
	lumo.events.on("T_ISOLATION", function() error("bug proposital") end, 10)
	lumo.events.on("T_ISOLATION", function() reached_after = true end, 20)
	lumo.events.emit("T_ISOLATION", {})
	check("erro em um assinante não impede os seguintes", reached_after)
	check("a falha vai para o log como erro",
		last_log_matching("bug proposital") ~= nil)
end

-- Sem nomear o culpado, o isolamento vira um bug mudo.
do
	current_mod = "mod_culpado"
	lumo.events.declare("T_BLAME")
	lumo.events.on("T_BLAME", function() error("x") end)
	current_mod = "test"
	lumo.events.emit("T_BLAME", {})
	check("o log nomeia o mod que falhou", last_log_matching("mod_culpado") ~= nil)
end

do
	local before = #logged
	lumo.events.emit("T_NAO_EXISTE", {})
	local entry = last_log_matching("T_NAO_EXISTE")
	check("emitir evento não declarado gera aviso",
		entry ~= nil and entry.level == "warning" and #logged > before)
end

do
	lumo.events.on("T_TAMBEM_NAO_EXISTE", function() end)
	local entry = last_log_matching("T_TAMBEM_NAO_EXISTE")
	check("assinar evento não declarado gera aviso",
		entry ~= nil and entry.level == "warning")
end

do
	lumo.events.declare("T_DUP")
	lumo.events.declare("T_DUP")
	check("redeclarar um evento gera aviso", last_log_matching("T_DUP") ~= nil)
end

do
	check("on() recusa handler que não é função",
		not pcall(lumo.events.on, "T_BASIC", "isto não é função"))
	check("declare() recusa nome que não é string",
		not pcall(lumo.events.declare, 123))
end

do
	local out = lumo.events.dump()
	check("dump lista eventos e assinantes",
		type(out) == "string" and out:find("T_ORDER", 1, true) ~= nil)
end

-- ---------------------------------------------------------------------------
-- Ajudantes de formspec
-- ---------------------------------------------------------------------------
-- Este bloco existe por causa de um bug real. O menu inteiro de acessibilidade
-- ficou inerte porque a lista de um dropdown era escapada *depois* de unida por
-- vírgulas, e o escape da engine converte vírgula em barra-vírgula. Cada
-- dropdown virava um item único, o cliente devolvia a string inteira, ela não
-- casava com rótulo nenhum e nenhuma preferência podia ser alterada.
--
-- Nada falhava. Nada aparecia no log. Só não funcionava.

print()
print("formspec:")

do
	local built = lumo.fs.list({"bastante", "normal", "pouco"})
	check("lista de dropdown mantém os separadores",
		built == "bastante,normal,pouco", built)
end

do
	-- A ordem errada, para provar que este teste detectaria o bug original.
	local errado = core.formspec_escape(table.concat({"a", "b"}, ","))
	check("a ordem errada é de fato detectável", errado ~= "a,b", errado)
end

do
	-- Uma vírgula dentro de um item continua escapada, sem virar separador.
	local built = lumo.fs.list({"um", "dois, e meio", "tres"})
	local escaped = "dois" .. string.char(92) .. ", e meio"
	check("vírgula dentro de um item não vira separador",
		built:find(escaped, 1, true) ~= nil, built)
end

do
	check("lista vazia não explode", lumo.fs.list({}) == "")
	check("esc aceita nil", lumo.fs.esc(nil) == "")
	check("esc escapa colchete",
		lumo.fs.esc("a[b") == "a" .. string.char(92) .. "[b")
end

print()
print(("%d passou, %d falhou"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
