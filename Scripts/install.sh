#!/bin/bash
set -euo pipefail

echo "╔══════════════════════════════════════════════╗"
echo "║         Ditado — Instalador                   ║"
echo "║   Ditado por voz com Whisper (offline)        ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# 1. Check dependencies
echo "▸ Verificando dependências..."

if ! command -v swift &>/dev/null; then
    echo "❌ Swift não encontrado. Instale Xcode Command Line Tools:"
    echo "   xcode-select --install"
    exit 1
fi

if ! command -v cmake &>/dev/null; then
    echo "▸ Instalando cmake via Homebrew..."
    if ! command -v brew &>/dev/null; then
        echo "❌ Homebrew não encontrado. Instale em https://brew.sh"
        exit 1
    fi
    brew install cmake
fi

echo "  ✓ Swift $(swift --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
echo "  ✓ cmake $(cmake --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"

# 2. Clone and build whisper.cpp
if [ ! -f "vendor/whisper.cpp/build/bin/whisper-cli" ]; then
    echo ""
    echo "▸ Baixando whisper.cpp..."
    mkdir -p vendor
    if [ ! -d "vendor/whisper.cpp" ]; then
        git clone --depth 1 https://github.com/ggerganov/whisper.cpp.git vendor/whisper.cpp
    fi

    echo "▸ Compilando whisper.cpp com Metal (Apple Silicon)..."
    cd vendor/whisper.cpp
    cmake -B build -DWHISPER_METAL=ON -DCMAKE_BUILD_TYPE=Release 2>&1 | tail -2
    cmake --build build --config Release -j$(sysctl -n hw.ncpu) 2>&1 | tail -2
    cd "$PROJECT_DIR"
    echo "  ✓ whisper.cpp compilado"
else
    echo "  ✓ whisper.cpp já compilado"
fi

# 3. Download Whisper model
if [ ! -f "vendor/whisper.cpp/models/ggml-medium.bin" ]; then
    echo ""
    echo "▸ Baixando modelo Whisper medium (~1.5GB)..."
    cd vendor/whisper.cpp
    bash models/download-ggml-model.sh medium
    cd "$PROJECT_DIR"
    echo "  ✓ Modelo medium baixado"
else
    echo "  ✓ Modelo medium já existe"
fi

# 4. Install whisper binary and model to Application Support
SUPPORT_DIR="$HOME/Library/Application Support/Ditado"
echo ""
echo "▸ Instalando whisper em $SUPPORT_DIR..."
mkdir -p "$SUPPORT_DIR/bin"
mkdir -p "$SUPPORT_DIR/models"

cp "$PROJECT_DIR/vendor/whisper.cpp/build/bin/whisper-cli" "$SUPPORT_DIR/bin/"
echo "  ✓ whisper-cli copiado"

if [ ! -f "$SUPPORT_DIR/models/ggml-medium.bin" ]; then
    echo "▸ Copiando modelo (~1.5GB)... aguarde"
    cp "$PROJECT_DIR/vendor/whisper.cpp/models/ggml-medium.bin" "$SUPPORT_DIR/models/"
    echo "  ✓ Modelo copiado"
else
    echo "  ✓ Modelo já instalado"
fi

# 5. Build Ditado
echo ""
echo "▸ Compilando Ditado..."
swift build -c release 2>&1 | tail -2

# 6. Create .app bundle
echo "▸ Montando Ditado.app..."
bash Scripts/build.sh 2>&1 | tail -2

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║         ✓ Instalação completa!               ║"
echo "╠══════════════════════════════════════════════╣"
echo "║                                              ║"
echo "║  Para usar:                                  ║"
echo "║  1. Abra Ditado.app                          ║"
echo "║  2. Habilite em Acessibilidade (Settings)    ║"
echo "║  3. Segure L-Shift + L-Control para ditar    ║"
echo "║                                              ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "Abrindo Ditado..."
open "$PROJECT_DIR/Ditado.app"
