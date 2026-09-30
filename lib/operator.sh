# shellcheck shell=bash
# Operator phase: resolve the requested version from the catalog and install it via OLM
# with manual install-plan approval, so the operator stays pinned to that version.

PACKAGE=quay-operator

# Find an existing quay-operator Subscription anywhere in the cluster and adopt its namespace,
# so a second subscription is never created. Sets OP_SUB (empty if none).
detect_subscription() {
  local found ns name
  found=$(oc get subscriptions.operators.coreos.com -A -o json 2>/dev/null \
    | jq -r --arg p "$PACKAGE" '.items[] | select(.spec.name == $p) | "\(.metadata.namespace) \(.metadata.name)"') || found=''
  OP_SUB=''
  [[ -n $found ]] || return 0
  [[ $(printf '%s\n' "$found" | wc -l) -eq 1 ]] || die "multiple $PACKAGE subscriptions found: $(printf '%s' "$found" | tr '\n' ',')"
  read -r ns name <<<"$found"
  if [[ $ns != "$OP_NS" ]]; then
    warn "$PACKAGE is already subscribed in namespace $ns; using it instead of $OP_NS"
    OP_NS=$ns
  fi
  OP_SUB=$name
}

sub_field() { # sub_field <jsonpath>
  [[ -n $OP_SUB ]] || return 0
  oc get subscriptions.operators.coreos.com "$OP_SUB" -n "$OP_NS" -o jsonpath="$1" 2>/dev/null || true
}

# A namespace-scoped OperatorGroup that does not include the registry namespace would leave the
# QuayRegistry unreconciled until the wait times out.
check_operator_scope() {
  local targets
  targets=$(oc get operatorgroups.operators.coreos.com -n "$OP_NS" -o json 2>/dev/null \
    | jq -r '[.items[0].spec.targetNamespaces // [] | .[]] | join(" ")') || targets=''
  if [[ -n $targets && " $targets " != *" $QB_NS "* ]]; then
    die "the OperatorGroup in $OP_NS only targets [$targets]; it must include $QB_NS (or be all-namespaces)"
  fi
}

resolve_operator_version() {
  local pm head installed
  pm=$(oc get packagemanifests -n "$OP_SOURCE_NS" -l "catalog=$OP_SOURCE" -o json 2>/dev/null \
    | jq -c --arg p "$PACKAGE" '[.items[] | select(.metadata.name == $p)][0] // empty') || true
  [[ -n $pm ]] || die "package $PACKAGE not found in catalog $OP_SOURCE_NS/$OP_SOURCE"

  # Unpinned re-runs normally move to the newest version; autoUpgrade=false keeps what is installed.
  if [[ -z $OP_CSV && -z $OP_CHANNEL && $(cfg .operator.autoUpgrade true) == false ]]; then
    installed=$(sub_field '{.status.installedCSV}')
    if [[ -n $installed ]]; then
      OP_CSV=$installed
      OP_CHANNEL=$(sub_field '{.spec.channel}')
      log "operator.autoUpgrade=false: keeping installed $installed"
    fi
  fi

  if [[ -n $OP_CSV ]]; then
    [[ $OP_CSV == "$PACKAGE".v* ]] || OP_CSV="$PACKAGE.v${OP_CSV#v}" # accept "3.15.1"
    if [[ -z $OP_CHANNEL ]]; then
      OP_CHANNEL=$(jq -r --arg c "$OP_CSV" \
        '[.status.channels[] | select(.currentCSV == $c or ((.entries // []) | any(.name == $c))) | .name] | sort | last // empty' <<<"$pm")
      [[ -n $OP_CHANNEL ]] || die "operator version $OP_CSV not found in any channel of $OP_SOURCE"
    fi
  elif [[ -z $OP_CHANNEL ]]; then
    # No version requested: take the channel whose head is the newest version.
    OP_CHANNEL=$(jq -r '.status.channels[]
        | "\(.currentCSVDesc.version // (.currentCSV | sub("^quay-operator\\.v"; ""))) \(.name)"' <<<"$pm" \
      | sort -V | tail -n 1 | awk '{print $2}')
  fi

  head=$(jq -r --arg ch "$OP_CHANNEL" '.status.channels[] | select(.name == $ch) | .currentCSV' <<<"$pm")
  [[ -n $head ]] || die "channel $OP_CHANNEL not found for $PACKAGE (available: $(jq -r '[.status.channels[].name] | join(", ")' <<<"$pm"))"

  if [[ -z $OP_CSV ]]; then
    OP_CSV=$head
  elif [[ $(jq -r --arg ch "$OP_CHANNEL" '.status.channels[] | select(.name == $ch) | has("entries")' <<<"$pm") == true ]]; then
    jq -e --arg ch "$OP_CHANNEL" --arg c "$OP_CSV" \
      '.status.channels[] | select(.name == $ch) | .entries | any(.name == $c)' <<<"$pm" >/dev/null \
      || die "$OP_CSV is not available in channel $OP_CHANNEL"
  fi
  OP_VERSION=${OP_CSV#"$PACKAGE".v}
}

ensure_operator_group() {
  local ogs
  ogs=$(oc get operatorgroups.operators.coreos.com -n "$OP_NS" -o json 2>/dev/null || echo '{"items":[]}')
  if [[ $(jq '.items | length' <<<"$ogs") == 0 ]]; then
    kapply <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: quay-bootstrap
  namespace: $OP_NS
  labels:
    $MANAGED_BY_KEY: $MANAGED_BY_VALUE
spec: {}
EOF
  elif [[ $(jq '[.items[] | select((.spec.targetNamespaces // []) | length > 0)] | length' <<<"$ogs") != 0 ]]; then
    warn "OperatorGroup in $OP_NS is namespace-scoped; the monitoring component needs an all-namespaces install"
  fi
}

install_operator() {
  step "Quay operator $OP_CSV (channel $OP_CHANNEL)"
  if [[ $OP_NS != openshift-operators ]]; then
    ensure_namespace "$OP_NS"
    ensure_operator_group
  fi

  local installed channel approval
  if [[ -z $OP_SUB ]]; then
    OP_SUB=$PACKAGE
    log "creating subscription $OP_NS/$OP_SUB"
    kapply <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: $OP_SUB
  namespace: $OP_NS
  labels:
    $MANAGED_BY_KEY: $MANAGED_BY_VALUE
spec:
  name: $PACKAGE
  channel: $OP_CHANNEL
  source: $OP_SOURCE
  sourceNamespace: $OP_SOURCE_NS
  installPlanApproval: Manual
  startingCSV: $OP_CSV
EOF
  else
    installed=$(sub_field '{.status.installedCSV}')
    channel=$(sub_field '{.spec.channel}')
    approval=$(sub_field '{.spec.installPlanApproval}')
    log "found subscription $OP_NS/$OP_SUB (installed: ${installed:-none})"
    if [[ -n $installed ]] && ! version_le "${installed#"$PACKAGE".v}" "$OP_VERSION"; then
      die "installed $installed is newer than requested $OP_CSV; OLM does not support downgrades"
    fi
    if [[ $channel != "$OP_CHANNEL" || $approval != Manual ]]; then
      log "updating subscription: channel $channel -> $OP_CHANNEL, approval $approval -> Manual"
      run oc patch subscriptions.operators.coreos.com "$OP_SUB" -n "$OP_NS" --type merge \
        -p "{\"spec\":{\"channel\":\"$OP_CHANNEL\",\"installPlanApproval\":\"Manual\"}}"
    fi
  fi

  wait_until "$OPERATOR_TIMEOUT" 10 "CSV $OP_CSV to reach Succeeded" operator_reconcile_step
  run oc wait --for condition=established crd/quayregistries.quay.redhat.com --timeout=120s
  log "operator ready: $OP_CSV"
}

csv_succeeded() {
  [[ $(oc get csv "$OP_CSV" -n "$OP_NS" -o jsonpath='{.status.phase}' 2>/dev/null) == Succeeded ]]
}

operator_reconcile_step() {
  if csv_succeeded; then return 0; fi
  approve_install_plans
  return 1
}

# Approve pending install plans that move quay-operator toward the target. Plans that go past it
# (e.g. the upgrade OLM queues after a pinned install) are left unapproved; that is the pin.
approve_install_plans() {
  local plans name csvs c quay_csv approved=0 beyond='' installed
  plans=$(oc get installplans.operators.coreos.com -n "$OP_NS" -o json 2>/dev/null \
    | jq -r '.items[] | select(.spec.approved == false)
             | "\(.metadata.name) \(.spec.clusterServiceVersionNames | join(","))"') || return 0
  while read -r name csvs; do
    [[ -n $name ]] || continue
    quay_csv=''
    for c in ${csvs//,/ }; do
      [[ $c != "$PACKAGE".v* ]] || quay_csv=$c
    done
    [[ -n $quay_csv ]] || continue
    if ! version_le "${quay_csv#"$PACKAGE".v}" "$OP_VERSION"; then
      beyond=$quay_csv
      debug "leaving install plan $name ($quay_csv) unapproved: beyond $OP_CSV"
      continue
    fi
    [[ $csvs != *,* ]] || warn "install plan $name also installs: $csvs"
    log "approving install plan $name ($csvs)"
    oc patch installplans.operators.coreos.com "$name" -n "$OP_NS" --type merge -p '{"spec":{"approved":true}}' >/dev/null
    approved=$((approved + 1))
  done <<<"$plans"

  # OLM only offers the channel head as an upgrade; if that overshoots, the target is unreachable.
  if [[ $approved == 0 && -n $beyond ]]; then
    installed=$(sub_field '{.status.installedCSV}')
    if [[ -n $installed && $installed != "$OP_CSV" ]]; then
      die "OLM can only upgrade $installed to $beyond, which is beyond the requested $OP_CSV; request $beyond or leave the version unset"
    fi
  fi
}
