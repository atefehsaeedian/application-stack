# Application Stack — DevOps Lab

A reproducible DevOps lab containing two application versions, Nginx reverse proxy, PostgreSQL, Prometheus, Loki, Grafana, automated deployment, and PostgreSQL backup.

## 1. Architecture

The lab contains three Ubuntu virtual machines:

| VM          | IP           | Role                  |
| ----------- | ------------ | --------------------- |
| gateway     | `10.10.10.1` | Gateway / test client |
| application | `10.10.10.2` | Application stack     |
| monitoring  | `10.10.10.3` | Monitoring stack      |

The main application stack runs on the `application` VM.

### Application VM

```text
                         HTTPS :8443
                              │
                              ▼
                       ┌─────────────┐
                       │    Nginx    │
                       │   :8080/443 │
                       └──────┬──────┘
                              │
                    ┌─────────┴─────────┐
                    ▼                   ▼
              ┌──────────┐        ┌──────────┐
              │   app1   │        │   app2   │
              │   :8001  │        │   :8002  │
              └────┬─────┘        └────┬─────┘
                   │                   │
                   └─────────┬─────────┘
                             │
                       backend network
                             │
                       ┌────────────┐
                       │ PostgreSQL │
                       │    :5432   │
                       └────────────┘
```

### Monitoring VM

Prometheus collects metrics from:

* gateway Node Exporter
* application Node Exporter
* monitoring Node Exporter
* application endpoints

Loki provides log aggregation.

Grafana is used for visualization.

---

## 2. Repository Structure

```text
application-stack/
│
├── app-v1/
│   ├── app.py
│   ├── Dockerfile
│   ├── .dockerignore
│   └── requirements.txt
│
├── app-v2/
│   ├── app.py
│   ├── Dockerfile
│   ├── .dockerignore
│   └── requirements.txt
│
├── docker/
│   ├── app-v1/
│   │   └── Dockerfile
│   ├── app-v2/
│   │   └── Dockerfile
│   └── compose.yaml
│
├── monitoring/
│   ├── prometheus/
│   │   └── prometheus.yml
│   ├── loki/
│   │   └── config.yml
│   └── grafana/
│
├── nginx/
│   └── nginx.conf
│
├── scripts/
│   ├── deploy.sh
│   └── postgres-backup.sh
│
├── systemd/
│   ├── application/
│   │   ├── postgres-backup.service
│   │   └── postgres-backup.timer
│   └── monitoring/
│       └── loki.service
│
├── docs/
│
├── .env.example
├── .gitignore
└── README.md
```

The repository is the source of truth for project configuration.

Machine-local copies under `/etc`, `/opt`, and `/usr/local/bin` are deployment targets and should not be treated as the primary source of configuration.

---

## 3. Prerequisites

The application VM requires:

* Ubuntu 24.04+
* Docker
* Docker Compose
* Git
* SSH server when remote administration or configuration transfer is required

Current lab versions:

```text
Docker: 29.1.3
Docker Compose: 2.40.3
```

The application VM uses:

```text
10.10.10.2
```

---

## 4. Clone the Repository

Clone the repository on the application VM:

```bash
git clone <REPOSITORY_URL> application-stack
cd application-stack
```

Checkout the required branch or release tag:

```bash
git checkout <TAG_OR_BRANCH>
```

---

## 5. Environment Configuration

Real passwords and secrets must never be committed to Git.

Create the local environment file from the example:

```bash
cp .env.example .env
```

Edit the local secret:

```bash
nano .env
```

Example:

```text
POSTGRES_PASSWORD=change-me
```

The real `.env` file is ignored by Git.

Verify that it is not tracked:

```bash
git ls-files .env
```

The command should produce no output.

Never place real passwords, private keys, API tokens, or other credentials in the repository.

---

## 6. Docker Compose Configuration

The main Compose configuration is:

```text
docker/compose.yaml
```

The application images and version are supplied by the deployment script:

```text
APP1_IMAGE
APP2_IMAGE
APP_VERSION
```

For example:

```bash
APP1_IMAGE=app-v1:v1.4.0 \
APP2_IMAGE=app-v2:v1.4.0 \
APP_VERSION=v1.4.0 \
sudo --preserve-env=APP1_IMAGE,APP2_IMAGE,APP_VERSION \
docker compose \
  -p application-stack \
  --env-file .env \
  -f docker/compose.yaml \
  config -q
```

No output indicates successful Compose validation.

The fixed Compose project name is:

```text
application-stack
```

This preserves stable container names and prevents accidentally creating a second Compose project.

---

## 7. Start the Application Stack

The preferred deployment method is:

```bash
sudo ./scripts/deploy.sh <VERSION>
```

Example:

```bash
sudo ./scripts/deploy.sh v1.4.0
```

The deployment script:

1. Validates the version format.
2. Verifies that the Git tag exists.
3. Extracts the exact source from the Git tag.
4. Saves the currently deployed images and version.
5. Builds release-specific Docker images.
6. Deploys app1 and app2.
7. Waits for both application health checks.
8. Restarts Nginx.
9. Verifies the externally visible version.
10. Performs rollback if deployment fails.

Versions must use semantic versioning with a `v` prefix:

```text
v1.0.0
v1.4.0
v1.5.0
```

---

## 8. Check the Stack

Display the running services:

```bash
APP1_IMAGE=app-v1:v1.4.0 \
APP2_IMAGE=app-v2:v1.4.0 \
APP_VERSION=v1.4.0 \
sudo --preserve-env=APP1_IMAGE,APP2_IMAGE,APP_VERSION \
docker compose \
  -p application-stack \
  --env-file .env \
  -f docker/compose.yaml \
  ps
```

Expected services:

```text
application-stack-app1-1
application-stack-app2-1
application-stack-nginx-1
application-stack-postgres-1
```

All application services should eventually report `healthy`.

---

## 9. Application Health Checks

Direct application health:

```bash
curl http://127.0.0.1:18081/health
curl http://127.0.0.1:18082/health
```

Expected response:

```json
{"status": "healthy"}
```

Nginx HTTPS health:

```bash
curl -ks https://127.0.0.1:8443/health
```

Check the deployed version:

```bash
curl -ks https://127.0.0.1:8443/version
```

---

## 10. Nginx

The version-controlled Nginx configuration is:

```text
nginx/nginx.conf
```

The running container receives the configuration from:

```text
/opt/nginx/nginx.conf
```

TLS files are intentionally kept outside the Git repository.

Expected TLS paths on the application VM:

```text
/opt/nginx/tls/nginx.crt
/opt/nginx/tls/nginx.key
```

The private key must never be committed to Git.

To install the version-controlled Nginx configuration:

```bash
sudo install -o root -g root -m 644 \
  nginx/nginx.conf \
  /opt/nginx/nginx.conf
```

Then restart Nginx:

```bash
sudo docker restart application-stack-nginx-1
```

---

## 11. PostgreSQL

PostgreSQL runs as a Docker container:

```text
postgres:16
```

Database:

```text
appdb
```

User:

```text
appuser
```

PostgreSQL is available internally on:

```text
5432
```

Persistent data is stored in the Docker volume:

```text
postgres-data
```

Check PostgreSQL health:

```bash
sudo docker inspect \
  -f '{{.State.Health.Status}}' \
  application-stack-postgres-1
```

---

## 12. PostgreSQL Backups

The backup script is version controlled at:

```text
scripts/postgres-backup.sh
```

The systemd configuration is:

```text
systemd/application/postgres-backup.service
systemd/application/postgres-backup.timer
```

The operational script is installed at:

```text
/usr/local/bin/postgres-backup.sh
```

Install the script:

```bash
sudo install -o root -g root -m 750 \
  scripts/postgres-backup.sh \
  /usr/local/bin/postgres-backup.sh
```

Install the systemd units:

```bash
sudo install -m 644 \
  systemd/application/postgres-backup.service \
  /etc/systemd/system/postgres-backup.service

sudo install -m 644 \
  systemd/application/postgres-backup.timer \
  /etc/systemd/system/postgres-backup.timer
```

Reload systemd:

```bash
sudo systemctl daemon-reload
```

Enable the timer:

```bash
sudo systemctl enable --now postgres-backup.timer
```

Check it:

```bash
systemctl status postgres-backup.timer
```

Backups are stored under:

```text
/opt/backups/postgres/
```

---

## 13. Prometheus

The version-controlled Prometheus configuration is:

```text
monitoring/prometheus/prometheus.yml
```

The operational configuration is:

```text
/etc/prometheus/prometheus.yml
```

Prometheus monitors:

* gateway
* application
* monitoring
* application endpoints
* Prometheus itself

Validate the configuration before applying changes when `promtool` is available:

```bash
promtool check config monitoring/prometheus/prometheus.yml
```

Install the configuration:

```bash
sudo install -m 644 \
  monitoring/prometheus/prometheus.yml \
  /etc/prometheus/prometheus.yml
```

Reload Prometheus:

```bash
sudo systemctl reload prometheus
```

Check service status:

```bash
systemctl status prometheus
```

---

## 14. Loki

The version-controlled Loki configuration is:

```text
monitoring/loki/config.yml
```

The systemd unit is:

```text
systemd/monitoring/loki.service
```

The operational locations are:

```text
/etc/loki/config.yml
/etc/systemd/system/loki.service
```

After configuration changes:

```bash
sudo systemctl daemon-reload
sudo systemctl restart loki
```

Check:

```bash
systemctl status loki
```

---

## 15. Grafana

Grafana is part of the monitoring environment.

No project-specific Grafana provisioning files are currently required by the application stack. Default package configuration remains machine-local unless a project-specific Grafana configuration is added later.

Do not copy the entire default `grafana.ini` into the repository just for configuration management.

Future Grafana dashboards or provisioning files should be placed under:

```text
monitoring/grafana/
```

---

## 16. Systemd Configuration

Project-managed systemd units are stored under:

```text
systemd/
```

Application units:

```text
systemd/application/
```

Monitoring units:

```text
systemd/monitoring/
```

When a unit is changed:

```bash
sudo install -m 644 <unit-file> /etc/systemd/system/
sudo systemctl daemon-reload
```

Then restart or enable the appropriate service.

---

## 17. Logs and Troubleshooting

### Docker containers

List containers:

```bash
sudo docker ps
```

Inspect a container:

```bash
sudo docker inspect <container>
```

View logs:

```bash
sudo docker logs <container>
```

Follow logs:

```bash
sudo docker logs -f <container>
```

### Compose

Show service status:

```bash
docker compose \
  -p application-stack \
  --env-file .env \
  -f docker/compose.yaml \
  ps
```

Validate configuration:

```bash
APP1_IMAGE=app-v1:v1.4.0 \
APP2_IMAGE=app-v2:v1.4.0 \
APP_VERSION=v1.4.0 \
sudo --preserve-env=APP1_IMAGE,APP2_IMAGE,APP_VERSION \
docker compose \
  -p application-stack \
  --env-file .env \
  -f docker/compose.yaml \
  config -q
```

### Systemd

Check a service:

```bash
systemctl status <service>
```

View recent logs:

```bash
journalctl -u <service> --no-pager -n 100
```

---

## 18. Security Rules

The following rules are mandatory:

1. Never commit `.env`.
2. Never commit real passwords.
3. Never commit API tokens or credentials.
4. Never commit private TLS keys.
5. Never copy production secrets into example files.
6. Use `.env.example` only as a configuration template.
7. Keep machine-specific secrets outside Git.
8. Review staged files before every commit.

Check Git status:

```bash
git status --short --ignored
```

Review staged changes:

```bash
git diff --cached
```

Check that `.env` is not tracked:

```bash
git ls-files .env
```

---

## 19. Git Release Workflow

Configuration changes should be committed and tagged.

Typical workflow:

```bash
git status
git add .
git diff --cached --check
git commit -m "chore: organize project configuration"
git tag v1.5.0
```

Verify:

```bash
git tag --sort=version:refname
git log --oneline --decorate -5
```

Deploy the tagged release:

```bash
sudo ./scripts/deploy.sh v1.5.0
```

The deployment script uses the Git tag as the source of truth, ensuring that the deployed files correspond to a specific version.

---

## 20. Source of Truth

The intended configuration hierarchy is:

```text
Git repository
      │
      ├── nginx/
      ├── docker/
      ├── monitoring/
      ├── scripts/
      └── systemd/
              │
              ▼
      Machine-local deployment
              │
       ┌──────┴───────┐
       ▼              ▼
     /etc             /opt
```

The Git repository contains the reproducible project configuration.

Machine-local files are deployment targets and should not be edited manually without updating the corresponding repository configuration.

---

## 21. First-Time Lab Bring-Up

For a new application VM:

```bash
git clone <REPOSITORY_URL> application-stack
cd application-stack
```

Create local secrets:

```bash
cp .env.example .env
nano .env
```

Provision required external TLS material:

```text
/opt/nginx/tls/nginx.crt
/opt/nginx/tls/nginx.key
```

Install the Nginx configuration:

```bash
sudo mkdir -p /opt/nginx
sudo install -m 644 nginx/nginx.conf /opt/nginx/nginx.conf
```

Install the PostgreSQL backup script and systemd units as described above.

Install the monitoring configurations on the monitoring VM.

Then deploy a release:

```bash
sudo ./scripts/deploy.sh <RELEASE_TAG>
```

Finally verify:

```bash
sudo docker ps
curl -ks https://127.0.0.1:8443/health
curl -ks https://127.0.0.1:8443/version
```

The exact TLS certificate/key provisioning mechanism is environment-specific and is intentionally not stored in this repository.
