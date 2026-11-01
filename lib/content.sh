# shellcheck shell=bash
# Content phase: organizations, robots, teams, repositories, permissions, proxy cache.
# Every step reads current state first, so re-running only applies differences.

reconcile_content() {
  step "Organizations"
  ensure_api_context
  creds_load
  resolve_config_token
  if ! load_admin_token; then
    [[ $DRY_RUN == true ]] || die "no valid admin token; run the init phase or set admin.token"
    log "[dry-run] no admin token yet; skipping content"
    return 0
  fi
  local i n
  n=$(cfg_len .organizations)
  for ((i = 0; i < n; i++)); do reconcile_org ".organizations[$i]"; done
  creds_save
}

reconcile_org() {
  local p=$1 org email body
  org=$(cfg "$p.name")
  log "organization $org"
  api GET "/api/v1/organization/$org"
  case $API_STATUS in
    200) ;;
    404)
      email=$(cfg "$p.email")
      body=$(jq -n --arg n "$org" --arg e "$email" '{name: $n} + (if $e != "" then {email: $e} else {} end)')
      api_expect "200 201" POST /api/v1/organization/ "$body"
      log "  created organization"
      ;;
    *) die "GET organization $org failed (HTTP $API_STATUS): $(api_error)" ;;
  esac
  reconcile_robots "$p" "$org"
  reconcile_teams "$p" "$org"
  reconcile_repos "$p" "$org"
  reconcile_proxy_cache "$p" "$org"
}

reconcile_robots() {
  local p=$1 org=$2 j n name desc rotate exists token
  n=$(cfg_len "$p.robots")
  for ((j = 0; j < n; j++)); do
    name=$(robot_name "$p.robots[$j]")
    desc='' rotate=false
    if [[ $(yq e "$p.robots[$j] | tag" "$CONFIG") == '!!map' ]]; then
      desc=$(cfg "$p.robots[$j].description")
      rotate=$(cfg "$p.robots[$j].rotate" false)
    fi
    api GET "/api/v1/organization/$org/robots/$name"
    exists=true
    [[ $API_STATUS == 200 ]] || exists=false
    if [[ $exists == true && $rotate == true ]]; then
      # Quay returns a token only when the robot is created, so reissuing one
      # means deleting the robot. Everything still using the old token breaks.
      warn "robot $org+$name: rotate is set, reissuing its token (consumers of the old token will fail)"
      api_expect "200 201 204" DELETE "/api/v1/organization/$org/robots/$name"
      exists=false
    fi
    if [[ $exists == false ]]; then
      api_expect "200 201" PUT "/api/v1/organization/$org/robots/$name" "$(jq -n --arg d "$desc" '{description: $d}')"
      log "  created robot $org+$name"
      token=$(jq -r '.token // empty' <<<"$API_BODY")
      if [[ -n $token ]]; then
        creds_set "robot.$org.$name" "$token"
      else
        warn "Quay returned no token for $org+$name; it is missing from secret $QB_NS/$CREDS_SECRET"
      fi
    elif [[ -z $(creds_get "robot.$org.$name") ]]; then
      warn "robot $org+$name exists but its token is not in secret $QB_NS/$CREDS_SECRET; set 'rotate: true' on it to reissue (the current token then stops working)"
    fi
  done
}

reconcile_teams() {
  local p=$1 org=$2 j m n n_mem team role members kind name member default
  n=$(cfg_len "$p.teams")
  for ((j = 0; j < n; j++)); do
    team=$(cfg "$p.teams[$j].name")
    role=$(cfg "$p.teams[$j].role" member)
    api_expect "200 201" PUT "/api/v1/organization/$org/team/$team" \
      "$(jq -n --arg r "$role" --arg d "$(cfg "$p.teams[$j].description")" '{role: $r, description: $d}')"
    debug "  team $team ($role)"

    api GET "/api/v1/organization/$org/team/$team/members"
    members=' '
    [[ $API_STATUS != 200 ]] || members=" $(jq -r '[.members[]?.name] | join(" ")' <<<"$API_BODY") "
    n_mem=$(cfg_len "$p.teams[$j].members")
    for ((m = 0; m < n_mem; m++)); do
      read -r kind name <<<"$(principal_of "$p.teams[$j].members[$m]")"
      member=$name
      # A unqualified robot belongs to this organization; a qualified one
      # ("org+robot") is added as is.
      [[ $kind != robot || $name == *"+"* ]] || member="$org+$name"
      [[ $members != *" $member "* ]] || continue
      api_expect "200 201" PUT "/api/v1/organization/$org/team/$team/members/$member" '{}'
      log "  added $member to team $team"
    done

    default=$(cfg "$p.teams[$j].defaultPermission")
    [[ -z $default ]] || reconcile_team_default_permission "$org" "$team" "$default"
  done
}

# Team membership grants nothing by itself, and the repositories a mirror fills
# in are usually created after this phase. Registering the team as an
# organization prototype gives it the role on the repositories created from now
# on *by the same user the API call runs as*; Quay applies prototypes per
# creating user, and this endpoint always binds it to the token owner. The
# sweep then covers every repository that already exists, so re-running the
# content phase after a mirror has pushed its content grants the team read on
# it. Repositories pushed by another identity, such as a robot, need that
# re-run: only an organization-wide prototype reaches them, which the API
# cannot create.
reconcile_team_default_permission() { # <org> <team> <role>
  local org=$1 team=$2 role=$3 payload page names repo seen=0 granted=0
  # The delegate kind travels inside `delegate`; without it Quay cannot tell a
  # team from a user and rejects the request as having no delegate.
  payload=$(jq -n --arg r "$role" --arg t "$team" '{role: $r, delegate: {name: $t, kind: "team"}}')
  api POST "/api/v1/organization/$org/prototypes" "$payload"
  case $API_STATUS in
    200 | 201) log "  team $team: default $role for repositories the API user creates" ;;
    400) debug "  team $team: default $role is already registered ($(api_error))" ;;
    *) die "prototype $team -> $role for $org failed (HTTP $API_STATUS): $(api_error)" ;;
  esac

  page=1
  while :; do
    api GET "/api/v1/repository?namespace=$org&starred=false&limit=1000&page=$page"
    [[ $API_STATUS == 200 ]] || die "listing repositories of $org failed (HTTP $API_STATUS): $(api_error)"
    names=$(jq -r '.repositories[]?.name' <<<"$API_BODY")
    [[ -n $names ]] || break
    while IFS= read -r repo; do
      [[ -n $repo ]] || continue
      seen=$((seen + 1))
      api_expect "200 201 204" PUT "/api/v1/repository/$org/$repo/permissions/team/$team" \
        "$(jq -n --arg r "$role" '{role: $r}')"
      granted=$((granted + 1))
    done <<<"$names"
    page=$((page + 1))
    ((page <= 20)) || break
  done
  log "  team $team: $role on $granted of $seen existing repositories"
}

reconcile_repos() {
  local p=$1 org=$2 j x n n_perm rp repo vis desc is_public want_public kind name role target
  n=$(cfg_len "$p.repositories")
  for ((j = 0; j < n; j++)); do
    rp="$p.repositories[$j]"
    repo=$(cfg "$rp.name")
    vis=$(cfg "$rp.visibility" private)
    desc=$(cfg "$rp.description")
    api GET "/api/v1/repository/$org/$repo"
    if [[ $API_STATUS == 200 ]]; then
      is_public=$(jq -r '.is_public' <<<"$API_BODY")
      want_public=false
      [[ $vis != public ]] || want_public=true
      if [[ $is_public != "$want_public" ]]; then
        api_expect "200 201" POST "/api/v1/repository/$org/$repo/changevisibility" "{\"visibility\": \"$vis\"}"
        log "  repository $org/$repo visibility -> $vis"
      fi
    else
      api_expect "200 201" POST /api/v1/repository "$(jq -n --arg ns "$org" --arg r "$repo" --arg v "$vis" --arg d "$desc" \
        '{namespace: $ns, repository: $r, visibility: $v, description: $d, repo_kind: "image"}')"
      log "  created repository $org/$repo ($vis)"
    fi

    n_perm=$(cfg_len "$rp.permissions")
    for ((x = 0; x < n_perm; x++)); do
      read -r kind name <<<"$(principal_of "$rp.permissions[$x]")"
      role=$(cfg "$rp.permissions[$x].role")
      [[ $kind != robot || $name == *"+"* ]] || name="$org+$name"
      case $kind in
        team) target="team/$name" ;;
        *) target="user/$name" ;;
      esac
      api_expect "200 201" PUT "/api/v1/repository/$org/$repo/permissions/$target" "{\"role\": \"$role\"}"
      debug "  $org/$repo: $kind $name -> $role"
    done
  done
}

reconcile_proxy_cache() {
  local p=$1 org=$2 up exp insecure user pass payload hash current
  cfg_has "$p.proxyCache" || return 0
  up=$(cfg "$p.proxyCache.upstream")
  exp=$(cfg "$p.proxyCache.expirationSeconds" 86400)
  insecure=$(cfg "$p.proxyCache.insecure" false)
  user=$(resolve_value "$p.proxyCache.username")
  pass=$(resolve_value "$p.proxyCache.password")
  payload=$(jq -n --arg o "$org" --arg up "$up" --arg exp "$exp" --arg ins "$insecure" --arg u "$user" --arg pw "$pass" \
    '{org_name: $o, upstream_registry: $up, expiration_s: ($exp | tonumber), insecure: ($ins == "true")}
     + (if $u != "" then {upstream_registry_username: $u, upstream_registry_password: $pw} else {} end)')
  hash=$(printf '%s' "$payload" | sha256_of)

  api GET "/api/v1/organization/$org/proxycache"
  current=''
  [[ $API_STATUS != 200 ]] || current=$(jq -r '.upstream_registry // empty' <<<"$API_BODY")
  # Credentials are write-only in Quay, so changes are detected through a hash kept in the output secret.
  if [[ -n $current && $(creds_get "proxycache.$org.hash") == "$hash" ]]; then
    debug "  proxy cache for $up is up to date"
    return 0
  fi

  api POST "/api/v1/organization/$org/validateproxycache" "$payload"
  [[ $API_STATUS == 200 || $API_STATUS == 202 ]] || die "proxy cache validation for $org -> $up failed (HTTP $API_STATUS): $(api_error)"
  if [[ -n $current ]]; then
    api_expect "200 201 204" DELETE "/api/v1/organization/$org/proxycache"
  fi
  api_expect "200 201" POST "/api/v1/organization/$org/proxycache" "$payload"
  creds_set "proxycache.$org.hash" "$hash"
  log "  proxy cache -> $up (expiration ${exp}s)"
}
