#!/bin/sh
# Tests orchestration, not Linux installation or certificate issuance.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' 0
export DOMAIN=example.com SUB=panel CAMO_SUB=cdn PANEL_PORT=2053 SUB_PORT=2096
export PANEL_USER=admin PANEL_PASS=Test-only-password CF_API_TOKEN=test-token-not-real-123456789
export CERT_MODE=origin TEST_ROOT="$ROOT" TRACE="$TMP/trace"
SH=${TEST_SHELL:-sh}
# apt-get cannot be a shell function under dash (hyphen), so stub it on PATH.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/apt-get" <<'STUB'
#!/bin/sh
printf 'apt\n' >> "$TRACE"
STUB
chmod +x "$TMP/bin/apt-get"
PATH="$TMP/bin:$PATH" "$SH" -c '
export VPN_SETUP_LIB_ONLY=1
. "$TEST_ROOT/install.sh"
id() { printf 0; }
detect_os() { OS_FAMILY=deb; }
pkg_install() { printf "packages %s\n" "$*" >> "$TRACE"; }
systemctl() { return 0; }
check_connectivity() { printf "connectivity\n" >> "$TRACE"; }
stage_dns_records() { printf "dns\n" >> "$TRACE"; }
stage_nginx() { printf "nginx\n" >> "$TRACE"; }
stage_xui() { printf "xui\n" >> "$TRACE"; }
stage_origin_cert() { printf "origin\n" >> "$TRACE"; }
install_acme() { printf "ERROR: invoked ACME\n" >> "$TRACE"; exit 99; }
stage_deploy() { printf "deploy\n" >> "$TRACE"; }
stage_firewall() { printf "firewall\n" >> "$TRACE"; }
stage_verify() { printf "verify\n" >> "$TRACE"; }
main --non-interactive --yes --config-dir "$TEST_ROOT"
' > "$TMP/main.log" 2>&1 || { cat "$TMP/main.log"; exit 1; }
grep -qx 'connectivity' "$TRACE"
[ "$(grep -E '^(dns|nginx|xui|origin|deploy|firewall|verify)$' "$TRACE" | tr '\n' ' ')" = 'dns nginx xui origin deploy firewall verify ' ]
! grep -q ERROR "$TRACE"
printf 'PASS: full mocked main flow selects Origin CA and installs its prerequisites\n'
