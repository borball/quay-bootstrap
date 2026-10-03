# shellcheck shell=bash
# Registry phase: config bundle secret + QuayRegistry CR, then wait for it to be available.

registry_exists() { oc get quayregistries.quay.redhat.com "$QB_NAME" -n "$QB_NS" >/dev/null 2>&1; }

registry_available() {
  [[ $(oc get quayregistries.quay.redhat.com "$QB_NAME" -n "$QB_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null) == True ]]
}

discover_endpoint() {
  local ep
  ep=$(oc get quayregistries.quay.redhat.com "$QB_NAME" -n "$QB_NS" -o jsonpath='{.status.registryEndpoint}' 2>/dev/null || true)
  [[ -n $ep ]] || die "QuayRegistry $QB_NS/$QB_NAME has no registryEndpoint; set registry.hostname"
  ep=${ep#https://}
  ep=${ep#http://}
  QUAY_HOST=${ep%%/*}
}

deploy_registry() {
  step "Quay registry $QB_NS/$QB_NAME"
  if [[ $DRY_RUN != true ]]; then
    oc get crd quayregistries.quay.redhat.com >/dev/null 2>&1 || die "QuayRegistry CRD not found; run the operator phase first"
  fi
  ensure_namespace "$QB_NS"
  rm -rf "$BUNDLE_DIR"
  mkdir -p "$BUNDLE_DIR" "$TLS_DIR"

  ensure_block_storage
  ensure_object_storage
  prepare_tls
  build_config_yaml
  apply_config_bundle
  apply_quay_registry
  wait_registry
  trust_cluster_ca
}

harden_wanted() { [[ $(cfg .security.hardenAfterBootstrap false) == true ]]; }
admin_initialized() { [[ -n $(secret_key "$QB_NS" "$CREDS_SECRET" token 2>/dev/null || true) ]]; }

build_config_yaml() {
  local base="$WORKDIR/config-base.yaml" extra="$WORKDIR/config-extra.yaml" out="$BUNDLE_DIR/config.yaml"
  if [[ -s $WORKDIR/storage.yaml ]]; then cp "$WORKDIR/storage.yaml" "$base"; else echo '{}' >"$base"; fi
  yq e '.registry.extraConfig // {}' "$CONFIG" >"$extra"

  # Required for API-driven bootstrap: first-user initialization and non-browser API calls.
  # With security.hardenAfterBootstrap, both are switched back off once the admin token exists.
  HARDENED=false
  if harden_wanted && admin_initialized; then
    yq -i '.FEATURE_USER_INITIALIZE = false | .BROWSER_API_CALLS_XHR_ONLY = true' "$base"
    HARDENED=true
    log "config: first-user initialization disabled (security.hardenAfterBootstrap)"
  else
    yq -i '.FEATURE_USER_INITIALIZE = true | .BROWSER_API_CALLS_XHR_ONLY = false' "$base"
  fi
  [[ -z $QUAY_HOST ]] || QUAY_HOST=$QUAY_HOST yq -i '.SERVER_HOSTNAME = strenv(QUAY_HOST)' "$base"
  if [[ $(yq e '[.organizations[] | select(.proxyCache != null)] | length' "$CONFIG") != 0 ]]; then
    yq -i '.FEATURE_PROXY_CACHE = true' "$base"
  fi
  # extraConfig wins, except that the admin always stays a superuser.
  yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$base" "$extra" >"$out"
  ADMIN_USER=$ADMIN_USER yq -i '.SUPER_USERS = (((.SUPER_USERS // []) + [strenv(ADMIN_USER)]) | unique)' "$out"
  [[ $VERBOSE != true ]] || debug "config.yaml keys: $(yq e 'keys | join(",")' "$out")"
}

apply_config_bundle() {
  local current
  BUNDLE_HASH=$(cd "$BUNDLE_DIR" && for f in *; do printf '%s\n' "$f"; cat "$f"; done | sha256_of)
  current=$(oc get quayregistries.quay.redhat.com "$QB_NAME" -n "$QB_NS" -o json 2>/dev/null \
    | jq -r '.metadata.annotations["quay-bootstrap.io/config-hash"] // empty') || current=''
  BUNDLE_CHANGED=false
  [[ $current == "$BUNDLE_HASH" ]] || BUNDLE_CHANGED=true
  log "config bundle: $(cd "$BUNDLE_DIR" && ls | tr '\n' ' ')($([[ $BUNDLE_CHANGED == true ]] && echo changed || echo unchanged))"
  oc create secret generic "$CONFIG_SECRET" -n "$QB_NS" --from-file="$BUNDLE_DIR" --dry-run=client -o yaml \
    | labeled | kapply
}

component_managed() {
  case $1 in
    objectstorage) [[ $OBJ_MODE == managed ]] && echo true || echo false ;;
    tls) [[ $TLS_MODE == ingress ]] && echo true || echo false ;;
    route) echo "$ROUTE_MANAGED" ;;
    mirror) cfg .registry.components.mirror false ;;
    *) cfg ".registry.components.$1" true ;;
  esac
}

apply_quay_registry() {
  local kind comps='[]' managed size
  for kind in $COMPONENT_KINDS; do
    managed=$(component_managed "$kind")
    size=''
    case $kind in
      postgres) size=$(cfg .storage.block.postgresVolumeSize) ;;
      clairpostgres) size=$(cfg .storage.block.clairPostgresVolumeSize) ;;
    esac
    comps=$(jq -c --arg k "$kind" --argjson m "$managed" --arg s "$size" \
      '. + [{kind: $k, managed: $m} + (if $s != "" and $m then {overrides: {volumeSize: $s}} else {} end)]' <<<"$comps")
  done
  jq -n --arg name "$QB_NAME" --arg ns "$QB_NS" --arg secret "$CONFIG_SECRET" --arg hash "$BUNDLE_HASH" \
    --arg lk "$MANAGED_BY_KEY" --arg lv "$MANAGED_BY_VALUE" --argjson comps "$comps" '{
      apiVersion: "quay.redhat.com/v1", kind: "QuayRegistry",
      metadata: {name: $name, namespace: $ns, labels: {($lk): $lv},
                 annotations: {"quay-bootstrap.io/config-hash": $hash}},
      spec: {configBundleSecret: $secret, components: $comps}}' | kapply
}

wait_registry() {
  if [[ $DRY_RUN == true ]]; then
    registry_exists && [[ -z $QUAY_HOST ]] && discover_endpoint
    return 0
  fi
  # Give the operator time to notice a changed bundle before trusting a stale Available condition.
  [[ $BUNDLE_CHANGED != true ]] || sleep 20
  wait_until "$REGISTRY_TIMEOUT" 15 "QuayRegistry $QB_NAME to become Available" registry_available
  oc rollout status "deployment/${QB_NAME}-quay-app" -n "$QB_NS" --timeout="${REGISTRY_TIMEOUT}s" >&2
  [[ -n $QUAY_HOST ]] || discover_endpoint
  log "registry available at https://$QUAY_HOST"
}
