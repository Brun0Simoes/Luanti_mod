-- Ajudantes de formspec.
--
-- Existem por causa de um bug que passou despercebido porque o menu *parecia*
-- funcionar: o menu inteiro de acessibilidade ficou inerte por semanas de
-- código porque a lista de opções de um dropdown era montada assim:
--
--     esc(table.concat(labels, ","))
--
-- `core.formspec_escape` converte "," em "\," (builtin/common/misc_helpers.lua),
-- então isso escapava os próprios separadores. O dropdown virava um item único
-- "bastante,normal,pouco", o cliente devolvia essa string inteira, ela não
-- casava com rótulo nenhum, e nenhuma preferência podia ser alterada. Nada
-- falhava, nada aparecia no log: só não funcionava.
--
-- A ordem correta é escapar cada item e *depois* juntar. Como isso é fácil de
-- inverter e impossível de notar olhando a tela, a regra mora aqui, num lugar
-- só, com teste.

lumo.fs = {}

--- Escapa um valor para caber dentro de um campo de formspec.
function lumo.fs.esc(value)
	return core.formspec_escape(tostring(value == nil and "" or value))
end

--- Monta a lista separada por vírgulas de um dropdown ou textlist.
---
--- Escapa cada item individualmente e só então junta, para que as vírgulas
--- separadoras permaneçam separadoras.
function lumo.fs.list(items)
	local out = {}
	for i, item in ipairs(items) do
		out[i] = lumo.fs.esc(item)
	end
	return table.concat(out, ",")
end
