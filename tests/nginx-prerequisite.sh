#!/bin/sh
# No packages or services are changed; trace the menu deployment prerequisites.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
VPN_SETUP_LIB_ONLY=1
. "$ROOT/install.sh"
trap 'rm -rf "$TMP"' 0
require_root() { :; }
# A real install makes `nginx` available on PATH; model that with a stub file
# instead of a shell variable (the install runs in a subshell).
mkdir -p "$TMP/bin"
install_stub() { printf '#!/bin/sh\n' > "$TMP/bin/nginx"; chmod +x "$TMP/bin/nginx"; }
remove_stub() { rm -f "$TMP/bin/nginx"; }
have() { [ "$1" = nginx ] && [ -x "$TMP/bin/nginx" ]; }
confirm() { printf 'confirm\n' >> "$TMP/trace"; [ "$ANSWER" = yes ]; }
nginx_install_menu() {
    printf 'install\n' >> "$TMP/trace"
    case $RESULT in
        fail) die 'Mock installation failed' ;;
        missing) return 0 ;;
        *) install_stub ;;
    esac
}
nginx_check_version() { printf 'version\n' >> "$TMP/trace"; }
ensure_os() { printf 'os\n' >> "$TMP/trace"; }
nginx_stream_support() { printf 'stream\n' >> "$TMP/trace"; }
collect_action_inputs() { printf 'questions\n' >> "$TMP/trace"; }
validate_combination() { :; }
# deploy_configs prints the render plan from these session answers.
DOMAIN=example.com SUB=panel CAMO_SUB=cdn PANEL_PORT=2053 SUB_PORT=8443
SUB_FQDN=panel.example.com CAMO_FQDN=cdn.example.com
CERT_DIR="$TMP/certs"
stage_deploy() { printf 'deploy\n' >> "$TMP/trace"; }
stage_verify() { printf 'verify\n' >> "$TMP/trace"; }
remove_stub
ANSWER=yes RESULT=success
deploy_configs > "$TMP/output"
printf 'confirm\ninstall\nversion\nos\nstream\nquestions\nconfirm\ndeploy\nverify\n' > "$TMP/expected"
cmp "$TMP/trace" "$TMP/expected"
printf 'PASS: missing nginx is installed and checked before deployment questions\n'
: > "$TMP/trace"
install_stub
deploy_configs > "$TMP/output"
printf 'version\nos\nstream\nquestions\nconfirm\ndeploy\nverify\n' > "$TMP/expected"
cmp "$TMP/trace" "$TMP/expected"
printf 'PASS: installed nginx is checked and asked once before deployment\n'
: > "$TMP/trace"
remove_stub
ANSWER=no
deploy_configs > "$TMP/output"
printf 'confirm\n' > "$TMP/expected"
cmp "$TMP/trace" "$TMP/expected"
printf 'PASS: declining returns without questions or deployment\n'
# In classic flag mode (arg omitted) the deploy confirmation is required too.
: > "$TMP/trace"
install_stub
ANSWER=no
deploy_configs > "$TMP/output"
printf 'version\nos\nstream\nquestions\nconfirm\n' > "$TMP/expected"
cmp "$TMP/trace" "$TMP/expected"
printf 'PASS: classic mode declines the deploy confirmation before any stage\n'
ANSWER=yes
for RESULT in fail missing; do
    : > "$TMP/trace"
    remove_stub
    _out=$(deploy_configs 2>&1); _status=$?
    # The failure is contained: deployment cancels with status 0 instead of
    # killing the whole script (the interactive menu keeps running).
    [ "$_status" = 0 ]
    if [ "$RESULT" = fail ]; then
        printf '%s' "$_out" | grep -q 'nginx installation failed; deployment cancelled.'
    else
        printf '%s' "$_out" | grep -q 'nginx is still not available after the installation; deployment cancelled.'
    fi
    printf 'confirm\ninstall\n' > "$TMP/expected"
    cmp "$TMP/trace" "$TMP/expected"
    printf 'PASS: %s installation cancels deployment without killing the script\n' "$RESULT"
done

# nginx status on a machine without nginx shows the red instruction to install.
remove_stub
nginx_status > "$TMP/status" 2>&1
grep -q "nginx is not installed, please install it first to continue." "$TMP/status"
grep -q '^\[x\]' "$TMP/status"
printf 'PASS: nginx status prints the red install-first error when nginx is missing\n'

printf 'All nginx prerequisite tests passed.\n'
