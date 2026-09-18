#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
SH=${TEST_SHELL:-sh}
VPN_SETUP_LIB_ONLY=1
. "$ROOT/install.sh"
trap 'rm -rf "$TMP"' 0
require_root() { :; }
ensure_os() { :; }
install_base_tools() { :; }
nginx_check_version() { :; }
nginx_stream_support() { :; }
nginx() { :; }
stage_nginx() { printf 'NGINX_INSTALL\n'; }
stage_xui() { printf 'XUI_INSTALL\n'; }
stage_deploy() { printf 'DEPLOY\n'; }
stage_verify() { printf 'VERIFY\n'; }
stage_firewall() { printf 'FIREWALL\n'; }
collect_secret() { die 'Unexpected certificate credential prompt'; }
collect_password() { die 'Unexpected panel password prompt'; }
nginx_install_menu </dev/null > "$TMP/nginx"
grep -q NGINX_INSTALL "$TMP/nginx"
NONINTERACTIVE=1
DOMAIN=example.com SUB=panel CAMO_SUB=cdn PANEL_PORT=2053 SUB_PORT=8443
PANEL_USER='' PANEL_PASS='' CF_API_TOKEN='' CERT_MODE=''
# Feed only the deploy confirmation; the mocked collectors still abort on any
# credential or certificate prompt, so scoping stays verified.
printf 'y\n' | deploy_configs > "$TMP/deploy"
grep -q DEPLOY "$TMP/deploy"
[ -z "$PANEL_USER$PANEL_PASS$CF_API_TOKEN$CERT_MODE" ]
printf 'PASS: nginx install needs no inputs; deploy needs no credentials or certificate answers\n'
CAMO_SUB=''
ensure_verify_config </dev/null > "$TMP/verify"
[ -z "$CAMO_SUB$PANEL_USER$PANEL_PASS$CF_API_TOKEN$CERT_MODE" ]
printf 'PASS: verify needs only root domain, panel prefix and ports\n'
collect_password() { PANEL_PASS=TestPassword123; }
PANEL_USER='admin'
xui_install_menu </dev/null > "$TMP/xui"
grep -q XUI_INSTALL "$TMP/xui"
[ -z "$CAMO_SUB$CF_API_TOKEN$CERT_MODE" ]
printf 'PASS: 3x-ui install needs no camouflage or certificate answers\n'
reset_config > /dev/null
menu_loop > "$TMP/menu" <<'EOF'
5
7
0
EOF
grep -q FIREWALL "$TMP/menu"
grep -q 'not set' "$TMP/menu"
[ -z "$DOMAIN$SUB$CAMO_SUB$PANEL_PORT$SUB_PORT$PANEL_USER$PANEL_PASS$CF_API_TOKEN" ]
printf 'PASS: firewall and summary ask no setup questions\n'
# Exercise the real CLI renderer without any panel or Cloudflare secrets.
unset PANEL_USER PANEL_PASS CF_API_TOKEN CF_ZONE_ID ACME_EMAIL CERT_MODE
DOMAIN=example.com SUB=panel CAMO_SUB=cdn PANEL_PORT=2053 SUB_PORT=8443 \
VPN_SETUP_LIB_ONLY=0 "$SH" "$ROOT/install.sh" --dry-run --non-interactive --render-out "$TMP/rendered" > "$TMP/dry.log" 2>&1
[ -f "$TMP/rendered/nginx.conf" ]
if grep -E 'Panel admin|Cloudflare API token|Panel password' "$TMP/dry.log"; then exit 1; fi
printf 'PASS: noninteractive dry-run succeeds with only rendering inputs\n'
printf 'All scoped-input tests passed.\n'
