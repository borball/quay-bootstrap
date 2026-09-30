# quay-bootstrap

Bootstraps Red Hat Quay on an OpenShift cluster with ODF from a single YAML file:

1. **operator**: installs `quay-operator` pinned to a version (newest in the catalog if none given), with manual install-plan approval so OLM never upgrades on its own.
2. **registry**: builds the config bundle (TLS, storage, feature flags), creates the `QuayRegistry`, waits until it is available, and optionally adds the registry CA to cluster trust.
3. **init**: creates the first superuser through `/api/v1/user/initialize` and stores its password and OAuth token in a Secret.
4. **content**: creates organizations, quotas, robot accounts, teams, repositories, permissions and proxy-cache settings.

Every phase is idempotent: re-running applies only differences.

## Requirements

- `oc` logged in as cluster-admin, plus `jq` (1.6+), `yq` v4 ([mikefarah](https://github.com/mikefarah/yq)), `curl`, `openssl`
- bash 3.2+ (works with the macOS default)
- ODF installed; NooBaa (MCG) Ready for the default managed object storage
- Connected cluster (`redhat-operators` catalog reachable)

## Usage

```bash
./quay-bootstrap.sh -c examples/minimal.yaml --dry-run   # preview
./quay-bootstrap.sh -c examples/minimal.yaml             # all phases
./quay-bootstrap.sh -c site.yaml --phase content         # only orgs/repos
./quay-bootstrap.sh -c site.yaml --destroy --yes         # remove everything it created
```

Credentials end up in `<registry namespace>/<admin.outputSecret>` (default `quay-enterprise/quay-bootstrap-creds`):

```bash
oc extract secret/quay-bootstrap-creds -n quay-enterprise --to=-
```

Keys: `username`, `password`, `email`, `token`, `endpoint`, `ca.crt` (private CA only), `robot.<org>.<robot>`, `proxycache.<org>.hash`.

See [`examples/reference.yaml`](examples/reference.yaml) for every option.

## Version selection

| `operator.channel` | `operator.csv` | Result |
|---|---|---|
| unset | unset | channel with the newest head version, and that head |
| set | unset | head of that channel |
| unset | set | the channel that contains the CSV |
| set | set | exactly that, verified against the channel |

- **Unpinned re-runs:** with no version set, every re-run moves to the newest version. Set `operator.autoUpgrade: false` to keep the installed version instead.
- **Upgrades:** raise the version and re-run. The script approves only install plans that don't go beyond the requested version. Plans past the pin, such as the upgrade OLM queues after a pinned install, stay unapproved. OLM can only upgrade to the channel head, so a target below the head that can't be reached fails with a clear message. Downgrades are refused.
- **Existing subscription:** a `quay-operator` Subscription that already exists in any namespace is reused; a second one is never created. A namespace-scoped OperatorGroup must include the registry namespace, which preflight checks.

## Route and TLS

| `tls.mode` | Hostname | Quay `tls` / route | Certificate |
|---|---|---|---|
| `ingress` (default) | unset, or `<label>.<apps domain>` | managed, edge route | cluster ingress wildcard |
| `custom` | any FQDN | unmanaged, passthrough | `file`, existing `secret`, or `certManager` |
| `selfsigned` | any FQDN | unmanaged, passthrough | CA kept in `<name>-bootstrap-ca`, server cert issued from it |

- `registry.route.managed: false` skips the Route; you expose `<name>-quay-app` (443, passthrough) yourself.
- Certificates are checked before deployment: SAN covers the hostname, key matches, not expired (warning within `minValidDays`), and the chain verifies against `ca`. When the cert file holds only the leaf, intermediates from `ca` are appended.
- A private CA is:
  - added to Quay's own trust (`extra_ca_cert_*`);
  - added to `image.config.openshift.io/cluster` `additionalTrustedCA` so nodes can pull (`tls.trust.cluster`, default on). This is skipped when the endpoint already validates against public CAs;
  - used by the script's API calls;
  - written to the output Secret as `ca.crt` for workstations (`/etc/containers/certs.d/<host>/ca.crt`).
- `tls.extraCAs` lists CAs Quay must trust for outbound connections (private upstream registries, S3, LDAP).
- Hostnames outside the apps domain need DNS pointing at the router (e.g. a CNAME to `router-default.<apps domain>`).
- cert-manager renewals update the Secret; re-run `--phase registry` to roll the new cert into Quay.

## Storage

- **Object storage** comes from `storage.object`, or is chosen automatically:
  1. `managed`: the operator provisions a bucket on NooBaa. This is the default when NooBaa is Ready.
  2. `obc`: an ObjectBucketClaim on `storage.object.storageClass` (NooBaa → `RHOCSStorage`, RGW → `RadosGWStorage`). This is the automatic fallback when only the RGW StorageClass exists. The in-cluster service CA is trusted automatically.
  3. `s3`: explicit endpoint and credentials (`S3Storage`, `RadosGWStorage` or `RHOCSStorage`).
- **Block storage** (managed postgres / clair-postgres PVCs) uses the cluster's default StorageClass; the operator has no per-component StorageClass setting. If no default exists, `storage.block.storageClass`, then `ocs-storagecluster-ceph-rbd`, then the first StorageClass is marked default (`setDefaultIfMissing: true`). Volume sizes are set with `postgresVolumeSize` / `clairPostgresVolumeSize`.

## Organizations and proxy cache

- Proxy cache is configured **per organization**. To cache only part of an upstream, narrow the upstream path (`docker.io/library`, `quay.io/prometheus`) and give it its own organization. A proxy-cache organization cannot also define repositories; the config is rejected.
- Upstream credentials are validated through `validateproxycache` before they are applied. Quay never returns them, so changes are detected through a hash stored in the output Secret.
- Principals in `members` / `permissions` are `{robot: name}` (org robot), `{user: name}` or `{team: name}`. Robots and teams must be declared in the same organization (`owners` always exists); preflight rejects unknown references.

## Secrets in the config file

Any credential field accepts a literal or a reference:

```yaml
password: {from: env:QUAY_ADMIN_PASSWORD}
password: {from: file:./secrets/admin.txt}
password: {from: secret:quay-enterprise/my-secret/password}
password: {from: generate}   # admin password only; reused from the output Secret on re-runs
```

## Security

- The output Secret holds the admin password, the admin token and the robot tokens. The `<name>-bootstrap-ca` Secret (self-signed mode) holds a CA private key. Restrict `get secrets` in the registry namespace.
- `security.hardenAfterBootstrap: true` switches first-user initialization off and sets `BROWSER_API_CALLS_XHR_ONLY: true` once the admin token exists. This costs one extra Quay rollout on the first run. Later runs keep working with the stored token.
- API writes are never retried after an ambiguous server error, so `/user/initialize` can't be replayed. TLS verification failures stop the script immediately.
- Robot tokens are never put on command lines: use `--password-stdin` as shown in the summary.

## Notes and limitations

- `/api/v1/user/initialize` works only on an empty database. If Quay already has users and the output Secret has no working token, create an OAuth token for a superuser in the UI and pass it as `admin.token`.
- The script manages robot-account tokens. It does not create organization OAuth-application tokens, because generating them needs an interactive authorization step.
- Changing the config bundle restarts the Quay pods (the operator redeploys them).
- `--destroy` deletes the QuayRegistry (and with it the database PVCs), any OBC it created (and its bucket), its Secrets and Certificates, and the cluster trust entry. It also removes the operator unless `--keep-operator` is set or other QuayRegistries exist. Namespaces are deleted only with `--delete-namespace` and only if this tool created them.
