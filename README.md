# Vaultwarden Backup (local machine)

A script for backing up our vaultwarden (SQLite) and getting it running locally on any machine.

Each run of `./backup.sh`:

1. finds the running vaultwarden container on the server via SSH,
2. creates a consistent snapshot with vaultwarden's built-in `backup` command
   (falls back to `sqlite3 .backup` on the host for vaultwarden < 1.32) and downloads it to `backups/`,
3. pins the image in the local `compose.yml` to the exact version the server runs
   (`latest` / `alpine` tags are resolved to the running version),
4. stops the local vaultwarden, puts the new DB into `data/db.sqlite3` and starts it again,
5. keeps only the newest 5 backups.

When it's done, the local copy is at <https://localhost:4280>. Log in with your usual account.

## Requirements

**Local:** bash, ssh with key-based login to the server (the script runs non-interactively), docker with compose v2.
`sqlite3` is optional; if installed, every download gets an integrity check.
`mkcert` is optional too; see [HTTPS](#https).

**Server:** vaultwarden with SQLite, run via docker compose. The SSH user needs docker access,
either via the `docker` group or passwordless sudo (see `REMOTE_SUDO`).

## Setup

```sh
cp .env.example .env
```

Then set in `.env` (gitignored):

| Variable              | Required | Description                                                                 |
| --------------------- | -------- | --------------------------------------------------------------------------- |
| `SSH_HOST`            | yes      | SSH destination, e.g. `user@vault.example.com` or a `~/.ssh/config` alias   |
| `REMOTE_COMPOSE_PATH` | yes      | Path to the compose file on the server, e.g. `/opt/vaultwarden/compose.yml` |
| `REMOTE_SUDO`         | no       | Prefix for remote docker commands, e.g. `sudo`                              |
| `KEEP`                | no       | Number of backups to keep (default `5`)                                     |

## Usage

```sh
./backup.sh
```

Backups are stored as `backups/db_<YYYYmmdd_HHMMSS>_<version>.sqlite3`, so each file shows
which vaultwarden version wrote it.

To run it daily, e.g. via cron:

```cron
0 3 * * * /path/to/backup.sh >> /path/to/backup.log 2>&1
```

## Good to know

- Only the database is backed up. Attachments and Sends stored in the server's data folder are not included.
- The local instance is overwritten on every run, so changes made there get lost. The files in `backups/` are never modified.
- Don't edit the image tag in `compose.yml` by hand; the script sets it on every run.

## HTTPS

The Bitwarden web vault refuses to log in over plain `http`, even on `localhost`
("Insecure URL not allowed. All URLs must use HTTPS."). So the local vaultwarden serves HTTPS itself,
with a certificate in `certs/` (gitignored) that the script creates on the first run:

- **With [mkcert](https://github.com/FiloSottile/mkcert)** installed, the certificate is trusted by your browser.
  Run `mkcert -install` once beforehand.
- **Without it**, a self-signed certificate is created. Your browser warns on the first visit;
  accept the warning to continue.

To switch from the self-signed certificate to mkcert later, delete `certs/` and run `./backup.sh` again.
