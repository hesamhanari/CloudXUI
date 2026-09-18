#!/bin/sh
# Menu-level nginx gate, driven through the real nginx_menu function.
# Installs are mocked: the fake installer just drops an nginx stub on PATH.
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
stage_nginx() {
    mkdir -p "$TMP/bin"
    printf '#!/bin/sh\n' > "$TMP/bin/nginx"
    chmod +x "$TMP/bin/nginx"
}
PATH="$TMP/bin:$PATH"
export PATH
have() {
    if [ "$1" = nginx ]; then [ -x "$TMP/bin/nginx" ]; else command -v "$1" >/dev/null 2>&1; fi
}

# Case 1: nginx missing, user approves -> install runs, then the menu appears.
_out=$(printf 'y\n0\n' | nginx_menu 2>&1)
printf '%s' "$_out" | grep -q "nginx is not installed, please install it first to continue."
printf '%s' "$_out" | grep -q 'Install nginx now?'
printf '%s' "$_out" | grep -q 'nginx is ready; opening the nginx menu.'
printf '%s' "$_out" | grep -q -- '--- nginx ---'
printf 'PASS: gate shows the error, installs on approval, then shows the menu\n'

# Case 2: nginx missing, user declines -> no menu at all.
rm -f "$TMP/bin/nginx"
_out=$(printf 'n\n' | nginx_menu 2>&1)
printf '%s' "$_out" | grep -q "nginx is not installed, please install it first to continue."
if printf '%s' "$_out" | grep -q -- '--- nginx ---'; then
    printf 'FAIL: declining the offer still opened the nginx menu\n'; exit 1
fi
printf '%s' "$_out" | grep -q 'Cancelled; nothing was changed.'
printf 'PASS: declining the install offer never shows the nginx menu\n'

# Case 3: install runs but the binary is still missing -> error again, no menu.
stage_nginx() { :; }   # this pass installs nothing
_out=$(printf 'y\n0\n' | nginx_menu 2>&1)
if printf '%s' "$_out" | grep -q -- '--- nginx ---'; then
    printf 'FAIL: a failed install opened the nginx menu\n'; exit 1
fi
_count=$(printf '%s' "$_out" | grep -c "nginx is not installed, please install it first to continue.")
[ "$_count" = 2 ]
printf 'PASS: a failed install reports the error again instead of the menu\n'

# Case 4: nginx already installed -> straight into the menu, no gate.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\n' > "$TMP/bin/nginx"
chmod +x "$TMP/bin/nginx"
_out=$(printf '0\n' | nginx_menu 2>&1)
if printf '%s' "$_out" | grep -q "please install it first"; then
    printf 'FAIL: gate ran although nginx is installed\n'; exit 1
fi
printf '%s' "$_out" | grep -q -- '--- nginx ---'
printf 'PASS: with nginx present the menu opens without any gate\n'

# Case 5: a real installer failure (die inside stage_nginx) must not terminate
# the menu; the parent reports the failure and returns to the main menu.
rm -f "$TMP/bin/nginx"
stage_nginx() { die 'Simulated fatal installer failure'; }
_out=$(printf 'y\n' | nginx_menu 2>&1)
printf '%s' "$_out" | grep -q 'nginx installation failed; returning to the main menu.'
if printf '%s' "$_out" | grep -q -- '--- nginx ---'; then
    printf 'FAIL: a die inside the installer terminated the menu or opened it\n'; exit 1
fi
printf 'PASS: real install die failure returns to the menu without terminating\n'

# Case 6: the same gate, reached through the real script's main menu.
# Remove earlier stubs so the child really sees a machine without nginx.
rm -f "$TMP/bin/nginx"
# Case 5 sets up its own stubs; remove them so case 6 sees no nginx.
rm -f "$TMP/bin/nginx"
VPN_SETUP_LIB_ONLY=0 "$SH" "$ROOT/install.sh" --menu > "$TMP/real" 2>&1 <<EOF
2
n
0
EOF
grep -q "nginx is not installed, please install it first to continue." "$TMP/real"
if grep -q -- '--- nginx ---' "$TMP/real"; then
    printf 'FAIL: real-script run showed the nginx menu after declining\n'; exit 1
fi
grep -q 'Cancelled; nothing was changed.' "$TMP/real" \
    || { printf -- '--- actual output ---\n'; cat "$TMP/real"; exit 1; }
printf 'PASS: the main menu applies the same gate before showing the nginx submenu\n'
printf 'All nginx gate tests passed.\n'
