# shellcheck shell=bash
# TLS handling.
#
#   ingress     tls managed by the operator; edge route with the cluster ingress wildcard cert.
#               Hostname (if set) must be <label>.<apps domain>.
#   custom      tls unmanaged; cert/key from file, an existing TLS secret, or cert-manager.
#               Quay terminates TLS (passthrough route).
#   selfsigned  tls unmanaged; CA kept in secret <name>-bootstrap-ca, server cert generated from it.
#
# Outputs: ssl.cert / ssl.key / extra_ca_cert_*.crt in $BUNDLE_DIR, QUAY_CA_FILE (private CA
# clients need to trust, empty if publicly trusted) and API_CA_BUNDLE (CA file for curl).

check_tls_plan() {
  if [[ $TLS_MODE == ingress && -n $QUAY_HOST && ${QUAY_HOST#*.} != "$APPS_DOMAIN" ]]; then
    die "hostname $QUAY_HOST is not covered by the ingress wildcard *.$APPS_DOMAIN; use tls.mode custom or selfsigned"
  fi
  if [[ $TLS_MODE != ingress && -n $QUAY_HOST && $QUAY_HOST != *".$APPS_DOMAIN" && $ROUTE_MANAGED == true ]]; then
    warn "DNS for $QUAY_HOST must point to the OpenShift router (e.g. a CNAME to router-default.$APPS_DOMAIN)"
  fi
  if [[ $TLS_MODE == custom ]]; then
    local p=.registry.tls.source f
    if cfg_has "$p.file"; then
      for f in cert key; do
        [[ -r $(abs_path "$(cfg "$p.file.$f")") ]] || die "$p.file.$f not readable"
      done
      if cfg_has "$p.file.ca"; then [[ -r $(abs_path "$(cfg "$p.file.ca")") ]] || die "$p.file.ca not readable"; fi
    elif cfg_has "$p.certManager"; then
      oc get crd certificates.cert-manager.io >/dev/null 2>&1 || die "cert-manager is not installed (certificates.cert-manager.io CRD missing)"
      [[ -n $(cfg "$p.certManager.issuerName") ]] || die "$p.certManager.issuerName is required"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Registry phase
# ---------------------------------------------------------------------------
prepare_tls() {
  mkdir -p "$TLS_DIR"
  case $TLS_MODE in
    ingress) ;;
    custom) load_custom_cert ;;
    selfsigned) ensure_selfsigned ;;
  esac
  resolve_quay_ca

  if [[ $TLS_MODE != ingress ]]; then
    if [[ -s $TLS_DIR/ssl.cert ]]; then
      validate_server_cert "$TLS_DIR/ssl.cert" "$TLS_DIR/ssl.key" "$QUAY_HOST" "$QUAY_CA_FILE"
      cp "$TLS_DIR/ssl.cert" "$TLS_DIR/ssl.key" "$BUNDLE_DIR/"
    elif [[ $DRY_RUN == true ]]; then
      warn "[dry-run] certificate not available yet; skipping validation"
    else
      die "no server certificate available"
    fi
    # Quay and Clair call the registry by its hostname, so they must trust a private CA.
    [[ -z $QUAY_CA_FILE ]] || cp "$QUAY_CA_FILE" "$BUNDLE_DIR/extra_ca_cert_quay-registry-ca.crt"
  fi
  add_extra_cas
}

add_extra_cas() {
  local i n name
  n=$(cfg_len .registry.tls.extraCAs)
  for ((i = 0; i < n; i++)); do
    name=$(cfg ".registry.tls.extraCAs[$i].name")
    [[ $name =~ ^[A-Za-z0-9_.-]+$ ]] || die "registry.tls.extraCAs[$i].name '$name' is invalid"
    resolve_value ".registry.tls.extraCAs[$i].cert" >"$BUNDLE_DIR/extra_ca_cert_${name}.crt"
    openssl x509 -in "$BUNDLE_DIR/extra_ca_cert_${name}.crt" -noout 2>/dev/null \
      || die "registry.tls.extraCAs[$i] ($name) is not a PEM certificate"
    log "extra CA trusted by Quay: $name"
  done
}

load_custom_cert() {
  local p=.registry.tls.source ns name
  if cfg_has "$p.file"; then
    cp "$(abs_path "$(cfg "$p.file.cert")")" "$TLS_DIR/ssl.cert"
    cp "$(abs_path "$(cfg "$p.file.key")")" "$TLS_DIR/ssl.key"
    if cfg_has "$p.file.ca"; then cp "$(abs_path "$(cfg "$p.file.ca")")" "$TLS_DIR/ca.pem"; fi
    log "certificate: from files"
    fix_chain
    return 0
  fi
  if cfg_has "$p.secret"; then
    ns=$(cfg "$p.secret.namespace" "$QB_NS")
    name=$(cfg "$p.secret.name")
    log "certificate: from secret $ns/$name"
  else
    ensure_certmanager_cert
    ns=$QB_NS
    name=$(certmanager_secret)
  fi
  if ! oc get secret "$name" -n "$ns" >/dev/null 2>&1; then
    [[ $DRY_RUN == true ]] && return 0
    die "TLS secret $ns/$name not found"
  fi
  secret_key "$ns" "$name" tls.crt >"$TLS_DIR/ssl.cert"
  secret_key "$ns" "$name" tls.key >"$TLS_DIR/ssl.key"
  secret_key "$ns" "$name" ca.crt >"$TLS_DIR/ca.pem" || true
  [[ -s $TLS_DIR/ca.pem ]] || rm -f "$TLS_DIR/ca.pem"
  fix_chain
}

certmanager_secret() { cfg .registry.tls.source.certManager.secretName "${QB_NAME}-quay-tls"; }

cert_ready() {
  [[ $(oc get certificates.cert-manager.io "$1" -n "$QB_NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) == True ]]
}

ensure_certmanager_cert() {
  local p=.registry.tls.source.certManager name secret
  secret=$(certmanager_secret)
  name=$secret
  log "certificate: cert-manager $(cfg "$p.issuerKind" ClusterIssuer)/$(cfg "$p.issuerName")"
  kapply <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: $name
  namespace: $QB_NS
  labels:
    $MANAGED_BY_KEY: $MANAGED_BY_VALUE
spec:
  secretName: $secret
  dnsNames:
    - $QUAY_HOST
  duration: $(cfg "$p.duration" 8760h)
  renewBefore: $(cfg "$p.renewBefore" 720h)
  privateKey:
    rotationPolicy: Always
  issuerRef:
    group: cert-manager.io
    kind: $(cfg "$p.issuerKind" ClusterIssuer)
    name: $(cfg "$p.issuerName")
EOF
  wait_until 600 10 "Certificate $name to be Ready" cert_ready "$name"
}

# If ssl.cert holds only the leaf, append intermediates from the CA bundle so clients get a full chain.
fix_chain() {
  [[ -s $TLS_DIR/ca.pem ]] || return 0
  [[ $(grep -c 'BEGIN CERTIFICATE' "$TLS_DIR/ssl.cert") == 1 ]] || return 0
  local split="$TLS_DIR/split" f
  mkdir -p "$split"
  awk -v d="$split" '/BEGIN CERTIFICATE/{n++} n{print > (d "/" n ".pem")}' "$TLS_DIR/ca.pem"
  for f in "$split"/*.pem; do
    [[ -e $f ]] || continue
    if [[ $(openssl x509 -in "$f" -noout -subject | sed 's/^subject=//') != "$(openssl x509 -in "$f" -noout -issuer | sed 's/^issuer=//')" ]]; then
      cat "$f" >>"$TLS_DIR/ssl.cert"
      log "appended intermediate CA to the certificate chain"
    fi
  done
}

ensure_selfsigned() {
  local ca_secret="${QB_NAME}-bootstrap-ca" days
  days=$(cfg .registry.tls.selfsigned.days 365)
  if oc get secret "$ca_secret" -n "$QB_NS" >/dev/null 2>&1; then
    secret_key "$QB_NS" "$ca_secret" tls.crt >"$TLS_DIR/ca.pem"
    secret_key "$QB_NS" "$ca_secret" tls.key >"$TLS_DIR/ca.key"
    log "self-signed CA: reusing secret $ca_secret"
  else
    cat >"$TLS_DIR/ca.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no
[dn]
CN = quay-bootstrap CA ($QB_NS/$QB_NAME)
[v3_ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
EOF
    openssl req -x509 -new -nodes -newkey rsa:4096 -sha256 -days 3650 \
      -keyout "$TLS_DIR/ca.key" -out "$TLS_DIR/ca.pem" -config "$TLS_DIR/ca.cnf" 2>/dev/null
    log "self-signed CA: generated (stored in secret $ca_secret)"
    oc create secret tls "$ca_secret" -n "$QB_NS" --cert="$TLS_DIR/ca.pem" --key="$TLS_DIR/ca.key" \
      --dry-run=client -o yaml | labeled | kapply
  fi

  # Reuse the current server certificate if it is still good, to avoid needless pod restarts.
  if secret_key "$QB_NS" "$CONFIG_SECRET" ssl.cert >"$TLS_DIR/ssl.cert" 2>/dev/null \
    && secret_key "$QB_NS" "$CONFIG_SECRET" ssl.key >"$TLS_DIR/ssl.key" 2>/dev/null \
    && [[ -s $TLS_DIR/ssl.cert ]] \
    && host_matches_cert "$QUAY_HOST" "$TLS_DIR/ssl.cert" \
    && openssl x509 -checkend $((MIN_VALID_DAYS * 86400)) -noout -in "$TLS_DIR/ssl.cert" >/dev/null \
    && openssl verify -CAfile "$TLS_DIR/ca.pem" "$TLS_DIR/ssl.cert" >/dev/null 2>&1; then
    log "self-signed certificate: reusing current certificate for $QUAY_HOST"
    return 0
  fi

  cat >"$TLS_DIR/server.ext" <<EOF
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:$QUAY_HOST
EOF
  openssl req -new -nodes -newkey rsa:2048 -keyout "$TLS_DIR/ssl.key" -out "$TLS_DIR/server.csr" \
    -subj "/CN=$QUAY_HOST" 2>/dev/null
  openssl x509 -req -in "$TLS_DIR/server.csr" -CA "$TLS_DIR/ca.pem" -CAkey "$TLS_DIR/ca.key" -CAcreateserial \
    -out "$TLS_DIR/ssl.cert" -days "$days" -sha256 -extfile "$TLS_DIR/server.ext" 2>/dev/null
  log "self-signed certificate: issued for $QUAY_HOST (valid $days days)"
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
cert_dns_names() {
  openssl x509 -in "$1" -noout -text \
    | awk '/X509v3 Subject Alternative Name/{getline; print}' \
    | tr ',' '\n' | sed -n 's/^[[:space:]]*DNS://p'
}

host_matches_cert() { # host_matches_cert <host> <cert>
  local name
  while read -r name; do
    [[ $name == "$1" ]] && return 0
    [[ $name == '*.'* && ${1#*.} == "${name#*.}" ]] && return 0
  done < <(cert_dns_names "$2")
  return 1
}

validate_server_cert() { # validate_server_cert <cert> <key> <host> [ca]
  local cert=$1 key=$2 host=$3 ca=${4-}
  openssl x509 -in "$cert" -noout 2>/dev/null || die "server certificate is not valid PEM"
  host_matches_cert "$host" "$cert" \
    || die "certificate SANs ($(cert_dns_names "$cert" | tr '\n' ' ')) do not cover $host"
  [[ $(openssl x509 -in "$cert" -noout -pubkey | sha256_of) == "$(openssl pkey -in "$key" -pubout 2>/dev/null | sha256_of)" ]] \
    || die "private key does not match the certificate"
  openssl x509 -checkend 0 -noout -in "$cert" >/dev/null || die "certificate has expired"
  openssl x509 -checkend $((MIN_VALID_DAYS * 86400)) -noout -in "$cert" >/dev/null \
    || warn "certificate expires within $MIN_VALID_DAYS days ($(openssl x509 -in "$cert" -noout -enddate | cut -d= -f2))"
  if [[ -n $ca ]]; then
    openssl verify -CAfile "$ca" -untrusted "$cert" "$cert" >/dev/null 2>&1 \
      || die "certificate does not chain to the provided CA"
  fi
  log "certificate OK for $host (expires $(openssl x509 -in "$cert" -noout -enddate | cut -d= -f2))"
}

# ---------------------------------------------------------------------------
# Trust (read-only; usable by any phase)
# ---------------------------------------------------------------------------
resolve_quay_ca() {
  local out="$TLS_DIR/quay-ca.pem" p=.registry.tls.source
  mkdir -p "$TLS_DIR"
  : >"$out"
  case $TLS_MODE in
    ingress)
      oc get configmap default-ingress-cert -n openshift-config-managed \
        -o jsonpath='{.data.ca-bundle\.crt}' >"$out" 2>/dev/null || true
      ;;
    selfsigned)
      if [[ -s $TLS_DIR/ca.pem ]]; then cp "$TLS_DIR/ca.pem" "$out"
      else secret_key "$QB_NS" "${QB_NAME}-bootstrap-ca" tls.crt >"$out" 2>/dev/null || true
      fi
      ;;
    custom)
      if [[ -s $TLS_DIR/ca.pem ]]; then cp "$TLS_DIR/ca.pem" "$out"
      elif cfg_has "$p.file.ca"; then cp "$(abs_path "$(cfg "$p.file.ca")")" "$out"
      elif cfg_has "$p.secret"; then secret_key "$(cfg "$p.secret.namespace" "$QB_NS")" "$(cfg "$p.secret.name")" ca.crt >"$out" 2>/dev/null || true
      elif cfg_has "$p.certManager"; then secret_key "$QB_NS" "$(certmanager_secret)" ca.crt >"$out" 2>/dev/null || true
      fi
      ;;
  esac
  QUAY_CA_FILE=''
  [[ -s $out ]] && QUAY_CA_FILE=$out

  API_CA_BUNDLE=''
  if [[ -n $QUAY_CA_FILE ]]; then
    local f
    API_CA_BUNDLE="$WORKDIR/api-ca-bundle.pem"
    : >"$API_CA_BUNDLE"
    for f in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem; do
      if [[ -r $f ]]; then cat "$f" >>"$API_CA_BUNDLE"; break; fi
    done
    cat "$QUAY_CA_FILE" >>"$API_CA_BUNDLE"
  fi
  TLS_TRUST_READY=true
}

# Add the registry CA to image.config additionalTrustedCA so cluster nodes can pull from Quay.
trust_cluster_ca() {
  [[ $(cfg .registry.tls.trust.cluster true) == true ]] || return 0
  if [[ -z $QUAY_CA_FILE ]] || { [[ $DRY_RUN != true ]] && publicly_trusted; }; then
    log "cluster trust: certificate is publicly trusted; nothing to add"
    return 0
  fi
  local cm current key=$QUAY_HOST patch
  cm=$(oc get image.config.openshift.io cluster -o jsonpath='{.spec.additionalTrustedCA.name}')
  if [[ -z $cm ]]; then
    cm=quay-bootstrap-registry-cas
    log "cluster trust: creating openshift-config/$cm and referencing it from image.config"
    jq -n --arg cm "$cm" --arg k "$key" --rawfile v "$QUAY_CA_FILE" --arg lk "$MANAGED_BY_KEY" --arg lv "$MANAGED_BY_VALUE" \
      '{apiVersion: "v1", kind: "ConfigMap", metadata: {name: $cm, namespace: "openshift-config", labels: {($lk): $lv}}, data: {($k): $v}}' \
      | kapply
    run oc patch image.config.openshift.io cluster --type merge -p "{\"spec\":{\"additionalTrustedCA\":{\"name\":\"$cm\"}}}"
    return 0
  fi
  current=$(oc get configmap "$cm" -n openshift-config -o json | jq -r --arg k "$key" '.data[$k] // empty')
  if [[ $current == "$(cat "$QUAY_CA_FILE")" ]]; then
    log "cluster trust: CA for $key already present in openshift-config/$cm"
    return 0
  fi
  log "cluster trust: adding CA for $key to openshift-config/$cm"
  patch=$(jq -n --arg k "$key" --rawfile v "$QUAY_CA_FILE" '{data: {($k): $v}}')
  run oc patch configmap "$cm" -n openshift-config --type merge -p "$patch"
}
