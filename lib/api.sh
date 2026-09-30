# shellcheck shell=bash
# Quay REST API client. Results are returned in API_STATUS / API_BODY.
# The bearer token is passed to curl through a header file so it never appears in `ps`.

qcurl() {
  if [[ $API_INSECURE == true ]]; then
    curl -k "$@"
  elif [[ -n ${API_CA_BUNDLE-} ]]; then
    curl --cacert "$API_CA_BUNDLE" "$@"
  else
    curl "$@"
  fi
}

set_token() {
  QUAY_TOKEN=$1
  printf 'Authorization: Bearer %s\n' "$1" >"$WORKDIR/auth.hdr"
}

_api_curl() { # method path data
  local args=(-sS -X "$1" -o "$WORKDIR/api.out" -w '%{http_code}' -H 'Accept: application/json')
  [[ -z ${QUAY_TOKEN-} ]] || args+=(-H "@$WORKDIR/auth.hdr")
  if [[ -n $3 ]]; then
    printf '%s' "$3" | qcurl "${args[@]}" -H 'Content-Type: application/json' --data-binary @- "$API_BASE$2"
  else
    qcurl "${args[@]}" "$API_BASE$2"
  fi
}

TLS_CURL_ERRORS=" 35 51 58 59 60 77 83 90 91 "

# Retry only when the request cannot have been applied, or when it is a read.
# Writes such as /user/initialize must never be replayed after an ambiguous 5xx.
api_should_retry() { # <method> <http-status> <curl-rc>
  case $3 in 6 | 7) return 0 ;; esac # DNS failure / connection refused
  [[ $1 == GET ]] || return 1
  case $3 in 28 | 52 | 56) return 0 ;; esac # timeout / empty reply / recv error
  [[ $2 == 502 || $2 == 503 || $2 == 504 ]]
}

api() { # api <METHOD> <path> [json]
  local method=$1 path=$2 data=${3-} attempt=0 rc
  if [[ $DRY_RUN == true && $method != GET ]]; then
    log "[dry-run] $method $path${data:+ $(redact_json <<<"$data")}"
    API_STATUS=200 API_BODY='{}'
    return 0
  fi
  while :; do
    rm -f "$WORKDIR/api.out"
    rc=0
    API_STATUS=$(_api_curl "$method" "$path" "$data" 2>"$WORKDIR/api.err") || rc=$?
    [[ $rc == 0 ]] || API_STATUS=000
    [[ $TLS_CURL_ERRORS != *" $rc "* ]] || die "TLS error talking to $API_BASE: $(cat "$WORKDIR/api.err") (check registry.tls / api.insecure)"
    if api_should_retry "$method" "$API_STATUS" "$rc" && ((++attempt < 6)); then
      debug "$method $path -> $API_STATUS (curl $rc), retrying ($attempt)"
      sleep $((attempt * 5))
      continue
    fi
    break
  done
  API_BODY=$(cat "$WORKDIR/api.out" 2>/dev/null || true)
  [[ $API_STATUS != 000 ]] || API_BODY=$(cat "$WORKDIR/api.err")
  debug "$method $path -> $API_STATUS"
}

api_error() {
  local msg
  msg=$(jq -r '.error_message // .message // .detail // .error_description // .error // empty' <<<"$API_BODY" 2>/dev/null) || msg=''
  printf '%s' "${msg:-${API_BODY:0:300}}"
}

api_expect() { # api_expect "<codes>" <METHOD> <path> [json]
  local codes=$1
  shift
  api "$@"
  [[ " $codes " == *" $API_STATUS "* ]] || die "$1 $2 failed (HTTP $API_STATUS): $(api_error)"
}

quay_healthy() {
  local rc=0
  qcurl -fsS -o /dev/null "$API_BASE/health/instance" 2>"$WORKDIR/health.err" || rc=$?
  # A certificate problem will not fix itself; fail now instead of waiting for the timeout.
  [[ $TLS_CURL_ERRORS != *" $rc "* ]] || die "TLS error talking to $API_BASE: $(cat "$WORKDIR/health.err") (check registry.tls / api.insecure)"
  [[ $rc == 0 ]]
}

# True if the endpoint validates against the system CA store alone (no private CA involved).
publicly_trusted() {
  curl -sS -o /dev/null "https://$QUAY_HOST/health/instance" 2>/dev/null
}

# Make sure host, CA trust and API reachability are known (any phase can call this).
ensure_api_context() {
  [[ -z ${API_BASE-} ]] || return 0
  [[ ${TLS_TRUST_READY-} == true ]] || resolve_quay_ca
  [[ -n $QUAY_HOST ]] || discover_endpoint
  API_BASE="https://$QUAY_HOST"
  wait_until 600 10 "Quay API at $API_BASE" quay_healthy
}
