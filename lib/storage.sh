# shellcheck shell=bash
# Storage planning (preflight) and provisioning (registry phase).
#
# Object storage (registry blobs), in order of precedence:
#   storage.object.type = managed | obc | s3   -> as configured
#   unset, NooBaa Ready                         -> managed (operator creates the bucket on NooBaa)
#   unset, RGW StorageClass present             -> obc on ocs-storagecluster-ceph-rgw
# Block storage (managed postgres / clair-postgres PVCs) comes from the cluster's default
# StorageClass; if none is marked default, one is selected and marked default.

noobaa_ready() {
  [[ $(oc get noobaa -n "$ODF_NS" -o jsonpath='{.items[0].status.phase}' 2>/dev/null) == Ready ]]
}

default_storage_class() {
  oc get storageclass -o json | jq -r '[.items[] | select(
      .metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true" or
      .metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true")][0].metadata.name // empty'
}

plan_storage() {
  local odf
  odf=$(oc get storagecluster -n "$ODF_NS" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
  if [[ -z $odf ]]; then
    warn "no ODF StorageCluster found in $ODF_NS"
  elif [[ $odf != Ready ]]; then
    warn "ODF StorageCluster phase is '$odf' (expected Ready)"
  else
    log "ODF StorageCluster is Ready"
  fi

  OBJ_MODE=$(cfg .storage.object.type)
  OBC_SC=''
  if [[ -z $OBJ_MODE ]]; then
    if noobaa_ready; then
      OBJ_MODE=managed
    elif sc_exists ocs-storagecluster-ceph-rgw; then
      OBJ_MODE=obc OBC_SC=ocs-storagecluster-ceph-rgw
    else
      die "no object storage available: NooBaa is not Ready and no RGW StorageClass exists; configure storage.object"
    fi
    log "object storage not configured; selected '$OBJ_MODE'"
  fi

  case $OBJ_MODE in
    managed)
      noobaa_ready || die "storage.object.type=managed needs NooBaa (ODF Multicloud Object Gateway) in $ODF_NS to be Ready"
      ;;
    obc)
      [[ -n $OBC_SC ]] || OBC_SC=$(cfg .storage.object.storageClass)
      if [[ -z $OBC_SC ]]; then
        if sc_exists openshift-storage.noobaa.io; then OBC_SC=openshift-storage.noobaa.io
        elif sc_exists ocs-storagecluster-ceph-rgw; then OBC_SC=ocs-storagecluster-ceph-rgw
        else die "storage.object.type=obc: no bucket StorageClass found; set storage.object.storageClass"
        fi
      fi
      sc_exists "$OBC_SC" || die "StorageClass $OBC_SC does not exist"
      ;;
    s3)
      local k
      for k in bucket accessKey secretKey; do
        cfg_has ".storage.object.s3.$k" || die "storage.object.s3.$k is required for type s3"
      done
      ;;
    *) die "storage.object.type must be managed, obc or s3 (got '$OBJ_MODE')" ;;
  esac

  DEFAULT_SC=$(default_storage_class)
  BLOCK_SC=$(cfg .storage.block.storageClass)
  SC_TO_MARK_DEFAULT=''
  if [[ -n $BLOCK_SC ]]; then sc_exists "$BLOCK_SC" || die "StorageClass $BLOCK_SC does not exist"; fi
  if [[ -z $DEFAULT_SC ]]; then
    SC_TO_MARK_DEFAULT=$BLOCK_SC
    if [[ -z $SC_TO_MARK_DEFAULT ]] && sc_exists ocs-storagecluster-ceph-rbd; then SC_TO_MARK_DEFAULT=ocs-storagecluster-ceph-rbd; fi
    [[ -n $SC_TO_MARK_DEFAULT ]] || SC_TO_MARK_DEFAULT=$(oc get storageclass -o jsonpath='{.items[0].metadata.name}')
    [[ -n $SC_TO_MARK_DEFAULT ]] || die "no StorageClass exists for the postgres volumes"
    [[ $(cfg .storage.block.setDefaultIfMissing true) == true ]] \
      || die "no default StorageClass; mark one default or set storage.block.setDefaultIfMissing: true"
    warn "no default StorageClass; $SC_TO_MARK_DEFAULT will be marked default (the operator uses it for its PVCs)"
  elif [[ -n $BLOCK_SC && $BLOCK_SC != "$DEFAULT_SC" ]]; then
    warn "the Quay operator creates its PVCs on the default StorageClass ($DEFAULT_SC); storage.block.storageClass=$BLOCK_SC cannot be applied to managed components"
  fi
}

ensure_block_storage() {
  [[ -n ${SC_TO_MARK_DEFAULT-} ]] || return 0
  log "marking StorageClass $SC_TO_MARK_DEFAULT as the cluster default"
  run oc annotate storageclass "$SC_TO_MARK_DEFAULT" storageclass.kubernetes.io/is-default-class=true --overwrite
}

# Writes $WORKDIR/storage.yaml (DISTRIBUTED_STORAGE_* keys) for unmanaged object storage.
ensure_object_storage() {
  : >"$WORKDIR/storage.yaml"
  case $OBJ_MODE in
    managed) log "object storage: managed by the operator (NooBaa)" ;;
    obc) ensure_obc_storage ;;
    s3) ensure_s3_storage ;;
  esac
}

obc_bound() { [[ $(oc get objectbucketclaim "$1" -n "$QB_NS" -o jsonpath='{.status.phase}' 2>/dev/null) == Bound ]]; }

ensure_obc_storage() {
  local obc="${QB_NAME}-quay-storage" host port bucket ak sk driver secure provisioner
  log "object storage: ObjectBucketClaim $obc on $OBC_SC"
  kapply <<EOF
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: $obc
  namespace: $QB_NS
  labels:
    $MANAGED_BY_KEY: $MANAGED_BY_VALUE
spec:
  generateBucketName: ${QB_NAME}-quay
  storageClassName: $OBC_SC
EOF
  wait_until 300 5 "ObjectBucketClaim $obc to be Bound" obc_bound "$obc"

  if [[ $DRY_RUN == true ]] && ! obc_bound "$obc"; then
    host='<obc-host>' port=443 bucket='<obc-bucket>' ak='<obc-key>' sk='<obc-secret>'
  else
    host=$(oc get configmap "$obc" -n "$QB_NS" -o jsonpath='{.data.BUCKET_HOST}')
    port=$(oc get configmap "$obc" -n "$QB_NS" -o jsonpath='{.data.BUCKET_PORT}')
    bucket=$(oc get configmap "$obc" -n "$QB_NS" -o jsonpath='{.data.BUCKET_NAME}')
    ak=$(secret_key "$QB_NS" "$obc" AWS_ACCESS_KEY_ID)
    sk=$(secret_key "$QB_NS" "$obc" AWS_SECRET_ACCESS_KEY)
  fi
  [[ -n $host && -n $bucket && -n $ak && -n $sk ]] || die "ObjectBucketClaim $obc is missing connection details"

  provisioner=$(oc get storageclass "$OBC_SC" -o jsonpath='{.provisioner}')
  case $provisioner in
    *noobaa.io/obc) driver=RHOCSStorage ;;
    *) driver=RadosGWStorage ;;
  esac
  secure=false
  [[ $port != 443 ]] || secure=true
  # In-cluster S3 endpoints are served with service-CA certificates.
  if [[ $secure == true ]]; then add_service_ca; fi
  write_storage_config "$driver" "$host" "$port" "$secure" "$bucket" "$ak" "$sk" /datastorage/registry ''
}

ensure_s3_storage() {
  local p=.storage.object.s3 driver host port secure bucket ak sk path region ca
  driver=$(cfg "$p.driver" S3Storage)
  host=$(cfg "$p.hostname")
  port=$(cfg "$p.port" 443)
  secure=$(cfg "$p.secure" true)
  bucket=$(cfg "$p.bucket")
  region=$(cfg "$p.region")
  path=$(cfg "$p.path" /datastorage/registry)
  ak=$(resolve_value "$p.accessKey")
  sk=$(resolve_value "$p.secretKey")
  case $driver in S3Storage | RadosGWStorage | RHOCSStorage) ;; *) die "$p.driver must be S3Storage, RadosGWStorage or RHOCSStorage" ;; esac
  [[ $driver == S3Storage || -n $host ]] || die "$p.hostname is required for $driver"
  log "object storage: $driver bucket $bucket${host:+ at $host}"
  if cfg_has "$p.ca"; then
    ca=$(resolve_value "$p.ca")
    printf '%s\n' "$ca" >"$BUNDLE_DIR/extra_ca_cert_object-storage.crt"
  fi
  write_storage_config "$driver" "$host" "$port" "$secure" "$bucket" "$ak" "$sk" "$path" "$region"
}

add_service_ca() {
  local ca
  wait_until 60 3 "service CA in $QB_NS" oc_exists configmap openshift-service-ca.crt -n "$QB_NS"
  ca=$(oc get configmap openshift-service-ca.crt -n "$QB_NS" -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null || true)
  [[ -n $ca ]] || { warn "service CA not found in $QB_NS; Quay may not trust the in-cluster S3 endpoint"; return 0; }
  printf '%s\n' "$ca" >"$BUNDLE_DIR/extra_ca_cert_service-ca.crt"
}

write_storage_config() { # driver host port secure bucket access secret path region
  local out="$WORKDIR/storage.yaml"
  if [[ $1 == S3Storage ]]; then
    HOST=$2 PORT=$3 BUCKET=$5 AK=$6 SK=$7 SPATH=$8 REGION=$9 yq -n '
      .DISTRIBUTED_STORAGE_CONFIG.default = ["S3Storage", {
        "s3_bucket": strenv(BUCKET), "storage_path": strenv(SPATH),
        "s3_access_key": strenv(AK), "s3_secret_key": strenv(SK),
        "host": strenv(HOST), "port": env(PORT), "s3_region": strenv(REGION)}]
      | .DISTRIBUTED_STORAGE_CONFIG.default[1] |= with_entries(select(.value != ""))' >"$out"
  else
    DRIVER=$1 HOST=$2 PORT=$3 SECURE=$4 BUCKET=$5 AK=$6 SK=$7 SPATH=$8 yq -n '
      .DISTRIBUTED_STORAGE_CONFIG.default = [strenv(DRIVER), {
        "hostname": strenv(HOST), "port": env(PORT), "is_secure": env(SECURE),
        "bucket_name": strenv(BUCKET), "access_key": strenv(AK), "secret_key": strenv(SK),
        "storage_path": strenv(SPATH)}]' >"$out"
  fi
  yq -i '.DISTRIBUTED_STORAGE_DEFAULT_LOCATIONS = [] | .DISTRIBUTED_STORAGE_PREFERENCE = ["default"]' "$out"
}
