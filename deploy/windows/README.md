# Dockur Windows 11

This is the Windows 11 virtual machine migrated from the previous Arch
installation. It is the same QEMU disk and UEFI state, now started manually
through Docker Compose. It is **not** a libvirt domain and Windows was not
reinstalled.

## Fixed image and parameters

- Image: `dockurr/windows:6.05`
- `VERSION: "11"`
- `RAM_SIZE: "4G"`
- `CPU_CORES: "4"`
- `DISK_SIZE: "64G"`
- `restart: "no"` (Docker and the host never start the VM automatically)
- Published ports are loopback only:
  - `127.0.0.1:8006` — web console
  - `127.0.0.1:3389/tcp` and `127.0.0.1:3389/udp` — RDP

Do not change `VERSION`, and do not set `CLEAR=Y` or otherwise ask Dockur to
reinstall. The container must keep using the existing disk, ROM, NVRAM and MAC
identity. `BOOT_MODE` is intentionally unset; do not add it or replace the
generated `.rom`/`.vars`/`.mac` files.

## Data

The persistent Windows storage is:

```
/var/lib/windows/windows
```

It is bind-mounted to `/storage` inside the container and contains the
original `data.img`, `windows.rom`, `windows.vars`, `windows.mac`,
`windows.base`, `windows.boot` and `windows.ver`. Nothing in this directory is
tracked by Git.

The read-only Arch source remains at:

```
/mnt/arch-home/calendar/docker/win/windows
```

It is kept unchanged as the rollback source. Do not delete or modify it as
part of normal operation.

This data is **not** part of the Restic backup set (`my.backup.paths` only
covers `/home/calendar` and `/var/lib/sops-nix`). Treat the Arch copy and any
separate disk backup as the recovery path.

## Start, stop and logs

Run from this directory:

```bash
cd deploy/windows

# Validate the rendered configuration
sudo docker compose config

# Start the VM (manual only)
sudo docker compose up -d windows

# Follow the container/QEMU log
sudo docker compose logs -f windows

# Stop the VM gracefully (Windows shutdown is preferred when possible)
sudo docker compose stop windows
```

`docker compose down` is not needed for normal use; the bind-mounted storage
is outside the container and is not deleted by either command.

The container is deliberately left stopped after verification. A host reboot
or Docker daemon restart will not boot Windows again because the restart
policy is `no`.

## Access

### Web console

Open <http://127.0.0.1:8006> on `main` while the container is running. The
port is not exposed to the LAN.

### RDP with FreeRDP

`freerdp` is installed on `main`. Use the interactive password prompt; do not
put the password in a command line, script, environment variable or Git file.

```bash
xfreerdp \
  /v:127.0.0.1:3389 \
  /u:Docker \
  /d:WIN-ERINGJ9FD3E \
  /cert:tofu \
  +dynamic-resolution \
  +clipboard
```

`WIN-ERINGJ9FD3E` is the guest computer name, used here as the local account
domain. `Docker` is the local account shown in `C:\Users\Docker`. If the
account name is different, use the name shown on the Windows login screen.
The password is entered interactively and is not stored in this repository.

`/cert:tofu` is intentional. Do not switch the default to `/cert:ignore`.
Under niri, `xfreerdp` runs through XWayland; if XWayland is unavailable, try
`wlfreerdp` from the same package.

There is no host/Windows file sharing configured at this stage. If sharing is
needed later, add a dedicated restricted directory instead of mounting the
whole home directory.

## Credentials

Windows account credentials are managed inside the guest, not by Compose.
No password is stored in this repository or in `compose.yaml`. Change any weak
password from inside Windows after the first successful login.
