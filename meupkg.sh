#!/bin/sh
# meupkg - gerenciador minimalista (source -> pacote -> install)
# Requisitos: curl/wget, tar, sha256sum, fakeroot, file, strip (opcional), git (para sync)
set -eu

##### CONFIG #####
RECIPES_DIR="/var/lib/meupkg/recipes"   # receitas: <nome>.sh
WORK_DIR="/tmp/meupkg"                  # área de trabalho
BUILD_DIR="$WORK_DIR/build"             # fontes extraídas/compiladas
SRC_DIR="$WORK_DIR/src"                 # tarballs baixados
PKGROOT="$WORK_DIR/pkgroot"             # DESTDIR (raiz temporária por pacote)
PKG_REPO="/var/cache/meupkg/packages"   # repositório local de pacotes binários
STATE_DIR="/var/lib/meupkg/state"       # estado de instalados (versão/arquivos)
PKG_EXT=".tar.gz"                       # formato do pacote binário

mkdir -p "$RECIPES_DIR" "$BUILD_DIR" "$SRC_DIR" "$PKGROOT" "$PKG_REPO" "$STATE_DIR"

##### FLAGS E ESTADO #####
STRIP_BINARIES=0
VISITED_PACKAGES=""

##### CORES #####
RED="\033[1;31m"; GRN="\033[1;32m"; YLW="\033[1;33m"; BLU="\033[1;34m"; NC="\033[0m"
msg_ok()   { printf "${GRN}[OK]${NC} %s\n" "$*"; }
msg_warn() { printf "${YLW}[!]${NC} %s\n" "$*"; }
msg_err()  { printf "${RED}[ERRO]${NC} %s\n" "$*"; }
msg_info() { printf "${BLU}[*]${NC} %s\n" "$*"; }
die()      { msg_err "$*"; exit 1; }

##### HELP #####
print_usage() {
  cat <<EOF
Uso: $0 [--strip] {build|b|install|i|remove|r|upgrade|u|sync|index|search} <pacote|termo>

  --strip       Aplica "strip --strip-unneeded" em ELF antes de empacotar

Comandos:
  build|b       Resolve deps, compila e gera pacote binário (não instala)
  install|i     Resolve deps e instala a versão da receita a partir do pacote local
  remove|r      Remove pacote instalado (usa a lista de arquivos registrada)
  upgrade|u     Rebuild + instala se a receita tiver versão mais nova
  sync          git pull no diretório de receitas
  index         Varre $PKG_REPO e gera $PKG_REPO/PACKAGES
  search        Busca no PACKAGES (use um termo, ex: "$0 search nano")
EOF
}

##### UTIL #####
have() { command -v "$1" >/dev/null 2>&1; }
bn() { printf "%s\n" "$(basename -- "$1")"; }
ext_from_url() {
  case "$1" in
    *.tar.gz|*.tgz)  echo ".tar.gz" ;;
    *.tar.xz)        echo ".tar.xz" ;;
    *.tar.zst)       echo ".tar.zst" ;;
    *.tar.bz2)       echo ".tar.bz2" ;;
    *.tar)           echo ".tar" ;;
    *)               echo "" ;;
  esac
}
tar_list() {
  case "$1" in
    *.tar.gz|*.tgz)  tar -tzf "$1" ;;
    *.tar.xz)        tar -tJf "$1" ;;
    *.tar.zst)       tar --zstd -tf "$1" ;;
    *.tar.bz2)       tar -tjf "$1" ;;
    *.tar)           tar -tf "$1" ;;
    *) die "Formato de tar desconhecido: $1" ;;
  esac
}
tar_extract() {
  # $1: arquivo, $2: destino
  mkdir -p "$2"
  case "$1" in
    *.tar.gz|*.tgz)  tar -xzf "$1" -C "$2" ;;
    *.tar.xz)        tar -xJf "$1" -C "$2" ;;
    *.tar.zst)       tar --zstd -xf "$1" -C "$2" ;;
    *.tar.bz2)       tar -xjf "$1" -C "$2" ;;
    *.tar)           tar -xf "$1" -C "$2" ;;
    *) die "Formato de tar desconhecido: $1" ;;
  esac
}
tar_extract_root_fakeroot() {
  # extrai diretamente em /
  case "$1" in
    *.tar.gz|*.tgz)  fakeroot tar -xzf "$1" -C / ;;
    *.tar.xz)        fakeroot tar -xJf "$1" -C / ;;
    *.tar.zst)       fakeroot tar --zstd -xf "$1" -C / ;;
    *.tar.bz2)       fakeroot tar -xjf "$1" -C / ;;
    *.tar)           fakeroot tar -xf  "$1" -C / ;;
    *) die "Formato de tar desconhecido: $1" ;;
  esac
}

# salvar/restaurar contexto (para resolver deps recursivas sem poluir variáveis)
save_ctx() {
  SAV_NAME="${NAME-}"; SAV_VERSION="${VERSION-}"; SAV_SOURCE_URL="${SOURCE_URL-}"
  SAV_CHECKSUM="${CHECKSUM-}"; SAV_DEPENDS="${DEPENDS-}"
}
restore_ctx() {
  NAME="${SAV_NAME-}"; VERSION="${SAV_VERSION-}"; SOURCE_URL="${SAV_SOURCE_URL-}"
  CHECKSUM="${SAV_CHECKSUM-}"; DEPENDS="${SAV_DEPENDS-}"
}

is_installed() { [ -f "$STATE_DIR/$1.version" ]; }

##### LOADER DE RECEITA #####
# Cada receita deve definir: NAME, VERSION, SOURCE_URL
# Opcional: CHECKSUM (sha256), DEPENDS (lista), e hooks abaixo
unset_hooks() {
  unset prepare patch_sources build check install post_install post_remove 2>/dev/null || true
}
define_noop_hooks() {
  prepare() { :; }
  patch_sources() { :; }
  build() { :; }
  check() { :; }
  install() { :; }
  post_install() { :; }
  post_remove() { :; }
}
load_recipe() {
  PKG="$1"
  FILE="$RECIPES_DIR/$PKG.sh"
  [ -f "$FILE" ] || die "Receita $PKG não encontrada em $RECIPES_DIR"
  unset NAME VERSION SOURCE_URL CHECKSUM DEPENDS
  unset_hooks
  # shellcheck disable=SC1090
  . "$FILE"
  define_noop_hooks
  : "${NAME:?Receita sem NAME}"; : "${VERSION:?Receita sem VERSION}"; : "${SOURCE_URL:?Receita sem SOURCE_URL}"
  DEPENDS="${DEPENDS-}"; CHECKSUM="${CHECKSUM-}"
}

##### META #####
write_meta() {
  META="$1/meta.txt"
  {
    echo "NAME=$NAME"
    echo "VERSION=$VERSION"
    echo "DEPENDS=${DEPENDS-}"
  } > "$META"
}

##### FETCH #####
pkg_fetch() {
  msg_info "Baixando fonte de ${NAME}-${VERSION}"
  cd "$SRC_DIR"
  SRC_FILE="$(bn "$SOURCE_URL")"
  if [ ! -f "$SRC_FILE" ]; then
    if have curl; then curl -L "$SOURCE_URL" -o "$SRC_FILE"; else wget -O "$SRC_FILE" "$SOURCE_URL"; fi
  else
    msg_ok "Já existe: $SRC_FILE"
  fi
  if [ -n "${CHECKSUM-}" ]; then
    printf "%s  %s\n" "$CHECKSUM" "$SRC_FILE" | sha256sum -c - || die "Checksum SHA256 inválido para $SRC_FILE"
    msg_ok "Checksum OK"
  fi
}

##### BUILD #####
pkg_build() {
  msg_info "Compilando ${NAME}-${VERSION}"
  SRC_FILE="$SRC_DIR/$(bn "$SOURCE_URL")"
  EXT="$(ext_from_url "$SRC_FILE")"
  [ -n "$EXT" ] || die "Arquivo fonte não parece ser um tar suportado: $SRC_FILE"

  # limpar áreas do pacote
  rm -rf "$BUILD_DIR/$NAME-$VERSION" "$PKGROOT/$NAME" 2>/dev/null || true
  mkdir -p "$BUILD_DIR/$NAME-$VERSION" "$PKGROOT/$NAME"

  # extrair fonte e entrar
  tar_extract "$SRC_FILE" "$BUILD_DIR/$NAME-$VERSION"
  cd "$BUILD_DIR/$NAME-$VERSION"

  # hooks pré-build
  patch_sources || true
  prepare || true

  # compilar
  build

  # testes (opcional)
  check || true

  # instalar em DESTDIR
  export PKGDIR="$PKGROOT/$NAME"
  install

  # strip opcional (somente ELF executável ou .so)
  if [ "$STRIP_BINARIES" -eq 1 ] && have strip && have file; then
    msg_info "Aplicando strip em binários ELF…"
    find "$PKGDIR" -type f -exec file {} \; \
      | grep -E 'ELF .* (executable|shared object)' \
      | cut -d: -f1 \
      | xargs -r strip --strip-unneeded 2>/dev/null || true
  fi

  # meta + pacote
  write_meta "$PKGDIR"
  pkg_package
}

##### PACKAGE #####
pkg_package() {
  PKG_FILE="$PKG_REPO/${NAME}-${VERSION}${PKG_EXT}"
  msg_info "Empacotando -> $PKG_FILE"
  (cd "$PKGROOT/$NAME" && fakeroot tar -czf "$PKG_FILE" .)
  msg_ok "Pacote criado: $PKG_FILE"
}

##### INSTALL #####
pkg_install() {
  PKG_FILE="$PKG_REPO/${NAME}-${VERSION}${PKG_EXT}"
  if [ ! -f "$PKG_FILE" ]; then
    msg_warn "Pacote binário não encontrado, construindo ${NAME}-${VERSION}"
    pkg_fetch
    pkg_build
  fi

  msg_info "Instalando ${NAME}-${VERSION} a partir de $PKG_FILE"
  # registrar lista de arquivos antes de extrair (relativos)
  FILELIST="$STATE_DIR/$NAME.files"
  tar_list "$PKG_FILE" > "$FILELIST"
  # extrair em /
  tar_extract_root_fakeroot "$PKG_FILE"

  echo "$VERSION" > "$STATE_DIR/$NAME.version"

  # pós-install
  post_install || true

  msg_ok "${NAME}-${VERSION} instalado."
}

##### REMOVE #####
pkg_remove() {
  PKG="$1"
  VERFILE="$STATE_DIR/$PKG.version"
  FILELIST="$STATE_DIR/$PKG.files"

  [ -f "$VERFILE" ] || die "$PKG não está instalado."
  VERSION="$(cat "$VERFILE")"

  # carrega receita (se existir) para hook post_remove
  if [ -f "$RECIPES_DIR/$PKG.sh" ]; then
    load_recipe "$PKG"
  else
    NAME="$PKG"
  fi

  msg_info "Removendo ${PKG}-${VERSION}"

  # remove arquivos listados
  if [ -f "$FILELIST" ]; then
    # remover arquivos; ignorar se já não existirem
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      f="/$rel"
      [ -f "$f" ] && rm -f "$f" || true
      # não remove diretórios aqui; faremos limpeza depois
    done < "$FILELIST"

    # tentativa de limpeza de diretórios vazios (best-effort)
    # varre diretórios que podem ter sido criados pelo pacote
    awk -F/ 'NF>1{ $NF=""; print "/"$0 }' OFS=/ "$FILELIST" \
      | sed 's:/*$::' \
      | sort -u -r \
      | while read -r d; do
          [ -d "$d" ] && rmdir "$d" 2>/dev/null || true
        done
  else
    msg_warn "Sem lista de arquivos ($FILELIST); nada para deletar."
  fi

  # hooks
  post_remove || true

  # limpar estado
  rm -f "$VERFILE" "$FILELIST"

  msg_ok "${PKG}-${VERSION} removido."
}

##### DEPENDÊNCIAS (recursivo + ciclo) #####
resolve_deps_recursive() {
  CUR="$NAME"

  # ciclo?
  echo " $VISITED_PACKAGES " | grep -qw " $CUR " && die "Ciclo de dependências detectado em: $CUR"
  VISITED_PACKAGES="$VISITED_PACKAGES $CUR"

  [ -n "${DEPENDS-}" ] || return 0

  for dep in $DEPENDS; do
    if is_installed "$dep"; then
      msg_ok "Dependência já instalada: $dep"
      continue
    fi

    # carregar receita da dependência
    save_ctx
    load_recipe "$dep"

    # recursão
    resolve_deps_recursive

    # compilar/instalar a dependência
    pkg_fetch
    pkg_build
    pkg_install

    # voltar ao contexto do pacote chamador
    restore_ctx
  done
}

##### UPGRADE #####
cmd_upgrade() {
  PKG="$1"
  load_recipe "$PKG"
  if is_installed "$PKG"; then
    CUR="$(cat "$STATE_DIR/$PKG.version")"
    if [ "$CUR" = "$VERSION" ]; then
      msg_ok "$PKG já está na versão $CUR"
      return 0
    fi
    msg_info "Upgrade: $PKG $CUR -> $VERSION"
  else
    msg_info "$PKG não está instalado; será instalado."
  fi
  VISITED_PACKAGES=""
  resolve_deps_recursive
  pkg_fetch
  pkg_build
  pkg_install
}

##### SYNC (git pull) #####
cmd_sync() {
  [ -d "$RECIPES_DIR/.git" ] || die "$RECIPES_DIR não é um repositório git"
  msg_info "Sincronizando receitas (git pull)…"
  (cd "$RECIPES_DIR" && git pull --ff-only)
  msg_ok "Receitas atualizadas."
}

##### INDEX #####
cmd_index() {
  INDEX_FILE="$PKG_REPO/PACKAGES"
  : > "$INDEX_FILE"
  for pkg in "$PKG_REPO"/*$PKG_EXT; do
    [ -f "$pkg" ] || continue
    TMP=$(mktemp -d)
    # extrai apenas meta.txt
    tar_extract "$pkg" "$TMP"
    if [ -f "$TMP/meta.txt" ]; then
      echo "---" >> "$INDEX_FILE"
      cat "$TMP/meta.txt" >> "$INDEX_FILE"
      echo "FILENAME=$(bn "$pkg")" >> "$INDEX_FILE"
    fi
    rm -rf "$TMP"
  done
  msg_ok "INDEX gerado: $INDEX_FILE"
}

##### SEARCH #####
cmd_search() {
  TERM="${1-}"
  [ -n "$TERM" ] || die "Informe um termo. Ex: $0 search nano"
  INDEX_FILE="$PKG_REPO/PACKAGES"
  [ -f "$INDEX_FILE" ] || die "Nenhum INDEX encontrado. Rode: $0 index"
  awk -v term="$TERM" -v GRN="$GRN" -v NC="$NC" '
    BEGIN { RS="---"; IGNORECASE=1 }
    {
      if ($0 ~ term) {
        name=""; version=""; deps=""
        n=split($0, L, "\n")
        for (i=1;i<=n;i++) {
          if (L[i] ~ /^NAME=/)    name=substr(L[i],6)
          if (L[i] ~ /^VERSION=/) version=substr(L[i],9)
          if (L[i] ~ /^DEPENDS=/) deps=substr(L[i],9)
        }
        if (name!="") {
          printf "%s%s%s %s\n", GRN, name, NC, version
          if (deps!="") printf "   deps: %s\n", deps
        }
      }
    }
  ' "$INDEX_FILE"
}

##### PARSE CLI #####
# flags
while [ "${1-}" ]; do
  case "$1" in
    --strip) STRIP_BINARIES=1; shift ;;
    -h|--help) print_usage; exit 0 ;;
    build|b|install|i|remove|r|upgrade|u|sync|index|search) break ;;
    *) break ;;
  esac
done

ACTION="${1-}"
ARG="${2-}"

[ -n "$ACTION" ] || { print_usage; exit 1; }

case "$ACTION" in
  build|b)
    [ -n "$ARG" ] || die "Informe o nome do pacote"
    load_recipe "$ARG"
    VISITED_PACKAGES=""
    resolve_deps_recursive
    pkg_fetch
    pkg_build
    ;;
  install|i)
    [ -n "$ARG" ] || die "Informe o nome do pacote"
    load_recipe "$ARG"
    VISITED_PACKAGES=""
    resolve_deps_recursive
    pkg_install
    ;;
  remove|r)
    [ -n "$ARG" ] || die "Informe o nome do pacote"
    pkg_remove "$ARG"
    ;;
  upgrade|u)
    [ -n "$ARG" ] || die "Informe o nome do pacote"
    cmd_upgrade "$ARG"
    ;;
  sync)
    cmd_sync
    ;;
  index)
    cmd_index
    ;;
  search)
    [ -n "$ARG" ] || die "Informe o termo de busca"
    cmd_search "$ARG"
    ;;
  *)
    print_usage; exit 1 ;;
esac
