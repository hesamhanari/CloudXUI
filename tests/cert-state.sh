#!/bin/sh
# Local fixtures only: no ACME, OpenSSL or HTTP requests reach real tools.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
VPN_SETUP_LIB_ONLY=1
. "$ROOT/install.sh"
trap 'rm -rf "$TMP"' 0
ACME_HOME="$TMP/acme"
CERT_BASE="$TMP/certs"
DOMAIN=example.com
CERT_DIR="$CERT_BASE/$DOMAIN"
mkdir -p "$ACME_HOME" "$CERT_DIR"
cat > "$ACME_HOME/acme.sh" <<'EOF'
#!/bin/sh
[ "${CF_Token:-}" = current-token ] || exit 81
[ "${CF_Zone_ID:-}" = '' ] || exit 82
case $1 in
    --install-cert)
        [ "${FAIL_INSTALL:-0}" = 0 ] || exit 83
        while [ $# -gt 0 ]; do
            case $1 in
                --fullchain-file|--key-file) shift; printf 'fixture\n' > "$1" ;;
            esac
            shift
        done ;;
esac
EOF
chmod +x "$ACME_HOME/acme.sh"
install_acme() { :; }
openssl() { :; }
CERT_MODE=le CF_API_TOKEN=current-token CF_ZONE_ID=''
export CF_Token=old-token CF_Zone_ID=old-zone
stage_certs > "$TMP/issue.log" 2>&1
[ "$CF_Token" = current-token ]
[ -z "$CF_Zone_ID" ]
printf 'PASS: LE invocation replaces stale exported token and clears blank zone\n'
GENERATED_PASSWORD=1 PASS_COUNT=7 FAIL_COUNT=8
reset_config > /dev/null
[ -z "$CF_API_TOKEN$CF_ZONE_ID$CF_Token$CF_Zone_ID" ]
[ "$GENERATED_PASSWORD:$PASS_COUNT:$FAIL_COUNT" = 0:0:0 ]
printf 'PASS: reset clears credentials, generated-password flag and counters\n'
