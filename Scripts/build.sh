#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="Ditado"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"

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

echo ""
echo "=== Build completo ==="
echo "App: $APP_BUNDLE"
echo ""
echo "Para executar:  open $APP_BUNDLE"
