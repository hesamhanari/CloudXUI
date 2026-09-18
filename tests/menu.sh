#!/bin/sh
# Menu behavior tests. No root, no installs: navigation only, plus mocked actions.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' 0
export TEST_ROOT="$ROOT"
SH=${TEST_SHELL:-sh}

_out=$(printf '0\n' | "$SH" "$ROOT/install.sh" --menu 2>&1)
printf '%s' "$_out" | grep -q 'Full install (nginx'
printf '%s' "$_out" | grep -q 'm a d e   b y'
printf '%s' "$_out" | grep -q 'HESAMTHEDR\|H e s a m\|#   #'
printf '%s' "$_out" | grep -q 'Bye\.'
! printf '%s' "$_out" | grep -q '>>>'
printf 'PASS: menu renders the credit box once and exits on 0\n'

# The nginx and 3x-ui submenus sit behind install gates; stubbed binaries on
# PATH represent an already-installed stack for these navigation tests.
mkdir -p "$TMP/bin" && printf '#!/bin/sh\n' > "$TMP/bin/nginx" && chmod +x "$TMP/bin/nginx"
printf '#!/bin/sh\n' > "$TMP/bin/x-ui" && chmod +x "$TMP/bin/x-ui"
for _entry in '2:nginx' '3:Cloudflare Management' '4:3x-ui'; do
    _num=${_entry%%:*}
    _name=${_entry#*:}
    _out=$(printf '%s\n0\n0\n' "$_num" | PATH="$TMP/bin:$PATH" "$SH" "$ROOT/install.sh" --menu 2>&1)
    printf '%s' "$_out" | grep -q -- "--- $_name ---"
    printf 'PASS: %s submenu opens and returns\n' "$_name"
done

# Cloudflare Management nested submenus
_out=$(printf '3\n1\n0\n0\n0\n' | PATH="$TMP/bin:$PATH" "$SH" "$ROOT/install.sh" --menu 2>&1)
printf '%s' "$_out" | grep -q -- '--- certificates ---'
printf 'PASS: Certificate manager submenu opens from Cloudflare Management\n'

_out=$(printf '3\n2\n0\n0\n0\n' | PATH="$TMP/bin:$PATH" "$SH" "$ROOT/install.sh" --menu 2>&1)
printf '%s' "$_out" | grep -q -- '--- Domain Manager ---'
printf 'PASS: Domain Manager submenu opens from Cloudflare Management\n'

# The gate cases must see a machine without nginx/x-ui even when the host has
# them installed, so they run with a PATH that links everything except those
# two binaries out of the way.
mkdir -p "$TMP/minbin"
for _p in /usr/bin/* /bin/* /usr/sbin/*; do
    _b=${_p##*/}
    case $_b in nginx|x-ui) continue ;; esac
    [ -e "$TMP/minbin/$_b" ] || ln -s "$_p" "$TMP/minbin/$_b" 2>/dev/null || true
done

# Without nginx the gate must appear instead of the submenu.
_out=$(printf '2\nn\n0\n' | PATH="$TMP/minbin" "$SH" "$ROOT/install.sh" --menu 2>&1)
printf '%s' "$_out" | grep -q "nginx is not installed, please install it first to continue."
if printf '%s' "$_out" | grep -q -- '--- nginx ---'; then
    printf 'FAIL: nginx submenu opened without nginx installed\n'; exit 1
fi
printf 'PASS: nginx submenu shows the install gate when nginx is missing\n'

# Without 3x-ui the same gate flow applies to its submenu (option 4).
_out=$(printf '4\nn\n0\n' | PATH="$TMP/minbin" "$SH" "$ROOT/install.sh" --menu 2>&1)
printf '%s' "$_out" | grep -q "3x-ui is not installed, please install it first to continue."
if printf '%s' "$_out" | grep -q -- '--- 3x-ui ---'; then
    printf 'FAIL: 3x-ui submenu opened without 3x-ui installed\n'; exit 1
fi
printf 'PASS: 3x-ui submenu shows the install gate when 3x-ui is missing\n'

_out=$(printf '42\n0\n' | "$SH" "$ROOT/install.sh" --menu 2>&1)
printf '%s' "$_out" | grep -q 'unknown option: 42'
printf 'PASS: unknown menu option warns\n'

"$SH" "$ROOT/install.sh" --help | grep -q -- '--menu'
printf 'PASS: --help documents the menu flag\n'

_out=$("$SH" -c '
VPN_SETUP_LIB_ONLY=1
. "$TEST_ROOT/install.sh"
collect_inputs() { die "Summary must not collect inputs"; }
print_summary() { printf "SUMMARY_CALLED\n"; }
printf "7\n0\n" | menu_loop
' 2>&1)
printf '%s' "$_out" | grep -q 'SUMMARY_CALLED'
printf '%s' "$_out" | grep -q 'Bye\.'
printf 'PASS: summary action runs with the collected configuration\n'

for _mode in origin le; do
    _out=$(TEST_CERT_MODE="$_mode" "$SH" -c '
VPN_SETUP_LIB_ONLY=1
. "$TEST_ROOT/install.sh"
DOMAIN=dochsm.ir SUB=fer CAMO_SUB=suboff PANEL_PORT=2053 SUB_PORT=8443
PANEL_USER=admin PANEL_PASS=Test-only-password
CF_API_TOKEN=test-token-not-real-123456789 CERT_MODE=$TEST_CERT_MODE
printf "7\n\n\n0\n" | menu_loop
' 2>&1)
    printf '%s' "$_out" | grep -q 'root domain          dochsm.ir'
    printf '%s' "$_out" | grep -q "certificate mode     $_mode"
    if printf '%s' "$_out" | grep -Eq 'Cloudflare Zone ID|Test-only-password|test-token-not-real-123456789'; then
        printf 'FAIL: summary prompted for or exposed secrets\n'; exit 1
    fi
    printf 'PASS: summary option 7 shows correct %s wording\n' "$_mode"
done

_out=$(DOMAIN=example.com CERT_BASE="$TMP/certbase" "$SH" -c '
VPN_SETUP_LIB_ONLY=1
. "$TEST_ROOT/install.sh"
DOMAIN=example.com
CERT_BASE="'"$TMP"'/certbase"
CONFIG_LOADED=1
CERT_DIR="$CERT_BASE/$DOMAIN"
cert_status
' 2>&1)
printf '%s' "$_out" | grep -q 'no certificate files in'
printf 'PASS: certificate status reports missing files without root\n'

if printf '0\n' | "$SH" "$ROOT/install.sh" --menu --dry-run > "$TMP/conflict.log" 2>&1; then
    printf 'FAIL: --menu accepted --dry-run\n'; exit 1
fi
grep -q 'cannot be combined' "$TMP/conflict.log"
printf 'PASS: --menu rejects --dry-run (modifying actions must be unreachable)\n'

_out=$("$SH" -c '
VPN_SETUP_LIB_ONLY=1
. "$TEST_ROOT/install.sh"
CERT_MODE=origin
printf "example.com\ntest-token-not-real-123456789\n" | collect_cert_inputs
' 2>&1)
printf '%s' "$_out" | grep -q 'Root domain'
printf '%s' "$_out" | grep -q 'Cloudflare API token'
! printf '%s' "$_out" | grep -q 'panel listens'
! printf '%s' "$_out" | grep -q 'subscription service listens'
! printf '%s' "$_out" | grep -q 'Panel admin username'
! printf '%s' "$_out" | grep -q 'admin password'
! printf '%s' "$_out" | grep -q 'Sub-domain prefix'
printf 'PASS: certificate questions are domain + token only\n'

_out=$("$SH" -c '
VPN_SETUP_LIB_ONLY=1
. "$TEST_ROOT/install.sh"
export DOMAIN=example.com CERT_MODE=origin CF_API_TOKEN=test-token-not-real-123456789
printf "" | collect_cert_inputs
' 2>&1)
! printf '%s' "$_out" | grep -q 'Root domain:'
! printf '%s' "$_out" | grep -q 'Cloudflare API token:'
printf 'PASS: certificate questions skip values already known\n'

_out=$("$SH" -c '
VPN_SETUP_LIB_ONLY=1
. "$TEST_ROOT/install.sh"
DOMAIN=example.com CF_API_TOKEN=test-token-not-real-123456789 CERT_MODE=origin
CONFIG_LOADED=0
CERT_CONFIG_LOADED=0
CERT_CONFIG_MODE=""
ensure_cert_config < /dev/null
printf "SUB=%s SUB_FQDN=%s CERT_DIR=%s\n" "${SUB-UNSET}" "${SUB_FQDN-UNSET}" "$CERT_DIR"
' 2>&1)
printf '%s' "$_out" | grep -q 'SUB=UNSET SUB_FQDN= CERT_DIR=/root/cert/example.com'
printf 'PASS: ensure_cert_config derives only certificate context, no panel answers\n'

_out=$("$SH" -c '
VPN_SETUP_LIB_ONLY=1
. "$TEST_ROOT/install.sh"
DOMAIN=example.com CERT_MODE=le CF_API_TOKEN=test-token-not-real-123456789
CONFIG_LOADED=0
CERT_CONFIG_LOADED=0
CERT_CONFIG_MODE=origin
ACME_EMAIL=old@example.com
ensure_cert_config <<"ANSWERS"

le-admin@example.com
ANSWERS
printf "EMAIL=%s\n" "$ACME_EMAIL"
' 2>&1)
printf '%s' "$_out" | grep -q 'EMAIL=le-admin@example.com'
printf '%s' "$_out" | grep -q 'Cloudflare Zone ID'
printf 'PASS: switching cert mode re-asks the mode-specific answers\n'

_out=$(printf '8\n0\n' | "$SH" "$ROOT/install.sh" --menu 2>&1)
printf '%s' "$_out" | grep -q 'Answers cleared'
printf 'PASS: option 8 clears the answers\n'

_out=$("$SH" -c '
VPN_SETUP_LIB_ONLY=1
. "$TEST_ROOT/install.sh"
credit_banner
' 2>&1)
[ "$(printf '%s\n' "$_out" | wc -l)" = 11 ]
[ "$(printf '%s\n' "$_out" | awk '{print length($0)}' | sort -u | wc -l | tr -d " ")" = 1 ]
[ "$(printf '%s\n' "$_out" | grep -c '#' | tr -d " ")" = 5 ]
! printf '%s\n' "$_out" | grep -q 'Made By HesamTheDr'
printf '%s\n' "$_out" | sed -n 10p | grep -q 'with Power Of AI |$'
! grep -q '\[9A' "$ROOT/install.sh"          # no hardcoded redraw distance
grep -q '033\[%sA' "$ROOT/install.sh"        # redraw distance derived from line count
printf 'PASS: credit banner aligned, spacer rows, AI credit bottom-right\n'

mkdir -p "$TMP/bin"
printf '#!/bin/sh\n' > "$TMP/bin/nginx"
chmod +x "$TMP/bin/nginx"
# apt-get cannot be a shell function under dash (hyphen), so stub it on PATH.
cat > "$TMP/bin/apt-get" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod +x "$TMP/bin/apt-get"
_out=$(PATH="$TMP/bin:$PATH" "$SH" -c '
VPN_SETUP_LIB_ONLY=1
. "$TEST_ROOT/install.sh"
require_root() { :; }
confirm() { return 0; }
ensure_os() { OS_FAMILY=deb; }
rm() { printf "BUG_RM: %s\n" "$*"; }
nginx_uninstall
' 2>&1) || true
! printf '%s' "$_out" | grep -q 'BUG_RM'
printf '%s' "$_out" | grep -q 'Removing the nginx package failed'
printf 'PASS: failed nginx removal aborts and keeps repository files\n'

mkdir -p "$TMP/bin"
printf '#!/bin/sh\n' > "$TMP/bin/x-ui"
chmod +x "$TMP/bin/x-ui"
_out=$(PATH="$TMP/bin:$PATH" "$SH" -c '
VPN_SETUP_LIB_ONLY=1
. "$TEST_ROOT/install.sh"
xui_conf_exists() { return 0; }   # pretend /etc/x-ui exists
require_root() { :; }
confirm() { return 0; }
systemctl() { return 0; }
date() { printf 20260917; }
cp() { return 1; }                # backup fails
rm() { printf "BUG_RM: %s\n" "$*"; }
BACKUP_BASE="'"$TMP"'/bak"
xui_uninstall
' 2>&1) || true
! printf '%s' "$_out" | grep -q 'BUG_RM'
printf '%s' "$_out" | grep -q 'Backing up /etc/x-ui failed; nothing was removed'
printf 'PASS: 3x-ui uninstall aborts without deleting when the backup fails\n'

printf 'All menu tests passed.\n'
