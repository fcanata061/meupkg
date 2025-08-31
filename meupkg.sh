#!/bin/sh
# meupkg - protótipo simples e funcional de gerenciador de pacotes

### CONFIGURAÇÕES ###
RECIPES_DIR="/var/lib/meupkg/recipes"   # Receitas dos pacotes
LOG_DIR="/var/log/meupkg"               # Registro de pacotes instalados
BUILD_DIR="/tmp/meupkg-build"           # Diretório temporário
SRC_DIR="$BUILD_DIR/src"                # Onde ficam os tarballs baixados
PKG_TMPDIR="$BUILD_DIR/pkg"             # Raiz temporária de instalação

# Garante que os diretórios existem
mkdir -p "$RECIPES_DIR" "$LOG_DIR" "$BUILD_DIR" "$SRC_DIR" "$PKG_TMPDIR"

### FUNÇÕES ###
pkg_load_recipe() {
    recipe="$RECIPES_DIR/$PKG_NAME.recipe"
    if [ ! -f "$recipe" ]; then
        echo "[ERRO] Receita $recipe não encontrada."
        exit 1
    fi
    . "$recipe"   # Carrega variáveis da receita
}

pkg_resolve_deps() {
    if [ -n "$DEPENDS" ]; then
        for dep in $DEPENDS; do
            if [ ! -f "$LOG_DIR/$dep.version" ]; then
                echo "[*] Resolvendo dependência: $dep"
                PKG_NAME="$dep"
                pkg_load_recipe
                pkg_download
                pkg_build
                pkg_install
            fi
        done
    fi
}

pkg_download() {
    echo "[*] Baixando $NAME-$VERSION de $URL"
    cd "$SRC_DIR" || exit 1
    if [ ! -f "$NAME-$VERSION.tar.gz" ]; then
        wget -q "$URL" -O "$NAME-$VERSION.tar.gz" || exit 1
    else
        echo "[OK] Já existe: $NAME-$VERSION.tar.gz"
    fi
    tar xf "$NAME-$VERSION.tar.gz" -C "$BUILD_DIR"
}

pkg_build() {
    echo "[*] Compilando $NAME-$VERSION"
    cd "$BUILD_DIR/$NAME-$VERSION" || exit 1
    export PKGDIR="$PKG_TMPDIR"
    rm -rf "$PKGDIR"/*
    mkdir -p "$PKGDIR"

    # Se existir patch_sources na receita → executa
    type patch_sources >/dev/null 2>&1 && patch_sources

    build

    # Se existir check na receita → executa
    type check >/dev/null 2>&1 && check
}

pkg_install() {
    echo "[*] Instalando $NAME"
    cd "$BUILD_DIR/$NAME-$VERSION" || exit 1
    install
    cp -rv "$PKGDIR"/* /

    # Registro
    find "$PKGDIR" -type f > "$LOG_DIR/$NAME.files"
    echo "$VERSION" > "$LOG_DIR/$NAME.version"

    # Se existir post_install → executa
    type post_install >/dev/null 2>&1 && post_install

    echo "[OK] $NAME-$VERSION instalado!"
}

pkg_remove() {
    if [ ! -f "$LOG_DIR/$PKG_NAME.files" ]; then
        echo "[ERRO] Pacote $PKG_NAME não está instalado."
        exit 1
    fi
    echo "[*] Removendo $PKG_NAME"
    while read -r file; do
        [ -f "$file" ] && rm -v "$file"
    done < "$LOG_DIR/$PKG_NAME.files"
    rm -f "$LOG_DIR/$PKG_NAME.files" "$LOG_DIR/$PKG_NAME.version"

    # Se existir post_remove → executa
    type post_remove >/dev/null 2>&1 && post_remove

    echo "[OK] $PKG_NAME removido!"
}

pkg_update() {
    for recipe in "$RECIPES_DIR"/*.recipe; do
        PKG_NAME=$(basename "$recipe" .recipe)
        pkg_load_recipe
        echo "[*] Atualizando $NAME"
        pkg_download
        pkg_build
        pkg_install
    done
}

### DISPATCH ###
PKG_NAME="$2"
case "$1" in
    build)
        pkg_load_recipe
        pkg_resolve_deps
        pkg_download
        pkg_build
        pkg_install
        ;;
    remove)
        pkg_remove
        ;;
    update)
        pkg_update
        ;;
    *)
        echo "Uso: $0 {build|remove|update} pacote"
        ;;
esac
