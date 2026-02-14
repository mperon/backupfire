#!/usr/bin/env bash
# backupfire.sh - Backup tool
#
# Runs backup "tasks" defined in an INI config file.
#
# Supported Types:
#   - Local  : rsync local->local
#   - Remote : rclone local<->remote
#   - Backup : run a Vault Action (e.g. Database / CopyFiles),
#              then optionally compress and encrypt before copying to destination.
set -o pipefail

# Resolve script directory (safe when invoked via symlink).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

SRC_DIR="${SCRIPT_DIR}/src"
DEST_DIR="${SCRIPT_DIR}/dist"
OUT_NAME="backupfire.sh"
OUT_FILE="${DEST_DIR}/${OUT_NAME}"

# Ensure dirs exist
rm -rf -- "$DEST_DIR"
mkdir -p -- "$DEST_DIR"

append_file() {
  local f="$1"
  awk '
    NR==1 && $0 ~ /^#!/ { next }                 # drop shebang
    $0 ~ /^[[:space:]]*#/ { next }               # drop full-line comments
    { sub(/[[:space:]]+$/, ""); }                # rtrim
    /^[[:space:]]*$/ {                           # blank line handling
      if (blank) next
      blank=1
      print ""
      next
    }
    { blank=0; print }
    END { if (!blank) print "" }                 # ensure exactly one trailing newline
  ' "$f" >>"$OUT_FILE"
}

# Write header once
cat >"$OUT_FILE" <<'EOF'
#!/usr/bin/env bash
# backupfire.sh - Backup tool
#
# Runs backup "tasks" defined in an INI config file.
#
# Supported Types:
#   - Local  : rsync local->local
#   - Remote : rclone local<->remote
#   - Backup : run a Vault Action (e.g. Database / CopyFiles),
#              then optionally compress and encrypt before copying to destination.
set -o pipefail

# SCRIPT NAME
SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"

# Resolve script directory (safe when invoked via symlink).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
EOF

# Collect files once (recursive), sorted for deterministic output
# Works on macOS + Alpine
mapfile -t files < <(find "$SRC_DIR" -type f -name '*.sh' -print | sort | uniq)

# Append cleaned content
for f in "${files[@]}"; do
  append_file "$f"
done

# Add main call
cat >>"$OUT_FILE" <<'EOF'
# calling main
bk_main "$@"
EOF

# Ensure only one main call
mains=$(grep -n 'bk_main "\$@"' "$OUT_FILE" | wc -l)
if [[ "$mains" -gt 1 ]]; then
  echo "Expected exactly one bk_main \"\$@\" call" >&2; exit 1;
fi

chmod +x "$OUT_FILE"
printf 'Built: %s\n' "$OUT_FILE"
