#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' 0
export CERT_MODE=origin DOMAIN=example.com SUB=panel CAMO_SUB=cdn PANEL_PORT=8443 SUB_PORT=2096
export PANEL_USER=admin PANEL_PASS=Test-only-password CF_API_TOKEN=test-token-not-real-123456789 ACME_EMAIL=admin@example.com
SH=${TEST_SHELL:-sh}
"$SH" "$ROOT/install.sh" --dry-run --non-interactive --render-out "$TMP/rendered" > "$TMP/render.log" 2>&1 || { cat "$TMP/render.log"; exit 1; }
grep -q 'proxy_pass http://127.0.0.1:8443;' "$TMP/rendered/proxy.conf"
[ "$(grep -c '127.0.0.1:2096' "$TMP/rendered/proxy.conf")" = 3 ]
printf 'PASS: panel port 8443 survives subscription port substitution\n'
mkdir -p "$TMP/live/conf.d" "$TMP/certs" "$TMP/backups"
printf 'old main\n' > "$TMP/live/nginx.conf"
printf 'old proxy\n' > "$TMP/live/conf.d/proxy.conf"
printf 'old additional site\n' > "$TMP/live/conf.d/site-conf.d-test.conf"
printf 'certificate fixture\n' > "$TMP/certs/fullchain.pem"
printf 'key fixture\n' > "$TMP/certs/privkey.pem"
export NGINX_MAIN_CONF="$TMP/live/nginx.conf" NGINX_CONF_D="$TMP/live/conf.d" BACKUP_BASE="$TMP/backups" WEB_ROOT="$TMP/web"
export TEST_ROOT="$ROOT" TEST_TMP="$TMP"
# A separate process preserves the installer's real EXIT trap and errexit behavior.
"$SH" -c '
VPN_SETUP_LIB_ONLY=1
. "$TEST_ROOT/install.sh"
CERT_DIR="$TEST_TMP/certs"
SUB_FQDN=panel.example.com
CAMO_FQDN=cdn.example.com
NGINX_TEMPLATE="$TEST_ROOT/nginx.conf"
PROXY_TEMPLATE="$TEST_ROOT/proxy.conf"
nginx() { return 1; }
systemctl() { return 0; }
stage_deploy
' > "$TMP/deploy.log" 2>&1 && { printf 'FAIL: rejected deployment succeeded\n'; exit 1; }
grep -qx 'old main' "$TMP/live/nginx.conf"
grep -qx 'old proxy' "$TMP/live/conf.d/proxy.conf"
grep -qx 'old additional site' "$TMP/live/conf.d/site-conf.d-test.conf"
[ "$(find "$TMP/live/conf.d" -type f | wc -l | tr -d ' ')" = 2 ]
printf 'PASS: rejected deployment restores main, proxy and exact conf.d filenames\n'
printf 'All deployment regression tests passed.\n'
