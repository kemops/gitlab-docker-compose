#!/bin/bash

# ==========================================
# CONFIGURATION
# ==========================================
SOURCE_FOLDER="/home/ubuntu/project/container/gitlab-docker-compose/archives"
DESTINATION="gdrive:db-backup/gitlab-docker-compose"

# ==========================================
# MAIN PROCESS
# ==========================================
echo "========================================="
echo "Start the backup process: $(date)"

# Check if the source directory exists
if [ ! -d "$SOURCE_FOLDER" ]; then
    echo "Error: Directory not found at $SOURCE_FOLDER"
    exit 1
fi

echo "Backing up: $SOURCE_FOLDER -> $DESTINATION"

# Execute rclone copy for directory
rclone copy "$SOURCE_FOLDER" "$DESTINATION" --progress

# Check the exit status of the rclone command
if [ $? -eq 0 ]; then
    echo "Success! Folder backup is complete at: $(date)"
else
    echo "Error: An error occurred during the backup."
    exit 1
fi

echo "========================================="