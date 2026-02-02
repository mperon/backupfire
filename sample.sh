#!/bin/bash

SOURCE_DIR="/path/to/local/backups"
REMOTE="myremote:backups/folder"
LIMIT=10

# 1. Copy the latest backup to the remote (using 'copy' to not delete other files)
rclone copy "$SOURCE_DIR" "$REMOTE"

# 2. List all files on the remote, sort by time (newest first), and select those past the limit
#    --max-depth 1 ensures we only list files in the main backup folder
rclone lsf "$REMOTE" --files-only -t --max-depth 1 | tail -n +$((LIMIT + 1)) > files_to_delete.txt

# 3. Delete the older files listed in files_to_delete.txt
if [ -s files_to_delete.txt ]; then
    echo "Deleting old backups:"
    cat files_to_delete.txt
    rclone delete "$REMOTE" --files-from=files_to_delete.txt --verbose
else
    echo "No old backups to delete."
fi

# 4. Clean up the temporary file
rm files_to_delete.txt
