# AxonHub local deployment

This directory contains the fixed AxonHub Compose model requested for the main
workstation. Do not replace the images with `latest`.

## Files and secrets

- `compose.yaml`: PostgreSQL 16 + AxonHub, private `backend` network, separate
  `egress` network, PostgreSQL without a host port, AxonHub bound to
  `127.0.0.1:${AXONHUB_PORT:-8090}`.
- `.env.example`: versioned template. It contains no real password.
- `.env`: local runtime file, mode `0600`, ignored by Git. It contains the
  PostgreSQL password. Never commit, upload, or paste it into a chat.
- PostgreSQL data lives in the Docker named volume `axonhub_postgres_data` on
  the NixOS root filesystem, not on Arch's `@home` and not on the 128 GB USB.

## Start and check

```bash
cd deploy/axonhub
sudo docker compose --env-file .env config --quiet
sudo docker compose --env-file .env pull
sudo docker compose --env-file .env up -d
sudo docker compose --env-file .env ps
curl --fail --silent --show-error http://127.0.0.1:8090/health
```

If this Docker installation does not discover the Compose CLI plugin, use
`sudo docker-compose --env-file .env ...` instead. Do not install a second
Compose implementation just to change the command name.

## Registry pulls and proxy

Image pulls are performed by the `dockerd` daemon, not by the `docker` CLI.
Exporting `HTTPS_PROXY` in an interactive shell does not make the daemon use
that proxy. This host sets the daemon's own environment in
`hosts/main/docker.nix`:

```nix
systemd.services.docker.environment = {
  HTTP_PROXY = "http://127.0.0.1:7897";
  HTTPS_PROXY = "http://127.0.0.1:7897";
  NO_PROXY = "localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,.local";
};
```

After a rebuild/switch, verify the running unit and pull again:

```bash
systemctl show docker -p Environment | tr ':' '\n' | grep -E 'HTTP_PROXY|HTTPS_PROXY|NO_PROXY'
cd deploy/axonhub
sudo docker compose --env-file .env pull
```

Do not disable TLS verification and do not point the daemon at a proxy that
is not already working. If a registry mirror lacks the image, Docker should
fall back to Docker Hub; the daemon proxy makes that fallback usable.

Expected checks:

```bash
ss -lntp | grep ':8090'          # must show only 127.0.0.1:8090
ss -lntp | grep ':5432'          # must show nothing on the host
sudo docker compose --env-file .env ps
```

PostgreSQL and AxonHub should both become healthy. A healthy PostgreSQL is a
prerequisite for AxonHub because of `depends_on.condition: service_healthy`.

## Logs

```bash
sudo docker compose --env-file .env logs --tail=100 postgres
sudo docker compose --env-file .env logs --tail=100 axonhub
```

The logging driver is `json-file` with rotation (`10m`, 3 files) per service.
Do not replace it with an unbounded driver.

## Backup

Create the ignored backup directory once:

```bash
cd deploy/axonhub
mkdir -p backups
```

Take a consistent PostgreSQL dump (custom format):

```bash
cd deploy/axonhub
stamp=$(date +%Y-%m-%d-%H%M%S)
sudo docker compose --env-file .env exec -T postgres \
  pg_dump -U axonhub -d axonhub -Fc > "backups/axonhub-$stamp.dump"
pg_restore --list "backups/axonhub-$stamp.dump" >/dev/null
sha256sum "backups/axonhub-$stamp.dump"
```

The dump is written by the invoking user; the password stays in `.env` and is
not passed on the command line. Keep at least one copy off this machine and
store the PostgreSQL password separately in a password manager. A database
dump without its password is not a complete recovery set.

## Restore test in an isolated temporary environment

Never test a restore by overwriting the live volume. Use a separate Docker
project, a separate volume, and no host port. The following is a design to run
only after the live deployment is healthy:

```bash
cd deploy/axonhub
# 1. Start a throwaway PostgreSQL with its own volume and a random password.
restore_pw=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
sudo docker run --rm -d --name axonhub-restore-test \
  -e POSTGRES_DB=axonhub \
  -e POSTGRES_USER=axonhub \
  -e POSTGRES_PASSWORD="$restore_pw" \
  -v axonhub_restore_test:/var/lib/postgresql/data \
  postgres:16-alpine
unset restore_pw

# 2. Wait for readiness, copy the dump in, and restore it.
sudo docker exec axonhub-restore-test \
  pg_isready -U axonhub -d axonhub
sudo docker cp "backups/axonhub-<stamp>.dump" \
  axonhub-restore-test:/tmp/axonhub.dump
sudo docker exec axonhub-restore-test \
  pg_restore -U axonhub -d axonhub --clean --if-exists /tmp/axonhub.dump

# 3. Inspect a few tables/counts, then remove only the test container/volume.
sudo docker exec axonhub-restore-test \
  psql -U axonhub -d axonhub -c '\dt'
sudo docker rm -f axonhub-restore-test
sudo docker volume rm axonhub_restore_test
```

Do not run `docker compose down -v`, `docker volume prune`, or any command that
deletes `axonhub_postgres_data`. The restored test must use a different volume
name from the live one.

## Network and security notes

- `backend` is `internal: true`; PostgreSQL is reachable only by AxonHub.
- `egress` gives AxonHub outbound access for upstream APIs.
- AxonHub drops all Linux capabilities, uses a non-root UID, a read-only root
  filesystem, and only a small `/tmp` tmpfs.
- Do not add `privileged`, the Docker socket, Arch's home, or the backup USB to
  this Compose file.
- Registry mirrors are third-party services. They are only pull accelerators;
  they are not a trust boundary. Do not disable TLS verification to work around
  a mirror failure.
