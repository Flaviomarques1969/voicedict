#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="Ditado"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
BUNDLE_ID="com.user.ditado"

echo "=== Building $APP_NAME ==="

cd "$PROJECT_DIR"

# 1. Build release binary
swift build -c release 2>&1

BINARY="$PROJECT_DIR/.build/release/$APP_NAME"
if [ ! -f "$BINARY" ]; then
    echo "ERRO: binário não encontrado em $BINARY"
    exit 1
fi

# 2. Assemble .app bundle
echo "=== Montando $APP_NAME.app ==="

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# 3. Ad-hoc code sign (required for Accessibility permission)
echo "=== Assinando (ad-hoc) ==="
codesign --force --sign - "$APP_BUNDLE"

# 4. Reabrir o ciclo de Acessibilidade automaticamente.
#    Toda vez que o binário é re-assinado, o cdhash muda e o macOS revoga
#    silenciosamente a permissão de Acessibilidade (a chave aparece ligada
#    mas o tap não recebe eventos). Removemos a entrada antiga via tccutil
#    e abrimos o painel pronto pra você arrastar o Ditado.app de volta.
echo ""
echo "=== Religando Acessibilidade ==="

# Mata o app rodando antes — TCC reset só faz efeito no próximo start
pkill -f "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
pkill -f "whisper-server.*--port 8178" 2>/dev/null || true
sleep 1

# Remove a entrada antiga em TCC (cdhash velho) — vai voltar limpa
tccutil reset Accessibility "$BUNDLE_ID" 2>&1 || true

# Abre o painel de Acessibilidade direto
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

# Sinaliza com som do sistema para chamar atenção
afplay /System/Library/Sounds/Glass.aiff 2>/dev/null &

cat <<EOF

╭───────────────────────────────────────────────────────╮
│  AÇÃO MANUAL (única coisa que tem que ser na mão):    │
│                                                       │
│  1. Arraste o Ditado.app para a lista de              │
│     Acessibilidade que acabou de abrir                │
│  2. Confirme que a chave está LIGADA                  │
│  3. Volte aqui — o app abre automaticamente           │
╰───────────────────────────────────────────────────────╯

App: $APP_BUNDLE

EOF

# Espera o usuário ligar e relança o app sozinho
read -r -p "Pressione Enter quando tiver ligado a permissão... " _
open "$APP_BUNDLE"

echo ""
echo "=== Build completo + Ditado relançado ==="
