# Lumo - Oficina dos Mundos

Um jogo de construção, descoberta e criatividade para a engine
[Luanti](https://www.luanti.org/). Sem inimigos, sem dano, sem objetivos
obrigatórios: o mundo simplesmente repara no que você constrói e reage.

## O que é

Lumo é um **fork do [Minetest Game](https://github.com/luanti-org/minetest_game)**,
usado como fundação técnica. O MTG fornece os blocos, o inventário, o
`player_api` e o resto da base de sandbox; o Lumo constrói por cima disso um
jogo próprio, nos mods com prefixo `lumo_`.

Base do fork: commit `c42e4d0` do `luanti-org/minetest_game` (2026-08-16).

O Minetest Game está oficialmente em *maintenance-only mode*, o que é
justamente o que queremos de uma fundação: ela não muda debaixo dos nossos pés.

## Arquitetura

Nada aqui exige modificar o C++ da engine. Todo o jogo é Lua.

Os sistemas do Lumo não observam o jogador diretamente. `lumo_core` mantém um
**event bus**: a engine avisa o `lumo_core`, que publica um evento, e cada
sistema interessado reage por conta própria.

    bloco colocado
          |
       lumo_core  (publica BLOCK_PLACED)
          |
      +---+---------------+------------------+
      |                   |                  |
    lumo_projects   lumo_discoveries   lumo_companion
    "isso ajuda      "isso ativa        "o Lumo deveria
     algum projeto?"  alguma            comentar?"
                      descoberta?"

Isso é o que evita que o jogo vire uma bola de código onde tudo consulta tudo.

| Módulo | Função | Estado |
|---|---|---|
| `lumo_core` | event bus e comunicação entre sistemas | implementado |
| `lumo_player` | progresso e preferências do jogador | implementado |
| `lumo_world` | regiões, Oficina, ilhas e locais especiais | implementado |
| `lumo_companion` | o personagem Lumo | diálogo e estados |
| `lumo_projects` | projetos de construção (sugestões, nunca obrigações) | implementado |
| `lumo_discoveries` | descobertas secretas | implementado |
| `lumo_blocks` | blocos e objetos próprios | implementado |
| `lumo_interactions` | coisas que reagem às construções | implementado |
| `lumo_automation` | robôs e máquinas programáveis | implementado |
| `lumo_ui` | HUD, inventário e menus | implementado |
| `lumo_accessibility` | opções sensoriais e de ritmo | implementado |
| `lumo_journal` | o Livro das Criações | implementado |
| `lumo_canvas` | desenha um PNG com blocos, pixel a pixel | implementado |

O Lumo do `lumo_companion` hoje conversa e muda de estado, mas ainda não tem
corpo: a entidade que anda pelo mundo depende de modelo e textura que ainda não
existem.

## Validando

Três checagens rodam em segundos e não precisam da engine compilada:

    python utils/check_mods.py       # dependências e as regras de first_mod/last_mod
    bash   utils/check_lua.sh        # sintaxe de todo o Lua
    lua    utils/test_events.lua     # comportamento do event bus
    lua    utils/test_png.lua        # decodificador de PNG
    lua    utils/test_paleta.lua     # paleta e casamento de cor

E uma quarta, que precisa da engine e é a única que responde "a engine aceita
este jogo?":

    bash utils/smoke_test.sh         # sobe um servidor headless e lê o log

Um `depends` satisfeito na ordem errada ou uma chamada de API que não existe
mais passa pelas três primeiras e só aparece nesta.

O `check_lua.sh` procura um `luac` de Lua 5.1 (a mesma linguagem do LuaJIT que
a engine usa). Dá para compilar um a partir de `lib/lua` da própria engine.

`test_events.lua` roda num interpretador Lua 5.1 comum, com um dublê mínimo de
`core`. Ele cobre justamente as garantias do núcleo que, quebradas, viram
sintoma confuso dentro do jogo: a ordem por prioridade, o desempate estável e o
isolamento de erro -- inclusive a exigência de que o log **nomeie** o mod que
falhou, sem o que o isolamento vira um bug mudo.

Cobre também `lumo.fs`, os ajudantes de formspec. Eles existem por causa de um
bug que passou despercebido porque **nada falhava**: a lista de um dropdown era
escapada depois de unida por vírgulas, e como o escape da engine converte
vírgula em `\,`, cada dropdown virava um item só. O menu de acessibilidade
inteiro ficou inerte, sem uma linha de log. A regra agora mora num lugar só, e
um dos testes prova que a ordem errada seria detectada.

### Ordem de carga

`game.conf` declara `first_mod = lumo_core`, e a engine impõe uma regra que
vale ter em mente ao editar os `mod.conf`: **o `lumo_core` não pode declarar
nenhuma dependência** (`src/content/mod_configuration.cpp:252`).

Houve também um `last_mod = lumo_journal`, removido: ele proibia o `lumo_ui` de
declarar a dependência real que tem do Livro, e não estava dando benefício
nenhum em troca -- ordem de carga não muda nada para quem só assina eventos.

### Ninguém se machuca

`minetest.conf` desliga dano, PvP, fogo e TNT, mas isso é só um *padrão*: quem
cria o mundo pode remarcar a caixa, e os mods do MTG que causam dano continuam
instalados. Por isso `lumo_core/hooks.lua` também zera qualquer perda de vida
em Lua. Num jogo para criança, essa garantia não deveria depender de um adulto
lembrar de deixar uma opção desmarcada.

## Convenções de código

- Use o namespace `core.*`. O `minetest.*` ainda funciona, mas é um alias
  depreciado (`builtin/init.lua:38` da engine).
- Um sistema novo assina eventos em vez de registrar seus próprios callbacks
  globais, sempre que possível.

## Licenciamento

Ver [LICENSE.txt](LICENSE.txt). O código herdado do Minetest Game é LGPL 2.1+ e
as mídias herdadas são CC BY-SA 3.0; essas licenças continuam valendo para todo
o material herdado.
