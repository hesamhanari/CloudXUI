#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' 0
export CERT_MODE=le DOMAIN=example.com SUB=panel CAMO_SUB=cdn PANEL_PORT=2053 SUB_PORT=2096
export PANEL_USER=admin PANEL_PASS='Test-only-password' CF_API_TOKEN='test-token-not-real-123456789' ACME_EMAIL=admin@example.com
SH=${TEST_SHELL:-sh}
"$SH" "$ROOT/install.sh" --dry-run --non-interactive --render-out "$TMP/rendered" > "$TMP/dry-run.log" 2>&1 || { cat "$TMP/dry-run.log"; exit 1; }
grep -q 'server_name panel.example.com;' "$TMP/rendered/proxy.conf"
grep -q '127.0.0.1:2053;' "$TMP/rendered/proxy.conf"
[ "$(grep -c '127.0.0.1:2096' "$TMP/rendered/proxy.conf")" = 3 ]
! grep -qE 'DOMAIN|SUBPORT|PANELPORT' "$TMP/rendered/proxy.conf"
printf 'PASS: full noninteractive dry run and rendered upstreams\n'
export VPN_SETUP_LIB_ONLY=1
. "$ROOT/install.sh"
trap 'rm -rf "$TMP"' 0
expect_reject() {
    if "$@" > "$TMP/reject.log" 2>&1; then
        printf 'FAIL: accepted invalid input: %s\n' "$*"
        exit 1
    fi
}
v_domain example.com
v_label panel
v_port 65535
expect_reject v_domain '-bad.example'
expect_reject v_domain 'bad-.example'
expect_reject v_label ''
expect_reject v_port 02053
expect_reject v_port 999999999999999999999999
printf 'PASS: runtime domain, label and port validation\n'
nginx() { printf '%s\n' 'configure arguments: --with-stream=dynamic --with-stream_ssl_preread_module' >&2; }
find_stream_module() { printf '/test/ngx_stream_module.so'; }
nginx_stream_support > "$TMP/stream.log"
[ "$STREAM_LOAD_LINE" = 'load_module /test/ngx_stream_module.so;' ]
printf 'PASS: dynamic stream module is explicitly loaded\n'
nginx() { printf '%s\n' 'configure arguments: --with-stream --with-stream_ssl_preread_module' >&2; }
nginx_stream_support > "$TMP/stream.log"
[ -z "$STREAM_LOAD_LINE" ]
printf 'PASS: static stream module needs no load directive\n'

# The script alone (no template files next to it) must render byte-identical
# output from its built-in copies of the templates. VPN_SETUP_LIB_ONLY is
# cleared so the child actually runs its main().
mkdir -p "$TMP/isolated"
cp "$ROOT/install.sh" "$TMP/isolated/install.sh"
VPN_SETUP_LIB_ONLY=0 "$SH" "$TMP/isolated/install.sh" --dry-run --non-interactive \
    --render-out "$TMP/builtin" > "$TMP/builtin.log" 2>&1 \
    || { cat "$TMP/builtin.log"; exit 1; }
grep -q 'rendered:' "$TMP/builtin.log"
grep -q 'using the built-in copy' "$TMP/builtin.log"
if cmp -s "$TMP/rendered/nginx.conf" "$TMP/builtin/nginx.conf" && cmp -s "$TMP/rendered/proxy.conf" "$TMP/builtin/proxy.conf"; then
    printf 'PASS: built-in templates render identically to the file templates\n'
else
    diff "$TMP/rendered/nginx.conf" "$TMP/builtin/nginx.conf" || true
    diff "$TMP/rendered/proxy.conf" "$TMP/builtin/proxy.conf" || true
    printf 'FAIL: built-in templates differ from the file templates\n'
    exit 1
fi

# An explicitly chosen template directory stays strict: missing file aborts.
VPN_SETUP_LIB_ONLY=0 "$SH" "$ROOT/install.sh" --dry-run --non-interactive \
    --config-dir "$TMP/empty-dir" --render-out "$TMP/strict" > "$TMP/strict.log" 2>&1 \
    && { printf 'FAIL: missing explicit template did not abort\n'; exit 1; }
grep -q 'nginx.conf not found' "$TMP/strict.log"
printf 'PASS: explicit --config-dir does not fall back to built-in templates\n'

printf 'All regression tests passed.\n'
