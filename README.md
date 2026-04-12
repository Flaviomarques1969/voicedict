# VoiceDict

Ditado por voz para macOS com Whisper (offline, gratuito).

Segure **Left Shift + Left Control** para ditar. O texto é inserido onde o cursor estiver.

## Requisitos

- macOS 15+
- Apple Silicon (M1/M2/M3/M4)
- Xcode Command Line Tools (`xcode-select --install`)
- Homebrew (`https://brew.sh`)

## Instalação

```bash
git clone https://github.com/Flaviomarques1969/voicedict.git
cd voicedict
chmod +x Scripts/install.sh
./Scripts/install.sh
```

O script baixa e compila tudo automaticamente (~5 min na primeira vez).

## Permissões necessárias

Na primeira execução, habilite em **Configurações → Privacidade → Acessibilidade**.

## Como usar

1. O ícone de microfone aparece na barra de menus
2. Segure **Left Shift + Left Control** por ~200ms
3. Fale
4. Solte as teclas — o texto é inserido no cursor
