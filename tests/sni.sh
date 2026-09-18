#!/bin/sh
# SNI menu and transaction tests; all service operations are mocked.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
SH=${TEST_SHELL:-sh}
VPN_SETUP_LIB_ONLY=1
. "$ROOT/install.sh"
trap 'rm -rf "$TMP"' 0
NGINX_MAIN_CONF="$TMP/nginx.conf"
BACKUP_BASE="$TMP/backups"
require_root() { :; }
MODE=success
nginx() {
    printf 'test\n' >> "$TMP/tests"
    if [ "$MODE" = invalid ] && grep -q 'new.example.com' "$NGINX_MAIN_CONF"; then return 1; fi
    return 0
}
systemctl() {
    case $1 in
        is-active) [ "$MODE" != stopped ] ;;
        reload)
            printf 'reload\n' >> "$TMP/reloads"
            [ "$MODE" != reload-fail ] ;;
        *) return 1 ;;
    esac
}
cp "$ROOT/nginx.conf" "$NGINX_MAIN_CONF"
sni_map list "$NGINX_MAIN_CONF" > "$TMP/list"
grep -q '^7. yahoo.com 10002$' "$TMP/list"
if grep -q default "$TMP/list"; then exit 1; fi
printf 'PASS: numbered list includes SNI ports and excludes default\n'

sni_update add NEW.example.com 10004 > "$TMP/add.log" 2>&1
sni_map list "$NGINX_MAIN_CONF" | grep -q 'new.example.com 10004'
grep -q reload "$TMP/reloads"
printf 'PASS: add normalizes hostname, validates config and reloads\n'
cp "$NGINX_MAIN_CONF" "$TMP/before"
for pair in 'NEW.EXAMPLE.COM:10005' 'bad;host.com:10005' 'bad.example.com:65536' 'bad.example.com:0' 'bad.example.com:080'; do
    if sni_update add "${pair%:*}" "${pair#*:}" > "$TMP/reject.log" 2>&1; then
        printf 'FAIL: accepted %s\n' "$pair"; exit 1
    fi
    cmp "$NGINX_MAIN_CONF" "$TMP/before"
done
printf 'PASS: duplicate, unsafe hostname and invalid ports leave config unchanged\n'

sni_update remove new.example.com > "$TMP/remove.log" 2>&1
cmp "$NGINX_MAIN_CONF" "$ROOT/nginx.conf"
printf 'PASS: remove preserves every unrelated line and default\n'
if sni_update remove default > "$TMP/default.log" 2>&1; then exit 1; fi
cmp "$NGINX_MAIN_CONF" "$ROOT/nginx.conf"

for MODE in invalid reload-fail; do
    if sni_update add new.example.com 10004 > "$TMP/failure.log" 2>&1; then
        printf 'FAIL: transaction succeeded in %s mode\n' "$MODE"; exit 1
    fi
    cmp "$NGINX_MAIN_CONF" "$ROOT/nginx.conf"
    printf 'PASS: %s restores original config byte-for-byte\n' "$MODE"
done
MODE=stopped
rm -f "$TMP/reloads"
sni_update add new.example.com 10004 > "$TMP/stopped.log" 2>&1
[ ! -f "$TMP/reloads" ]
grep -q 'was not started' "$TMP/stopped.log"
printf 'PASS: stopped nginx is not started or reloaded\n'
MODE=success
cp "$ROOT/nginx.conf" "$NGINX_MAIN_CONF"
ASSUME_YES=0
sni_remove > "$TMP/cancel.log" <<'EOF'
7
n
EOF
cmp "$NGINX_MAIN_CONF" "$ROOT/nginx.conf"
sni_remove > "$TMP/select.log" <<'EOF'
7
y
EOF
if sni_map list "$NGINX_MAIN_CONF" | grep -q ' yahoo.com '; then exit 1; fi
sni_map list "$NGINX_MAIN_CONF" | grep -q ' www.yahoo.com '
printf 'PASS: numbered removal respects cancellation and removes only selected SNI\n'

printf 'events {}\nhttp {}\n' > "$TMP/missing"
if sni_map add "$TMP/missing" new.example.com 10004 > "$TMP/out" 2>&1; then exit 1; fi
printf 'stream {\nmap $ssl_preread_server_name $backend_name {\ninclude other.conf;\n}\n}\n' > "$TMP/include"
if sni_map list "$TMP/include" > "$TMP/out" 2>&1; then exit 1; fi
sni_map add "$ROOT/nginx.conf" new.example.com 10004 > "$TMP/one"
# Two copies imply two maps and must never be edited automatically.
cat "$ROOT/nginx.conf" "$ROOT/nginx.conf" > "$TMP/double"
if sni_map add "$TMP/double" new.example.com 10004 > "$TMP/out" 2>&1; then exit 1; fi
printf 'PASS: missing, included and ambiguous maps fail without edits\n'

cp "$NGINX_MAIN_CONF" "$TMP/locked-original"
mkdir "$NGINX_MAIN_CONF.sni-lock"
if sni_update add new.example.com 10004 > "$TMP/lock.log" 2>&1; then exit 1; fi
cmp "$NGINX_MAIN_CONF" "$TMP/locked-original"
[ -d "$NGINX_MAIN_CONF.sni-lock" ]
rmdir "$NGINX_MAIN_CONF.sni-lock"
printf 'PASS: concurrent-edit lock prevents changes and remains owned by its creator\n'

# The nginx submenu is gated on nginx presence; stub a binary for the
# navigation run so the SNI submenu is reachable.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\n' > "$TMP/bin/nginx"
chmod +x "$TMP/bin/nginx"
_out=$(printf '2\n5\n0\n0\n0\n' | PATH="$TMP/bin:$PATH" VPN_SETUP_LIB_ONLY=0 "$SH" "$ROOT/install.sh" --menu)
printf '%s' "$_out" | grep -q -- '--- SNI management ---'
printf '%s' "$_out" | grep -q 'Show all'
printf '%s' "$_out" | grep -q 'Add new'
printf '%s' "$_out" | grep -q 'Bye\.'
printf 'PASS: nginx SNI submenu opens and returns\n'
printf 'All SNI tests passed.\n'
