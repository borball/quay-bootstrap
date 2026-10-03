#!/usr/bin/env bash
# Bootstrap Red Hat Quay on OpenShift (with ODF) from a YAML description:
# operator install (pinned version) -> QuayRegistry -> first admin + token -> orgs/repos/proxy cache.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
for _lib in common preflight operator storage tls api registry init content destroy; do
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/$_lib.sh"
done

ALL_PHASES="operator,registry,init,content"

usage() {
  cat <<EOF
Usage: $(basename "$0") -c <config.yaml> [options]

Phases (run in order; preflight always runs):
  operator   install the Quay operator (pinned CSV, manual install-plan approval)
  registry   config bundle, TLS, object storage, QuayRegistry; wait until available
  init       create the first superuser and its API token (stored in a secret)
  content    organizations, robots, teams, repositories, permissions, proxy cache

Options:
  -c, --config FILE     configuration file (required)
  -p, --phase LIST      comma-separated phases to run (default: $ALL_PHASES)
  -n, --dry-run         show what would change without changing anything
      --destroy         remove the registry and everything this tool created (needs --yes)
      --yes             confirm --destroy
      --keep-operator   with --destroy: leave the operator installed
      --delete-namespace  with --destroy: delete namespaces created by this tool
  -v, --verbose         debug output
  -h, --help            show this help

Examples:
  $(basename "$0") -c examples/minimal.yaml
  $(basename "$0") -c site.yaml --phase content
  $(basename "$0") -c site.yaml --dry-run
EOF
}

parse_args() {
  CONFIG='' PHASES=$ALL_PHASES DRY_RUN=false DESTROY=false ASSUME_YES=false
  KEEP_OPERATOR=false DELETE_NAMESPACE=false VERBOSE=false
  while (($#)); do
    case $1 in
      -c | --config) [[ $# -ge 2 ]] || die "$1 needs a value"; CONFIG=$2; shift 2 ;;
      -p | --phase | --phases) [[ $# -ge 2 ]] || die "$1 needs a value"; PHASES=$2; shift 2 ;;
      -n | --dry-run) DRY_RUN=true; shift ;;
      --destroy) DESTROY=true; shift ;;
      --yes | -y) ASSUME_YES=true; shift ;;
      --keep-operator) KEEP_OPERATOR=true; shift ;;
      --delete-namespace) DELETE_NAMESPACE=true; shift ;;
      -v | --verbose) VERBOSE=true; shift ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown argument: $1 (see --help)" ;;
    esac
  done
  [[ -n $CONFIG ]] || { usage >&2; die "--config is required"; }
  local ph
  for ph in ${PHASES//,/ }; do
    [[ ",$ALL_PHASES," == *",$ph,"* ]] || die "unknown phase '$ph' (valid: $ALL_PHASES)"
  done
}

phase_enabled() { [[ ",$PHASES," == *",$1,"* ]]; }

print_summary() {
  step "Summary"
  local host=${QUAY_HOST:-<pending>}
  cat <<EOF
Registry:     https://$host
Operator:     ${OP_CSV:-<not managed in this run>}${OP_CHANNEL:+ (channel $OP_CHANNEL)}
Admin user:   $ADMIN_USER
Credentials:  oc extract secret/$CREDS_SECRET -n $QB_NS --to=-
              keys: username, password, token, endpoint${QUAY_CA_FILE:+, ca.crt}, robot.<org>.<robot>
              The secret holds admin and robot tokens: restrict 'get secrets' in $QB_NS accordingly.
Login:        oc extract secret/$CREDS_SECRET -n $QB_NS --keys=password --to=- | podman login $host -u $ADMIN_USER --password-stdin
Robot login:  oc extract secret/$CREDS_SECRET -n $QB_NS --keys=robot.<org>.<robot> --to=- | podman login $host -u '<org>+<robot>' --password-stdin
EOF
  if [[ -n ${QUAY_CA_FILE-} ]]; then
    cat <<EOF
Client trust: the registry certificate is signed by a private CA. On a workstation:
              sudo mkdir -p /etc/containers/certs.d/$host
              oc extract secret/$CREDS_SECRET -n $QB_NS --keys=ca.crt --to=- | sudo tee /etc/containers/certs.d/$host/ca.crt
EOF
  fi
  if [[ $ROUTE_MANAGED == false ]]; then
    echo "Route:        not managed; expose service ${QB_NAME}-quay-app (port 443, TLS passthrough) as $host yourself"
  fi
  if [[ $TLS_MODE == custom ]] && cfg_has .registry.tls.source.certManager; then
    echo "Renewal:      cert-manager renews the certificate; re-run '--phase registry' to roll it into Quay"
  fi
}

main() {
  parse_args "$@"
  WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/quay-bootstrap.XXXXXX")
  trap 'rm -rf "$WORKDIR"' EXIT
  BUNDLE_DIR="$WORKDIR/bundle" TLS_DIR="$WORKDIR/tls"
  QUAY_CA_FILE='' API_CA_BUNDLE=''
  [[ $DRY_RUN != true ]] || warn "dry-run: nothing will be changed"

  load_config
  if [[ $DESTROY == true ]]; then
    preflight_cluster
    detect_subscription
    destroy_all
    return 0
  fi
  preflight

  if phase_enabled operator; then install_operator; fi
  if phase_enabled registry; then deploy_registry; fi
  if [[ $DRY_RUN == true ]] && ! registry_available; then
    log "[dry-run] registry is not available yet; init and content will run after it is deployed"
  else
    if phase_enabled init; then init_admin; fi
    if phase_enabled content; then reconcile_content; fi
  fi
  # First run with hardening: the admin exists only now, so roll out the locked-down config once.
  if phase_enabled registry && harden_wanted && [[ ${HARDENED-} == false && $DRY_RUN != true ]] && admin_initialized; then
    step "Hardening: disabling first-user initialization (Quay pods will restart)"
    deploy_registry
  fi
  print_summary
}

main "$@"
