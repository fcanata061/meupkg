#!/bin/sh
# meupkg - gerenciador minimalista (source -> pacote -> install)
# Reqs: curl/wget, tar, sha256sum, fakeroot, file, strip (opcional), git
set -eu

##### CONFIG #####
RECIPES_DIR="/var/lib/meupkg/recipes"   # receitas: <nome>.sh
WORK_DIR="/tmp/meupkg"                  # área de trabalho
BUILD_DIR="$WORK_DIR/build"             # fontes extraídas/compiladas
SRC_DIR="$WORK_DIR/src"                 # tarballs baixados
PKGROOT="$WORK_DIR/pkgroot"             # DESTDIR (raiz temporária por pacote)
PKG_REPO="/var/cache/meupkg/packages"   # repositório local de pacotes binários
STATE_DIR="/var/lib/meupkg/state"       # estado (versão/arquivos/deps)
PKG_EXT=".tar.gz"                       # formato do pacote binário

mkdir -p "$RECIPES_DIR" "$BUILD_DIR" "$SRC_DIR" "$PKGROOT" "$PKG_REPO" "$STATE_DIR"

##### FLAGS/ESTADO #####
STRIP_BINARIES=0
CASCADE=0               # remove dependentes automaticamente
VISITED_PACKAGES=""
# cores
RED="\033[1;31m"; GRN="\033[1;32m"; YLW="\033[1;33m"; BLU="\033[1;34m"; NC="\033[0m"
msg_ok()   { printf "${GRN}[OK]${NC} %s\n" "$*"; }
msg_warn() { printf "${YLW}[!]${NC} %s\n" "$*"; }
msg_err()  { printf "${RED}[ERRO]${NC} %s\n" "$*"; }
msg_info() { printf "${BLU}[*]${NC} %s\n" "$*"; }
die()      { msg_err "$*"; exit 1; }

##### HELP #####
print_usage() {
  cat <<EOF
Uso: $0 [--strip] [--cascade|-c] {build|b|install|i|remove|r|upgrade|u|sync|index|search} <args>

  --strip           Aplica strip em ELF antes de empacotar
  --cascade, -c     Em 'remove': remove alvo + dependentes (ordem topológica)

Comandos:
  build|b <pkg>     Resolve deps, compila e gera pacote binário (não instala)
  install|i <pkg>   Resolve deps e instala a versão da receita
  remove|r <pkg...> Remove pacote(s); bloqueia se houver dependentes (a menos que --cascade)
  upgrade|u <pkg>   Rebuild + instala se a receita tiver versão mais nova
  sync              git pull no diretório de receitas
  index             Gera $PKG_REPO/PACKAGES a partir dos pacotes
  search <termo>    Busca no PACKAGES
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
  case "$1" in
    *.tar.gz|*.tgz)  fakeroot tar -xzf "$1" -C / ;;
    *.tar.xz)        fakeroot tar -xJf "$1" -C / ;;
    *.tar.zst)       fakeroot tar --zstd -xf "$1" -C / ;;
    *.tar.bz2)       fakeroot tar -xjf "$1" -C / ;;
    *.tar)           fakeroot tar -xf  "$1" -C / ;;
    *) die "Formato de tar desconhecido: $1" ;;
  esac
}

save_ctx() {
  SAV_NAME="${NAME-}"; SAV_VERSION="${VERSION-}"; SAV_SOURCE_URL="${SOURCE_URL-}"
  SAV_CHECKSUM="${CHECKSUM-}"; SAV_DEPENDS="${DEPENDS-}"
}
restore_ctx() {
  NAME="${SAV_NAME-}"; VERSION="${SAV_VERSION-}"; SOURCE_URL="${SAV_SOURCE_URL-}"
  CHECKSUM="${SAV_CHECKSUM-}"; DEPENDS="${SAV_DEPENDS-}"
}

is_installed() { [ -f "$STATE_DIR/$1.version" ]; }

##### RECEITAS / HOOKS #####
unset_hooks() {
  unset prepare patch_sources build check install post_install post_remove 2>/dev/null || true
}
define_noop_hooks() {
  prepare() { :; }; patch_sources() { :; }; build() { :; }; check() { :; }
  install() { :; }; post_install() { :; }; post_remove() { :; }
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

##### META + MANIFEST #####
write_meta() {
  META="$1/meta.txt"
  {
    echo "NAME=$NAME"
    echo "VERSION=$VERSION"
    echo "DEPENDS=${DEPENDS-}"
  } > "$META"
}
write_manifest_from_tree() {
  # Gera manifest.txt (apenas arquivos/links regulares), caminhos relativos
  ( cd "$1" && find . -type f -o -type l | sed 's|^\./||' | sort ) > "$1/manifest.txt"
}

##### FETCH/BUILD/PACK #####
pkg_fetch() {
  msg_info "Baixando ${NAME}-${VERSION}"
  cd "$SRC_DIR"
  SRC_FILE="$(bn "$SOURCE_URL")"
  if [ ! -f "$SRC_FILE" ]; then
    if have curl; then curl -L "$SOURCE_URL" -o "$SRC_FILE"; else wget -O "$SRC_FILE" "$SOURCE_URL"; fi
  else
    msg_ok "Já existe: $SRC_FILE"
  fi
  if [ -n "${CHECKSUM-}" ]; then
    printf "%s  %s\n" "$CHECKSUM" "$SRC_FILE" | sha256sum -c - || die "Checksum SHA256 inválido"
    msg_ok "Checksum OK"
  fi
}

pkg_build() {
  msg_info "Compilando ${NAME}-${VERSION}"
  SRC_FILE="$SRC_DIR/$(bn "$SOURCE_URL")"
  EXT="$(ext_from_url "$SRC_FILE")"
  [ -n "$EXT" ] || die "Fonte não é um tar suportado: $SRC_FILE"

  rm -rf "$BUILD_DIR/$NAME-$VERSION" "$PKGROOT/$NAME" 2>/dev/null || true
  mkdir -p "$BUILD_DIR/$NAME-$VERSION" "$PKGROOT/$NAME"

  tar_extract "$SRC_FILE" "$BUILD_DIR/$NAME-$VERSION"
  cd "$BUILD_DIR/$NAME-$VERSION"

  patch_sources || true
  prepare || true

  build
  check || true

  export PKGDIR="$PKGROOT/$NAME"
  install

  if [ "$STRIP_BINARIES" -eq 1 ] && have strip && have file; then
    msg_info "Strip em binários ELF…"
    find "$PKGDIR" -type f -exec file {} \; \
      | grep -E 'ELF .* (executable|shared object)' \
      | cut -d: -f1 \
      | xargs -r strip --strip-unneeded 2>/dev/null || true
  fi

  write_meta "$PKGDIR"
  write_manifest_from_tree "$PKGDIR"
  pkg_package
}

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
    msg_warn "Pacote binário não encontrado; construindo ${NAME}-${VERSION}"
    pkg_fetch
    pkg_build
  fi

  msg_info "Instalando ${NAME}-${VERSION}"
  # Captura lista de arquivos a partir do pacote (manifest incluído facilita)
  TMP=$(mktemp -d)
  tar_extract "$PKG_FILE" "$TMP"

  # Se o pacote tem manifest.txt, use-o. Caso não, derive da lista do tar.
  if [ -f "$TMP/manifest.txt" ]; then
    cat "$TMP/manifest.txt" > "$STATE_DIR/$NAME.files"
  else
    tar_list "$PKG_FILE" | grep -vE '/$' > "$STATE_DIR/$NAME.files"
  fi

  # Registra deps declaradas na instalação
  DEPFILE="$STATE_DIR/$NAME.deps"
  if [ -f "$TMP/meta.txt" ]; then
    grep '^DEPENDS=' "$TMP/meta.txt" | sed 's/^DEPENDS=//' > "$DEPFILE" || echo "" > "$DEPFILE"
  else
    printf "%s\n" "${DEPENDS-}" > "$DEPFILE"
  fi

  # Extrai em /
  fakeroot cp -a "$TMP"/. /
  rm -rf "$TMP"

  echo "$VERSION" > "$STATE_DIR/$NAME.version"

  post_install || true
  msg_ok "${NAME}-${VERSION} instalado."
}

##### REMOVE (limpo + reverso/topológico) #####
installed_pkgs() { ls "$STATE_DIR"/*.version 2>/dev/null | xargs -r -n1 basename | sed 's/\.version$//' || true; }
deps_of() { [ -f "$STATE_DIR/$1.deps" ] && tr ' ' '\n' < "$STATE_DIR/$1.deps" | sed '/^$/d' || true; }

# constroi grafo: A->B (A depende de B)
build_graph() {
  # imprime arestas "A B" (A depende de B) para todos instalados
  for p in $(installed_pkgs); do
    for d in $(deps_of "$p"); do
      echo "$p $d"
    done
  done
}

reverse_dependents_closure() {
  # entrada: lista de pacotes alvo via args; saída: todos dependentes (diretos/indiretos) incluindo alvos
  # usa mapa reverso (dep -> consumidores)
  EDGES=$(build_graph)
  # constrói mapa reverso em awk
  echo "$EDGES" | awk -v targets="$*" '
    BEGIN{
      n=split(targets, T, " ");
      for(i=1;i<=n;i++){ queue[T[i]]=1; }
    }
    { dep=$2; use=$1; rev[dep]=(dep in rev)? rev[dep]" "use : use }
    END{
      # BFS reverso
      changed=1
      while(changed){
        changed=0
        for (k in queue){
          split(rev[k], L, " ")
          for (i in L){
            u=L[i]; if(u!="" && !(u in queue)){ queue[u]=1; changed=1 }
          }
        }
      }
      out=""
      for (k in queue) if(k!="") out=out k " "
      print out
    }'
}

topo_remove_order() {
  # entrada: conjunto S (pacotes) -> produz ordem tal que dependentes vêm antes de dependências
  S="$*"
  EDGES=$(build_graph | awk -v set="$S" '
    BEGIN{
      split(set, SS, " "); for(i in SS) if(SS[i]!="") keep[SS[i]]=1
    }
    { if(keep[$1] && keep[$2]) print $0 }
  ')
  # Kahn: deg_in = nº de dependentes "entrantes" no grafo reverso (queremos remover quem não é dependido)
  # como aresta é A->B (A depende de B), para remoção queremos processar nós com outdegree=0 (sem dependentes em S).
  # Implementar Kahn no grafo invertido: B->A
  echo "$EDGES" | awk -v set="$S" '
    BEGIN{
      split(set, SS, " "); for(i in SS){ if(SS[i]!=""){ nodes[SS[i]]=1 } }
    }
    {
      a=$1; b=$2;
      if(a!="" && b!=""){ # invertido: b -> a
        out[b]=(b in out)? out[b]" "a : a
        indeg[a]++
        nodes[a]=1; nodes[b]=1
      }
    }
    END{
      # fila = nós com indeg==0 no grafo invertido => sem dependentes no subgrafo
      for (n in nodes) if (indeg[n]==0) q[++qend]=n
      while(qstart<qend){
        n=q[++qstart]; print n
        split(out[n], L, " ")
        for (i in L){
          m=L[i]; if(m=="") continue
          indeg[m]--; if(indeg[m]==0) q[++qend]=m
        }
      }
    }'
}

pkg_remove_clean() {
  PKG="$1"
  VERFILE="$STATE_DIR/$PKG.version"
  FILELIST="$STATE_DIR/$PKG.files"

  [ -f "$VERFILE" ] || die "$PKG não está instalado."
  VERSION="$(cat "$VERFILE")"

  # carregar receita (se existir) para hook post_remove
  if [ -f "$RECIPES_DIR/$PKG.sh" ]; then load_recipe "$PKG"; else NAME="$PKG"; fi

  msg_info "Removendo ${PKG}-${VERSION}"

  if [ -f "$FILELIST" ]; then
    # remover arquivos (ignora ausentes)
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      f="/$rel"
      [ -f "$f" ] && rm -f "$f" || [ -L "$f" ] && rm -f "$f" || true
    done < "$FILELIST"

    # limpeza best-effort de diretórios vazios
    awk -F/ 'NF>1{ $NF=""; print "/"$0 }' OFS=/ "$FILELIST" \
      | sed 's:/*$::' | sort -u -r \
      | while read -r d; do [ -d "$d" ] && rmdir "$d" 2>/dev/null || true; done
  else
    msg_warn "Sem manifest ($FILELIST). Nenhum arquivo deletado."
  fi

  post_remove || true

  rm -f "$STATE_DIR/$PKG.version" "$STATE_DIR/$PKG.files" "$STATE_DIR/$PKG.deps"
  msg_ok "${PKG}-${VERSION} removido."
}

cmd_remove() {
  # aceita 1..N pacotes
  [ $# -ge 1 ] || die "Informe ao menos um pacote para remover"
  TARGETS="$*"

  if [ $CASCADE -eq 0 ] && [ $# -eq 1 ]; then
    # remoção simples com bloqueio se houver dependentes
    T="$1"
    # calcula dependentes diretos/indiretos instalados (exclui o próprio)
    CLOSURE=$(reverse_dependents_closure "$T" | tr ' ' '\n' | grep -v "^$" | grep -v "^$T$" || true)
    if [ -n "${CLOSURE-}" ]; then
      msg_err "Não é possível remover '$T' — pacotes dependem dele:"
      echo "$CLOSURE" | sed 's/^/  - /'
      echo "Use --cascade para remover também os dependentes acima (ordem segura)."
      exit 1
    fi
    # seguro, remover só T
    pkg_remove_clean "$T"
    return 0
  fi

  # CASCADE (ou vários pacotes): construir conjunto total e ordenar
  # 1) inicia com TARGETS; 2) adiciona dependentes reversos (fecho) se CASCADE=1
  if [ $CASCADE -eq 1 ]; then
    ALL=$(reverse_dependents_closure $TARGETS)
  else
    # sem cascade mas múltiplos alvos: ainda precisamos ordem topológica entre eles por segurança
    ALL="$TARGETS"
  fi

  # filtra apenas instalados
  INST=$(installed_pkgs)
  # intersect
  SET=""
  for p in $ALL; do
    echo "$INST" | grep -qx "$p" && SET="$SET $p" || true
  done
  [ -n "${SET# }" ] || { msg_warn "Nenhum dos pacotes informados está instalado."; exit 0; }

  ORDER=$(topo_remove_order $SET)

  # ORDER pode não conter todos (se algum isolado sem arestas). Completar.
  for p in $SET; do echo "$ORDER" | grep -qx "$p" || ORDER="$p
$ORDER"; done

  msg_info "Ordem de remoção (dependentes → dependências):"
  echo "$ORDER" | awk 'NF{print "  - "$0}'

  for p in $ORDER; do pkg_remove_clean "$p"; done
}

##### DEPENDÊNCIAS (build/install) #####
resolve_deps_recursive() {
  CUR="$NAME"
  echo " $VISITED_PACKAGES " | grep -qw " $CUR " && die "Ciclo de dependências detectado em: $CUR"
  VISITED_PACKAGES="$VISITED_PACKAGES $CUR"
  [ -n "${DEPENDS-}" ] || return 0
  for dep in $DEPENDS; do
    if is_installed "$dep"; then msg_ok "Dep já instalada: $dep"; continue; fi
    save_ctx; load_recipe "$dep"; resolve_deps_recursive; pkg_fetch; pkg_build; pkg_install; restore_ctx
  done
}

##### UPGRADE / SYNC / INDEX / SEARCH #####
cmd_upgrade() {
  PKG="$1"
  load_recipe "$PKG"
  if is_installed "$PKG"; then
    CUR="$(cat "$STATE_DIR/$PKG.version")"
    [ "$CUR" = "$VERSION" ] && { msg_ok "$PKG já na versão $CUR"; return 0; }
    msg_info "Upgrade: $PKG $CUR -> $VERSION"
  else
    msg_info "$PKG não instalado; será instalado."
  fi
  VISITED_PACKAGES=""; resolve_deps_recursive; pkg_fetch; pkg_build; pkg_install
}
cmd_sync() {
  [ -d "$RECIPES_DIR/.git" ] || die "$RECIPES_DIR não é um repositório git"
  msg_info "Sincronizando receitas (git pull)…"
  (cd "$RECIPES_DIR" && git pull --ff-only)
  msg_ok "Receitas atualizadas."
}
cmd_index() {
  INDEX_FILE="$PKG_REPO/PACKAGES"
  : > "$INDEX_FILE"
  for pkg in "$PKG_REPO"/*$PKG_EXT; do
    [ -f "$pkg" ] || continue
    TMP=$(mktemp -d)
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
cmd_search() {
  TERM="${1-}"; [ -n "$TERM" ] || die "Informe um termo. Ex: $0 search nano"
  INDEX_FILE="$PKG_REPO/PACKAGES"; [ -f "$INDEX_FILE" ] || die "Nenhum INDEX. Rode: $0 index"
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
# flags globais
while [ "${1-}" ]; do
  case "$1" in
    --strip) STRIP_BINARIES=1; shift ;;
    --cascade|-c) CASCADE=1; shift ;;
    -h|--help) print_usage; exit 0 ;;
    build|b|install|i|remove|r|upgrade|u|sync|index|search) break ;;
    *) break ;;
  esac
done

ACTION="${1-}"; shift || true
case "${ACTION-}" in
  build|b)
    PKG="${1-}"; [ -n "$PKG" ] || die "Informe o pacote"
    load_recipe "$PKG"; VISITED_PACKAGES=""; resolve_deps_recursive; pkg_fetch; pkg_build
    ;;
  install|i)
    PKG="${1-}"; [ -n "$PKG" ] || die "Informe o pacote"
    load_recipe "$PKG"; VISITED_PACKAGES=""; resolve_deps_recursive; pkg_install
    ;;
  remove|r)
    [ $# -ge 1 ] || die "Informe ao menos um pacote para remover"
    cmd_remove "$@"
    ;;
  upgrade|u)
    PKG="${1-}"; [ -n "$PKG" ] || die "Informe o pacote"
    cmd_upgrade "$PKG"
    ;;
  sync)
    cmd_sync
    ;;
  index)
    cmd_index
    ;;
  search)
    TERM="${1-}"; [ -n "$TERM" ] || die "Informe o termo de busca"
    cmd_search "$TERM"
    ;;
  *) print_usage; exit 1 ;;
esac
