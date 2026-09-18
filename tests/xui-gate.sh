#!/bin/sh
# Menu-level 3x-ui gate, driven through the real xui_menu function.
# The installer is mocked: the fake install drops an x-ui stub on PATH,
# which is what the gate's `have x-ui` check looks for.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
VPN_SETUP_LIB_ONLY=1
. "$ROOT/install.sh"
trap 'rm -rf "$TMP"' 0
require_root() { :; }
ensure_xui_config() { :; }
ensure_os() { :; }
install_base_tools() { :; }
stage_xui() {
    mkdir -p "$TMP/bin"
    printf '#!/bin/sh\n' > "$TMP/bin/x-ui"
    chmod +x "$TMP/bin/x-ui"
}
PATH="$TMP/bin:$PATH"
export PATH
xui_installed() { [ -x "$TMP/bin/x-ui" ]; }

# Case 1: 3x-ui missing, user approves -> install runs, then the menu appears.
_out=$(printf 'y\n0\n' | xui_menu 2>&1)
printf '%s' "$_out" | grep -q "3x-ui is not installed, please install it first to continue."
printf '%s' "$_out" | grep -q 'Install 3x-ui now?'
printf '%s' "$_out" | grep -q '3x-ui is ready; opening the 3x-ui menu.'
printf '%s' "$_out" | grep -q -- '--- 3x-ui ---'
printf 'PASS: gate shows the error, installs on approval, then shows the menu\n'

# Case 2: 3x-ui missing, user declines -> no menu at all.
rm -f "$TMP/bin/x-ui"
_out=$(printf 'n\n' | xui_menu 2>&1)
printf '%s' "$_out" | grep -q "3x-ui is not installed, please install it first to continue."
if printf '%s' "$_out" | grep -q -- '--- 3x-ui ---'; then
    printf 'FAIL: declining the offer still opened the 3x-ui menu\n'; exit 1
fi
printf '%s' "$_out" | grep -q 'Cancelled; nothing was changed.'
printf 'PASS: declining the install offer never shows the 3x-ui menu\n'

# Case 3: install runs but leaves nothing on PATH -> error again, no menu.
stage_xui() { :; }
_out=$(printf 'y\n0\n' | xui_menu 2>&1)
if printf '%s' "$_out" | grep -q -- '--- 3x-ui ---'; then
    printf 'FAIL: a failed install opened the 3x-ui menu\n'; exit 1
fi
_count=$(printf '%s' "$_out" | grep -c "3x-ui is not installed, please install it first to continue.")
[ "$_count" = 2 ]
printf 'PASS: a failed install reports the error again instead of the menu\n'

# Case 4: 3x-ui already installed -> straight into the menu, no gate.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\n' > "$TMP/bin/x-ui"
chmod +x "$TMP/bin/x-ui"
_out=$(printf '0\n' | xui_menu 2>&1)
if printf '%s' "$_out" | grep -q "please install it first"; then
    printf 'FAIL: gate ran although 3x-ui is installed\n'; exit 1
fi
printf '%s' "$_out" | grep -q -- '--- 3x-ui ---'
printf 'PASS: with 3x-ui present the menu opens without any gate\n'
# Case 5: a real installer failure (die inside stage_xui) must not terminate
# the menu; the parent reports the failure and returns to the main menu.
rm -f "$TMP/bin/x-ui"
stage_xui() { die 'Simulated fatal installer failure'; }
_out=$(printf 'y\n' | xui_menu 2>&1)
printf '%s' "$_out" | grep -q '3x-ui installation failed; returning to the main menu.'
if printf '%s' "$_out" | grep -q -- '--- 3x-ui ---'; then
    printf 'FAIL: a die inside the installer terminated the menu or opened it\n'; exit 1
fi
printf 'PASS: real install die failure returns to the menu without terminating\n'
printf 'All 3x-ui gate tests passed.\n'
