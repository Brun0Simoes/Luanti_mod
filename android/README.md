# Gerando o APK do Lumo para Android

O APK oficial do Luanti sai **sem jogo nenhum**: quem instala escolhe um pelo
ContentDB dentro do app. Para um APK em que o Lumo já vem junto e jogável, o
empacotamento da engine precisa de duas mudanças — descritas aqui, e aplicáveis
pelo patch neste diretório.

As mudanças ficam na árvore da **engine** (`android/`), que não é este
repositório. Por isso elas moram aqui como patch: sem isso, a receita se perderia
na máquina de quem construiu.

## O que o build precisa

| | |
|---|---|
| JDK | 17 (é o que o CI do Luanti usa; o 21 também funciona) |
| Android SDK | `platforms;android-34` e `android-35`, `build-tools;35.0.0` |
| NDK | a versão fixada em `android/build.gradle` (`ext.ndk_version`) |
| CMake | `cmake;3.22.1` do próprio SDK |
| gettext | `msgfmt` no PATH — o build compila as traduções `.po` |

As bibliotecas nativas (SDL2, LuaJIT, freetype, curl, OpenSSL...) **não** são
compiladas: o Gradle baixa `deps-lite.zip` já pronto do repositório
`luanti-org/luanti_android_deps`. É o que torna este build viável sem montar um
cross-compile para ARM.

## As duas mudanças

Aplique com `git apply` a partir da raiz da engine:

    git apply games/lumo/android/empacotar-lumo.patch

**1. Incluir o jogo nos assets.** A tarefa `prepareAssets` de
`android/app/build.gradle` copia builtin, shaders, fontes, texturas e locales —
mas não `games/`. O patch acrescenta uma cópia de `games/lumo`, excluindo
`.git` (o histórico sozinho passa de dez megabytes) e `utils` (as ferramentas de
validação não servem para nada num telefone).

**2. Identidade própria.** O `applicationId` passa de `net.minetest.minetest`
para `org.lumo.oficina`, e o rótulo do app de "Luanti" para "Lumo". Sem isso,
instalar o Lumo substituiria um Luanti que a pessoa já tivesse no aparelho.

O ícone continua o do Luanti: não temos arte própria, e a
[política do projeto](../../../doc/developing/ai_policy.md) proíbe arte gerada
por máquina.

## Minificação: desligada, de propósito

O `build.gradle` do Luanti liga `minifyEnabled true` **apenas quando existe uma
keystore configurada** — e o projeto não tem nenhum `proguard-rules.pro`. Como o
CI do Luanti compila sem keystore, os APKs oficiais nunca são minificados: esse
caminho não é exercitado por ninguém.

Configurar a assinatura, que é obrigatória para o APK instalar, liga esse
caminho sem avisar. O resultado é um APK que instala, abre, descompacta os
assets — e morre ao entrar no jogo:

    Failed to register native method
    org.libsdl.app.SDLControllerManager.onNativeJoy(IIF)V

O código nativo registra métodos Java pelo nome, via `RegisterNatives`. O R8 não
enxerga essa ligação: para ele são métodos sem uso, e ele os renomeia.

O patch desliga a minificação. O APK é quase todo código nativo e assets, então
o R8 economizaria uns poucos quilobytes da camada Java — não vale trocar isso
por um caminho que ninguém testa. Para religá-la seria preciso um
`proguard-rules.pro` mantendo `org.libsdl.app.**`, `net.minetest.minetest.**` e
`-keepclasseswithmembernames` dos métodos nativos.

Vale registrar como isso apareceu: **todas as verificações estruturais
passavam**. Assinatura válida, pacote certo, 1583 arquivos do jogo dentro do
APK. Só rodar num emulador mostrou o problema.

## Assinatura

Um APK precisa ser assinado para instalar. Crie uma chave e aponte
`android/local.properties` para ela:

```bash
keytool -genkeypair -v -keystore /caminho/lumo.jks -alias lumo \
  -keyalg RSA -keysize 4096 -validity 10000
```

```properties
# android/local.properties  (ignorado pelo git — chave não se versiona)
sdk.dir=E:/android-sdk

keystore=E:/lumo-assinatura/lumo.jks
keystore.password=...
key=lumo
key.password=...
```

Barras normais de propósito: num arquivo `.properties` a contrabarra é caractere
de escape, e `E:\android-sdk` seria lido como `E:android-sdk`.

**Guarde essa chave.** O Android só aceita atualizar um app instalado se a nova
versão for assinada com a mesma chave. Perdida a chave, a única saída é
desinstalar e reinstalar — o que apaga os mundos e o progresso da criança.

## Construindo

    cd android
    ./gradlew assemblerelease

O repositório traz apenas o `gradlew` do Unix. No Windows, invoque o wrapper
direto pelo Java, que é o que o `gradlew.bat` faria:

    java -classpath gradle/wrapper/gradle-wrapper.jar \
      org.gradle.wrapper.GradleWrapperMain assemblerelease

Os APKs saem em `android/app/build/outputs/apk/release/`, um por arquitetura.
Para um aparelho moderno, o de `arm64-v8a`.
