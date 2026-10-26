# Apple Web Push proxy exception

This deployment tool adds `web.push.apple.com` to the existing app-scoped
`no_proxy` and `NO_PROXY` lists. It preserves other exclusions and proxy routes.
It does not modify Discourse Core, plugins, user subscriptions, notification
settings, the database, firewall rules, or the Docker image.

The incident was reproduced using credential-free HEAD requests to the public
Apple push host: the environment proxy failed during TLS with `EOFError`, while
direct `FinalDestination::HTTP` succeeded. An HTTP 405 at the public root confirms
transport only; it does not prove device delivery or use a subscription endpoint.

## Activation

1. Review the exact source hashes, active launcher configuration, service script,
   template ordering and protected directory ancestry. `after_code` must run after
   the service launcher exists. The installer refuses environment clearing,
   additional environment loaders, unknown managed blocks and proxy rewrites.
2. Run the fixture checks and normal repository CI. Merge the reviewed commit.
3. Copy only these merged deployment files into a private task directory and
   verify their Git source hashes. Do not deploy or update the runtime plugin.
4. Run `release.py apply` as root with the existing container, app config, origin,
   merged commit, expected config SHA-256 and expected launcher SHA-256.
   It uses the shared production release lock, takes private exact backups,
   changes only the two environment values plus one tagged `after_code` hook,
   installs the protected sourceable policy, and restarts the existing Unicorn
   service. This also reloads the native Sidekiq processes on this deployment.
5. Verify actual web **and** Sidekiq process environments; an unrelated
   `docker exec` process retains the original Docker environment and is not proof.
   Probe native `FinalDestination::HTTP` with default WebPush proxy options:
   Apple must bypass the proxy and the unrelated control must keep its prior route.
   Confirm HTTP health, unchanged plugin/source and asset fingerprints, and
   natural queue recovery. Do not send a test push without separate authorization.

The future-build hook embeds hash-pinned installer and policy bytes directly in
launcher YAML. It runs last among existing `after_code` hooks and installs into
root-protected `/etc/isbf/apple-web-push/` before the service starts. No code is
sourced as root from application-writable shared storage. Existing image contents,
plugin release links, assets and peer hooks are retained; no image rebuild is used.

`release.py` prints only digests, status flags, health codes and private backup
locations. Never print the launcher YAML, environment values, subscription keys,
endpoints, user IDs, message bodies or raw delivery logs. Configuration backups
contain secrets and must remain server-side under the private root backup folder.

## Rollback

Use the same merged tools with `release.py rollback`, the saved private backup,
existing container, config and origin. It checks backup digests and the container
identity, restores only recognized startup bytes and owned YAML fields, preserves
unrelated later configuration edits, and reloads the service. Changes to the owned
fields or launcher stop the rollback for review. A failed activation attempts the
same guarded inverse. No user data or subscription is restored or deleted.

## Local fixtures

```sh
python3 -m pip install PyYAML==6.0.3
python3 -m unittest discover -s deploy/apple-web-push/tests -v
sh -n deploy/apple-web-push/env-policy.sh
bash -n deploy/apple-web-push/env-policy.sh
```

Linux root fixtures run in private temporary directories under `/root`; they do
not contact a service. Windows skips ownership fixtures. The dedicated CI job runs
all fixtures as root so those checks cannot silently remain unverified.
