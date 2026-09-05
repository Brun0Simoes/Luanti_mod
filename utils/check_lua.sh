#!/bin/bash
# Verifica a sintaxe de todo o Lua do jogo.
#
# O Luanti roda LuaJIT, que é compatível com Lua 5.1, então um `luac -p` de
# 5.1 é exatamente a checagem certa. O binário sai do próprio lib/lua da
# engine -- ver README de desenvolvimento.
set -u
GAME_DIR="$(cd "$(dirname "$0")/.." && pwd)"

for candidate in "$GAME_DIR/../../.tools/luac.exe" "$(command -v luac 2>/dev/null)" \
                 "$(command -v luac5.1 2>/dev/null)" "$(command -v luajit 2>/dev/null)"; do
	if [ -n "$candidate" ] && [ -x "$candidate" ]; then LUAC="$candidate"; break; fi
done

if [ -z "${LUAC:-}" ]; then
	echo "Nenhum luac/luajit encontrado. Compile o de lib/lua da engine ou instale um."
	exit 2
fi

fail=0
count=0
while IFS= read -r f; do
	count=$((count + 1))
	if ! out=$("$LUAC" -p "$f" 2>&1); then
		echo "FALHA $f"
		echo "      $out"
		fail=1
	fi
done < <(find "$GAME_DIR/mods" -name "*.lua" | sort)

echo "$count arquivos verificados com $(basename "$LUAC")"
[ $fail -eq 0 ] && echo "OK: sintaxe válida." || echo "Erros de sintaxe encontrados."
exit $fail
