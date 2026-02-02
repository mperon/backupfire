# pgbackup (Docker) — PostgreSQL backup + encryption + rclone upload

This project packages a Bash script (`/app/pgbackup.sh`) into a Docker image that can:

- **Dump a PostgreSQL database** using `pg_dump`
- **Compress** the dump
- **Encrypt the backup** using a randomly generated symmetric key (AES-256), where that symmetric key is encrypted with your **public key** (`.pem`)
- Produce a final tarball containing:
  - `*.enc` (encrypted DB dump)
  - `*.key` (the symmetric key encrypted with the public key)
- Optionally **upload backups to cloud remotes** using **rclone**
- Optionally run on a **schedule** using **cron inside the container**

## How the encryption works (high level)

For each backup run:

1. The script generates a random symmetric key.
2. It encrypts that symmetric key with your **public key** (RSA) and saves it as `*.key`.
3. It encrypts the compressed database dump using AES-256 and the symmetric key and saves it as `*.enc`.
4. It bundles `*.key` + `*.enc` into a single archive: `${BK_PREFIX}_${DB_NAME}_${timestamp}${BK_SUFFIX}` (default suffix: `.enc`).

✅ Result: **only whoever owns the matching private key** can decrypt the symmetric key and then decrypt the backup.

## Directory layout inside the container

- `/app` — application directory
- `/app/data` — where backups are written (mount this)
- `/app/config` — where configs/keys live (mount this)

The image is designed to run as **non-root user** `pgbackup`.

---

# Configuration

You can configure via:

1. **Environment variables** (`docker run -e ...`)
2. A config file `.pgbackup.conf` in `/app/config` (recommended for many variables)

The entrypoint auto-detects these files in `/app/config`:

- `/app/config/.pgbackup.conf` → main config file
- `/app/config/rclone.conf` or `/app/config/.rclone.conf` → rclone config
- `/app/config/pubkey.pem` or `/app/config/.pubkey.pem` → encryption public key

## Common environment variables

Database:

- `DB_HOST` (default: `localhost`)
- `DB_USER` (default: `postgres`)
- `DB_NAME` (default: `postgres`)
- `DB_PASSWORD` (default: empty)

Backup behavior:

- `BK_DEST` (default: `/app/data`)
- `BK_DAYS_TO_KEEP` (default: `10`)
- `BK_PREFIX` (default: `bk`)
- `BK_SUFFIX` (default: `.enc`)
- `BK_PLAIN` (if set: disables encryption)

Encryption + remote:

- `BK_PUBKEY_LOC` (default: auto-detected from `/app/config/pubkey.pem`)
- `BK_RCLONE_CONF` (default: auto-detected from `/app/config/rclone.conf`)
- `BK_REMOTE` (remotes to upload to; see below)
- `BK_REMOTE_INTERVAL` (days; default `5`)

Scheduling:

- `BK_CRON` (cron expression like `0 2 * * *`; if set, container runs in cron mode)

> Tip: If you put values in `.pgbackup.conf`, prefer defaults like `DB_HOST=${DB_HOST:-localhost}` so `docker run -e` can override them.

---

# Build

From the directory containing your `Dockerfile`, `pgbackup.sh`, and `docker-entrypoint.sh`:

```bash
docker build -t pgbackup:latest .
```

---

# Run (one-shot backup)

## Minimum example (encrypted backup)

```bash
docker run --rm \
  -v "$PWD/data:/app/data" \
  -v "$PWD/config:/app/config:ro" \
  -e DB_HOST=postgres \
  -e DB_USER=postgres \
  -e DB_NAME=mydb \
  -e DB_PASSWORD='secret' \
  pgbackup:latest
```

- Backups will be created in `./data` on your host.
- The public key must exist in `./config/pubkey.pem` (or `.pubkey.pem`) for encryption.

## Plain (unencrypted) backup

```bash
docker run --rm \
  -v "$PWD/data:/app/data" \
  -v "$PWD/config:/app/config:ro" \
  -e DB_HOST=postgres \
  -e DB_USER=postgres \
  -e DB_NAME=mydb \
  -e DB_PASSWORD='secret' \
  -e BK_PLAIN=1 \
  pgbackup:latest
```

---

# Run (scheduled via cron in container)

If `BK_CRON` is set, the container runs `crond` in the foreground and executes backups on schedule.

Example: **every day at 02:00**:

```bash
docker run -d --name pgbackup \
  -v "$PWD/data:/app/data" \
  -v "$PWD/config:/app/config:ro" \
  -e BK_CRON="0 2 * * *" \
  -e DB_HOST=postgres \
  -e DB_USER=postgres \
  -e DB_NAME=mydb \
  -e DB_PASSWORD='secret' \
  pgbackup:latest
```

Check logs:

```bash
docker logs -f pgbackup
```

---

# Generating a PEM public key

## Option A (recommended): generate a fresh RSA keypair

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out private.pem
openssl pkey -in private.pem -pubout -out pubkey.pem
```

- Keep `private.pem` safe (do not put it in the container).
- Put `pubkey.pem` into your config folder: `./config/pubkey.pem`

## Option B: create a PEM public key from an existing `id_rsa`

If you already have `~/.ssh/id_rsa` (RSA), you can export the public key in PEM format:

```bash
ssh-keygen -f ~/.ssh/id_rsa -e -m PEM > pubkey.pem
```

Then copy it to:

- `./config/pubkey.pem` (recommended filename)

> Note: This is for RSA keys. Ed25519 keys are not compatible with this same `pkeyutl -encrypt` flow.

---

# Where to put the PEM file

Place your public key at one of these paths in the mounted config directory:

- `./config/pubkey.pem` ✅ (recommended)
- `./config/.pubkey.pem`

When you run the container with:

```bash
-v "$PWD/config:/app/config:ro"
```

the script will auto-detect the key.

Alternatively you can explicitly set:

```bash
-e BK_PUBKEY_LOC=/app/config/pubkey.pem
```

---

# rclone configuration

## How rclone is used

If `BK_REMOTE` is configured, the script uploads the backup directory to one or more rclone remotes using:

- `rclone copy <BK_DEST>/ <remote>/ ...`

## Configure rclone locally (interactive)

Run on your machine:

```bash
rclone config
```

This will create a config file, typically at:

- `~/.config/rclone/rclone.conf`

## Copy `rclone.conf` for the container

Copy it into your project config directory:

```bash
mkdir -p ./config
cp ~/.config/rclone/rclone.conf ./config/rclone.conf
```

Then run the container with:

```bash
-v "$PWD/config:/app/config:ro"
```

The entrypoint will auto-detect:

- `/app/config/rclone.conf` (or `/app/config/.rclone.conf`)

Or set explicitly:

```bash
-e BK_RCLONE_CONF=/app/config/rclone.conf
```

## Set BK_REMOTE

`BK_REMOTE` supports one or more remotes. Example:

```bash
-e BK_REMOTE="remote1:bucket/path remote2:another/path"
```

(Each entry will be uploaded to.)

---

# Example .pgbackup.conf (recommended)

Create `./config/.pgbackup.conf`:

```bash
# Database defaults (env can override)
DB_HOST=${DB_HOST:-postgres}
DB_USER=${DB_USER:-postgres}
DB_NAME=${DB_NAME:-mydb}
DB_PASSWORD=${DB_PASSWORD:-}

# Backups
BK_DEST=${BK_DEST:-/app/data}
BK_DAYS_TO_KEEP=${BK_DAYS_TO_KEEP:-10}
BK_PREFIX=${BK_PREFIX:-bk}
BK_SUFFIX=${BK_SUFFIX:-.enc}

# Encryption key
BK_PUBKEY_LOC=${BK_PUBKEY_LOC:-/app/config/pubkey.pem}

# rclone
BK_RCLONE_CONF=${BK_RCLONE_CONF:-/app/config/rclone.conf}
BK_REMOTE=(${BK_REMOTE:-"myremote:mybucket/backups"})
```

---

# Security notes

- Anything embedded in a container image is accessible to anyone who can pull/run it.
  ✅ Keep **private keys** outside the image.
- Environment variables can be visible via container inspection. If you need stronger secrecy for `DB_PASSWORD`, prefer reading from a mounted file/secret (can be added).

---

# What this app does (summary)

This containerized script creates **encrypted PostgreSQL backups**:

- **Encrypted with a public key**, so only the owner of the matching private key can decrypt
- Stores backups in `/app/data`
- Optionally uploads backups to cloud storage (S3, GDrive, etc.) using **rclone**
- Can run **on demand** or **scheduled via cron**

---

# How to decrypt a backup

Each backup archive contains two files:

- `*.enc` — the database dump encrypted with AES-256 using a random symmetric key
- `*.key` — that symmetric key encrypted with your **RSA public key**

To decrypt, you need the matching **private key** (the one that corresponds to the public key used in the container).

### 1) Extract the archive

```bash
tar -xzf bk_<DB_NAME>_<TIMESTAMP>.enc
```

This will produce something like:

- `bk_<DB_NAME>_<TIMESTAMP>.key`
- `bk_<DB_NAME>_<TIMESTAMP>.enc`

### 2) Decrypt the symmetric key with your private key

```bash
openssl pkeyutl -decrypt \
  -inkey private.pem \
  -in  bk_<DB_NAME>_<TIMESTAMP>.key \
  -out key.bin
```

> `key.bin` is the raw symmetric key material the backup used.

### 3) Decrypt the encrypted dump using the recovered key

Your script encrypts with:

- `aes-256-cbc`
- base64 output (`-a`)
- `-md sha512`
- `-pbkdf2`
- `-iter 1000000`
- `-salt`
- password source: `file:./key`

So to reverse it:

```bash
openssl enc -d -aes-256-cbc -a -md sha512 -pbkdf2 -iter 1000000 \
  -in  bk_<DB_NAME>_<TIMESTAMP>.enc \
  -out dump.sql.gz \
  -pass "file:./key.bin"
```

Now you have a gzip-compressed SQL dump.

### 4) Decompress and restore

Decompress:

```bash
gunzip -c dump.sql.gz > dump.sql
```

Restore into Postgres:

```bash
psql -h <host> -U <user> -d <database> -f dump.sql
```

### Notes / troubleshooting

- If `openssl pkeyutl -decrypt` fails, you are likely using the wrong private key (it must match the public key used for encryption).
- Keep `private.pem` secure and never store it in the Docker image.
- If you prefer restoring directly without creating `dump.sql`, you can stream it:

```bash
openssl enc -d -aes-256-cbc -a -md sha512 -pbkdf2 -iter 1000000 \
  -in bk_<DB_NAME>_<TIMESTAMP>.enc \
  -pass "file:./key.bin" \
| gunzip -c \
| psql -h <host> -U <user> -d <database>
```

# Import the decrypted dump into a running database

After decryption you typically end up with a gzip-compressed SQL dump, e.g. `dump.sql.gz` (or a plain `dump.sql` if you already decompressed it).

### Option A — Import from a plain SQL file (`dump.sql`)

```bash
psql -h <host> -U <user> -d <database> -f dump.sql
```

Examples:

```bash
psql -h 127.0.0.1 -U postgres -d mydb -f dump.sql
```

### Option B — Import from a compressed file (`dump.sql.gz`) without writing `dump.sql`

```bash
gunzip -c dump.sql.gz | psql -h <host> -U <user> -d <database>
```

### Option C — Import directly from the encrypted backup (one pipeline)

This decrypts → decompresses → restores in a single stream:

```bash
openssl pkeyutl -decrypt \
  -inkey private.pem \
  -in  bk_<DB_NAME>_<TIMESTAMP>.key \
  -out key.bin

openssl enc -d -aes-256-cbc -a -md sha512 -pbkdf2 -iter 1000000 \
  -in bk_<DB_NAME>_<TIMESTAMP>.enc \
  -pass "file:./key.bin" \
| gunzip -c \
| psql -h <host> -U <user> -d <database>
```

### Import into a _new_ empty database (recommended for safety)

```bash
createdb -h <host> -U <user> <new_database>
psql -h <host> -U <user> -d <new_database> -f dump.sql
```

### Useful flags

- Stop on first error (recommended):

  ```bash
  psql -v ON_ERROR_STOP=1 -h <host> -U <user> -d <database> -f dump.sql
  ```

- If you need to provide password non-interactively:

  ```bash
  PGPASSWORD='<password>' psql -h <host> -U <user> -d <database> -f dump.sql
  ```

### Troubleshooting

- **Permission errors**: restore as a superuser or ensure roles exist in the target DB.
- **“database does not exist”**: create it first (`createdb`) or use the correct `-d`.
- **Objects already exist**: restore into an empty DB, or drop/recreate the schema before import.
