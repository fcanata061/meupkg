#!/bin/sh
# meupkg - Gerenciador simples de pacotes (source + binário)
# Diretórios principais
BUILD_DIR="/tmp/meupkg-build"
PKG_TMPDIR="/tmp/meupkg-pkg"
PKG_REPO="/var/cache/meupkg/packages"
LOG_DIR="/var/lib/meupkg"

mkdir -p "$BUILD_DIR" "$PKG_TMPDIR" "$PKG_REPO" "$LOG_DIR"
# -----------------------------------------------------------
# Funções principais
# -----------------------------------------------------------
pkg_fetch() {
    echo "[*] Baixando $NAME-$VERSION"
    cd "$BUILD_DIR" || exit 1
    if [ ! -f "${NAME}-${VERSION}.tar.*" ]; then
        wget -O "${NAME}-${VERSION}.tar.gz" "$URL"
    fi
    tar -xf ${NAME}-${VERSION}.tar.* -C "$BUILD_DIR"
}

pkg_build() {
    echo "[*] Compilando $NAME-$VERSION"
    cd "$BUILD_DIR/$NAME-$VERSION" || exit 1
    export PKGDIR="$PKG_TMPDIR"
    rm -rf "$PKGDIR"/*
    mkdir -p "$PKGDIR"

    # Hook opcional: patch
    type patch_sources >/dev/null 2>&1 && patch_sources

    # Build principal
    build

    # Hook opcional: check
    type check >/dev/null 2>&1 && check

    # Instalação no PKGDIR
    install

    # Empacotamento
    pkg_package
}

pkg_package() {
    echo "[*] Empacotando $NAME-$VERSION"
    PKG_FILE="$PKG_REPO/$NAME-$VERSION.tar.gz"
    fakeroot tar -czf "$PKG_FILE" -C "$PKGDIR" .
    echo "[OK] Pacote criado: $PKG_FILE"
}

pkg_install() {
    PKG_FILE="$PKG_REPO/$PKG_NAME-$VERSION.tar.gz"
    if [ ! -f "$PKG_FILE" ]; then
        echo "[ERRO] Binário $PKG_FILE não encontrado. Compile primeiro."
        exit 1
    fi

    echo "[*] Instalando $PKG_NAME-$VERSION a partir do binário"
    fakeroot tar -xzf "$PKG_FILE" -C /

    # Registro de arquivos
    tar -tzf "$PKG_FILE" > "$LOG_DIR/$PKG_NAME.files"
    echo "$VERSION" > "$LOG_DIR/$PKG_NAME.version"

    # Hook opcional pós-install
    type post_install >/dev/null 2>&1 && post_install

    echo "[OK] $PKG_NAME-$VERSION instalado!"
}

pkg_remove() {
    if [ ! -f "$LOG_DIR/$PKG_NAME.files" ]; then
        echo "[ERRO] Pacote $PKG_NAME não está instalado."
        exit 1
    fi
    echo "[*] Removendo $PKG_NAME"
    while read -r file; do
        [ -f "/$file" ] && rm -v "/$file"
    done < "$LOG_DIR/$PKG_NAME.files"

    rm -f "$LOG_DIR/$PKG_NAME.files" "$LOG_DIR/$PKG_NAME.version"

    # Hook opcional pós-remove
    type post_remove >/dev/null 2>&1 && post_remove

    echo "[OK] $PKG_NAME removido!"
}
# -----------------------------------------------------------
# Entrada principal
# -----------------------------------------------------------
if [ $# -lt 2 ]; then
    echo "Uso: $0 {build|install|remove} pacote"
    exit 1
fi

ACTION="$1"
PKG_NAME="$2"
RECIPE="/var/lib/meupkg/recipes/$PKG_NAME.sh"

if [ ! -f "$RECIPE" ]; then
    echo "[ERRO] Receita $RECIPE não encontrada"
    exit 1
fi
# Carrega receita (define NAME, VERSION, URL, funções, etc.)
. "$RECIPE"

case "$ACTION" in
    build)
        pkg_fetch
        pkg_build
        ;;
    install)
        pkg_install
        ;;
    remove)
        pkg_remove
        ;;
    *)
        echo "Ação inválida: $ACTION"
        exit 1
        ;;
esac
