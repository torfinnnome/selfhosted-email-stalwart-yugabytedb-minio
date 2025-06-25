# Stalwart Email Server with YugabyteDB and MinIO

This repository provides Docker Compose configurations for setting up a [Stalwart](https://stalw.art) email server using [YugabyteDB](https://www.yugabyte.com/) for metadata storage and [MinIO](https://min.io) for blob storage.

*This is heavily inspired by https://gist.github.com/chripede/99b7eaa1101ee05cc64a59b46e4d299f - Thanks! Please check it out on how to configure Stalwart to use a setup like this.*

The cluster configuration is deployed across three Virtual Machines (VMs), each situated in a distinct physical location. Inter-node communication is established via Tailscale.

The roles and services are distributed as follows:

- Two front-end nodes: These nodes handle incoming requests, running Nginx, Stalwart, YugabyteDB, and MinIO.
- One back-end node: YugabyteDB and MinIO.

(Or just run Stalwart, YugabyteDB and MinIO on all three nodes, or whatever setup you prefer.)

## Prerequisites

*   Docker with [Docker Compose](https://github.com/docker/compose) (or Podman)
*   [MinIO Client](https://min.io/docs/minio/linux/reference/minio-mc.html) (`mc`) installed and configured

## Setup Instructions

This guide helps you set up Stalwart with clustered YugabyteDB and MinIO.

### 1. Environment Configuration

Create a `.env` file in the root of this project directory. Below is an example template. Adjust the placeholder values to match your specific environment.

```env
STALWART_VERSION=v0.12.5
YB_VERSION=2024.2.3.2-b6
MINIO_RELEASE=RELEASE.2025-04-22T22-12-26Z
MINIO_ROOT_USER=adminuser
MINIO_ROOT_PASSWORD=verysecret
GRAFANA_ADMIN_USER=adminuser
GRAFANA_ADMIN_PASSWORD=alsoverysecret
POSTGRES_USER=yugabyte
POSTGRES_PASSWORD=yugabyte
POSTGRES_DB=yugabyte
```

### 2. YugabyteDB Cluster Setup

The `docker-compose.yml` file starts a single-node YugabyteDB cluster. The service is named `yb` and is accessible within the Docker network at `yb:5433` (PostgreSQL port).

For a multi-node setup, you would typically run the `docker-compose.yml` on multiple hosts and configure the YugabyteDB instances to form a cluster using the `--join` flag. Refer to the [YugabyteDB documentation](https://docs.yugabyte.com/latest/deploy/docker/multi-node-deployment/) for detailed instructions.

Stalwart connects to YugabyteDB using the PostgreSQL protocol. You will need to configure the data store settings in your Stalwart configuration file (e.g., `/opt/stalwart/config.toml`) to point to your YugabyteDB instance(s).

Example configuration for Stalwart:
```toml
[store]
backend = "postgres"
url = "postgres://yugabyte:yugabyte@yb:5433/yugabyte"
```
Ensure the username, password, hostname, port, and database name match your `.env` file and YugabyteDB setup.

### 3. Nginx Reverse-Proxy Setup

The `nginx/nginx.conf` file configures Nginx to act as a reverse proxy for both Stalwart services and the MinIO S3 API. This allows you to expose these services on standard ports and manage SSL/TLS termination centrally.

Key aspects of the configuration:
*   **Stalwart Services:**
    *   Nginx listens on standard mail ports: `25` (SMTP), `993` (IMAPS), `465` (SMTPS), `587` (Submission), and `443` (HTTPS for Stalwart web interface/JMAP/etc.).
    *   It uses `upstream` blocks (e.g., `backend_smtp`, `backend_imaps`) to define the Stalwart backend servers (e.g., `server1:1025`, `server2:1025`). These should point to your Stalwart instances. The current configuration assumes Stalwart is reachable via `server1` and `server2` on specific internal ports, which match the exposed ports in the `stalwart` service in `docker-compose.yml`.
    *   `proxy_protocol on;` is enabled for mail services. This sends client connection information (like the original IP address) to Stalwart. Ensure your Stalwart instances are configured to accept the proxy protocol.
*   **MinIO S3 API:**
    *   Nginx listens on port `81` for S3 traffic.
    *   The `server_name s3.yourdomain;` directive should be updated to your desired domain for accessing MinIO.
    *   It proxies requests to the `minio_backend` upstream, which includes `server1:9000`, `server2:9000`, and `server3:9000`. These should be the addresses of your MinIO server instances.
    *   `client_max_body_size 5G;` allows for large file uploads. Adjust as needed.
*   **General:**
    *   The Nginx service in `docker-compose.yml` uses `network_mode: host`. Adjust as needed.
    *   Ensure that `server1`, `server2`, `server3` in `nginx.conf` are resolvable to the correct IP addresses of your backend Stalwart and MinIO instances.
    *   For production, configure SSL/TLS for the MinIO endpoint (port 81) and ensure mail service ports are secured with SSL/TLS certificates. The `nginx.conf` proxies HTTPS on port 443 to Stalwart.

To use this Nginx configuration:
1.  Ensure `nginx/nginx.conf` reflects your server hostnames/IPs and desired domain names.
2.  If using SSL/TLS, place your certificate and key files (e.g., in `./nginx/certs`), uncomment the certs volume in `docker-compose.yml`, and update `nginx.conf`.

### 4. MinIO Bucket Setup

Ensure the MinIO service is running before proceeding. This setup assumes MinIO is accessible via hostnames like `server1`, `server2`, `server3` on port `9000`.

**a. Create Buckets:**

Create the necessary bucket (e.g., `mydata`) on your MinIO instance (source). If you plan to use replication to another S3 target, create the bucket there as well. The target bucket *must* exist before setting up replication.

```bash
# Replace placeholders with your actual values.
# 'source' refers to the MinIO instance in this Docker Compose setup.
# Use one of your MinIO server hostnames/IPs (e.g., server1, server2, or server3 from your setup).
# The MINIO_ROOT_USER and MINIO_ROOT_PASSWORD are from your .env file.
mc alias set source http://server1_ip_or_hostname:9000 MINIO_ROOT_USER MINIO_ROOT_PASSWORD --api s3v4

# If replicating, 'target' refers to your backup/remote MinIO instance or S3-compatible service.
# mc alias set target http://<remote_s3_ip_or_hostname>:<remote_s3_port> S3_ROOT_USER S3_ROOT_PASSWORD --api s3v4

mc mb source/mydata
# mc mb target/mydata # Only if replicating to a target you manage with 'mc'
```

**b. Enable Versioning:**

Enable versioning on the source bucket, and on the target bucket if replicating.

```bash
mc version enable source/mydata
# mc version enable target/mydata # Only if replicating
```

### 5. Monitoring

This configuration includes a monitoring stack based on Prometheus and Grafana:

*   **Prometheus:** Collects metrics from various exporters and services. Access the UI at `http://<your_host_ip>:9090`.
    *   Configuration: `prometheus/etc/prometheus.yml`
    *   Default Scrape Targets (as per `prometheus.yml`): Prometheus itself, Node Exporter, cAdvisor, MinIO (e.g., `server1:9000`), Stalwart (`stalwart:8080`), and YugabyteDB.
    *   To monitor YugabyteDB, ensure your `prometheus.yml` scrapes the YB-Master (`yb:7000/prometheus-metrics`) and YB-TServer (`yb:9010/prometheus-metrics`) endpoints.
*   **Grafana:** Visualizes the metrics collected by Prometheus. Access the UI at `http://<your_host_ip>:3000`.
    *   Default credentials (unless changed in `.env`): `admin` / `admin` (or `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` from `.env`)
    *   Provisioning: `grafana/provisioning/`
*   **Node Exporter:** Exports host system metrics (CPU, RAM, disk, network) to Prometheus.
*   **cAdvisor:** Exports container metrics (resource usage per container) to Prometheus.

This stack allows you to monitor the health and performance of the host system, Docker containers, YugabyteDB, and MinIO. You can import pre-built Grafana dashboards via the Grafana UI (`http://<your_host_ip>:3000`) using their IDs or by uploading their JSON definitions. Recommended dashboards include:
*   **Node Exporter Full (ID: 1860):** Host system metrics.
*   **Docker and System Monitoring (ID: 193):** Container metrics (from cAdvisor).
*   **YugabyteDB (ID: 19887):** YugabyteDB metrics.
*   **MinIO Dashboard (ID: 13502):** MinIO server metrics.
*   **Stalwart Server:** A dashboard is available [here](https://github.com/torfinnnome/grafana-dashboard-stalwart). *Note: Requires enabling the Prometheus metrics endpoint in Stalwart's configuration.*

### 6. MinIO Replication Setup (optional)

Configure replication from your local MinIO instance (source) to a backup/target MinIO instance or S3-compatible service.

```bash
# Replace placeholders with your actual values
mc replicate add source/mydata \
  --remote-bucket "arn:aws:s3:::mydata" \ # Example ARN for target bucket, adjust for your S3 provider
  --storage-class STANDARD \ # Optional: specify storage class on target
  --endpoint "http://SOME_OTHER_S3:9000" \ # Endpoint of the target S3 service
  --access-key "TARGET_S3_ACCESS_KEY" \
  --secret-key "TARGET_S3_SECRET_KEY" \
  --replicate "delete,delete-marker,existing-objects" \
  --priority 1

# Verify replication status
mc replicate status source/mydata --data

# If old items are not synced and you want to mirror them (use with caution):
# mc mirror --overwrite source/mydata target/mydata
```

*Note: The `mc replicate add` command structure can vary based on the S3 provider. The example above uses parameters common for MinIO-to-MinIO or MinIO-to-S3 replication. Replace placeholders with your actual values for the target S3 instance. The `--remote-bucket` often requires an ARN or specific format. Consult MinIO and your target S3 provider's documentation.*


### 7. Running the Services

Navigate to the root of this project directory and start all services using Docker (or Podman) Compose:

```bash
docker-compose up -d
```

## Backup Procedures

This setup includes scripts to back up your YugabyteDB database, MinIO bucket contents, and MinIO system configurations. These scripts are located in the `backup/` directory. It's crucial to schedule these scripts to run regularly, for example, using `cron`.

**Important Considerations Before Scheduling:**
*   **Script Paths:** Ensure the paths to the scripts in your crontab entries are correct. The examples below assume your project root is `/path/to/your/project`. Adjust this accordingly.
*   **Permissions:** The scripts must be executable (`chmod +x backup/*.sh`).
*   **Environment:** Cron jobs run with a minimal environment. If scripts rely on environment variables not set in the script itself (e.g., for `docker compose`), you might need to source a profile file or set them directly in the crontab. The provided scripts are designed to be relatively self-contained or use `docker compose exec` which handles the container environment.
*   **`mc` Alias Configuration:**
    *   The `minio_backup_local.sh` and `minio-system_backup_local.sh` scripts rely on an `mc` alias (defaulting to `source`). This alias must be configured on the machine where the cron job runs, pointing to your MinIO server.
    *   For `minio-system_backup_local.sh`, the `mc` alias **must be configured with MinIO admin credentials** (root user/password or an access key with admin privileges).
    *   Example `mc` alias setup:
        ```bash
        # For regular bucket access (used by minio_backup_local.sh)
        mc alias set source http://your-minio-server-ip:9000 YOUR_ACCESS_KEY YOUR_SECRET_KEY --api s3v4
        # For admin access (required by minio-system_backup_local.sh - use root credentials)
        mc alias set source http://your-minio-server-ip:9000 MINIO_ROOT_USER MINIO_ROOT_PASSWORD --api s3v4
        ```
        Ensure the `source` alias used by the scripts matches the one you've configured with the appropriate permissions.
*   **Log Files:** The scripts generate log files. Monitor these logs for successful execution or errors. The default log locations are specified within each script.
*   **Backup Storage:** Ensure the `LOCAL_BACKUP_DIR` (for `minio_backup_local.sh`) and `BACKUP_BASE_DIR` (for `minio-system_backup_local.sh`) have sufficient free space.

### 1. YugabyteDB Backup (`backup/yb_backup_local.sh`)

This script uses `ysql_dump` to create a compressed SQL backup of your YugabyteDB database.

*   **Configuration:**
    *   The script uses environment variables from your `.env` file for the database user and name (`POSTGRES_USER`, `POSTGRES_DB`).
    *   The `HOST_BACKUP_DIR` variable inside the script determines where the backup file is stored on the host (default: `./yb/backups`).
*   **Execution:**
    ```bash
    cd /path/to/your/project
    ./backup/yb_backup_local.sh
    ```
*   **Crontab Example (daily at 2 AM):**
    ```cron
    0 2 * * * /path/to/your/project/backup/yb_backup_local.sh >> /path/to/your/project/backup/yb_backup_cron.log 2>&1
    ```

### 2. MinIO Bucket Backup (`backup/minio_backup_local.sh`)

This script uses `mc mirror` to back up a specified MinIO bucket to a local directory.

*   **Configuration:**
    *   Edit `backup/minio_backup_local.sh` and set:
        *   `MINIO_ALIAS`: The `mc` alias for your source MinIO server (default: `source`).
        *   `BUCKET_NAME`: The name of the bucket to back up (default: `stalwart`).
        *   `LOCAL_BACKUP_DIR`: The absolute path to your local backup destination.
        *   `MC_BIN`: Path to your `mc` binary if not in standard PATH for the cron user.
    *   Ensure the `mc` alias is configured correctly on the host running the script.
*   **Execution:**
    ```bash
    cd /path/to/your/project # Not strictly necessary if script uses absolute paths, but good practice
    ./backup/minio_backup_local.sh
    ```
*   **Crontab Example (daily at 3 AM):**
    ```cron
    0 3 * * * /path/to/your/project/backup/minio_backup_local.sh >> /path/to/your/project/backup/minio_bucket_backup_cron.log 2>&1
    ```

### 2. MinIO System Configuration Backup (`backup/minio-system_backup_local.sh`)

This script exports MinIO's IAM configuration (users, groups, policies) and bucket policies. **It requires the `mc` alias to be configured with admin credentials.**

*   **Configuration:**
    *   Edit `backup/minio-system_backup_local.sh` and set:
        *   `MINIO_ALIAS`: The `mc` alias for your source MinIO server (default: `source`). **Must have admin privileges.**
        *   `BACKUP_BASE_DIR`: The absolute path where backup archives will be stored.
    *   Ensure `jq` is installed on the system running the script.
*   **Execution:**
    ```bash
    cd /path/to/your/project # Not strictly necessary
    ./backup/minio-system_backup_local.sh
    ```
*   **Crontab Example (weekly, Sunday at 4 AM):**
    ```cron
    0 4 * * 0 /path/to/your/project/backup/minio-system_backup_local.sh >> /path/to/your/project/backup/minio_system_backup_cron.log 2>&1
    ```
    *Note: IAM and system configurations typically change less frequently than bucket data, so a weekly backup might be sufficient, but adjust to your needs.*

---

## Todo

- Instructions for SSL/TLS certificate setup for MinIO.
