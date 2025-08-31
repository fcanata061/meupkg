#!/bin/sh
# meupkg - gerenciador simples (source -> binário -> instalar)
# Requisitos: wget, tar, sha256sum, fakeroot, file, strip (opcional quando --strip)

set -eu

##### CONFIGURAÇÃO #####
RECIPES_DIR="/var/lib/meupkg/recipes"   # onde ficam as receitas *.sh
WORK_DIR="/tmp/meupkg"                   # área de trabalho
BUILD_DIR="$WORK_DIR/build"             # onde as fontes são extraídas/compiladas
SRC_DIR="$WORK_DIR/src"                 # onde os tarballs são baixados
PKG_TMPDIR="$WORK_DIR/pkgroot"          # raiz temporária de instalação (DESTDIR)
PKG_REPO="/var/cache/meupkg/packages"   # repositório local de pacotes binários
STATE_DIR="/var/lib/meupkg/state"       # registros (arquivos instalados/versões)

PKG_EXT=".tar.gz"                       # extensão dos pacotes binários gerados

# cria diretórios
mkdir -p "$RECIPES_DIR" "$BUILD_DIR" "$SRC_DIR" "$PKG_TMPDIR" "$PKG_REPO" "$STATE_DIR"

# flags
STRIP_BINARIES=0
VISITED_PACKAGES=""

##### UTIL #####
die() { echo "[ERRO] $*" >&2; exit 1; }
msg() { printf "%s\n" "$*"; }

# Detecta lista de arquivos em um tar (por extensão)
tar_list() {
  case "$1" in
    *.tar.gz|*.tgz) tar -tzf "$1" ;;
    *.tar.xz)       tar -tJf "$1" ;;
    *.tar.zst)      tar --zstd -tf "$1" ;;
    *.tar)          tar -tf "$1" ;;
    *) die "Formato de tar desconhecido para listar: $1" ;;
  esac
}

# Extrai um tar para destino /
tar_extract_to_root() {
  case "$1" in
    *.tar.gz|*.tgz) fakeroot tar -xzf "$1" -C / ;;
    *.tar.xz)       fakeroot tar -xJf "$1" -C / ;;
    *.tar.zst)      fakeroot tar --zstd -xf "$1" -C / ;;
    *.tar)          fakeroot tar -xf  "$1" -C / ;;
    *) die "Formato de tar desconhecido para extrair: $1" ;;
  esac
}

# Empacota o conteúdo do PKGDIR em .tar.gz fixo (para simplificar registro)
make_pkg_tar() {
  pkgfile="$1" ; pkgdir="$2"
  fakeroot tar -czf "$pkgfile" -C "$pkgdir" .
}

# Salva/Restauta contexto de variáveis de receita para recursão segura
save_ctx() {
  SAV_NAME="${NAME-}"; SAV_VERSION="${VERSION-}"; SAV_URL="${URL-}"
  SAV_SHA256SUM="${SHA256SUM-}"; SAV_DEPENDS="${DEPENDS-}"
}
restore_ctx() {
  NAME="${SAV_NAME-}"; VERSION="${SAV_VERSION-}"; URL="${SAV_URL-}"
  SHA256SUM="${SAV_SHA256SUM-}"; DEPENDS="${SAV_DEPENDS-}"
}

# Verifica se pacote está instalado (usa arquivo de versão)
is_installed() { [ -f "$STATE_DIR/$1.version" ]; }

# Carrega receita de um pacote
load_recipe() {
  RECIPE="$RECIPES_DIR/$1.sh"
  [ -f "$RECIPE" ] || die "Receita não encontrada: $RECIPE"
  # limpa possíveis funções/variáveis antigas do shell (evita vazamento entre receitas)
  unset NAME VERSION URL SHA256SUM DEPENDS
  unset prepare patch_sources build check install post_install post_remove 2>/dev/null || true
  # shellcheck disable=SC1090
  . "$RECIPE"
  [ -n "${NAME-}" ] && [ -n "${VERSION-}" ] && [ -n "${URL-}" ] || die "Receita $1 incompleta (NAME/VERSION/URL)."
}

##### FASES #####

pkg_fetch() {
  msg "[*] Baixando ${NAME}-${VERSION}"
  cd "$SRC_DIR"
  SRC_ARCHIVE="$(basename "$URL")"
  if [ ! -f "$SRC_ARCHIVE" ]; then
    wget -O "$SRC_ARCHIVE" "$URL" || die "Falha no download"
  else
    msg "[OK] Já existe: $SRC_ARCHIVE"
  fi

  # valida SHA256 se fornecido
  if [ -n "${SHA256SUM-}" ]; then
    echo "$SHA256SUM  $SRC_ARCHIVE" | sha256sum -c - || die "Checksum SHA256 inválido para $SRC_ARCHIVE"
  fi

  # extrai
  rm -rf "$BUILD_DIR/${NAME}-${VERSION}" 2>/dev/null || true
  mkdir -p "$BUILD_DIR"
  tar -xf "$SRC_ARCHIVE" -C "$BUILD_DIR"
}

pkg_build() {
  msg "[*] Compilando ${NAME}-${VERSION}"
  cd "$BUILD_DIR/${NAME}-${VERSION}" || die "Diretório de build não encontrado"

  export PKGDIR="$PKG_TMPDIR"
  rm -rf "$PKGDIR"/* 2>/dev/null || true
  mkdir -p "$PKGDIR"

  # hooks antes do build
  command -v patch_sources >/dev/null 2>&1 && patch_sources
  command -v prepare       >/dev/null 2>&1 && prepare

  # build principal (obrigatório)
  command -v build >/dev/null 2>&1 || die "Receita sem função build()"
  build

  # testes opcionais
  command -v check >/dev/null 2>&1 && check

  # install (obrigatório) no DESTDIR
  command -v install >/dev/null 2>&1 || die "Receita sem função install()"
  install

  # strip opcional
  if [ "$STRIP_BINARIES" -eq 1 ]; then
    msg "[*] Strip de binários..."
    # encontra executáveis e shared objects ELF e aplica strip
    find "$PKGDIR" -type f -exec file {} \; \
      | grep -E 'ELF .* (executable|shared object)' \
      | cut -d: -f1 \
      | xargs -r strip --strip-unneeded 2>/dev/null || true
  fi

  # empacota
  pkg_package
}

pkg_package() {
  PKG_FILE="$PKG_REPO/${NAME}-${VERSION}${PKG_EXT}"
  msg "[*] Empacotando ${NAME}-${VERSION} -> $PKG_FILE"
  make_pkg_tar "$PKG_FILE" "$PKGDIR"
  msg "[OK] Pacote criado: $PKG_FILE"
}

pkg_install() {
  PKG_FILE="$PKG_REPO/${NAME}-${VERSION}${PKG_EXT}"
  [ -f "$PKG_FILE" ] || die "Binário não encontrado: $PKG_FILE (rode build primeiro)."

  msg "[*] Instalando ${NAME}-${VERSION} a partir do binário"
  tar_extract_to_root "$PKG_FILE"

  # registra arquivos e versão
  tar_list "$PKG_FILE" > "$STATE_DIR/$NAME.files"
  echo "$VERSION" > "$STATE_DIR/$NAME.version"

  # pós-install (opcional)
  command -v post_install >/dev/null 2>&1 && post_install

  msg "[OK] ${NAME}-${VERSION} instalado."
}

pkg_remove() {
  PKG="$1"
  FILES="$STATE_DIR/$PKG.files"
  [ -f "$FILES" ] || die "Pacote $PKG não está instalado."

  # pós-remove precisa da receita (se existir)
  if [ -f "$RECIPES_DIR/$PKG.sh" ]; then
    load_recipe "$PKG"
  else
    NAME="$PKG" # para mensagens
  fi

  msg "[*] Removendo $PKG"
  # remove apenas arquivos listados (se existirem)
  while IFS= read -r rel; do
    f="/$rel"
    [ -f "$f" ] && rm -f "$f"
  done < "$FILES"

  # limpa arquivos vazios/dirs órfãos simples (opcional, best-effort)
  # find /usr /etc /lib /lib64 /usr/local -type d -empty -delete 2>/dev/null || true

  rm -f "$STATE_DIR/$PKG.files" "$STATE_DIR/$PKG.version"

  command -v post_remove >/dev/null 2>&1 && post_remove

  msg "[OK] $PKG removido."
}

##### RESOLVER DE DEPENDÊNCIAS (RECURSIVO + CICLOS) #####

resolve_deps_recursive() {
  # Usa variáveis da receita atual: NAME, VERSION, DEPENDS
  CURPKG="$NAME"

  # marca pacote atual como visitado nesta cadeia
  case " $VISITED_PACKAGES " in
    *" $CURPKG "*) die "Ciclo de dependência detectado: ...->$CURPKG" ;;
  esac
  VISITED_PACKAGES="$VISITED_PACKAGES $CURPKG"

  [ -n "${DEPENDS-}" ] || return 0

  for dep in $DEPENDS; do
    if ! is_installed "$dep"; then
      msg "[*] Dependência ausente: $dep"

      # ciclo direto?
      echo " $VISITED_PACKAGES " | grep -qw " $dep " && die "Ciclo: $CURPKG -> $dep"

      # salva contexto da receita atual
      save_ctx

      # carrega receita da dependência
      load_recipe "$dep"

      # resolve dependências da dependência (recursivo)
      resolve_deps_recursive

      # build + install da dependência
      pkg_fetch
      pkg_build
      pkg_install

      # restaura contexto original para voltar ao pacote que chamou
      restore_ctx
    else
      msg "[OK] Dependência já instalada: $dep"
    fi
  done
}

##### CLI / DISPATCH #####

print_usage() {
  cat <<EOF
Uso: $0 [--strip] {build|b|install|i|remove|r} <pacote>

  --strip     Aplica strip em binários/ELF antes de empacotar

Comandos:
  build|b     Resolve dependências, compila, empacota binário (não instala)
  install|i   Resolve dependências e instala a partir do binário local
  remove|r    Remove um pacote instalado

Receitas: $RECIPES_DIR/<pacote>.sh
Estado:   $STATE_DIR
Repo:     $PKG_REPO
EOF
}

# parse flags
while [ "${1-}" ]; do
  case "$1" in
    --strip) STRIP_BINARIES=1; shift ;;
    build|b|install|i|remove|r) break ;;
    -h|--help) print_usage; exit 0 ;;
    *) break ;;
  esac
done

[ $# -ge 2 ] || { print_usage; exit 1; }

ACTION="$1"
PKG_REQ="$2"

case "$ACTION" in
  build|b)
    load_recipe "$PKG_REQ"
    VISITED_PACKAGES=""
    resolve_deps_recursive
    pkg_fetch
    pkg_build
    ;;
  install|i)
    load_recipe "$PKG_REQ"
    VISITED_PACKAGES=""
    resolve_deps_recursive
    pkg_install
    ;;
  remove|r)
    pkg_remove "$PKG_REQ"
    ;;
  *)
    print_usage; exit 1 ;;
esac
