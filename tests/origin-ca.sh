#!/bin/sh
# Cloudflare and OpenSSL are mocked; jq parses real request/response JSON.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
SH=${TEST_SHELL:-sh}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' 0
export TEST_ROOT="$ROOT" TEST_TMP="$TMP"
export DOMAIN=example.com SUB=panel CAMO_SUB=cdn PANEL_PORT=2053 SUB_PORT=2096
export PANEL_USER=admin PANEL_PASS=Test-only-password CF_API_TOKEN=test-token-not-real-123456789
export CERT_MODE=origin
unset ACME_EMAIL CF_ZONE_ID
command -v jq >/dev/null || { printf 'jq is required for this test.\n' >&2; exit 1; }
"$SH" "$ROOT/install.sh" --dry-run --non-interactive --render-out "$TMP/rendered" > "$TMP/dry.log" 2>&1
! grep -q 'Contact email\|Cloudflare Zone ID' "$TMP/dry.log"
printf 'PASS: Origin mode needs neither ACME email nor zone ID\n'
unset CERT_MODE
printf '\n' | "$SH" -c 'VPN_SETUP_LIB_ONLY=1; . "$TEST_ROOT/install.sh"; collect_inputs; print_plan' > "$TMP/default.log" 2>&1
grep -q 'certificate mode     origin' "$TMP/default.log"
printf 'PASS: interactive certificate mode defaults to Origin CA\n'
export CERT_MODE=invalid
if "$SH" -c 'VPN_SETUP_LIB_ONLY=1; NONINTERACTIVE=1; . "$TEST_ROOT/install.sh"; collect_inputs' > "$TMP/invalid.log" 2>&1; then
    printf 'FAIL: invalid certificate mode was accepted\n'; exit 1
fi
export CERT_MODE=origin
cat > "$TMP/worker.sh" <<'WORKER'
set -eu
export VPN_SETUP_LIB_ONLY=1
. "$TEST_ROOT/install.sh"
CERT_DIR="$TEST_TMP/$CASE/cert"
SUB_FQDN=panel.example.com
CAMO_FQDN=cdn.example.com
# Keep all scratch and recovery files inside this test's owned directory.
mktemp() { mkdir -p "$TEST_TMP/$CASE/scratch"; printf '%s' "$TEST_TMP/$CASE/scratch"; }
openssl() {
    _mock_cmd=$1
    shift
    _mock_key=''; _mock_out=''; _mock_host=''
    _mock_pub=0; _mock_expiry=0; _mock_ext=0
    while [ "$#" -gt 0 ]; do
        case $1 in
            -keyout) shift; _mock_key=$1 ;;
            -out) shift; _mock_out=$1 ;;
            -verify_hostname) shift; _mock_host=$1 ;;
            -pubkey|-pubout) _mock_pub=1 ;;
            -checkend) _mock_expiry=1 ;;
            -ext) _mock_ext=1 ;;
        esac
        shift
    done
    case $_mock_cmd in
        req)
            [ "$CASE" != csr-fail ] || return 1
            printf 'PRIVATE KEY FIXTURE\n' > "$_mock_key"
            printf 'CSR FIXTURE\n' > "$_mock_out" ;;
        verify)
            [ "$CASE" != hostname-fail ] || return 1
            [ -n "$_mock_host" ] || return 1 ;;
        x509)
            if [ "$_mock_expiry" = 1 ]; then
                [ "$CASE" != expired ] || return 1
            fi
            if [ "${_mock_ext:-0}" = 1 ]; then
                printf 'X509v3 Subject Alternative Name: \n    DNS:example.com, DNS:*.example.com\n'
                return 0
            fi
            if [ "$_mock_pub" = 1 ]; then printf 'PUBLIC KEY FIXTURE\n'; fi ;;
        pkey)
            if [ "$CASE" = key-mismatch ]; then printf 'WRONG KEY\n'; else printf 'PUBLIC KEY FIXTURE\n'; fi ;;
        *) return 1 ;;
    esac
}
curl() {
    printf 'called\n' >> "$TEST_TMP/$CASE/calls"
    _mock_output=''; _mock_request=''; _mock_header=''; _mock_url=''; _mock_method=''
    while [ "$#" -gt 0 ]; do
        case $1 in
            -X) shift; _mock_method=$1 ;;
            -o) shift; _mock_output=$1 ;;
            --data-binary) shift; _mock_request=${1#@} ;;
            -H) shift; case $1 in @*) _mock_header=${1#@} ;; esac ;;
            https://*) _mock_url=$1 ;;
            --retry*) return 91 ;;
        esac
        shift
    done
    [ "$_mock_method" = POST ] || return 92
    [ "$_mock_url" = https://api.cloudflare.com/client/v4/certificates ] || return 93
    grep -qx "Authorization: Bearer $CF_API_TOKEN" "$_mock_header" || return 94
    jq -e '.requested_validity == 5475 and .request_type == "origin-rsa" and .hostnames == ["example.com","*.example.com"] and .csr == "CSR FIXTURE\n"' "$_mock_request" >/dev/null || return 95
    cp "$_mock_request" "$TEST_TMP/$CASE/request.json"
    case $CASE in
        network-fail) return 28 ;;
        api-fail) printf '{"success":false,"errors":[{"message":"Denied"}]}' > "$_mock_output" ;;
        malformed) printf 'not JSON' > "$_mock_output" ;;
        missing-cert) printf '{"success":true,"result":{}}' > "$_mock_output" ;;
        *) jq -n '{success:true,result:{certificate:"CERTIFICATE FIXTURE",id:"test-id",expires_on:"2041-09-17T00:00:00Z",requested_validity:5475,hostnames:["example.com","*.example.com"]}}' > "$_mock_output" ;;
    esac
}
install_acme() { printf 'FAIL: Origin mode invoked ACME\n'; exit 99; }
stage_certs
WORKER
for CASE in success existing csr-fail network-fail api-fail malformed missing-cert expired hostname-fail key-mismatch; do
    export CASE
    mkdir -p "$TMP/$CASE"
    if [ "$CASE" = existing ]; then
        mkdir -p "$TMP/$CASE/cert"
        printf 'EXISTING KEY\n' > "$TMP/$CASE/cert/privkey.pem"
    fi
    rc=0
    "$SH" "$TMP/worker.sh" > "$TMP/$CASE/log" 2>&1 || rc=$?
    if [ "$CASE" = success ]; then
        [ "$rc" = 0 ] || { cat "$TMP/$CASE/log"; exit 1; }
        grep -qx 'PRIVATE KEY FIXTURE' "$TMP/$CASE/cert/privkey.pem"
        grep -qx 'CERTIFICATE FIXTURE' "$TMP/$CASE/cert/fullchain.pem"
        jq -e '.id == "test-id" and .requested_validity == 5475' "$TMP/$CASE/cert/origin-ca.json" >/dev/null
        [ ! -d "$TMP/$CASE/scratch" ]
    else
        [ "$rc" != 0 ] || { printf 'FAIL: %s returned success\n' "$CASE"; exit 1; }
        [ ! -e "$TMP/$CASE/cert/fullchain.pem" ]
        case $CASE in
            existing)
                grep -qx 'EXISTING KEY' "$TMP/$CASE/cert/privkey.pem"
                [ ! -e "$TMP/$CASE/calls" ] ;;
            csr-fail) [ ! -e "$TMP/$CASE/calls" ]; [ ! -d "$TMP/$CASE/scratch" ] ;;
            *)
                [ "$(wc -l < "$TMP/$CASE/calls" | tr -d ' ')" = 1 ]
                [ -s "$TMP/$CASE/scratch/privkey.pem" ]
                [ ! -e "$TMP/$CASE/scratch/auth.header" ] ;;
        esac
    fi
    printf 'PASS: Origin CA %s\n' "$CASE"
done
printf 'All Origin CA mocked tests passed (no API calls or cryptographic validation performed).\n'
