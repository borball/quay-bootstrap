# shellcheck shell=bash
# Config loading/validation and cluster preflight checks (read-only).

NAME_RE='^[a-z0-9]+([._-][a-z0-9]+)*$'
ROBOT_RE='^[a-z][a-z0-9_]{1,254}$'
TEAM_RE='^[a-z][a-z0-9]+$'
COMPONENT_KINDS="clair clairpostgres postgres redis objectstorage route tls horizontalpodautoscaler mirror monitoring quay"

load_config() {
  [[ -r $CONFIG ]] || die "config file not readable: $CONFIG"
  yq e '.' "$CONFIG" >/dev/null 2>&1 || die "config file is not valid YAML: $CONFIG"
  CONFIG_DIR=$(cd "$(dirname "$CONFIG")" && pwd)

  OP_NS=$(cfg .operator.namespace openshift-operators)
  OP_SOURCE=$(cfg .operator.source redhat-operators)
  OP_SOURCE_NS=$(cfg .operator.sourceNamespace openshift-marketplace)
  OP_CHANNEL=$(cfg .operator.channel)
  OP_CSV=$(cfg .operator.csv)

  QB_NAME=$(cfg .registry.name quay)
  QB_NS=$(cfg .registry.namespace quay-enterprise)
  QUAY_HOST=$(cfg .registry.hostname)
  ROUTE_MANAGED=$(cfg .registry.route.managed true)
  TLS_MODE=$(cfg .registry.tls.mode ingress)
  MIN_VALID_DAYS=$(cfg .registry.tls.minValidDays 30)
  CONFIG_SECRET="${QB_NAME}-config-bundle"
  ODF_NS=$(cfg .storage.odfNamespace openshift-storage)

  ADMIN_USER=$(cfg .admin.username quayadmin)
  ADMIN_EMAIL=$(cfg .admin.email "${ADMIN_USER}@example.com")
  CREDS_SECRET=$(cfg .admin.outputSecret "${QB_NAME}-bootstrap-creds")

  API_INSECURE=$(cfg .api.insecure false)
  OPERATOR_TIMEOUT=$(cfg .timeouts.operator 900)
  REGISTRY_TIMEOUT=$(cfg .timeouts.registry 1800)
}

validate_config() {
  local b
  for b in "$ROUTE_MANAGED" "$API_INSECURE"; do
    [[ $b == true || $b == false ]] || die "boolean expected, got '$b'"
  done
  [[ $OPERATOR_TIMEOUT =~ ^[0-9]+$ && $REGISTRY_TIMEOUT =~ ^[0-9]+$ && $MIN_VALID_DAYS =~ ^[0-9]+$ ]] \
    || die "timeouts and registry.tls.minValidDays must be integers"
  [[ $ADMIN_USER =~ $NAME_RE ]] || die "admin.username '$ADMIN_USER' is not a valid Quay username"

  case $TLS_MODE in
    ingress | custom | selfsigned) ;;
    *) die "registry.tls.mode must be ingress, custom or selfsigned (got '$TLS_MODE')" ;;
  esac
  if [[ $TLS_MODE != ingress && -z $QUAY_HOST ]]; then
    die "registry.hostname is required when registry.tls.mode is $TLS_MODE"
  fi
  if [[ $ROUTE_MANAGED == false ]]; then
    [[ -n $QUAY_HOST ]] || die "registry.hostname is required when registry.route.managed is false"
    [[ $TLS_MODE != ingress ]] || die "registry.route.managed=false requires tls.mode custom or selfsigned"
  fi
  if [[ $TLS_MODE == custom ]]; then
    local n=0 s
    for s in file secret certManager; do cfg_has ".registry.tls.source.$s" && n=$((n + 1)); done
    [[ $n == 1 ]] || die "registry.tls.source must define exactly one of: file, secret, certManager"
  fi

  local kind k
  for k in $(yq e '.registry.components // {} | keys | .[]' "$CONFIG"); do
    [[ " $COMPONENT_KINDS " == *" $k "* ]] || die "unknown component '$k' in registry.components"
    case $k in objectstorage | route | tls)
      warn "registry.components.$k is derived from the storage/route/tls settings and is ignored" ;;
    esac
    kind=$(cfg ".registry.components.$k")
    [[ $kind == true || $kind == false ]] || die "registry.components.$k must be true or false"
  done

  local i j n_orgs org seen=" "
  n_orgs=$(cfg_len .organizations)
  for ((i = 0; i < n_orgs; i++)); do
    local p=".organizations[$i]"
    org=$(cfg "$p.name")
    [[ $org =~ $NAME_RE && ${#org} -ge 2 ]] || die "$p.name '$org' is not a valid organization name"
    [[ $seen != *" $org "* ]] || die "organization '$org' is defined twice"
    [[ $org != "$ADMIN_USER" ]] || die "organization '$org' collides with the admin username"
    seen="$seen$org "

    if cfg_has "$p.proxyCache"; then
      [[ $(cfg_len "$p.repositories") == 0 ]] \
        || die "organization '$org' is a proxy-cache org and cannot also define repositories (proxy cache is per organization)"
      [[ -n $(cfg "$p.proxyCache.upstream") ]] || die "$p.proxyCache.upstream is required"
      local e; e=$(cfg "$p.proxyCache.expirationSeconds" 86400)
      [[ $e =~ ^[0-9]+$ ]] || die "$p.proxyCache.expirationSeconds must be an integer"
    fi

    # Robots and teams referenced below must be declared in the same organization
    # ("owners" always exists in a Quay organization).
    local robots=" " teams=" owners "
    local n_rob; n_rob=$(cfg_len "$p.robots")
    for ((j = 0; j < n_rob; j++)); do
      local r; r=$(robot_name "$p.robots[$j]")
      [[ $r =~ $ROBOT_RE ]] || die "$p.robots[$j]: '$r' is not a valid robot name (lowercase letters, digits, _)"
      [[ $robots != *" $r "* ]] || die "$p.robots: '$r' is defined twice"
      robots="$robots$r "
    done

    local n_team; n_team=$(cfg_len "$p.teams")
    for ((j = 0; j < n_team; j++)); do
      local t; t=$(cfg "$p.teams[$j].name")
      [[ $t =~ $TEAM_RE ]] || die "$p.teams[$j].name '$t' is not a valid team name (lowercase letter, then lowercase letters/digits)"
      [[ $teams != *" $t "* || $t == owners ]] || die "$p.teams: '$t' is defined twice"
      teams="$teams$t "
      local role; role=$(cfg "$p.teams[$j].role" member)
      [[ $role =~ ^(member|creator|admin)$ ]] || die "$p.teams[$j].role must be member, creator or admin"
      local m n_mem; n_mem=$(cfg_len "$p.teams[$j].members")
      for ((m = 0; m < n_mem; m++)); do
        validate_principal "$p.teams[$j].members[$m]" "robot user"
        check_reference "$p.teams[$j].members[$m]" "$robots" "$teams"
      done
    done

    local n_repo; n_repo=$(cfg_len "$p.repositories")
    for ((j = 0; j < n_repo; j++)); do
      local rp="$p.repositories[$j]" repo vis
      repo=$(cfg "$rp.name")
      [[ $repo =~ $NAME_RE ]] || die "$rp.name '$repo' is not a valid repository name"
      vis=$(cfg "$rp.visibility" private)
      [[ $vis == private || $vis == public ]] || die "$rp.visibility must be private or public"
      local x n_perm; n_perm=$(cfg_len "$rp.permissions")
      for ((x = 0; x < n_perm; x++)); do
        validate_principal "$rp.permissions[$x]" "robot team user"
        check_reference "$rp.permissions[$x]" "$robots" "$teams"
        [[ $(cfg "$rp.permissions[$x].role") =~ ^(read|write|admin)$ ]] || die "$rp.permissions[$x].role must be read, write or admin"
      done
    done
  done
}

robot_name() { # robots may be plain strings or {name, description}
  if [[ $(yq e "$1 | tag" "$CONFIG") == '!!map' ]]; then cfg "$1.name"; else cfg "$1"; fi
}

validate_principal() { # validate_principal <path> <allowed kinds>
  local k n=0
  for k in robot team user; do
    if cfg_has "$1.$k"; then
      [[ " $2 " == *" $k "* ]] || die "$1: '$k' is not allowed here (allowed: $2)"
      n=$((n + 1))
    fi
  done
  [[ $n == 1 ]] || die "$1 must set exactly one of: $2"
}

check_reference() { # check_reference <path> "<declared robots>" "<declared teams>"
  local kind name
  read -r kind name <<<"$(principal_of "$1")"
  case $kind in
    robot) [[ $2 == *" $name "* ]] || die "$1: robot '$name' is not declared in this organization's robots" ;;
    team) [[ $3 == *" $name "* ]] || die "$1: team '$name' is not declared in this organization's teams" ;;
  esac
}

principal_of() { # prints "<kind> <name>"
  local k
  for k in robot team user; do
    if cfg_has "$1.$k"; then printf '%s %s' "$k" "$(cfg "$1.$k")"; return 0; fi
  done
  return 1
}

preflight_cluster() {
  require_cmd oc jq yq curl openssl awk sed base64 sort
  yq --version 2>&1 | grep -q 'mikefarah' || die "yq v4 from https://github.com/mikefarah/yq is required"
  oc whoami >/dev/null 2>&1 || die "not logged in to a cluster; run 'oc login' first"
  [[ $(oc auth can-i '*' '*' --all-namespaces 2>/dev/null) == yes ]] || die "cluster-admin privileges are required"
  log "cluster: $(oc whoami --show-server) (as $(oc whoami))"
}

preflight() {
  step "Preflight"
  preflight_cluster
  validate_config
  APPS_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
  # A bare label (no dot) means "<label>.<apps domain>".
  if [[ -n $QUAY_HOST && $QUAY_HOST != *.* ]]; then QUAY_HOST="$QUAY_HOST.$APPS_DOMAIN"; fi
  detect_subscription

  # Only check what the selected phases need (e.g. --phase content must not fail on storage).
  if phase_enabled operator || phase_enabled registry; then check_operator_scope; fi
  if phase_enabled operator; then
    resolve_operator_version
    log "operator:  $OP_CSV (channel $OP_CHANNEL, catalog $OP_SOURCE, namespace $OP_NS)"
  fi
  if phase_enabled registry; then
    check_tls_plan
    plan_storage
    log "registry:  $QB_NS/$QB_NAME, host ${QUAY_HOST:-<operator default under $APPS_DOMAIN>}"
    log "tls:       mode=$TLS_MODE route.managed=$ROUTE_MANAGED"
    log "storage:   object=$OBJ_MODE${OBC_SC:+ (OBC on $OBC_SC)}, default StorageClass=${DEFAULT_SC:-<none>}"
  fi
  if phase_enabled content; then
    log "orgs:      $(yq e '[.organizations[].name] | join(", ")' "$CONFIG")"
  fi
}
