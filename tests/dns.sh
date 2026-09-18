#!/bin/sh
# Cloudflare DNS A-record tests. curl is mocked, jq parses real JSON.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
SH=${TEST_SHELL:-sh}
command -v jq >/dev/null || { printf 'jq is required for this test.\n' >&2; exit 1; }
CALLS="$TMP/calls"
POSTS="$TMP/posts"
ARGV="$TMP/argv"
: > "$CALLS"; : > "$POSTS"; : > "$ARGV"

VPN_SETUP_LIB_ONLY=1
. "$ROOT/install.sh"
trap 'rm -rf "$TMP"' 0
require_root() { :; }
NONINTERACTIVE=1
DOMAIN=example.com SUB=sub CAMO_SUB=suboff PANEL_PORT=2053 SUB_PORT=8443
PANEL_USER=admin PANEL_PASS=TestPassword123
CF_API_TOKEN=test-token-not-real-123456789 CERT_MODE=origin
derive_names

# Fixtures the curl mock reads at call time; empty IP means "record missing".
EXISTING_SUB_IP=''
EXISTING_CAMO_IP=''
EXISTING_SUB_PROXIED=true
EXISTING_CAMO_PROXIED=true
ZONE_STATUS=200
DETECTED_IP=203.0.113.10

curl() {
    _m_method=GET
    _m_url=''
    _m_out=''
    _m_data=''
    printf '%s\n' "$*" >> "$ARGV"   # lets tests assert the token never appears
    while [ $# -gt 0 ]; do
        case $1 in
            -X) shift; _m_method=$1 ;;
            -o) shift; _m_out=$1 ;;
            --data) shift; _m_data=$1 ;;
            https://*) _m_url=$1 ;;
        esac
        shift
    done
    printf '%s %s\n' "$_m_method" "$_m_url" >> "$CALLS"
    if [ "$_m_method" != GET ]; then
        printf '%s %s\n' "$_m_method" "$_m_data" >> "$POSTS"
        if [ -n "$_m_out" ]; then
            printf '%s' '{"success":true,"result":{"id":"new-record"}}' > "$_m_out"
        else
            printf '%s' '{"success":true,"result":{"id":"new-record"}}'
        fi
        printf '200'
        return 0
    fi
    case $_m_url in
        *api.ipify.org*|*icanhazip*)
            # detect_public_ip captures the body from stdout (no -o flag).
            if [ -n "$_m_out" ]; then
                printf '%s' "$DETECTED_IP" > "$_m_out"
            else
                printf '%s' "$DETECTED_IP"
            fi ;;
        */zones?name=*)
            if [ "$ZONE_STATUS" = 200 ]; then
                printf '%s' '{"success":true,"result":[{"id":"zone-123"}]}' > "$_m_out"
            else
                printf '%s' '{"success":false,"errors":[{"message":"not authorized"}]}' > "$_m_out"
            fi
            printf '%s' "$ZONE_STATUS" ;;
        */dns_records*)
            case $_m_url in
                *name=sub.example.com*) _m_ip=$EXISTING_SUB_IP; _m_id=rec-sub; _m_proxied=$EXISTING_SUB_PROXIED ;;
                *name=suboff.example.com*) _m_ip=$EXISTING_CAMO_IP; _m_id=rec-camo; _m_proxied=$EXISTING_CAMO_PROXIED ;;
                *) _m_ip=''; _m_id=''; _m_proxied=true ;;
            esac
            if [ -n "$_m_ip" ]; then
                printf '%s' "{\"success\":true,\"result\":[{\"id\":\"$_m_id\",\"content\":\"$_m_ip\",\"proxied\":$_m_proxied}]}" > "$_m_out"
            else
                printf '%s' '{"success":true,"result":[]}' > "$_m_out"
            fi
            printf '200' ;;
        *)
            printf '%s' '{"success":false,"errors":[{"message":"unexpected endpoint"}]}' > "$_m_out"
            printf '400' ;;
    esac
}

# 1: both records missing -> created, proxied, with the detected IP.
stage_dns_records pre-approved > "$TMP/out"
grep -q 'Created A record: sub.example.com -> 203.0.113.10 (proxied)' "$TMP/out"
grep -q 'Created A record: suboff.example.com -> 203.0.113.10 (proxied)' "$TMP/out"
grep -q 'zones?name=example.com' "$CALLS"
_count=$(grep -c '"name":"sub.example.com' "$POSTS" || true)
if [ "$_count" != 1 ]; then
    printf 'DEBUG: sub POST count=%s\n' "$_count" >&2
    sed 's/^/  | /' "$POSTS" >&2
    exit 1
fi
grep -q '"proxied":true' "$POSTS"
printf 'PASS: missing records are created proxied with the detected IP\n'

# 1b: the API token never appears on the curl command line (ps/proc leak).
if grep -q "$CF_API_TOKEN" "$ARGV"; then
    printf 'FAIL: the API token is visible in the curl arguments\n'; exit 1
fi
grep -q -- '-H @' "$ARGV"
printf 'PASS: the token goes through a header file, never the curl argv\n'

# 2: rerun with correct proxied records -> no writes.
EXISTING_SUB_IP=203.0.113.10
EXISTING_CAMO_IP=203.0.113.10
_before=$(grep -c 'POST' "$POSTS" || true)
stage_dns_records pre-approved > "$TMP/out"
grep -q 'A record already correct' "$TMP/out"
_after=$(grep -c 'POST' "$POSTS" || true)
[ "$_before" = "$_after" ]
printf 'PASS: correct existing records are left untouched\n'

# 3: grey-cloud record with the right IP, unattended -> warned, not touched.
EXISTING_SUB_PROXIED=false
: > "$POSTS"
stage_dns_records pre-approved > "$TMP/out"
grep -q 'DNS-only (grey cloud)' "$TMP/out"
grep -q 'Leaving it unchanged' "$TMP/out"
if grep -q 'PATCH' "$POSTS"; then exit 1; fi
printf 'PASS: unattended runs leave a grey-cloud record alone but warn\n'

# 4: grey-cloud record, interactive accept -> PATCH enables the proxy.
EXISTING_CAMO_IP=203.0.113.10
: > "$POSTS"
NONINTERACTIVE=0 ASSUME_YES=0
stage_dns_records pre-approved > "$TMP/out" <<'EOF'

y
EOF
grep -q 'Enable the Cloudflare proxy (orange cloud) for sub.example.com?' "$TMP/out"
grep -q 'PATCH {"content":"203.0.113.10","ttl":1,"proxied":true}' "$POSTS"
EXISTING_SUB_PROXIED=true
printf 'PASS: a grey-cloud record is only proxied after confirmation\n'

# 5: conflicting record, interactive decline -> no PATCH.
EXISTING_SUB_IP=198.51.100.1
: > "$POSTS"
stage_dns_records pre-approved > "$TMP/out" <<'EOF'

n
EOF
grep -q 'Left sub.example.com unchanged' "$TMP/out"
if grep -q 'PATCH' "$POSTS"; then exit 1; fi
printf 'PASS: conflicting record is not updated after declining\n'

# 6: conflicting record, interactive accept -> PATCH with the new IP.
stage_dns_records pre-approved > "$TMP/out" <<'EOF'

y
EOF
grep -q 'Updated A record: sub.example.com -> 203.0.113.10 (proxied)' "$TMP/out"
grep -q 'PATCH {"content":"203.0.113.10","ttl":1,"proxied":true}' "$POSTS"
EXISTING_SUB_IP=203.0.113.10
printf 'PASS: confirmed update patches the record content\n'

# 7: conflicting record in unattended runs -> never overwritten.
EXISTING_SUB_IP=198.51.100.1
NONINTERACTIVE=1
: > "$POSTS"
stage_dns_records pre-approved > "$TMP/out"
grep -q 'Leaving it unchanged' "$TMP/out"
if grep -q 'PATCH' "$POSTS"; then exit 1; fi
EXISTING_SUB_IP=203.0.113.10
printf 'PASS: unattended runs never overwrite conflicting records\n'

# 8: zone lookup fails -> clear warning, nonzero status, no writes.
EXISTING_CAMO_IP=''
EXISTING_SUB_IP=''
ZONE_STATUS=400
_before=$(grep -c 'POST' "$POSTS" || true)
if stage_dns_records pre-approved > "$TMP/out"; then
    printf 'FAIL: stage succeeded although the zone lookup failed\n'; exit 1
fi
grep -q 'Could not resolve the Cloudflare zone id' "$TMP/out"
[ "$(grep -c 'POST' "$POSTS" || true)" = "$_before" ]
printf 'PASS: zone lookup failure aborts the DNS stage without writes\n'

# 9: explicit CF_ZONE_ID skips the lookup entirely.
CF_ZONE_ID=manual-zone-42
: > "$CALLS"   # ignore lookups from the earlier cases
stage_dns_records pre-approved > "$TMP/out"
grep -q '/zones/manual-zone-42/dns_records' "$CALLS"
if grep -q 'zones?name=' "$CALLS"; then exit 1; fi
printf 'PASS: explicit CF_ZONE_ID bypasses the zone lookup\n'
unset CF_ZONE_ID
ZONE_STATUS=200

# 10: no detectable IP -> warning and nonzero status, never a fatal exit.
DETECTED_IP=''
if stage_dns_records pre-approved > "$TMP/out"; then
    printf 'FAIL: stage succeeded without an IPv4\n'; exit 1
fi
grep -q 'No public IPv4 address was detected or provided' "$TMP/out"
printf 'after-no-ip\n' >> "$TMP/out"
grep -q 'after-no-ip' "$TMP/out"   # the script continued instead of exiting
printf 'PASS: a missing public IP warns and returns instead of aborting\n'

# 11: invalid DNS_IP values are rejected before any API call.
DETECTED_IP=203.0.113.10
for _bad in '999.999.999.999' '1.2.3' '1.2.3.4;echo pwned' 'not-an-ip' '1.2.3.256'; do
    : > "$CALLS"
    if DNS_IP="$_bad" stage_dns_records pre-approved > "$TMP/out" 2>&1; then
        printf 'FAIL: accepted invalid DNS_IP %s\n' "$_bad"; exit 1
    fi
    grep -q 'not a valid IPv4 address' "$TMP/out"
    if [ -s "$CALLS" ]; then
        printf 'FAIL: API call made for invalid DNS_IP %s\n' "$_bad"; exit 1
    fi
done
printf 'PASS: invalid IPv4 values are rejected without any API call\n'

# 12: the standalone menu action drives the same flow through the real script.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'STUB'
#!/bin/sh
_m_method=GET; _m_url=''; _m_out=''; _m_data=''
while [ $# -gt 0 ]; do
    case $1 in
        -X) shift; _m_method=$1 ;;
        -o) shift; _m_out=$1 ;;
        --data) shift; _m_data=$1 ;;
        https://*) _m_url=$1 ;;
    esac
    shift
done
if [ "$_m_method" != GET ]; then
    printf '%s %s\n' "$_m_method" "$_m_data" >> "$DNS_E2E_POSTS"
    printf '%s' '{"success":true,"result":{"id":"new-record"}}' > "$_m_out"
    printf '200'
    exit 0
fi
case $_m_url in
    *api.ipify.org*|*icanhazip*)
        printf '%s' '203.0.113.10' ;;
    */zones?name=*)
        printf '%s' '{"success":true,"result":[{"id":"zone-123"}]}' > "$_m_out"; printf '200' ;;
    */dns_records*)
        printf '%s' '{"success":true,"result":[]}' > "$_m_out"; printf '200' ;;
esac
STUB
chmod +x "$TMP/bin/curl"
DNS_E2E_POSTS="$TMP/e2e-posts"
export DNS_E2E_POSTS
: > "$DNS_E2E_POSTS"
_out=$(printf '9\nexample.com\n\n\ntest-token-not-real-123456789\n\ny\n0\n' \
    | PATH="$TMP/bin:$PATH" VPN_SETUP_LIB_ONLY=0 "$SH" "$ROOT/install.sh" --menu 2>&1)
printf '%s' "$_out" | grep -q 'Created A record: sub.example.com -> 203.0.113.10 (proxied)'
printf '%s' "$_out" | grep -q 'Created A record: suboff.example.com'
printf '%s' "$_out" | grep -q 'Bye\.'
[ "$(grep -c 'POST' "$DNS_E2E_POSTS" || true)" = 2 ]
printf 'PASS: menu option 9 creates both records through the real script\n'

# 13: dns_records_list formats records in table style: DNS RECORD, TYPE, FORWARD TO
cat > "$TMP/dns_table.json" <<'EOF'
{"success":true,"result":[
  {"name":"example.com","type":"A","content":"203.0.113.10","proxied":true},
  {"name":"mail.example.com","type":"CNAME","content":"example.com","proxied":false}
]}
EOF
cf_api() {
    _cf_status=200
    if [ -z "${_CF_OUT:-}" ]; then
        _CF_OUT=$(mktemp)
    fi
    cp "$TMP/dns_table.json" "$_CF_OUT"
}
DOMAIN=example.com CF_API_TOKEN=test-token-not-real-123456789 DNS_ZONE_ID=zone-123
_out=$(dns_records_list 2>&1)
printf '%s' "$_out" | grep -q 'DNS RECORD'
printf '%s' "$_out" | grep -q 'TYPE'
printf '%s' "$_out" | grep -q 'FORWARD TO'
printf '%s' "$_out" | grep -q '203.0.113.10 (Proxied)'
printf '%s' "$_out" | grep -q 'example.com (DNS only)'
printf 'PASS: dns_records_list displays all records in a formatted table\n'

# 14: dns_record_add_interactive prompts and creates the expected record
cf_api() {
    _cf_method=$1
    _cf_path=$2
    _cf_data=${3:-}
    _cf_status=200
    printf '%s %s %s\n' "$_cf_method" "$_cf_path" "$_cf_data" >> "$TMP/add_calls"
}
: > "$TMP/add_calls"
printf 'A\ncustom\n203.0.113.99\ny\n' | dns_record_add_interactive > "$TMP/add.log" 2>&1
grep -q 'POST /zones/zone-123/dns_records' "$TMP/add_calls"
grep -q '"name":"custom.example.com"' "$TMP/add_calls"
grep -q '"content":"203.0.113.99"' "$TMP/add_calls"
grep -q '"proxied":true' "$TMP/add_calls"
grep -q 'Created A record: custom.example.com -> 203.0.113.99 (proxied: true)' "$TMP/add.log"
printf 'PASS: dns_record_add_interactive prompts and creates a proxied record\n'

# 15: show_all_domains looks up zones and displays their DNS records
cat > "$TMP/zones.json" <<'EOF'
{"success":true,"result":[
  {"id":"zone-aaa","name":"site1.com"},
  {"id":"zone-bbb","name":"site2.com"}
]}
EOF
cat > "$TMP/zone_aaa_records.json" <<'EOF'
{"success":true,"result":[
  {"name":"site1.com","type":"A","content":"198.51.100.1","proxied":true}
]}
EOF
cat > "$TMP/zone_bbb_records.json" <<'EOF'
{"success":true,"result":[
  {"name":"sub.site2.com","type":"CNAME","content":"target.site","proxied":false}
]}
EOF
cf_api() {
    _cf_method=$1
    _cf_path=$2
    _cf_status=200
    case $_cf_path in
        /zones\?*|/zones) cp "$TMP/zones.json" "$_CF_OUT" ;;
        /zones/zone-aaa/dns_records*) cp "$TMP/zone_aaa_records.json" "$_CF_OUT" ;;
        /zones/zone-bbb/dns_records*) cp "$TMP/zone_bbb_records.json" "$_CF_OUT" ;;
    esac
}
CF_API_TOKEN=test-token-not-real-123456789
_out=$(printf '\n\n' | show_all_domains 2>&1)
printf '%s' "$_out" | grep -q 'Domain: site1.com'
printf '%s' "$_out" | grep -q '198.51.100.1 (Proxied)'
printf '%s' "$_out" | grep -q 'Domain: site2.com'
printf '%s' "$_out" | grep -q 'target.site (DNS only)'
printf 'PASS: show_all_domains lists each domain and its formatted DNS table\n'

printf 'All DNS tests passed.\n'
