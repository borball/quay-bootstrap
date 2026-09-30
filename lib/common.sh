# shellcheck shell=bash
# Shared helpers: logging, config access, secret references, apply/wait wrappers.
# Written for bash >= 3.2 (macOS default): no associative arrays, no mapfile.

MANAGED_BY_KEY="app.kubernetes.io/managed-by"
MANAGED_BY_VALUE="quay-bootstrap"
FIELD_MANAGER="quay-bootstrap"

if [[ -t 2 ]]; then
  _C_RESET=$'\033[0m' _C_BOLD=$'\033[1m' _C_RED=$'\033[31m' _C_YEL=$'\033[33m' _C_BLU=$'\033[34m' _C_DIM=$'\033[2m'
else
  _C_RESET='' _C_BOLD='' _C_RED='' _C_YEL='' _C_BLU='' _C_DIM=''
fi

_ts()  { date +%H:%M:%S; }
log()  { printf '%s %s\n' "${_C_DIM}$(_ts)${_C_RESET}" "$*" >&2; }
warn() { printf '%s %sWARN%s  %s\n' "${_C_DIM}$(_ts)${_C_RESET}" "$_C_YEL" "$_C_RESET" "$*" >&2; }
die()  { printf '%s %sERROR%s %s\n' "${_C_DIM}$(_ts)${_C_RESET}" "$_C_RED" "$_C_RESET" "$*" >&2; exit 1; }
step() { printf '\n%s==> %s%s\n' "$_C_BOLD$_C_BLU" "$*" "$_C_RESET" >&2; }
debug() {
  if [[ ${VERBOSE:-false} == true ]]; then
    printf '%s DEBUG %s\n' "${_C_DIM}$(_ts)" "$*${_C_RESET}" >&2
  fi
  return 0
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

# ---------------------------------------------------------------------------
# Config access (yq v4). Missing keys and nulls resolve to the default.
# ---------------------------------------------------------------------------
cfg() { # cfg <yq-path> [default]
  local v
  v=$(yq e "$1" "$CONFIG") || die "cannot evaluate config path $1"
  if [[ -z $v || $v == null ]]; then v=${2-}; fi
  printf '%s' "$v"
}

cfg_has() { [[ $(yq e "$1 != null" "$CONFIG") == true ]]; }

cfg_len() {
  local n
  n=$(yq e "($1) | length" "$CONFIG")
  [[ $n =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

abs_path() {
  if [[ $1 == /* ]]; then printf '%s' "$1"; else printf '%s' "$CONFIG_DIR/$1"; fi
}

# Resolve a value that is either a literal or a reference object:
#   {from: env:VAR} | {from: file:path} | {from: secret:ns/name/key} | {from: generate}
# Prints the value; prints "__generate__" for {from: generate}; prints nothing if unset.
resolve_value() {
  local path=$1 tag ref
  tag=$(yq e "$path | tag" "$CONFIG")
  case $tag in
    '!!null') return 0 ;;
    '!!map') ref=$(cfg "$path.from") ;;
    *) cfg "$path"; return 0 ;;
  esac
  case $ref in
    env:*)
      local var=${ref#env:}
      [[ $var =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "$path: invalid environment variable name '$var'"
      [[ -n ${!var-} ]] || die "$path: environment variable $var is not set"
      printf '%s' "${!var}"
      ;;
    file:*)
      local f
      f=$(abs_path "${ref#file:}")
      [[ -r $f ]] || die "$path: file not readable: $f"
      cat "$f"
      ;;
    secret:*)
      local ns name key v
      IFS=/ read -r ns name key <<<"${ref#secret:}"
      [[ -n $ns && -n $name && -n $key ]] || die "$path: expected secret:<namespace>/<name>/<key>"
      v=$(secret_key "$ns" "$name" "$key") || true
      [[ -n $v ]] || die "$path: key '$key' not found in secret $ns/$name"
      printf '%s' "$v"
      ;;
    generate) printf '__generate__' ;;
    *) die "$path: unsupported reference '$ref' (use env:, file:, secret: or generate)" ;;
  esac
}

# ---------------------------------------------------------------------------
# Cluster helpers
# ---------------------------------------------------------------------------
secret_key() { # secret_key <ns> <name> <key>  -> decoded value (fails if the secret is missing)
  local json
  json=$(oc get secret "$2" -n "$1" -o json 2>/dev/null) || return 1
  jq -r --arg k "$3" '.data[$k] // empty' <<<"$json" | base64 --decode
}

labeled() { # add the managed-by label to a manifest on stdin
  oc label --local -f - "$MANAGED_BY_KEY=$MANAGED_BY_VALUE" -o yaml
}

# Apply a manifest from stdin with server-side apply (no last-applied annotation,
# so Secret data is not duplicated). In dry-run mode the manifest is printed instead.
kapply() {
  local manifest
  manifest=$(cat)
  if [[ $DRY_RUN == true ]]; then
    log "[dry-run] would apply:"
    printf '%s\n' "$manifest" \
      | yq e 'with(select(.kind == "Secret" and .data != null); .data[] = "<redacted>")' - \
      | sed 's/^/      /' >&2
    return 0
  fi
  printf '%s\n' "$manifest" \
    | oc apply --server-side --force-conflicts --field-manager="$FIELD_MANAGER" -f - >&2
}

run() { # run a mutating command, or only print it in dry-run mode
  if [[ $DRY_RUN == true ]]; then
    log "[dry-run] $*"
  else
    "$@" >&2
  fi
}

wait_until() { # wait_until <timeout-s> <interval-s> <description> <command...>
  local timeout=$1 interval=$2 desc=$3 start=$SECONDS
  shift 3
  if [[ $DRY_RUN == true ]]; then
    log "[dry-run] skipping wait: $desc"
    return 0
  fi
  log "waiting for $desc (timeout ${timeout}s)"
  until "$@"; do
    if (( SECONDS - start >= timeout )); then die "timed out waiting for $desc"; fi
    sleep "$interval"
  done
}

ensure_namespace() {
  oc get namespace "$1" >/dev/null 2>&1 && return 0
  log "creating namespace $1"
  kapply <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $1
  labels:
    $MANAGED_BY_KEY: $MANAGED_BY_VALUE
EOF
}

oc_exists() { oc get "$@" >/dev/null 2>&1; }
sc_exists() { oc_exists storageclass "$1"; }

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi
}

version_le() { # version_le <a> <b>  -> true if a <= b
  [[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1) == "$1" ]]
}

gen_password() {
  local p
  p=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')
  printf '%s' "${p:0:24}"
}

redact_json() {
  jq -c 'walk(if type == "object" then with_entries(if (.key | test("pass|secret|token"; "i")) then .value = "***" else . end) else . end)' 2>/dev/null \
    || printf '<unparseable body>'
}
