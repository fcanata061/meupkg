#!/bin/sh
# meupkg — gerenciador minimalista (source -> pacote -> binário -> install)
# Requisitos: sh, awk, sed, grep, tar, gzip, sha256sum, fakeroot, file, curl ou wget, git (p/ sync), xargs
set -eu

##### CONFIG #####
RECIPES_DIR="/var/lib/meupkg/recipes"   # receitas: <nome>.sh
WORK_DIR="/tmp/meupkg"                  # área de trabalho
BUILD_DIR="$WORK_DIR/build"             # fontes extraídas/compiladas
SRC_DIR="$WORK_DIR/src"                 # tarballs baixados
PKGROOT="$WORK_DIR/pkgroot"             # DESTDIR (raiz temporária por pacote)
PKG_REPO="/var/cache/meupkg/packages"   # repositório local de pacotes binários
STATE_DIR="/var/lib/meupkg/state"       # estado (versão/arquivos/deps/provides)
PKG_EXT=".tar.gz"                       # formato do pacote binário

mkdir -p "$RECIPES_DIR" "$BUILD_DIR" "$SRC_DIR" "$PKGROOT" "$PKG_REPO" "$STATE_DIR"

##### FLAGS/ESTADO #####
STRIP_BINARIES=0
CASCADE=0                 # remove dependentes automaticamente
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
Uso: $0 [--strip] [--cascade|-c] {build|b|install|i|remove|r|upgrade|u|verify|sync|index|repo-add|search} <args>

  --strip           Strip ELF na hora do empacotamento
  --cascade, -c     Em 'remove': remove alvo + dependentes (ordem topológica)

Comandos:
  build|b <pkg>        Resolve deps, compila e gera pacote binário (não instala)
  install|i <pkg>      Resolve deps e instala a versão da receita
  remove|r <pkg...>    Remove pacote(s); bloqueia se houver dependentes (a menos que --cascade)
  upgrade|u <pkg>      Rebuild + instala se a receita tiver versão mais nova
  verify <pkg>         Verifica integridade (sha256) dos arquivos instalados
  sync                 git pull no diretório de receitas
  index                Gera PACKAGES e PACKAGES.gz a partir do repositório local
  repo-add             Alias de 'index' (gera PACKAGES + PACKAGES.gz)
  search <termo>       Busca no PACKAGES
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

save_ctx() {
  SAV_NAME="${NAME-}"; SAV_VERSION="${VERSION-}"; SAV_SOURCE_URL="${SOURCE_URL-}"
  SAV_CHECKSUM="${CHECKSUM-}"; SAV_DEPENDS="${DEPENDS-}"; SAV_PROVIDES="${PROVIDES-}"; SAV_REPLACES="${REPLACES-}"
}
restore_ctx() {
  NAME="${SAV_NAME-}"; VERSION="${SAV_VERSION-}"; SOURCE_URL="${SAV_SOURCE_URL-}"
  CHECKSUM="${SAV_CHECKSUM-}"; DEPENDS="${SAV_DEPENDS-}"; PROVIDES="${SAV_PROVIDES-}"; REPLACES="${SAV_REPLACES-}"
}

is_installed() { [ -f "$STATE_DIR/$1.version" ]; }
installed_pkgs() { ls "$STATE_DIR"/*.version 2>/dev/null | xargs -r -n1 basename | sed 's/\.version$//' || true; }

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
  unset NAME VERSION SOURCE_URL CHECKSUM DEPENDS PROVIDES REPLACES
  unset_hooks
  # shellcheck disable=SC1090
  . "$FILE"
  define_noop_hooks
  : "${NAME:?Receita sem NAME}"; : "${VERSION:?Receita sem VERSION}"; : "${SOURCE_URL:?Receita sem SOURCE_URL}"
  DEPENDS="${DEPENDS-}"; CHECKSUM="${CHECKSUM-}"; PROVIDES="${PROVIDES-}"; REPLACES="${REPLACES-}"
}

##### META + MANIFEST #####
write_meta() {
  META="$1/meta.txt"
  {
    echo "NAME=$NAME"
    echo "VERSION=$VERSION"
    echo "DEPENDS=${DEPENDS-}"
    echo "PROVIDES=${PROVIDES-}"
    echo "REPLACES=${REPLACES-}"
  } > "$META"
}
write_manifest_with_sha256() {
  # duas colunas: SHA256<duas espaços>caminho_relativo
  ( cd "$1" && find . -type f -o -type l | sed 's|^\./||' | sort \
      | while IFS= read -r p; do
          if [ -f "$p" ]; then
            sha256sum "$p" | awk '{print $1"  "$2}'
          else
            # link simbólico: sem hash de conteúdo (marca especial)
            printf "SYMLINK  %s\n" "$p"
          fi
        done
  ) > "$1/manifest.txt"
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
  write_manifest_with_sha256 "$PKGDIR"
  pkg_package
}

pkg_package() {
  PKG_FILE="$PKG_REPO/${NAME}-${VERSION}${PKG_EXT}"
  msg_info "Empacotando -> $PKG_FILE"
  (cd "$PKGROOT/$NAME" && fakeroot tar -czf "$PKG_FILE" .)
  msg_ok "Pacote criado: $PKG_FILE"
}

##### PROVIDER/REPLACES (RESOLUÇÃO) #####
deps_of() { [ -f "$STATE_DIR/$1.deps" ] && tr ' ' '\n' < "$STATE_DIR/$1.deps" | sed '/^$/d' || true; }
provides_of() { [ -f "$STATE_DIR/$1.provides" ] && tr ' ' '\n' < "$STATE_DIR/$1.provides" | sed '/^$/d' || true; }

provider_of() {
  # primeiro: o próprio nome instalado
  if is_installed "$1"; then echo "$1"; return 0; fi
  # senão: alguém que proveja virtual '$1'
  for p in $(installed_pkgs); do
    if provides_of "$p" | grep -qx "$1"; then echo "$p"; return 0; fi
  done
  return 1
}

find_recipe_by_provides() {
  # procura uma receita cujo PROVIDES contenha o nome dado
  term="$1"
  for f in "$RECIPES_DIR"/*.sh; do
    [ -f "$f" ] || continue
    unset NAME VERSION SOURCE_URL CHECKSUM DEPENDS PROVIDES REPLACES
    # shellcheck disable=SC1090
    . "$f"
    if [ -n "${PROVIDES-}" ] && printf "%s\n" $PROVIDES | grep -qx "$term"; then
      bn "$f" | sed 's/\.sh$//'
      return 0
    fi
  done
  return 1
}

##### DEPS (build/install) #####
resolve_deps_recursive() {
  CUR="$NAME"
  echo " $VISITED_PACKAGES " | grep -qw " $CUR " && die "Ciclo de dependências detectado em: $CUR"
  VISITED_PACKAGES="$VISITED_PACKAGES $CUR"
  [ -n "${DEPENDS-}" ] || return 0
  for dep in $DEPENDS; do
    if provider_of "$dep" >/dev/null 2>&1; then
      prov="$(provider_of "$dep" || true)"
      if [ -n "$prov" ]; then
        msg_ok "Dep '${dep}' satisfeita por instalado: $prov"
        continue
      fi
    fi
    # há receita explícita?
    if [ -f "$RECIPES_DIR/$dep.sh" ]; then
      save_ctx; load_recipe "$dep"
    else
      # procurar receita que PROVIDES "dep"
      prov_recipe="$(find_recipe_by_provides "$dep" || true)"
      [ -n "$prov_recipe" ] || die "Dependência '${dep}' não encontrada e nenhum pacote PROVIDES a satisfaz."
      save_ctx; load_recipe "$prov_recipe"
    fi
    resolve_deps_recursive
    pkg_fetch; pkg_build; pkg_install
    restore_ctx
  done
}
##### INSTALL (usa manifest, meta; respeita REPLACES) #####
pre_remove_replaced_if_needed() {
  # remove pacotes listados em REPLACES, se estiverem instalados (com cascade)
  [ -n "${REPLACES-}" ] || return 0
  TOREM=""
  for rp in $REPLACES; do
    is_installed "$rp" && TOREM="$TOREM $rp" || true
  done
  [ -z "${TOREM# }" ] && return 0
  msg_warn "$NAME REPLACES:${TOREM}; removendo substituídos (cascade)…"
  # remoção em cascade garante ordem correta
  CASCADE_SAV=$CASCADE; CASCADE=1
  cmd_remove $TOREM
  CASCADE=$CASCADE_SAV
}

pkg_install() {
  PKG_FILE="$PKG_REPO/${NAME}-${VERSION}${PKG_EXT}"
  if [ ! -f "$PKG_FILE" ]; then
    msg_warn "Pacote binário não encontrado; construindo ${NAME}-${VERSION}"
    pkg_fetch; pkg_build
  fi

  pre_remove_replaced_if_needed

  msg_info "Instalando ${NAME}-${VERSION}"
  TMP=$(mktemp -d)
  tar_extract "$PKG_FILE" "$TMP"

  # ler meta/manifest do pacote
  [ -f "$TMP/meta.txt" ] || die "Pacote sem meta.txt"
  [ -f "$TMP/manifest.txt" ] || die "Pacote sem manifest.txt"

  # registrar deps/provides para o estado
  DEPFILE="$STATE_DIR/$NAME.deps"
  PROVFILE="$STATE_DIR/$NAME.provides"
  grep '^DEPENDS=' "$TMP/meta.txt"  | sed 's/^DEPENDS=//'  > "$DEPFILE"  || echo "" > "$DEPFILE"
  grep '^PROVIDES=' "$TMP/meta.txt" | sed 's/^PROVIDES=//' > "$PROVFILE" || echo "" > "$PROVFILE"

  # registrar manifest no estado
  cp "$TMP/manifest.txt" "$STATE_DIR/$NAME.files"

  # não instalar meta/manifest
  rm -f "$TMP/meta.txt" "$TMP/manifest.txt"

  # copiar para /
  fakeroot cp -a "$TMP"/. /
  rm -rf "$TMP"

  echo "$VERSION" > "$STATE_DIR/$NAME.version"

  post_install || true
  msg_ok "${NAME}-${VERSION} instalado."
}

##### GRAFO DE DEPENDÊNCIAS (A -> B se A depende de B) #####
build_graph() {
  for p in $(installed_pkgs); do
    # DEPENDS declaradas em nomes lógicos; resolvemos para provedores instalados
    for d in $(deps_of "$p"); do
      prov="$(provider_of "$d" || true)"
      if [ -n "$prov" ]; then
        echo "$p $prov"
      else
        # depende de algo não instalado (inconsistência), ignore na remoção
        :
      fi
    done
  done
}

reverse_dependents_closure() {
  # entrada: args = targets; saída: todos os dependentes (diretos+indiretos) incluindo alvos
  EDGES=$(build_graph)
  echo "$EDGES" | awk -v targets="$*" '
    BEGIN{
      n=split(targets, T, " ");
      for(i=1;i<=n;i++){ if(T[i]!="") queue[T[i]]=1; }
    }
    { dep=$2; use=$1; rev[dep]=(dep in rev)? rev[dep]" "use : use }
    END{
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
      for (k in queue) if(k!="") print k
    }'
}

topo_remove_order() {
  # produz ordem: dependentes → dependências (segura para remover)
  S="$*"
  EDGES=$(build_graph | awk -v set="$S" '
    BEGIN{ split(set, SS, " "); for(i in SS) if(SS[i]!="") keep[SS[i]]=1 }
    { if(keep[$1] && keep[$2]) print $0 }
  ')
  echo "$EDGES" | awk -v set="$S" '
    BEGIN{
      split(set, SS, " "); for(i in SS) if(SS[i]!="") nodes[SS[i]]=1
    }
    { a=$1; b=$2; out[b]=(b in out)? out[b]" "a : a; indeg[a]++; nodes[a]=1; nodes[b]=1 }
    END{
      for (n in nodes) if (indeg[n]==0) q[++qend]=n
      while(qstart<qend){
        n=q[++qstart]; print n
        split(out[n], L, " ")
        for (i in L){ m=L[i]; if(m!=""){ indeg[m]--; if(indeg[m]==0) q[++qend]=m } }
      }
    }'
}

##### REMOVE (limpo com manifest + bloqueios + cascade) #####
pkg_remove_clean() {
  PKG="$1"
  VERFILE="$STATE_DIR/$PKG.version"
  FILELIST="$STATE_DIR/$PKG.files"

  [ -f "$VERFILE" ] || die "$PKG não está instalado."
  VERSION="$(cat "$VERFILE")"

  # carrega receita (se existir) para hook post_remove
  if [ -f "$RECIPES_DIR/$PKG.sh" ]; then load_recipe "$PKG"; else NAME="$PKG"; fi

  msg_info "Removendo ${PKG}-${VERSION}"

  if [ -f "$FILELIST" ]; then
    # Remoção baseada no manifest (2 colunas: HASH/flag  caminho)
    awk '{ $1=""; sub(/^  /,""); print }' "$FILELIST" \
      | while IFS= read -r rel; do
          [ -n "$rel" ] || continue
          f="/$rel"
          [ -f "$f" ] && rm -f "$f" || [ -L "$f" ] && rm -f "$f" || true
        done

    # limpeza de diretórios vazios (best-effort)
    awk '{ $1=""; sub(/^  /,""); print }' "$FILELIST" \
      | awk -F/ 'NF>1{ $NF=""; print "/"$0 }' OFS=/ \
      | sed 's:/*$::' | sort -u -r \
      | while read -r d; do [ -d "$d" ] && rmdir "$d" 2>/dev/null || true; done
  else
    msg_warn "Sem manifest ($FILELIST). Nenhum arquivo deletado."
  fi

  post_remove || true
  rm -f "$STATE_DIR/$PKG.version" "$STATE_DIR/$PKG.files" "$STATE_DIR/$PKG.deps" "$STATE_DIR/$PKG.provides"
  msg_ok "${PKG}-${VERSION} removido."
}

cmd_remove() {
  [ $# -ge 1 ] || die "Informe ao menos um pacote para remover"
  TARGETS="$*"

  if [ $CASCADE -eq 0 ] && [ $# -eq 1 ]; then
    T="$1"
    CLOSURE=$(reverse_dependents_closure "$T" | grep -v "^$" | grep -v "^$T$" || true)
    if [ -n "${CLOSURE-}" ]; then
      msg_err "Não é possível remover '$T' — pacotes dependem dele:"
      echo "$CLOSURE" | sed 's/^/  - /'
      echo "Use --cascade para remover também os dependentes acima (ordem segura)."
      exit 1
    fi
    pkg_remove_clean "$T"
    return 0
  fi

  # CASCADE (ou lista): calcula fecho reverso + ordem topológica
  if [ $CASCADE -eq 1 ]; then
    ALL=$(reverse_dependents_closure $TARGETS)
  else
    ALL="$TARGETS"
  fi

  # filtra apenas os instalados
  INST=$(installed_pkgs)
  SET=""; for p in $ALL; do echo "$INST" | grep -qx "$p" && SET="$SET $p" || true; done
  [ -n "${SET# }" ] || { msg_warn "Nenhum dos pacotes informados está instalado."; exit 0; }

  ORDER=$(topo_remove_order $SET)
  # adiciona isolados que não apareceram
  for p in $SET; do echo "$ORDER" | grep -qx "$p" || ORDER="$p
$ORDER"; done

  msg_info "Ordem de remoção (dependentes → dependências):"
  echo "$ORDER" | awk 'NF{print "  - "$0}'

  for p in $ORDER; do pkg_remove_clean "$p"; done
}

##### UPGRADE / VERIFY / SYNC / INDEX / SEARCH #####
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

cmd_verify() {
  PKG="$1"
  [ -n "$PKG" ] || die "Informe o pacote"
  [ -f "$STATE_DIR/$PKG.files" ] || die "$PKG não está instalado ou sem manifest"
  FAILED=0; TOTAL=0; OKC=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    hash="$(printf "%s" "$line" | awk '{print $1}')"
    rel="$(printf "%s" "$line" | awk '{ $1=""; sub(/^  /,""); print }')"
    f="/$rel"
    TOTAL=$((TOTAL+1))
    if [ "$hash" = "SYMLINK" ]; then
      [ -L "$f" ] && OKC=$((OKC+1)) || { msg_err "LINK ausente: $f"; FAILED=$((FAILED+1)); }
      continue
    fi
    if [ -f "$f" ]; then
      cur="$(sha256sum "$f" | awk '{print $1}')"
      if [ "$cur" = "$hash" ]; then
        OKC=$((OKC+1))
      else
        msg_err "HASH difere: $f"
        FAILED=$((FAILED+1))
      fi
    else
      msg_err "Arquivo ausente: $f"
      FAILED=$((FAILED+1))
    fi
  done < "$STATE_DIR/$PKG.files"
  msg_info "Verificação: $OKC OK de $TOTAL; falhas=$FAILED"
  [ $FAILED -eq 0 ] && msg_ok "Integridade OK" || exit 1
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
  gzip -c "$INDEX_FILE" > "$PKG_REPO/PACKAGES.gz"
  msg_ok "INDEX gerado: $INDEX_FILE e $PKG_REPO/PACKAGES.gz"
}

cmd_search() {
  TERM="${1-}"; [ -n "$TERM" ] || die "Informe um termo. Ex: $0 search nano"
  INDEX_FILE="$PKG_REPO/PACKAGES"; [ -f "$INDEX_FILE" ] || die "Nenhum INDEX. Rode: $0 index"
  awk -v term="$TERM" -v GRN="$GRN" -v NC="$NC" '
    BEGIN { RS="---"; IGNORECASE=1 }
    {
      if ($0 ~ term) {
        name=""; version=""; deps=""; prov=""
        n=split($0, L, "\n")
        for (i=1;i<=n;i++) {
          if (L[i] ~ /^NAME=/)     name=substr(L[i],6)
          if (L[i] ~ /^VERSION=/)  version=substr(L[i],9)
          if (L[i] ~ /^DEPENDS=/)  deps=substr(L[i],9)
          if (L[i] ~ /^PROVIDES=/) prov=substr(L[i],10)
        }
        if (name!="") {
          printf "%s%s%s %s\n", GRN, name, NC, version
          if (deps!="") printf "   deps: %s\n", deps
          if (prov!="") printf "   provides: %s\n", prov
        }
      }
    }
  ' "$INDEX_FILE"
}

##### CLI #####
# flags globais
while [ "${1-}" ]; do
  case "$1" in
    --strip) STRIP_BINARIES=1; shift ;;
    --cascade|-c) CASCADE=1; shift ;;
    -h|--help) print_usage; exit 0 ;;
    build|b|install|i|remove|r|upgrade|u|verify|sync|index|repo-add|search) break ;;
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
  verify)
    PKG="${1-}"; [ -n "$PKG" ] || die "Informe o pacote"
    cmd_verify "$PKG"
    ;;
  sync)
    cmd_sync
    ;;
  index|repo-add)
    cmd_index
    ;;
  search)
    TERM="${1-}"; [ -n "$TERM" ] || die "Informe o termo de busca"
    cmd_search "$TERM"
    ;;
  *)
    print_usage; exit 1 ;;
esac
