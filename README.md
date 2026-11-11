<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Ícone do Fader">
</p>

<h1 align="center">Fader</h1>

<p align="center">Controle de volume por aplicativo na barra de menus do macOS.</p>

O Fader ajusta o volume (0% a 150%) e o mute de cada aplicativo em tempo real. Ele usa somente a API nativa Core Audio Process Tap (`AudioHardwareCreateProcessTap`): não instala driver virtual, não tem dependências externas e não abre nenhuma conexão de rede.

## Requisitos

* macOS 15.0 ou mais recente
* Mac com Apple Silicon (arm64)

## Instalação

1. Baixe o `Fader-1.0.0.dmg` na página de [Releases](../../releases).
2. Abra o DMG e arraste o `Fader.app` para a pasta Aplicativos.
3. O app é assinado localmente (ad hoc), sem notarização da Apple. Na primeira abertura o Gatekeeper bloqueia. Libere com:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Fader.app
   ```

4. Abra o Fader. Ele aparece só na barra de menus, sem ícone no Dock.
5. Ao mexer no primeiro slider, o macOS pede a permissão de captura de áudio do sistema. Aceite: sem ela o aplicativo controlado fica mudo.

## Uso

* Clique no ícone de sliders na barra de menus.
* O cabeçalho mostra o dispositivo de saída atual, o volume master e o mute master.
* Cada aplicativo com sessão de áudio aberta ganha uma linha com mute, slider e percentual. O ícone de onda indica quem está tocando agora.
* O slider vai até 150%. Há um encaixe com resposta tátil em 100%.
* "Resetar Todos" devolve todos os aplicativos para 100% e remove a interceptação.
* Volumes e mutes são lembrados por aplicativo entre execuções.
* "Iniciar no Login" registra o app como item de login.

## Como funciona

* Para cada aplicativo com volume diferente de 100% (ou mutado), o Fader cria um Process Tap privado com `muteBehavior = .mutedWhenTapped`, que silencia o fluxo original e entrega o áudio para o Fader.
* Um dispositivo agregado privado junta o tap com o dispositivo de saída padrão. Um `AudioDeviceIOProc` copia o áudio do tap para a saída aplicando o ganho.
* O callback de áudio não aloca memória, não usa locks e não toca em objetos Swift ou Objective C. Ganho e mute chegam por valores atômicos (`Synchronization.Atomic`).
* A curva de volume é quadrática até 100% e linear de 100% a 150%. Acima de 100% entra um soft clip com `tanhf`. O ganho é interpolado amostra a amostra para evitar estalos.
* Processos auxiliares (Chrome, Electron, WebKit) são agrupados no aplicativo pai, então cada app aparece uma única vez.
* Em 100% e sem mute não existe tap: o áudio do aplicativo passa intocado.

## Compilar

Precisa do Xcode instalado (Swift 6).

```bash
./build_app.sh      # gera build/Fader.app assinado ad hoc
./package_dmg.sh    # gera build/Fader-<versão>.dmg
swift test          # testes do processamento de áudio
./scripts/make_icon.sh   # regenera Resources/Fader.icns
```

## Limitações conhecidas

* O primeiro ajuste de um aplicativo leva de 1,5 a 2 segundos para fazer efeito, tempo que o macOS gasta inicializando o dispositivo agregado. O mesmo vale ao trocar o dispositivo de saída.
* Sem a permissão de captura de áudio, um aplicativo com volume alterado fica mudo. "Resetar Todos" desfaz.
* Aplicativos em 100% e sem mute não são interceptados.

## Diagnóstico

```bash
/usr/bin/log show --last 5m --predicate 'subsystem == "com.local.fader"'
```
