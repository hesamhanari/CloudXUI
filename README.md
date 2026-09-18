# CloudXUI — Automated Nginx & 3x-UI Front-End Suite

**Made By HesamTheDr with Power Of AI**

[![POSIX sh](https://img.shields.io/badge/shell-POSIX%20sh-blue.svg)](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html)
[![Nginx Mainline](https://img.shields.io/badge/nginx-1.31%2B%20mainline-green.svg)](https://nginx.org)
[![3x-ui](https://img.shields.io/badge/3x--ui-latest-orange.svg)](https://github.com/MHSanaei/3x-ui)
[![TLS](https://img.shields.io/badge/TLS-Origin%20CA%20%7C%20Let's%20Encrypt-purple.svg)](https://www.cloudflare.com)
[![Tests](https://img.shields.io/badge/test%20suite-12%20passed-brightgreen.svg)](tests/run-all.sh)

A secure, fully automated, and self-contained installer for deploying a high-performance **CloudXUI (Nginx Mainline + 3x-UI) VPN Front-End** on a Linux VPS. It sets up SNI-based TLS preread routing, reverse proxies the 3x-ui management panel and subscription service, deploys an anti-censorship camouflage website, manages Cloudflare DNS records, and automates 15-year Cloudflare Origin CA or Let's Encrypt certificates.

---

## Architecture Overview

```
                      Internet Client (HTTPS: 443)
                                  │
                                  ▼
                     ┌─────────────────────────┐
                     │   Nginx (stream module) │
                     │   Port 443 SNI Preread  │
                     └────────────┬────────────┘
                                  │
            ┌─────────────────────┴─────────────────────┐
            ▼                                           ▼
┌──────────────────────────┐               ┌──────────────────────────┐
│  Direct VPN Inbounds     │               │  Local Nginx Web Backend │
│  REALITY / TLS Pass-thru │               │  Port 4443 (HTTP/2 TLS)  │
│  Ports: 10000, 20000,    │               └────────────┬─────────────┘
│  30000, 40000 (Xray)     │                            │
└──────────────────────────┘         ┌──────────────────┼──────────────────┐
                                     ▼                  ▼                  ▼
                              ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
                              │ 3x-ui Panel │    │Subscription │    │ Camouflage  │
                              │ /xuipanel/  │    │   Service   │    │   Website   │
                              │ (127.0.0.1) │    │  ^~ /s/     │    │  (goldcalc) │
                              └─────────────┘    └─────────────┘    └─────────────┘
```

* **SNI-based Stream Routing (`nginx.conf`)**: Nginx intercepts inbound TLS traffic on port 443 without terminating TLS upfront (`ssl_preread on`). VPN inbounds with custom SNIs (e.g. REALITY or raw-TCP) are forwarded directly to Xray backends, while your domain traffic routes to local HTTPS termination.
* **Hardened Nginx Reverse Proxy (`proxy.conf`)**:
  * `/xuipanel/`: Proxies 3x-UI web dashboard with strict WebSocket support (`Upgrade` / `Connection` hop-by-hop headers). Accessing `/xuipanel` cleanly redirects to `/xuipanel/`.
  * `^~ /s/`: Exposes the 3x-ui subscription service with priority prefix routing, ensuring subscription download paths are never blocked by regex filters.
  * Security filters: Automatically blocks common exploit probes, sensitive hidden files (`.git`, `.env`), and VPN configuration scraping (`.conf`, `.ovpn`, etc.).
  * Camouflage site: Hosts an authentic web application (Gold Calculator) to resist active probing.
* **Dual Certificate Engine**:
  * **Cloudflare Origin CA (Default)**: Generates local RSA-2048 private key & CSR, requesting a **15-year (5475 days)** certificate covering `<domain>` and `*.<domain>` directly via Cloudflare API. The private key never leaves your VPS.
  * **Let's Encrypt Wildcard (`le`)**: Issues auto-renewing certificates via `acme.sh` DNS-01 challenge.
* **Automated Cloudflare DNS Management**: Detects server public IPv4, checks zone records, and creates or updates proxied (orange-cloud) A records for your panel and camouflage subdomains with automatic TTL.
* **Self-Contained & Resilient**: Built-in templates inside `install.sh` allow deployment with just a single file. Full transaction safety with automatic backup and rollback if `nginx -t` fails.

---

## Supported Operating Systems

* **Debian**: 11, 12 (Bookworm), 13 (Trixie)
* **Ubuntu**: 20.04 (Focal), 22.04 (Jammy), 24.04 (Noble)
* **RHEL / Clones**: AlmaLinux 8/9+, Rocky Linux 8/9+, CentOS Stream 9+, Fedora

*Requirements*: Fresh VPS with root access, IPv4 connectivity, `curl`, `jq`, `openssl`, and `sed`/`awk`.

---

## Cloudflare API Token Permissions

Create an API token in your Cloudflare dashboard (**Profile** → **API Tokens** → **Create Token** → **Create Custom Token**):

| Mode | Required Permissions | Scope |
| --- | --- | --- |
| **Origin CA** (Default) | • **Zone → SSL and Certificates → Edit**<br>• **Zone → DNS → Edit** *(for A records)*<br>• **Zone → Zone → Read** *(for zone lookup)* | Include → Specific zone → `yourdomain.com` |
| **Let's Encrypt** (`le`) | • **Zone → DNS → Edit**<br>• **Zone → Zone → Read** | Include → Specific zone → `yourdomain.com` |

> [!NOTE]
> When using **Origin CA**, ensure your Cloudflare SSL/TLS encryption mode is set to **Full (strict)** and the DNS records are **Proxied (Orange Cloud)**.

---

## Quick Start

### 1. Download & Run the Installer

You only need the single `install.sh` script:

```bash
# Download install.sh
curl -fsSL -O https://raw.githubusercontent.com/<username>/CloudXUI/main/install.sh

# Run the interactive menu (as root)
bash install.sh
```

*(Alternatively, upload `install.sh`, `nginx.conf`, and `proxy.conf` together if you want to edit templates beforehand).*

---

### 2. Interactive Menu

Running `bash install.sh` without options displays the main management console:

```
================ CloudXUI ================
  1) Full install (nginx + 3x-ui + certificate)
  2) Nginx: install / status / deploy / uninstall
  3) Cloudflare Management
  4) 3x-ui: install / status / manage / uninstall
  5) Firewall (ufw: open 80 and 443)
  6) Verify the whole setup
  7) Show the current configuration summary
  8) Re-answer the configuration questions
  0) Exit
```

#### Menu Navigation Highlights:
* **Option 1 (Full install)**: One-shot setup from zero to a fully running system. Prompts for domain, prefixes, ports, admin credentials, certificate mode, and API token, shows the installation plan, and performs the entire deployment safely.
* **Option 2 (Nginx)**: Check status, reload configurations, deploy templates, uninstall, or access **SNI management** (add/remove custom SNI route bindings).
* **Option 3 (Cloudflare Management)**: Unified Cloudflare management center:
  * **Certificate manager**: Check certificate status & SAN coverage, or issue 15-year Origin CA / Let's Encrypt wildcard certificates.
  * **Domain Manager**:
    * **Show All Domains**: Prompts for Cloudflare Account/Zone ID and API token to query and list all accessible domains and their DNS records in an aligned table format.
    * **Show DNS Records**: Prompts for domain and API key/token to display that domain's DNS records in an aligned table (`DNS RECORD`, `TYPE`, `FORWARD TO` with proxy status).
    * **Add Record**: Interactively creates `A`, `AAAA`, `CNAME`, or `TXT` records with optional Cloudflare proxy (orange cloud).
    * **Auto-configure panel & camouflage A records**: Auto-detects VPS public IP and upserts proxied A records for your panel and camouflage subdomains.
* **Option 4 (3x-UI)**: Install/update panel, inspect listening sockets, launch the `x-ui` CLI management utility, or cleanly uninstall.
* **Option 5 (Firewall)**: Open ports 80 and 443 with `ufw`.
* **Option 6 (Verify)**: Audit all endpoints, SSL certificate, and loopback services.

---

## Unattended / Automated Installation

To automate deployment across servers or in CI/CD, pass environment variables with `--non-interactive --yes`:

```bash
DOMAIN="example.com" \
SUB="panel" \
CAMO_SUB="cdn" \
PANEL_PORT=2053 \
SUB_PORT=2096 \
PANEL_USER="admin" \
PANEL_PASS="YourSuperStrongPassword123" \
CERT_MODE="origin" \
CF_API_TOKEN="your_cloudflare_api_token_here" \
bash install.sh --non-interactive --yes
```

### Environment Variables Reference

| Variable | Description | Default |
| --- | --- | --- |
| `DOMAIN` | Root domain name (e.g. `example.com`) | *Required* |
| `SUB` | Subdomain prefix for 3x-ui panel & subscriptions | `sub` |
| `CAMO_SUB` | Subdomain prefix for the camouflage website | `suboff` |
| `PANEL_PORT` | Local loopback port for 3x-ui web dashboard | Random (20000–59000) |
| `SUB_PORT` | Local loopback port for subscription service | `8443` |
| `PANEL_USER` | Admin username for 3x-ui | `admin` |
| `PANEL_PASS` | Admin password for 3x-ui | Auto-generated if empty |
| `CERT_MODE` | Certificate authority: `origin` (15-yr) or `le` (Let's Encrypt) | `origin` |
| `CF_API_TOKEN`| Cloudflare zone API token | *Required* |
| `CF_ZONE_ID` | Cloudflare Zone ID (optional, auto-discovered if omitted) | *(Auto)* |
| `ACME_EMAIL` | Email for Let's Encrypt notifications (only for `le` mode) | `admin@<domain>` |
| `DNS_IP` | Public IPv4 address override for Cloudflare A records | *(Auto-detected)* |
| `PANEL_PATH` | Base URL path for 3x-ui panel | `/xuipanel/` |
| `SUB_PATH` | Base URL path for subscriptions | `/s/` |

---

## Command Line Flags

| Flag | Purpose |
| --- | --- |
| *(no flag)* | Launches interactive menu (terminal) or runs prompt flow |
| `--menu` | Forces interactive menu even if other flags are present |
| `--dry-run` | Renders templates to `./rendered-configs/` without applying changes |
| `--configs-only`| Re-renders and updates Nginx configs without touching 3x-ui or certs |
| `--yes` | Skips interactive confirmation prompts |
| `--non-interactive`| Requires all configuration variables via environment |
| `--config-dir DIR` | Directory to read custom `nginx.conf` and `proxy.conf` from |

---

## Security & Reliability Design

1. **Least Privilege & Token Safety**:
   - Cloudflare API tokens are passed to `curl` via mode-600 temporary files (`-H "@tempfile"`), preventing exposure in `ps`, `/proc`, or shell history.
   - Panel & subscription listeners bind exclusively to `127.0.0.1`.
2. **Pre-flight Validation & Atomic Rollback**:
   - Configuration templates are validated with `nginx -t` before activation.
   - If validation or reloading fails, previous working configs are restored automatically.
3. **Database Integrity**:
   - Subscription settings are injected into 3x-ui's SQLite database inside an atomic transaction with service stopped and an automated `.backup` file preserved.
4. **Origin Certificate Protection**:
   - Existing valid certificates are never silently overwritten.
   - If an API error occurs after CSR submission, keys and CSRs are preserved in a root-only recovery directory.

---

## Verification & Testing

The repository includes a comprehensive 12-suite automated test framework (`tests/run-all.sh`) validating POSIX compliance, template rendering, safety rollbacks, Cloudflare API interaction, and menu navigation:

```bash
bash tests/run-all.sh
```

**Test Suite Coverage:**
* `scoped-inputs`: Scoped input collection per action
* `nginx-gate`: Nginx installation gating & menu safety
* `nginx-prerequisite`: Deployment prerequisite checks
* `regression`: Template substitution byte-for-byte fidelity
* `deployment`: Rollback on invalid configs & backup verification
* `main-flow`: End-to-end mocked full installation flow
* `cert-state`: Certificate expiry and state detection
* `origin-ca`: 15-year Origin CA issuance, error handling & CSR flow
* `dns`: Cloudflare A-record upsertion, grey/orange cloud & TTL safety
* `sni`: Stream SNI map parsing, addition, and removal
* `xui-gate`: 3x-ui installation gating & status checks
* `menu`: Menu navigation, credits, and session persistence

---

## Post-Installation Checklist

1. **Cloudflare Dashboard**:
   - Ensure SSL/TLS encryption mode is set to **Full (strict)**.
   - Verify that your panel (`sub.domain.com`) and camouflage (`suboff.domain.com`) A records have the **Proxy status** set to **Proxied** (Orange Cloud).
2. **3x-UI Panel Access**:
   - Open `https://<SUB>.<DOMAIN>/xuipanel/` in your browser and log in with your admin credentials.
   - If Nginx is ever stopped, access locally via SSH tunnel:
     ```bash
     ssh -L 8080:127.0.0.1:<PANEL_PORT> root@YOUR_SERVER_IP
     # Open http://127.0.0.1:8080/xuipanel/
     ```
3. **Inbound Configurations**:
   - In 3x-ui, configure inbounds on `127.0.0.1` matching the listening ports defined in `nginx.conf` (`10001`, `10002`, `10003`, `10000`, `20000`, `30000`, `40000`).
   - Do not bind inbounds directly to 0.0.0.0:443 — Nginx manages port 443 with SNI demultiplexing.

---

## Troubleshooting

| Issue | Cause & Solution |
| --- | --- |
| **`nginx -t` fails on reload** | Check syntax in custom templates. The script automatically rolls back to working configs. Run `bash install.sh --dry-run` to inspect rendered files. |
| **Panel returns 404** | Ensure URL includes trailing slash: `https://<SUB>.<DOMAIN>/xuipanel/`. Check that `PANEL_PATH` matches the panel base path. |
| **Panel returns 502 Bad Gateway** | 3x-ui service is not running on the configured port. Run `systemctl status x-ui` and verify with `ss -lntp`. |
| **Origin CA certificate error** | Verify API token has **Zone → SSL and Certificates → Edit** permission and that your domain is on that Cloudflare account. |
| **Subscription URL returns 404** | Verify SQLite updated properly: check `systemctl status x-ui` and verify `SUB_PORT` with `ss -lnt`. |
| **Inspect System Logs** | `journalctl -u nginx -u x-ui -n 50 --no-pager` |

---

## Credits & License

**Made By HesamTheDr with Power Of AI**  
Released under the [MIT License](LICENSE).
