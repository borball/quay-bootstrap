# shellcheck shell=bash
# Teardown of everything this tool created (objects labelled app.kubernetes.io/managed-by=quay-bootstrap).

destroy_all() {
  step "Destroy $QB_NS/$QB_NAME"
  [[ $ASSUME_YES == true ]] || die "--destroy deletes the registry and ALL its data (database, bucket); re-run with --yes to confirm"
  local sel="$MANAGED_BY_KEY=$MANAGED_BY_VALUE" host=$QUAY_HOST kind

  if registry_exists; then
    [[ -n $host ]] || { discover_endpoint 2>/dev/null && host=$QUAY_HOST; } || true
    log "deleting QuayRegistry (the operator removes its deployments and PVCs)"
    run oc delete quayregistries.quay.redhat.com "$QB_NAME" -n "$QB_NS" --wait=true --timeout=15m
  fi

  for kind in objectbucketclaims.objectbucket.io certificates.cert-manager.io secrets; do
    if oc api-resources -o name 2>/dev/null | grep -qx "$kind"; then
      run oc delete "$kind" -n "$QB_NS" -l "$sel" --ignore-not-found --wait=true
    fi
  done

  [[ -z $host ]] || untrust_cluster_ca "$host"

  if [[ $KEEP_OPERATOR == true ]]; then
    log "keeping the Quay operator (--keep-operator)"
  elif [[ $(other_registries) != 0 ]]; then
    warn "other QuayRegistry instances exist in the cluster; keeping the operator"
  else
    remove_operator
  fi

  if [[ $DELETE_NAMESPACE == true ]]; then
    local ns
    for ns in "$QB_NS" "$OP_NS"; do
      [[ $ns != openshift-operators ]] || continue
      if [[ $(oc get namespace "$ns" -o jsonpath="{.metadata.labels.app\.kubernetes\.io/managed-by}" 2>/dev/null) == "$MANAGED_BY_VALUE" ]]; then
        run oc delete namespace "$ns" --wait=false
      else
        debug "namespace $ns was not created by quay-bootstrap; keeping it"
      fi
    done
  fi
  log "destroy complete"
}

other_registries() {
  (oc get quayregistries.quay.redhat.com -A -o json 2>/dev/null || echo '{"items":[]}') \
    | jq --arg ns "$QB_NS" --arg n "$QB_NAME" '[.items[] | select(.metadata.namespace != $ns or .metadata.name != $n)] | length'
}

remove_operator() {
  local csv
  if [[ -n $OP_SUB ]]; then
    csv=$(sub_field '{.status.installedCSV}')
    run oc delete subscriptions.operators.coreos.com "$OP_SUB" -n "$OP_NS"
    [[ -z $csv ]] || run oc delete csv "$csv" -n "$OP_NS" --ignore-not-found
  fi
  run oc delete operatorgroups.operators.coreos.com -n "$OP_NS" -l "$MANAGED_BY_KEY=$MANAGED_BY_VALUE" --ignore-not-found
}

untrust_cluster_ca() {
  local host=$1 cm remaining
  cm=$(oc get image.config.openshift.io cluster -o jsonpath='{.spec.additionalTrustedCA.name}' 2>/dev/null || true)
  [[ -n $cm ]] || return 0
  if [[ -n $(oc get configmap "$cm" -n openshift-config -o json 2>/dev/null | jq -r --arg k "$host" '.data[$k] // empty') ]]; then
    log "removing CA for $host from openshift-config/$cm"
    run oc patch configmap "$cm" -n openshift-config --type json -p "[{\"op\":\"remove\",\"path\":\"/data/$host\"}]"
  fi
  if [[ $cm == quay-bootstrap-registry-cas ]]; then
    remaining=$(oc get configmap "$cm" -n openshift-config -o json 2>/dev/null | jq '.data // {} | length')
    if [[ $DRY_RUN != true && $remaining == 0 ]]; then
      run oc patch image.config.openshift.io cluster --type json -p '[{"op":"remove","path":"/spec/additionalTrustedCA"}]'
      run oc delete configmap "$cm" -n openshift-config
    fi
  fi
}
