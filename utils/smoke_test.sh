#!/bin/bash
# Sobe o Lumo num servidor dedicado headless, deixa rodar alguns segundos e
# verifica o log.
#
# É o teste que as outras checagens não conseguem dar: `check_mods.py` valida o
# grafo de dependências e `check_lua.sh` valida a sintaxe, mas nenhum dos dois
# sabe se a engine de fato aceita o jogo. Só carregando é que se descobre um
# `depends` satisfeito na ordem errada ou uma chamada de API que não existe
# mais.
#
# Uso:  bash utils/smoke_test.sh [segundos]
set -u

SECONDS_TO_RUN="${1:-15}"
GAME_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$GAME_DIR/../.." && pwd)"
BIN="$ROOT/bin/luanti.exe"
WORLD="$ROOT/worlds/lumo_smoke"
LOG="$WORLD/smoke.log"

if [ ! -x "$BIN" ]; then
	echo "Binário não encontrado em $BIN -- compile a engine primeiro."
	exit 2
fi

# Mundo descartável, recriado a cada execução para que o teste não dependa do
# que ficou de uma rodada anterior.
rm -rf "$WORLD"
mkdir -p "$WORLD"
cat > "$WORLD/world.mt" <<CONF
gameid = lumo
world_name = lumo_smoke
backend = sqlite3
player_backend = sqlite3
auth_backend = sqlite3
# Sem isto a engine cai no backend de arquivos, que ela mesma marca como
# obsoleto. O lumo_world e o lumo_player usam mod storage, então o teste deve
# exercitar o mesmo backend que o jogo de verdade vai usar.
mod_storage_backend = sqlite3
CONF

echo "Subindo servidor por ${SECONDS_TO_RUN}s..."
"$BIN" --server --world "$WORLD" --logfile "$LOG" --info > "$WORLD/stdout.log" 2>&1 &
PID=$!

for _ in $(seq "$SECONDS_TO_RUN"); do
	sleep 1
	kill -0 "$PID" 2>/dev/null || break
done

if kill -0 "$PID" 2>/dev/null; then
	kill "$PID" 2>/dev/null
	sleep 2
	kill -9 "$PID" 2>/dev/null
	CRASHED=0
else
	# Morreu sozinho antes da hora: isso é falha, não sucesso.
	CRASHED=1
fi

if [ ! -f "$LOG" ]; then
	echo "FALHA: nenhum log foi gerado."
	cat "$WORLD/stdout.log" 2>/dev/null | tail -20
	exit 1
fi

fail=0

if [ "$CRASHED" = "1" ]; then
	echo "FALHA: o servidor encerrou sozinho antes do tempo."
	fail=1
fi

# Os mods do Lumo anunciam-se ao carregar; a ausência de um deles é sintoma.
for marker in "lumo_core] event bus pronto" "lumo_companion] Lumo acordou" "lumo_projects]"; do
	if grep -qF "$marker" "$LOG"; then
		echo "  ok    $marker"
	else
		echo "  FALHA marcador ausente: $marker"
		fail=1
	fi
done

# Erros de Lua e de carga de mod.
if grep -qEi "ModError|Lua: |attempt to (call|index)|stack traceback" "$LOG"; then
	echo "  FALHA erros de Lua no log:"
	grep -Ei "ModError|Lua: |attempt to (call|index)" "$LOG" | head -10 | sed 's/^/        /'
	fail=1
else
	echo "  ok    nenhum erro de Lua"
fi

# Avisos do nosso próprio event bus: evento não declarado, assinante quebrado.
if grep -qF "[lumo_core]" "$LOG" && grep -F "[lumo_core]" "$LOG" | grep -qiE "não declarado|falhou"; then
	echo "  AVISO o event bus reclamou:"
	grep -F "[lumo_core]" "$LOG" | grep -iE "não declarado|falhou" | head -5 | sed 's/^/        /'
	fail=1
else
	echo "  ok    event bus sem reclamações"
fi

echo
if [ $fail -eq 0 ]; then
	echo "OK: o Lumo carregou."
else
	echo "Falhas encontradas. Log completo: $LOG"
fi
exit $fail
