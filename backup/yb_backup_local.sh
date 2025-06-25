#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
YB_SERVICE_NAME="yb"
# This is a directory inside the container where the backup will be temporarily stored.
CONTAINER_BACKUP_DIR="/data0/backups"
# This is the directory on the host machine where the final backup will be stored.
# It should correspond to a volume mount in your docker-compose.yml.
HOST_BACKUP_DIR="./yb/backups"
DB_USER="${POSTGRES_USER:-yugabyte}"
DB_NAME="${POSTGRES_DB:-yugabyte}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="yb_dump_${TIMESTAMP}.sql"

# --- Script Logic ---

echo "------------------------------------"
echo "Starting YugabyteDB Backup Script: $(date)"
echo "------------------------------------"

# 1. Ensure the host backup directory exists
echo "INFO: Ensuring host backup directory exists at ${HOST_BACKUP_DIR}"
mkdir -p "${HOST_BACKUP_DIR}"

# Function to execute commands inside the YugabyteDB container
yb_exec_sync() {
    docker compose exec -T "${YB_SERVICE_NAME}" "$@"
}

# 2. Create the backup directory inside the container
echo "INFO: Creating backup directory inside the container at ${CONTAINER_BACKUP_DIR}"
yb_exec_sync mkdir -p "${CONTAINER_BACKUP_DIR}"

# 3. Run ysql_dump to create the backup
echo "INFO: Running ysql_dump to back up database '${DB_NAME}' to '${CONTAINER_BACKUP_DIR}/${BACKUP_FILE}'"
# The backup is created inside the container first
yb_exec_sync ysql_dump -U "${DB_USER}" -d "${DB_NAME}" -f "${CONTAINER_BACKUP_DIR}/${BACKUP_FILE}"

# 4. Compress the backup file inside the container
echo "INFO: Compressing the backup file..."
yb_exec_sync gzip "${CONTAINER_BACKUP_DIR}/${BACKUP_FILE}"

# 5. Move the compressed backup from the container to the host
# Docker cp can be used for this, but it's often simpler to use a mounted volume.
# This script assumes a volume is mounted from ${HOST_BACKUP_DIR} to ${CONTAINER_BACKUP_DIR}
# or that the user will manually copy the file if needed.
# For this setup, we'll copy it from the container to the host directory.
echo "INFO: Copying compressed backup from container to host at ${HOST_BACKUP_DIR}/${BACKUP_FILE}.gz"
docker compose cp "${YB_SERVICE_NAME}:${CONTAINER_BACKUP_DIR}/${BACKUP_FILE}.gz" "${HOST_BACKUP_DIR}/"

# 6. Clean up the backup file from inside the container
echo "INFO: Cleaning up backup file from container..."
yb_exec_sync rm "${CONTAINER_BACKUP_DIR}/${BACKUP_FILE}.gz"

echo "SUCCESS: Backup completed successfully."
echo "Backup file is located at: ${HOST_BACKUP_DIR}/${BACKUP_FILE}.gz"
echo "------------------------------------"
echo "YugabyteDB Backup Script Finished: $(date)"
echo "------------------------------------"
