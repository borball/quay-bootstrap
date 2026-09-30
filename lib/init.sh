# shellcheck shell=bash
# Init phase: create the first (super)user through /api/v1/user/initialize and keep its
# credentials and OAuth token in the output secret (<registry ns>/<admin.outputSecret>).

# The output secret is mirrored in $CREDS_DIR (one file per key) and written back whole.
creds_load() {
  [[ -z ${CREDS_LOADED-} ]] || return 0
  CREDS_DIR="$WORKDIR/creds"
  mkdir -p "$CREDS_DIR"
  local json k
  json=$(oc get secret "$CREDS_SECRET" -n "$QB_NS" -o json 2>/dev/null) || json='{}'
  for k in $(jq -r '.data // {} | keys[]' <<<"$json"); do
    jq -r --arg k "$k" '.data[$k]' <<<"$json" | base64 --decode >"$CREDS_DIR/$k"
  done
  CREDS_LOADED=true
}

creds_get() { [[ ! -f $CREDS_DIR/$1 ]] || cat "$CREDS_DIR/$1"; }
creds_set() { printf '%s' "$2" >"$CREDS_DIR/$1"; }

creds_save() {
  if [[ $DRY_RUN == true ]]; then
    log "[dry-run] would update secret $QB_NS/$CREDS_SECRET"
    return 0
  fi
  oc create secret generic "$CREDS_SECRET" -n "$QB_NS" --from-file="$CREDS_DIR" --dry-run=client -o yaml \
    | labeled | kapply
}

token_valid() {
  local saved=${QUAY_TOKEN-}
  set_token "$1"
  api GET /api/v1/user/
  if [[ $API_STATUS == 200 ]]; then return 0; fi
  if [[ -n $saved ]]; then set_token "$saved"; else QUAY_TOKEN=''; fi
  return 1
}

# Resolve admin.token at top level: inside an `if` condition bash ignores errexit, so a broken
# reference would only print an error and carry on.
resolve_config_token() {
  if [[ -z ${CONFIG_TOKEN_RESOLVED-} ]]; then
    CONFIG_TOKEN=$(resolve_value .admin.token)
    CONFIG_TOKEN_RESOLVED=true
  fi
}

# Use a token from config (admin.token) or from the output secret, if one works.
# Callers must run creds_load and resolve_config_token first.
load_admin_token() {
  local t
  [[ -z ${QUAY_TOKEN-} ]] || return 0
  if [[ -n $CONFIG_TOKEN ]]; then
    if token_valid "$CONFIG_TOKEN"; then debug "using admin.token from config"; return 0; fi
    warn "admin.token from the config was rejected by Quay (HTTP $API_STATUS)"
  fi
  t=$(creds_get token)
  if [[ -n $t ]] && token_valid "$t"; then debug "using token from secret $CREDS_SECRET"; return 0; fi
  return 1
}

init_admin() {
  step "Admin user"
  ensure_api_context
  creds_load
  resolve_config_token
  if load_admin_token; then
    log "admin token is valid ($(jq -r '.username' <<<"$API_BODY")); skipping initialization"
    return 0
  fi

  local pw token generated=false
  pw=$(resolve_value .admin.password)
  if [[ -z $pw || $pw == __generate__ ]]; then
    pw=$(creds_get password)
    if [[ -z $pw ]]; then
      pw=$(gen_password)
      generated=true
    fi
  fi
  ((${#pw} >= 8)) || die "admin password must be at least 8 characters"

  # Persist the credentials before initializing so they can never be lost.
  creds_set username "$ADMIN_USER"
  creds_set password "$pw"
  creds_set email "$ADMIN_EMAIL"
  creds_set endpoint "https://$QUAY_HOST"
  [[ -z $QUAY_CA_FILE ]] || cp "$QUAY_CA_FILE" "$CREDS_DIR/ca.crt"
  creds_save

  log "initializing first user $ADMIN_USER"
  QUAY_TOKEN=''
  api POST /api/v1/user/initialize "$(jq -n --arg u "$ADMIN_USER" --arg p "$pw" --arg e "$ADMIN_EMAIL" \
    '{username: $u, password: $p, email: $e, access_token: true}')"
  [[ $DRY_RUN != true ]] || return 0
  case $API_STATUS in
    200 | 201) ;;
    *)
      # Don't leave behind a password that belongs to no account.
      if [[ $generated == true ]]; then
        rm -f "$CREDS_DIR/password"
        creds_save
      fi
      if grep -qi 'non-empty' <<<"$API_BODY"; then
        die "Quay already has users, so the admin cannot be initialized again. Create an OAuth token for a superuser in the UI and pass it as admin.token (e.g. {from: env:QUAY_TOKEN})"
      fi
      die "user initialization failed (HTTP $API_STATUS): $(api_error)"
      ;;
  esac
  token=$(jq -r '.access_token // empty' <<<"$API_BODY")
  [[ -n $token ]] || die "initialization response did not contain an access token"
  set_token "$token"
  creds_set token "$token"
  creds_save
  log "admin $ADMIN_USER created; credentials stored in secret $QB_NS/$CREDS_SECRET"
}
