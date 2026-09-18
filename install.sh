#!/bin/sh
# =============================================================================
#  CloudXUI: nginx (mainline) + 3x-ui + Cloudflare wildcard TLS & DNS Suite
# =============================================================================
#
#  What it does on a fresh VPS:
#
#    1. Installs nginx from the official nginx.org mainline repository, which
#       currently ships 1.31.x (the newest release, as requested).
#    2. Installs the latest 3x-ui panel, non-interactively, and applies the
#       panel port, admin credentials, base path and the subscription settings.
#    3. Issues a Cloudflare Origin CA certificate (5475 days), or optionally
#       a Let's Encrypt wildcard via acme.sh, into /root/cert/<domain>/ as
#       fullchain.pem + privkey.pem, exactly where proxy.conf expects it.
#    4. Renders nginx.conf and proxy.conf from the template files that sit next
#       to this script; when those files are absent, built-in copies inside
#       this script are used instead — so uploading install.sh alone is enough.
#       They are then deployed to /etc/nginx/nginx.conf and
#       /etc/nginx/conf.d/proxy.conf with the placeholders filled in.
#
#  Placeholders understood in the templates:
#
#    nginx.conf : DOMAIN, SUB.DOMAIN
#    proxy.conf : DOMAIN, SUB.DOMAIN, SUBoff.DOMAIN, PANELPORT,
#                 and the hardcoded subscription upstream 127.0.0.1:8443
#                 (there is no literal SUBPORT token in the file, so the
#                  subscription port is patched through that upstream).
#
#  Everything else (REALITY SNI list, web root, ports ...) is left untouched.
#
#  Usage:
#     ./install.sh                     interactive, asks everything
#     ./install.sh --dry-run           only render the configs, change nothing
#     ./install.sh --configs-only      only re-render and redeploy the configs
#     ./install.sh --yes               do not ask for confirmations
#     ./install.sh --non-interactive   take every answer from environment vars
#     ./install.sh --help
#
#  Every question can be answered in advance through an environment variable
#  (see README.md), which is what --non-interactive relies on.
#
#  Written in POSIX sh on purpose: it runs under dash, bash and busybox ash.
# =============================================================================

set -eu

SCRIPT_VERSION='1.5.1'

# --- tunables ----------------------------------------------------------------
NGINX_MIN_MAJOR=1
NGINX_MIN_MINOR=31

# Panel base path and subscription path are coupled to the nginx templates:
# proxy.conf routes "location ^~ /xuipanel/" and "location /s/".
PANEL_PATH=${PANEL_PATH:-/xuipanel/}
SUB_PATH=${SUB_PATH:-/s/}

XUI_INSTALL_URL=${XUI_INSTALL_URL:-https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh}
ACME_INSTALL_URL=${ACME_INSTALL_URL:-https://get.acme.sh}
ACME_GIT_URL=${ACME_GIT_URL:-https://github.com/acmesh-official/acme.sh.git}
ACME_GIT_MIRROR=${ACME_GIT_MIRROR:-https://gitee.com/neilpang/acme.sh.git}
ACME_DNSSLEEP=${ACME_DNSSLEEP:-}
XUI_DB_TYPE=${XUI_DB_TYPE:-sqlite}
XUI_ENABLE_FAIL2BAN=${XUI_ENABLE_FAIL2BAN:-true}
ORIGIN_VALIDITY=5475

# Real system paths. They can be overridden, which is handy for a dry run on a
# machine that is not the target VPS.
NGINX_MAIN_CONF=${NGINX_MAIN_CONF:-/etc/nginx/nginx.conf}
NGINX_CONF_D=${NGINX_CONF_D:-/etc/nginx/conf.d}
CERT_BASE=${CERT_BASE:-/root/cert}
WEB_ROOT=${WEB_ROOT:-/var/www/goldcalc}
BACKUP_BASE=${BACKUP_BASE:-/root}
ACME_HOME=${ACME_HOME:-/root/.acme.sh}

# --- runtime state (filled in by parse_args / collect) -----------------------
ASSUME_YES=${ASSUME_YES:-0}
DRY_RUN=${DRY_RUN:-0}
NONINTERACTIVE=${NONINTERACTIVE:-0}
CONFIGS_ONLY=${CONFIGS_ONLY:-0}
MENU=${MENU:-0}
CERT_MODE=${CERT_MODE:-}
RENDER_OUT=${RENDER_OUT:-}
CONFIG_DIR=${CONFIG_DIR:-}
NGINX_TEMPLATE=${NGINX_TEMPLATE:-}
PROXY_TEMPLATE=${PROXY_TEMPLATE:-}
NGINX_CONF_EXPLICIT=0
PROXY_CONF_EXPLICIT=0
MISSING_ENV=''
GENERATED_PASSWORD=0
OS_ID=''
OS_CODENAME=''
OS_FAMILY=''
STREAM_LOAD_LINE=''
BACKUP_DIR=''
PROXY_CONF_EXISTED=0
PASS_COUNT=0
FAIL_COUNT=0
# Cloudflare API scratch files, created with mktemp on first use (see cf_api).
_CF_OUT=''
_CF_HDR=''

# --- output helpers ----------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$(printf '\033[31m')
    C_GRN=$(printf '\033[32m')
    C_YLW=$(printf '\033[33m')
    C_CYN=$(printf '\033[36m')
    C_BLD=$(printf '\033[1m')
    C_RST=$(printf '\033[0m')
else
    C_RED=''; C_GRN=''; C_YLW=''; C_CYN=''; C_BLD=''; C_RST=''
fi

say()  { printf '%s\n' "$*"; }
hdr()  { printf '\n%s==> %s%s\n' "$C_BLD" "$*" "$C_RST"; }
info() { printf '%s[i]%s %s\n' "$C_CYN" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YLW" "$C_RST" "$*"; }
err()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# Reads a variable's value without eval'ing user data: printenv is used so that
# shell metacharacters inside answers stay inert.
read_env() { printenv "$1" 2>/dev/null || true; }

# Restore the terminal if the user interrupts a hidden password prompt.
restore_tty() { if [ -t 0 ]; then stty echo 2>/dev/null || true; fi; }
DEPLOY_ACTIVE=0
MAIN_CONF_EXISTED=0
cleanup() {
    restore_tty
    [ -z "$_CF_OUT" ] || rm -f "$_CF_OUT"
    [ -z "$_CF_HDR" ] || rm -f "$_CF_HDR"
    if [ "$DEPLOY_ACTIVE" = 1 ]; then
        DEPLOY_ACTIVE=0
        restore_backup || err "Rollback failed; restore files from $BACKUP_DIR manually."
    fi
}
trap 'cleanup' 0
trap 'exit 130' INT
trap 'exit 143' TERM

confirm() {   # $1 = question, default answer is yes
    if [ "$ASSUME_YES" = 1 ]; then
        return 0
    fi
    printf '%s [Y/n]: ' "$1"
    _confirm_reply=''
    if ! IFS= read -r _confirm_reply; then
        # No terminal to answer on: never assume a destructive "yes".
        die 'No answer available on stdin. Use --yes for unattended runs.'
    fi
    case ${_confirm_reply:-y} in
        [Yy]*) return 0 ;;
        *) return 1 ;;
    esac
}

# --- validators --------------------------------------------------------------
v_domain() {
    case $1 in
        *[!a-zA-Z0-9.-]*|.*|*.)
            err 'Only letters, digits, dots and inner hyphens are allowed (e.g. example.com).'
            return 1 ;;
    esac
    case $1 in
        *.*) : ;;
        *) err 'The domain needs at least one dot (e.g. example.com).'; return 1 ;;
    esac
    case $1 in
        *..*) err 'The domain must not contain two dots in a row.'; return 1 ;;
    esac
    if [ "${#1}" -gt 253 ]; then
        err 'The domain is too long.'
        return 1
    fi
    _vd_rest=$1
    while :; do
        _vd_label=${_vd_rest%%.*}
        v_label "$_vd_label" || return 1
        case $_vd_rest in
            *.*) _vd_rest=${_vd_rest#*.} ;;
            *) break ;;
        esac
    done
    return 0
}

v_label() {   # a single DNS label, used for the sub-domain prefixes
    case $1 in
        ''|-*|*-|*[!a-zA-Z0-9-]*)
            err 'Only letters, digits and inner hyphens are allowed (e.g. sub).'
            return 1 ;;
    esac
    if [ "${#1}" -gt 63 ]; then
        err 'A DNS label may not be longer than 63 characters.'
        return 1
    fi
    return 0
}

v_port() {
    case $1 in
        ''|*[!0-9]*) err 'The port must be a number.'; return 1 ;;
    esac
    case $1 in
        0*) err 'Use a port without leading zeroes.'; return 1 ;;
    esac
    if [ "${#1}" -gt 5 ]; then
        err 'The port must be between 1 and 65535.'
        return 1
    fi
    if [ "$1" -lt 1 ] || [ "$1" -gt 65535 ]; then
        err 'The port must be between 1 and 65535.'
        return 1
    fi
    return 0
}

v_ipv4() {   # four numeric octets, each 0-255
    case ${1:-} in
        ''|*[!0-9.]*)
            err 'Enter an IPv4 address like 203.0.113.10.'
            return 1 ;;
    esac
    _vi_ok=$(printf '%s' "$1" | awk -F. '
        { if (NF != 4) { print "bad"; exit }
          for (i = 1; i <= 4; i++) {
              if ($i == "" || $i + 0 > 255) { print "bad"; exit }
          }
          print "ok" }')
    if [ "$_vi_ok" != ok ]; then
        err 'Enter an IPv4 address like 203.0.113.10 (four numbers, each 0-255).'
        return 1
    fi
    return 0
}

v_username() {
    case $1 in
        *[!a-zA-Z0-9_.@-]*) err 'Allowed: letters, digits, dot, underscore, dash, at.'; return 1 ;;
    esac
    if [ "${#1}" -lt 3 ] || [ "${#1}" -gt 32 ]; then
        err 'The username must be 3 to 32 characters long.'
        return 1
    fi
    return 0
}

v_password() {
    case $1 in
        *[![:print:]]*) err 'The password must not contain control characters.'; return 1 ;;
    esac
    if [ "${#1}" -lt 8 ]; then
        err 'The password must be at least 8 characters long.'
        return 1
    fi
    return 0
}

v_email() {
    case $1 in
        *@*.*) return 0 ;;
        *) err 'That does not look like an email address.'; return 1 ;;
    esac
}

v_cert_mode() {
    case $1 in origin|le) return 0 ;; esac
    err 'Certificate mode must be origin or le.'
    return 1
}

v_token() {
    case $1 in *[!a-zA-Z0-9_-]*) err 'Use an API token containing only letters, digits, underscore and hyphen.'; return 1 ;; esac
    if [ "${#1}" -lt 20 ]; then
        err 'That does not look like a Cloudflare API token (too short).'
        return 1
    fi
    return 0
}

# --- input collection --------------------------------------------------------
# collect VAR "question" "default" validator [ENV_NAME] [optional]
collect() {
    _co_var=$1
    _co_ask=$2
    _co_def=${3:-}
    _co_val=${4:-}
    _co_env=${5:-$1}
    _co_opt=${6:-}

    # Already answered in this menu session: keep it. (Option 9 clears answers.)
    # The value is validated again, since it may come from the environment.
    eval "_co_prev=\${$_co_var:-}"
    if [ -n "$_co_prev" ]; then
        if [ -n "$_co_val" ] && ! "$_co_val" "$_co_prev"; then
            die "The value of $_co_var is not valid."
        fi
        info "$_co_var already set, keeping $_co_prev"
        return 0
    fi

    _co_cur=$(read_env "$_co_env")
    if [ -n "$_co_cur" ]; then
        if [ -n "$_co_val" ] && ! "$_co_val" "$_co_cur"; then
            die "The value of $_co_env is not valid."
        fi
        eval "$_co_var=\$_co_cur"
        info "$_co_var = $_co_cur (from \$$_co_env)"
        return 0
    fi

    if [ "$NONINTERACTIVE" = 1 ]; then
        # Still assign, so the variable is defined even if the value is missing
        # and the script can report everything that is absent at once.
        eval "$_co_var=''"
        if [ "$_co_opt" != 'optional' ]; then
            MISSING_ENV="$MISSING_ENV $_co_env"
        fi
        return 0
    fi

    while :; do
        if [ -n "$_co_def" ]; then
            printf '%s [%s]: ' "$_co_ask" "$_co_def"
        else
            printf '%s: ' "$_co_ask"
        fi
        _co_cur=''
        if ! IFS= read -r _co_cur; then
            say ''
            die "Input ended before $_co_env was answered. Pass it as an environment variable or use --non-interactive."
        fi
        if [ -z "$_co_cur" ]; then
            _co_cur=$_co_def
        fi
        if [ -z "$_co_cur" ] && [ "$_co_opt" = 'optional' ]; then
            eval "$_co_var=''"
            return 0
        fi
        if [ -z "$_co_cur" ]; then
            err 'A value is required.'
            continue
        fi
        if [ -n "$_co_val" ] && ! "$_co_val" "$_co_cur"; then
            continue
        fi
        break
    done
    eval "$_co_var=\$_co_cur"
}

# collect_secret VAR "question" validator [ENV_NAME]
collect_secret() {
    _cs_var=$1
    _cs_ask=$2
    _cs_val=${3:-}
    _cs_env=${4:-$1}

    eval "_cs_prev=\${$_cs_var:-}"
    if [ -n "$_cs_prev" ]; then
        if [ -n "$_cs_val" ] && ! "$_cs_val" "$_cs_prev"; then
            die "The value of $_cs_var is not valid."
        fi
        info "$_cs_var already set (hidden), keeping it"
        return 0
    fi

    _cs_cur=$(read_env "$_cs_env")
    if [ -n "$_cs_cur" ]; then
        if [ -n "$_cs_val" ] && ! "$_cs_val" "$_cs_cur"; then
            die "The value of $_cs_env is not valid."
        fi
        eval "$_cs_var=\$_cs_cur"
        info "$_cs_var set from \$$_cs_env (hidden)"
        return 0
    fi

    if [ "$NONINTERACTIVE" = 1 ]; then
        eval "$_cs_var=''"
        MISSING_ENV="$MISSING_ENV $_cs_env"
        return 0
    fi

    while :; do
        printf '%s: ' "$_cs_ask"
        if [ -t 0 ]; then
            stty -echo 2>/dev/null || true
        fi
        _cs_cur=''
        if ! IFS= read -r _cs_cur; then
            restore_tty
            say ''
            die "Input ended before $_cs_env was answered. Pass it as an environment variable or use --non-interactive."
        fi
        if [ -t 0 ]; then
            stty echo 2>/dev/null || true
            say ''
        fi
        if [ -z "$_cs_cur" ]; then
            err 'A value is required.'
            continue
        fi
        if [ -n "$_cs_val" ] && ! "$_cs_val" "$_cs_cur"; then
            continue
        fi
        break
    done
    eval "$_cs_var=\$_cs_cur"
}

gen_password() {
    _gp=''
    if have openssl; then
        _gp=$(openssl rand -base64 24 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c1-20) || _gp=''
    fi
    if [ -z "$_gp" ]; then
        _gp=$(dd if=/dev/urandom bs=256 count=1 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c1-20) || _gp=''
    fi
    printf '%s' "$_gp"
}

collect_password() {
    if [ -n "${PANEL_PASS:-}" ]; then
        v_password "$PANEL_PASS" || die 'PANEL_PASS is not valid.'
        info 'PANEL_PASS already set, keeping it'
        return 0
    fi
    _cp_env=$(read_env PANEL_PASS)
    if [ -n "$_cp_env" ]; then
        v_password "$_cp_env" || die 'The value of $PANEL_PASS is not valid.'
        PANEL_PASS=$_cp_env
        info 'PANEL_PASS set from $PANEL_PASS (hidden)'
        return 0
    fi

    if [ "$NONINTERACTIVE" = 1 ]; then
        PANEL_PASS=''
        MISSING_ENV="$MISSING_ENV PANEL_PASS"
        return 0
    fi

    while :; do
        printf 'Panel admin password (empty = generate a strong one): '
        if [ -t 0 ]; then
            stty -echo 2>/dev/null || true
        fi
        _cp_cur=''
        if ! IFS= read -r _cp_cur; then
            restore_tty
            say ''
            die 'Input ended before the panel password was answered. Pass PANEL_PASS or use --non-interactive.'
        fi
        if [ -t 0 ]; then
            stty echo 2>/dev/null || true
            say ''
        fi
        if [ -z "$_cp_cur" ]; then
            _cp_cur=$(gen_password)
            if [ -z "$_cp_cur" ]; then
                err 'Could not generate a password, please type one.'
                continue
            fi
            GENERATED_PASSWORD=1
            ok "Generated password: $_cp_cur"
            say '    (write it down now, it is shown again in the final summary)'
            break
        fi
        if v_password "$_cp_cur"; then
            break
        fi
    done
    PANEL_PASS=$_cp_cur
}

collect_inputs() {
    collect_action_inputs full
}

collect_action_inputs() {   # full|render|xui|verify
    _input_action=$1
    MISSING_ENV=''
    hdr 'Configuration'
    collect DOMAIN 'Root domain, the one that owns the certificate (e.g. example.com)' '' v_domain
    DOMAIN=$(printf '%s' "${DOMAIN:-}" | tr '[:upper:]' '[:lower:]')
    collect SUB 'Sub-domain prefix for the panel, subscription and inbounds (e.g. sub)' 'sub' v_label
    SUB=$(printf '%s' "$SUB" | tr '[:upper:]' '[:lower:]')
    case $_input_action in
        full|render)
            collect CAMO_SUB 'Sub-domain prefix for the camouflage site (SUBoff in proxy.conf)' 'suboff' v_label
            CAMO_SUB=$(printf '%s' "$CAMO_SUB" | tr '[:upper:]' '[:lower:]') ;;
    esac
    case $_input_action in
        full|xui) _panel_default=$(random_port) ;;
        *) _panel_default=''; info 'Enter the existing upstream ports; this action does not configure 3x-ui.' ;;
    esac
    collect PANEL_PORT 'Local port the 3x-ui panel listens on (hidden behind nginx)' "$_panel_default" v_port
    collect SUB_PORT 'Local port the 3x-ui subscription service listens on' '8443' v_port
    case $_input_action in
        full|xui)
            say ''
            info 'These credentials are for the 3x-ui login page.'
            collect PANEL_USER 'Panel admin username' 'admin' v_username
            collect_password ;;
    esac
    if [ "$_input_action" = full ]; then
        [ "$XUI_DB_TYPE" = sqlite ] || die 'Only the SQLite 3x-ui database is supported.'
        collect CERT_MODE 'Certificate type: origin = 15-year Cloudflare Origin CA, le = Let'\''s Encrypt' 'origin' v_cert_mode
        collect_cert_answers
    fi
    [ -z "$MISSING_ENV" ] || die "--non-interactive needs these environment variables:$MISSING_ENV"
    derive_names
}

ensure_render_config() {
    collect_action_inputs render
    validate_combination
}

ensure_xui_config() {
    collect_action_inputs xui
    [ "$XUI_DB_TYPE" = sqlite ] || die 'Only the SQLite 3x-ui database is supported.'
    validate_route_paths
    v_domain "$SUB_FQDN" || die 'The panel hostname is invalid.'
    validate_ports
}

ensure_verify_config() {
    collect_action_inputs verify
    v_domain "$SUB_FQDN" || die 'The panel hostname is invalid.'
    # Inspect broken configurations too; conflicts are diagnostic, not fatal.
    if [ "$PANEL_PORT" = "$SUB_PORT" ]; then
        warn 'Panel and subscription ports are identical; check the installed settings.'
    fi
    for _port in "$PANEL_PORT" "$SUB_PORT"; do
        case $_port in
            22|80|443|4443|10000|10001|10002|10003|20000|30000|40000)
                warn "Port $_port conflicts with SSH, nginx or a configured inbound." ;;
        esac
    done
}

certificate_mode_on_disk() {
    if [ -f "$CERT_DIR/origin-ca.json" ]; then
        printf '%s' origin
    elif [ -f "$ACME_HOME/${DOMAIN}_ecc/${DOMAIN}.conf" ] || [ -f "$ACME_HOME/$DOMAIN/$DOMAIN.conf" ]; then
        printf '%s' le
    else
        printf '%s' unknown
    fi
}

# The certificate questions, shared by the full configuration and the
# certificate menu (which must not ask about panel ports or credentials).
collect_cert_answers() {
    say ''
    info 'Create a Cloudflare API token limited to your zone.'
    if [ "$CERT_MODE" = origin ]; then
        info 'Permissions: Zone -> SSL and Certificates -> Edit (for Origin CA), plus Zone -> DNS -> Edit and Zone -> Zone -> Read (for DNS A records).'
        warn 'Origin CA requires proxied (orange-cloud) DNS and Full (strict) TLS.'
        warn 'Direct clients do not trust Origin CA. Track expiry yourself; it is not permanent.'
    else
        info 'Permissions: Zone -> Zone -> Read, and Zone -> DNS -> Edit.'
    fi
    collect_secret CF_API_TOKEN 'Cloudflare API token' v_token

    CF_ZONE_ID=${CF_ZONE_ID:-}
    if [ "$CERT_MODE" = 'le' ]; then
        collect CF_ZONE_ID 'Cloudflare Zone ID (optional)' '' '' CF_ZONE_ID optional
        collect ACME_EMAIL 'Contact email for the Let'\''s Encrypt account' "admin@$DOMAIN" v_email
    else
        ACME_EMAIL=$(read_env ACME_EMAIL)
        [ -n "$ACME_EMAIL" ] || ACME_EMAIL="admin@$DOMAIN"
    fi

    if [ -n "$MISSING_ENV" ]; then
        die "--non-interactive needs these environment variables:$MISSING_ENV"
    fi
}

# Certificate-only configuration: domain and certificate answers, nothing else.
collect_cert_inputs() {
    hdr 'Certificate configuration'
    collect DOMAIN 'Root domain, the one that owns the certificate (e.g. example.com)' '' v_domain
    DOMAIN=$(printf '%s' "$DOMAIN" | tr 'A-Z' 'a-z')
    DOMAIN=${DOMAIN%.}
    collect_cert_answers
    derive_names
}

# Derived names used by the templates. Only meaningful after the full
# questions; certificate-only actions leave SUB/CAMO_SUB empty on purpose so
# they cannot silently become answers to a later full configuration.
derive_names() {
    if [ -n "${SUB:-}" ]; then SUB_FQDN="$SUB.$DOMAIN"; else SUB_FQDN=''; fi
    if [ -n "${CAMO_SUB:-}" ]; then CAMO_FQDN="$CAMO_SUB.$DOMAIN"; else CAMO_FQDN=''; fi
    CERT_DIR="$CERT_BASE/$DOMAIN"
}

random_port() {
    while :; do
        if have shuf; then
            _rp=$(shuf -i 20000-59000 -n 1)
        elif have awk; then
            _rp=$(awk 'BEGIN { srand(); printf "%d\n", 20000 + rand() * 39000 }')
        else
            _rp=2053
        fi
        case $_rp in
            20000|30000|40000) continue ;;   # used by the configured inbounds
            *) printf '%s\n' "$_rp"; return 0 ;;
        esac
    done
}

validate_route_paths() {
    if [ "$PANEL_PATH" != /xuipanel/ ] || [ "$SUB_PATH" != /s/ ]; then
        die 'The supplied templates require PANEL_PATH=/xuipanel/ and SUB_PATH=/s/.'
    fi
}

# A DNS label used twice would make nginx reject the map block, so this is fatal.
validate_combination() {
    hdr 'Checking the answers'
    validate_route_paths
    v_domain "$SUB_FQDN" || die 'The panel hostname is invalid.'
    v_domain "$CAMO_FQDN" || die 'The camouflage hostname is invalid.'
    if [ "$SUB" = 'www' ] || [ "$CAMO_SUB" = 'www' ]; then
        die 'The sub-domain prefix "www" collides with the www.DOMAIN entry in nginx.conf. Pick another one.'
    fi
    if [ "$SUB" = "$CAMO_SUB" ]; then
        die 'The sub-domain and the camouflage prefix must differ, otherwise nginx.conf would contain a duplicate map entry.'
    fi
    validate_ports
}

validate_ports() {
    if [ "$PANEL_PORT" = "$SUB_PORT" ]; then
        die 'The panel port and the subscription port must differ.'
    fi
    for _port in "$PANEL_PORT" "$SUB_PORT"; do
        case $_port in
            22|80|443|4443|10000|10001|10002|10003|20000|30000|40000)
                die "Port $_port is reserved for SSH, nginx or a configured inbound. Pick another one." ;;
        esac
    done
    ok 'Domain, sub-domains and ports are consistent.'

    warn_if_port_busy "$PANEL_PORT" 'panel'
    warn_if_port_busy "$SUB_PORT" 'subscription'
}

warn_if_port_busy() {
    have ss || return 0
    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"; then
        warn "Port $1 (the $2 port) is already in use on this machine - make sure that is what you want."
    fi
    return 0
}

print_summary() {
    hdr 'Current session configuration (not a scan of installed services)'
    say "  root domain          ${DOMAIN:-not set}"
    say "  panel prefix         ${SUB:-not set}"
    say "  camouflage prefix    ${CAMO_SUB:-not set}"
    say "  panel port           ${PANEL_PORT:-not set}"
    say "  subscription port    ${SUB_PORT:-not set}"
    say "  panel login          ${PANEL_USER:-not set}"
    say "  certificate mode     ${CERT_MODE:-not set}"
    say "  nginx.conf           $NGINX_MAIN_CONF"
    say "  proxy.conf           $NGINX_CONF_D/proxy.conf"
    info 'Unset values are requested only when an action needs them. Passwords and tokens are not displayed.'
}

print_render_plan() {
    hdr 'Configuration deployment (existing services and certificates)'
    say "  root domain          $DOMAIN"
    say "  panel                $SUB_FQDN -> 127.0.0.1:$PANEL_PORT"
    say "  subscription         $SUB_FQDN -> 127.0.0.1:$SUB_PORT"
    say "  camouflage           $CAMO_FQDN"
    say "  certificate files    $CERT_DIR"
    say "  nginx.conf           $NGINX_MAIN_CONF"
}

print_plan() {
    hdr 'Ready to install'
    say "  root domain          $DOMAIN"
    say "  panel                https://$SUB_FQDN$PANEL_PATH"
    say "  panel upstream       127.0.0.1:$PANEL_PORT (bound to localhost)"
    say "  panel login          $PANEL_USER"
    say "  subscription         https://$SUB_FQDN$SUB_PATH<subId>  ->  127.0.0.1:$SUB_PORT"
    say "  camouflage site      https://$CAMO_FQDN"
    if [ "$CERT_MODE" = origin ]; then
        say '  certificate mode     origin (5475 days, Cloudflare-proxied HTTPS only)'
    else
        say '  certificate mode     le (Let'\''s Encrypt wildcard, auto-renewed)'
    fi
    say "  dns a records        ${SUB_FQDN} and ${CAMO_FQDN} (proxied, created automatically)"
    say "  certificate          $CERT_DIR/fullchain.pem + privkey.pem (wildcard)"
    say "  nginx.conf           $NGINX_MAIN_CONF"
    say "  proxy.conf           $NGINX_CONF_D/proxy.conf"
    say ''
}

# --- OS / packages -----------------------------------------------------------
detect_os() {
    if [ ! -r /etc/os-release ]; then
        die '/etc/os-release is missing: this script targets Debian, Ubuntu or a RHEL clone.'
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID=${ID:-}
    OS_CODENAME=${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}
    case "$OS_ID" in
        debian|ubuntu|raspbian|linuxmint|pop|neon|elementary|kali)
            OS_FAMILY=deb ;;
        rhel|centos|rocky|almalinux|fedora|ol|virtuozzo)
            OS_FAMILY=rpm ;;
        *)
            case ${ID_LIKE:-} in
                *debian*|*ubuntu*) OS_FAMILY=deb ;;
                *rhel*|*fedora*) OS_FAMILY=rpm ;;
                *) die "Unsupported distribution: ${PRETTY_NAME:-$OS_ID}. Use Debian, Ubuntu or an Enterprise Linux clone." ;;
            esac ;;
    esac
}

pkg_install() {
    if [ $# -eq 0 ]; then
        return 0
    fi
    case ${OS_FAMILY:-} in
        deb) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@" ;;
        rpm) dnf install -y -q "$@" ;;
        *) return 1 ;;
    esac
}

check_connectivity() {
    _net_bad=0
    _cert_endpoint=https://api.cloudflare.com/client/v4/ips
    if [ "$CERT_MODE" = le ]; then
        _cert_endpoint=https://acme-v02.api.letsencrypt.org/directory
    fi
    # Plain GET: HEAD is rejected (405) by some endpoints, and the Cloudflare
    # API base URL itself answers 400 even to GET.
    for _url in https://nginx.org/packages/ https://github.com https://raw.githubusercontent.com "$_cert_endpoint"; do
        if curl -fsS -m 15 -o /dev/null "$_url" 2>/dev/null; then
            ok "reachable: $_url"
        else
            warn "not reachable: $_url"
            _net_bad=1
        fi
    done
    if [ "$_net_bad" = 1 ]; then
        warn 'Some endpoints are unreachable. The 3x-ui installer downloads from GitHub'
        warn 'and the selected certificate provider must be reachable.'
        confirm 'Continue anyway?' || die 'Aborted before changing anything.'
    fi
}

check_cloudflare_token() {
    if [ "$CERT_MODE" = origin ]; then
        info 'Origin CA token permissions will be checked by the certificate creation endpoint.'
        return 0
    fi
    hdr 'Checking the Cloudflare API token'
    if [ -n "$CF_ZONE_ID" ]; then
        _cf_url="https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID"
    else
        _cf_url="https://api.cloudflare.com/client/v4/zones?name=$DOMAIN"
    fi
    _cf_c_hdr=$(mktemp) || _cf_c_hdr=''
    if [ -n "$_cf_c_hdr" ]; then
        chmod 600 "$_cf_c_hdr" 2>/dev/null || true
        printf 'Authorization: Bearer %s\n' "$CF_API_TOKEN" > "$_cf_c_hdr"
        _cf_body=$(curl -sS -m 20 -H "@$_cf_c_hdr" "$_cf_url" 2>/dev/null) || _cf_body=''
        rm -f "$_cf_c_hdr"
    else
        _cf_body=$(curl -sS -m 20 -H "Authorization: Bearer $CF_API_TOKEN" "$_cf_url" 2>/dev/null) || _cf_body=''
    fi
    case $_cf_body in
        *'"success":true'*)
            ok 'The token was accepted by Cloudflare.'
            if [ -z "$CF_ZONE_ID" ] && ! printf '%s' "$_cf_body" | grep -q "\"name\":\"$DOMAIN\""; then
                warn "The token works but did not return the zone $DOMAIN."
                warn 'If issuance fails later, set CF_ZONE_ID (and make sure the token is'
                warn 'scoped to this account and zone) and run the script again.'
            fi
            ;;
        *'"success":false'*)
            _cf_msg=$(printf '%s' "$_cf_body" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p')
            warn "Cloudflare rejected the token: ${_cf_msg:-unknown error}"
            warn 'DNS-01 issuance will almost certainly fail with this token.'
            confirm 'Continue anyway?' || die 'Aborted before changing anything.' ;;
        *)
            warn 'Could not verify the token (no usable answer from the Cloudflare API).'
            warn 'Continuing; acme.sh will report the API error if the token is wrong.' ;;
    esac
}

# --- nginx -------------------------------------------------------------------
nginx_add_repo_deb() {
    _repo_dist=$OS_ID
    case "$OS_ID" in
        ubuntu|linuxmint|pop|neon|elementary|kali) _repo_dist=ubuntu ;;
    esac
    if [ -z "$OS_CODENAME" ]; then
        warn 'Could not determine the distribution codename, keeping the distribution package.'
        return 0
    fi
    if ! curl -fsS -m 20 -o /dev/null -I "https://nginx.org/packages/mainline/$_repo_dist/dists/$OS_CODENAME/Release" 2>/dev/null; then
        warn "nginx.org has no mainline packages for $_repo_dist/$OS_CODENAME yet."
        warn "The distribution package is usually older than $NGINX_MIN_MAJOR.$NGINX_MIN_MINOR -"
        warn 'the version check below will tell you what you ended up with.'
        return 0
    fi
    if ! pkg_install gnupg ca-certificates; then
        warn 'Could not install gnupg/ca-certificates, keeping the distribution package.'
        return 0
    fi
    _key=/usr/share/keyrings/nginx-archive-keyring.gpg
    if [ ! -s "$_key" ]; then
        if ! curl -fsSL --retry 3 https://nginx.org/keys/nginx_signing.key | gpg --dearmor --yes -o "$_key" 2>/dev/null; then
            warn 'Could not fetch the nginx signing key, keeping the distribution package.'
            return 0
        fi
        chmod 644 "$_key"
    fi
    printf 'deb [signed-by=%s] https://nginx.org/packages/mainline/%s %s nginx\n' \
        "$_key" "$_repo_dist" "$OS_CODENAME" > /etc/apt/sources.list.d/nginx.list
    printf 'Package: *\nPin: origin nginx.org\nPin-Priority: 900\n' > /etc/apt/preferences.d/99nginx
    apt-get update -qq || warn 'apt-get update reported problems, continuing.'
    ok "nginx.org mainline repository enabled ($_repo_dist/$OS_CODENAME)"
}

nginx_add_repo_rpm() {
    cat > /etc/yum.repos.d/nginx.repo <<'EOF'
[nginx-mainline]
name=nginx mainline repo
baseurl=https://nginx.org/packages/mainline/centos/$releasever/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
EOF
    ok 'nginx.org mainline repository enabled'
}

nginx_install_pkg() {
    case $OS_FAMILY in
        deb)
            if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
                    -o Dpkg::Options::=--force-confold --allow-downgrades nginx; then
                warn 'nginx installation failed, removing the distribution packages and retrying.'
                DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq \
                    nginx-core nginx-full nginx-light nginx-extras nginx-common >/dev/null 2>&1 || true
                apt-get update -qq || true
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
                    -o Dpkg::Options::=--force-confold --allow-downgrades nginx \
                    || die 'Could not install nginx.'
            fi ;;
        rpm)
            dnf module disable -y nginx >/dev/null 2>&1 || true
            dnf install -y -q nginx || die 'Could not install nginx.' ;;
    esac
    systemctl enable nginx >/dev/null 2>&1 || true
    ok "nginx installed: $(nginx -v 2>&1)"
}

nginx_check_version() {
    _v=$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9][0-9.]*\).*|\1|p')
    if [ -z "$_v" ]; then
        die 'Could not read the nginx version; cannot verify the minimum version.'
    fi
    _maj=${_v%%.*}
    _rest=${_v#*.}
    _min=${_rest%%.*}
    if [ "$_maj" -gt "$NGINX_MIN_MAJOR" ] || { [ "$_maj" -eq "$NGINX_MIN_MAJOR" ] && [ "$_min" -ge "$NGINX_MIN_MINOR" ]; }; then
        ok "nginx $_v satisfies the >= $NGINX_MIN_MAJOR.$NGINX_MIN_MINOR requirement."
    else
        warn "nginx $_v is older than $NGINX_MIN_MAJOR.$NGINX_MIN_MINOR."
        warn 'The templates use "http2 on", which needs nginx >= 1.25.1, so nginx -t may reject the config.'
        die "Please install nginx >= $NGINX_MIN_MAJOR.$NGINX_MIN_MINOR and run the script again."
    fi
}

find_stream_module() {
    for _sm in /usr/lib/nginx/modules/ngx_stream_module.so \
               /usr/lib64/nginx/modules/ngx_stream_module.so \
               /usr/share/nginx/modules/ngx_stream_module.so \
               /usr/local/nginx/modules/ngx_stream_module.so; do
        if [ -f "$_sm" ]; then
            printf '%s' "$_sm"
            return 0
        fi
    done
    return 1
}

nginx_stream_support() {
    STREAM_LOAD_LINE=''
    if nginx -V 2>&1 | grep -qE -- '(^|[[:space:]])--with-stream([[:space:]]|$)'; then
        ok 'This nginx build has stream support compiled in (needed for the 443 SNI router).'
        return 0
    fi
    if _mod=$(find_stream_module); then
        STREAM_LOAD_LINE="load_module $_mod;"
        ok "stream module found and will be loaded: $_mod"
        return 0
    fi
    warn 'The stream module is missing, trying to install it.'
    case $OS_FAMILY in
        deb) pkg_install libnginx-mod-stream >/dev/null 2>&1 || true ;;
        rpm) pkg_install nginx-mod-stream >/dev/null 2>&1 || true ;;
    esac
    if _mod=$(find_stream_module); then
        STREAM_LOAD_LINE="load_module $_mod;"
        ok "stream module installed: $_mod"
        return 0
    fi
    warn 'Without the stream module the stream block of nginx.conf cannot work.'
    die 'Install a compatible stream module (Debian/Ubuntu: libnginx-mod-stream, RHEL: nginx-mod-stream) and re-run.'
}

stage_nginx() {
    hdr 'Installing nginx'
    case $OS_FAMILY in
        deb) nginx_add_repo_deb ;;
        rpm) nginx_add_repo_rpm ;;
    esac
    nginx_install_pkg
    nginx_check_version
    nginx_stream_support
}

# --- 3x-ui -------------------------------------------------------------------
restart_xui() {
    systemctl restart x-ui || die 'Could not restart x-ui.'
    sleep 2
    systemctl is-active --quiet x-ui || die 'x-ui stopped after restarting; check journalctl -u x-ui.'
}

xui_cli() {
    (cd /usr/local/x-ui && ./x-ui "$@")
}

xui_flag_supported() {   # $1 = flag, e.g. -port
    { xui_cli setting -h 2>&1 || true; } | grep -qE "^[[:space:]]*$1([[:space:]]|=|$)"
}

apply_xui_panel_settings() {
    info 'Applying the panel settings'
    for _flag in -port -username -password -webBasePath -listenIP; do
        xui_flag_supported "$_flag" || die "The installed panel binary does not support $_flag."
    done
    systemctl stop x-ui || die 'Could not stop x-ui before updating settings.'
    if ! xui_cli setting -port "$PANEL_PORT" -username "$PANEL_USER" \
        -password "$PANEL_PASS" -webBasePath "$PANEL_PATH" -listenIP 127.0.0.1; then
        systemctl start x-ui || true
        die 'Could not apply the panel settings.'
    fi
    restart_xui
    ok "Panel settings command completed: port $PANEL_PORT, user $PANEL_USER, base path $PANEL_PATH."
}

xui_db_path() {
    for _db in /etc/x-ui/x-ui.db /usr/local/x-ui/x-ui.db /etc/x-ui/x-ui/x-ui.db; do
        if [ -f "$_db" ]; then
            printf '%s' "$_db"
            return 0
        fi
    done
    _db=$(find /etc /usr/local /opt -maxdepth 4 -name 'x-ui.db' -print 2>/dev/null | head -n 1) || _db=''
    if [ -n "$_db" ]; then
        printf '%s' "$_db"
        return 0
    fi
    return 1
}

manual_sub_note() {
    warn 'Set these by hand in the panel, Settings -> Subscription:'
    warn "    enabled, port = $SUB_PORT, path = $SUB_PATH, domain = $SUB_FQDN"
    warn 'The subscription URL in proxy.conf points at 127.0.0.1:'"$SUB_PORT"' and would not answer.'
}

# Current 3x-ui releases have no CLI for subscription settings; they are stored
# as key/value rows ("settings" table) in the panel database, written here.
configure_xui_subscription() {
    hdr 'Configuring the subscription service'
    _db=$(xui_db_path) || _db=''
    if [ -z "$_db" ]; then
        warn 'Could not locate the 3x-ui database.'
        manual_sub_note
        return 1
    fi
    if ! have sqlite3; then
        info 'Installing sqlite3 to write the subscription settings.'
        case ${OS_FAMILY:-} in
            rpm) pkg_install sqlite >/dev/null 2>&1 || true ;;
            *)   pkg_install sqlite3 >/dev/null 2>&1 || true ;;
        esac
    fi
    if ! have sqlite3; then
        warn 'sqlite3 is not available.'
        manual_sub_note
        return 1
    fi
    _tbl=$(sqlite3 "$_db" "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('settings','setting') LIMIT 1;" 2>/dev/null) || _tbl=''
    if [ -z "$_tbl" ]; then
        warn "No settings table found in $_db."
        manual_sub_note
        return 1
    fi

    systemctl stop x-ui || die 'Could not stop x-ui; database was not changed.'
    _bak=$(mktemp "$_db.bak-XXXXXX") || { systemctl start x-ui || true; die 'Cannot create database backup.'; }
    if ! sqlite3 "$_db" ".backup '$_bak'"; then
        systemctl start x-ui || true
        die 'Could not back up the panel database.'
    fi
    chmod 600 "$_bak"
    _sql='BEGIN IMMEDIATE;'
    for _kv in "subEnable:true" "subPort:$SUB_PORT" "subPath:$SUB_PATH" \
        'subListen:127.0.0.1' 'subDomain:' "subURI:https://$SUB_FQDN$SUB_PATH" \
        'subCertFile:' 'subKeyFile:' 'webCertFile:' 'webKeyFile:'; do
        _k=${_kv%%:*}
        _val=${_kv#*:}
        _escaped=$(printf '%s' "$_val" | sed "s/'/''/g")
        _sql="$_sql DELETE FROM \"$_tbl\" WHERE \"key\"='$_k'; INSERT INTO \"$_tbl\" (\"key\",\"value\") VALUES ('$_k','$_escaped');"
    done
    if ! sqlite3 -bail "$_db" "$_sql COMMIT;"; then
        systemctl start x-ui || true
        die "Subscription transaction failed; no partial subscription update was committed. Backup: $_bak"
    fi
    restart_xui
    info 'Stored values:'
    sqlite3 "$_db" "SELECT '    '||\"key\"||' = '||\"value\" FROM \"$_tbl\" WHERE \"key\" IN ('subEnable','subPort','subPath','subDomain') ORDER BY \"key\";" 2>/dev/null || true
    ok "Subscription database updated (backup: $_bak)."
}

stage_xui() {
    hdr 'Installing 3x-ui'
    if ! have bash; then
        info 'Installing bash, which the 3x-ui installer requires.'
        pkg_install bash || die 'Could not install bash; the 3x-ui installer needs it.'
    fi
    _dir=$(mktemp -d 2>/dev/null) || die 'Could not create a temporary directory.'
    info "Downloading $XUI_INSTALL_URL"
    if ! curl -fsSL --retry 3 -o "$_dir/install.sh" "$XUI_INSTALL_URL"; then
        rm -rf "$_dir"
        die 'Could not download the 3x-ui installer. GitHub must be reachable from this server.'
    fi
    info 'Running the 3x-ui installer without prompts (no TLS on the panel: nginx terminates it).'
    # install.sh reads XUI_WEB_BASE_PATH while the first panel start reads
    # XUI_INIT_WEB_BASE_PATH; both spellings are passed so either build agrees.
    # The authoritative values are applied again below through the panel binary.
    if ! env XUI_NONINTERACTIVE=1 \
             XUI_USERNAME="$PANEL_USER" \
             XUI_PASSWORD="$PANEL_PASS" \
             XUI_PANEL_PORT="$PANEL_PORT" \
             XUI_WEB_BASE_PATH="$PANEL_PATH" \
             XUI_INIT_WEB_BASE_PATH="$PANEL_PATH" \
             XUI_SSL_MODE=none \
             XUI_DB_TYPE="$XUI_DB_TYPE" \
             XUI_ENABLE_FAIL2BAN="$XUI_ENABLE_FAIL2BAN" \
             bash "$_dir/install.sh" < /dev/null; then
        rm -rf "$_dir"
        die 'The 3x-ui installer failed, see its output above.'
    fi
    rm -rf "$_dir"
    if [ ! -x /usr/local/x-ui/x-ui ]; then
        die 'The 3x-ui binary was not found after the installation.'
    fi
    apply_xui_panel_settings
    configure_xui_subscription
    if [ -f /etc/x-ui/install-result.env ]; then
        info 'The installer also wrote its own credentials file: /etc/x-ui/install-result.env'
    fi
}

# --- certificates ------------------------------------------------------------
install_acme() {
    if [ -x "$ACME_HOME/acme.sh" ]; then
        ok 'acme.sh is already installed.'
        return 0
    fi
    info 'Installing acme.sh'
    if curl -fsSL --retry 3 "$ACME_INSTALL_URL" | sh -s "email=$ACME_EMAIL" >/dev/null 2>&1; then
        if [ -x "$ACME_HOME/acme.sh" ]; then
            ok 'acme.sh installed.'
            return 0
        fi
    fi
    warn 'The get.acme.sh installer did not work, trying a git clone.'
    if ! have git; then
        pkg_install git >/dev/null 2>&1 || true
    fi
    if have git; then
        rm -rf /root/.acme.sh.src
        if git clone --depth 1 "$ACME_GIT_URL" /root/.acme.sh.src >/dev/null 2>&1 \
           || git clone --depth 1 "$ACME_GIT_MIRROR" /root/.acme.sh.src >/dev/null 2>&1; then
            ( cd /root/.acme.sh.src && ./acme.sh --install -m "$ACME_EMAIL" ) >/dev/null 2>&1 || true
            rm -rf /root/.acme.sh.src
        fi
    fi
    if [ ! -x "$ACME_HOME/acme.sh" ]; then
        die 'Could not install acme.sh (neither get.acme.sh nor git worked).'
    fi
    ok 'acme.sh installed from git.'
}

stage_origin_cert() (
    set -eu
    hdr 'Issuing a Cloudflare Origin CA certificate (5475 days)'
    have openssl || { info 'Installing openssl.'; pkg_install openssl || true; }
    have jq || { info 'Installing jq.'; pkg_install jq || true; }
    have openssl || die 'openssl is required for Origin CA issuance.'
    have jq || die 'jq is required for Origin CA issuance.'
    if [ -e "$CERT_DIR/fullchain.pem" ] || [ -e "$CERT_DIR/privkey.pem" ]; then
        die "Certificate files already exist in $CERT_DIR. Keep them with --configs-only; this script will not overwrite an existing key or certificate."
    fi
    umask 077
    _oc_tmp=$(mktemp -d) || die 'Cannot create certificate workspace.'
    _oc_submitted=0
    _oc_complete=0
    origin_cleanup() {
        rm -f "$_oc_tmp/auth.header"
        if [ "$_oc_submitted" = 1 ] && [ "$_oc_complete" = 0 ]; then
            warn "Issuance may have created a certificate. Private key, CSR and response retained for recovery in $_oc_tmp (root only)." >&2
        else
            rm -rf "$_oc_tmp"
        fi
    }
    trap 'origin_cleanup' 0
    trap 'exit 130' INT
    trap 'exit 143' TERM
    openssl req -new -newkey rsa:2048 -nodes \
        -keyout "$_oc_tmp/privkey.pem" -out "$_oc_tmp/request.csr" \
        -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN,DNS:*.$DOMAIN" \
        >/dev/null 2>&1 || die 'Could not generate the private key and CSR.'
    jq -n --rawfile csr "$_oc_tmp/request.csr" --arg domain "$DOMAIN" \
        --argjson days "$ORIGIN_VALIDITY" \
        '{csr:$csr,hostnames:[$domain,("*."+$domain)],request_type:"origin-rsa",requested_validity:$days}' \
        > "$_oc_tmp/request.json" || die 'Could not build the certificate request.'
    printf 'Authorization: Bearer %s\n' "$CF_API_TOKEN" > "$_oc_tmp/auth.header"
    # Do not retry this POST: a lost response may already have issued a certificate.
    _oc_submitted=1
    if ! curl --fail --silent --show-error --connect-timeout 15 --max-time 90 \
        -X POST https://api.cloudflare.com/client/v4/certificates \
        -H @"$_oc_tmp/auth.header" -H 'Content-Type: application/json' \
        --data-binary @"$_oc_tmp/request.json" -o "$_oc_tmp/response.json"; then
        die 'Cloudflare issuance failed or its response was lost. Check Origin Server certificates in the dashboard before retrying.'
    fi
    jq -er 'select(.success == true) | .result.certificate | select(type == "string" and length > 0)' \
        "$_oc_tmp/response.json" > "$_oc_tmp/fullchain.pem" \
        || die 'Cloudflare did not return a certificate. Check token permissions and zone access.'
    openssl x509 -in "$_oc_tmp/fullchain.pem" -noout -checkend 86400 >/dev/null \
        || die 'The returned certificate is invalid or expires within a day.'
    _oc_san=$(openssl x509 -in "$_oc_tmp/fullchain.pem" -noout -ext subjectAltName 2>/dev/null) || _oc_san=''
    printf '%s\n' "$_oc_san" | grep -q "DNS:\*.$DOMAIN" \
        || die "The certificate does not cover *.$DOMAIN."
    # SUB_FQDN/CAMO_FQDN are empty in certificate-only runs; the wildcard
    # check above already proves every sub-domain is covered.
    _oc_hosts="$DOMAIN www.$DOMAIN"
    [ -n "$SUB_FQDN" ] && _oc_hosts="$_oc_hosts $SUB_FQDN"
    [ -n "$CAMO_FQDN" ] && _oc_hosts="$_oc_hosts $CAMO_FQDN"
    for _oc_host in $_oc_hosts; do
        openssl verify -trusted "$_oc_tmp/fullchain.pem" -partial_chain \
            -verify_hostname "$_oc_host" "$_oc_tmp/fullchain.pem" >/dev/null \
            || die "The certificate does not cover $_oc_host."
    done
    openssl x509 -in "$_oc_tmp/fullchain.pem" -pubkey -noout > "$_oc_tmp/cert.pub"
    openssl pkey -in "$_oc_tmp/privkey.pem" -pubout > "$_oc_tmp/key.pub"
    cmp -s "$_oc_tmp/cert.pub" "$_oc_tmp/key.pub" || die 'The returned certificate does not match the private key.'
    mkdir -p "$CERT_DIR"
    cp "$_oc_tmp/privkey.pem" "$CERT_DIR/privkey.pem"
    cp "$_oc_tmp/fullchain.pem" "$CERT_DIR/fullchain.pem"
    chmod 600 "$CERT_DIR/privkey.pem"
    chmod 644 "$CERT_DIR/fullchain.pem"
    jq -r '.result | {id,expires_on,requested_validity,hostnames}' "$_oc_tmp/response.json" > "$CERT_DIR/origin-ca.json"
    _oc_complete=1
    ok "Origin CA certificate installed in $CERT_DIR"
    openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -enddate
    warn 'Keep these DNS names proxied through Cloudflare with Full (strict) TLS. Schedule replacement before expiry.'
)

stage_certs() {
    if [ "$CERT_MODE" = origin ]; then
        if [ -e "$CERT_DIR/fullchain.pem" ] && [ -e "$CERT_DIR/privkey.pem" ] && \
           openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -checkend 86400 >/dev/null 2>&1; then
            info "Valid certificate already exists in $CERT_DIR; skipping re-issuance."
            return 0
        fi
        stage_origin_cert
        return
    fi
    hdr 'Issuing the wildcard certificate'
    install_acme
    _acme="$ACME_HOME/acme.sh"

    CF_Token="$CF_API_TOKEN"
    # Never carry a previous action's zone ID into this invocation.
    CF_Zone_ID=${CF_ZONE_ID:-}
    export CF_Token CF_Zone_ID

    "$_acme" --set-default-ca --server letsencrypt >/dev/null 2>&1 \
        || warn 'Could not set Let'\''s Encrypt as the default CA (continuing anyway).'

    info "Requesting $DOMAIN and *.$DOMAIN through the Cloudflare DNS API."
    _rc=0
    if [ -n "$ACME_DNSSLEEP" ]; then
        "$_acme" --issue --dns dns_cf --server letsencrypt --dnssleep "$ACME_DNSSLEEP" \
            -d "$DOMAIN" -d "*.$DOMAIN" || _rc=$?
    else
        "$_acme" --issue --dns dns_cf --server letsencrypt \
            -d "$DOMAIN" -d "*.$DOMAIN" || _rc=$?
    fi

    if [ "$_rc" -ne 0 ]; then
        if [ "$_rc" = 2 ]; then
            info 'acme.sh reports that renewal is not due; installing the existing certificate.'
        else
            die 'Certificate issuance failed. Check that the token may edit DNS for this zone and that the domain is on that Cloudflare account.'
        fi
    fi

    mkdir -p "$CERT_DIR"
    "$_acme" --install-cert -d "$DOMAIN" \
        --fullchain-file "$CERT_DIR/fullchain.pem" \
        --key-file "$CERT_DIR/privkey.pem" \
        --reloadcmd 'systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true' \
        || die "Could not install the certificate into $CERT_DIR."
    chmod 644 "$CERT_DIR/fullchain.pem" 2>/dev/null || true
    chmod 600 "$CERT_DIR/privkey.pem" 2>/dev/null || true
    rm -f "$CERT_DIR/origin-ca.json" || die 'Certificate installed, but stale Origin CA metadata could not be removed.'

    if grep -q 'CF_Token' "$ACME_HOME/account.conf" 2>/dev/null; then
        ok 'The Cloudflare token was saved, automatic renewal will keep working.'
    else
        warn 'The Cloudflare token was not found in '"$ACME_HOME"'/account.conf.'
        warn 'Future renewals would need CF_Token exported again.'
    fi

    _exp=$(openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -enddate 2>/dev/null | cut -d= -f2) || _exp=''
    ok "Certificate installed in $CERT_DIR"
    if [ -n "$_exp" ]; then
        info "Expires: $_exp (acme.sh renews it automatically)"
    fi
}

# --- built-in templates -------------------------------------------------------
# These mirror the nginx.conf / proxy.conf files that ship next to this script.
# If those files exist they take precedence; the built-in copies make the script
# self-contained, so uploading install.sh alone is enough.

builtin_nginx_conf() {
    cat <<'BUILTIN_NGINX_EOF'

user  nginx;
worker_processes  auto;

error_log  /var/log/nginx/error.log notice;
pid        /run/nginx.pid;


events {
    worker_connections  1024;
}


http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile        on;
    #tcp_nopush     on;

    keepalive_timeout  65;

    #gzip  on;

    include /etc/nginx/conf.d/*.conf;
}

stream {
	map $ssl_preread_server_name $backend_name {
        # 1.1 Your VLESS xhttp REALITY SNI
        www.varzesh3.com			127.0.0.1:10001;
        varzesh3.com				127.0.0.1:10001;
		spiegel.de					127.0.0.1:10001;
		www.partneredge.sap.com		127.0.0.1:10001;
		partneredge.sap.com			127.0.0.1:10001;
        www.yahoo.com				127.0.0.1:10002;
        yahoo.com					127.0.0.1:10002;
    

		amp-api-edge.apps.apple.com		127.0.0.1:10003;
		www.amp-api-edge.apps.apple.com	127.0.0.1:10003;

    
    # 3. Your actual website domain proxied via Cloudflare
    DOMAIN		127.0.0.1:4443;
    SUB.DOMAIN	127.0.0.1:4443;
    www.DOMAIN	127.0.0.1:4443;
        
    # 4. Fallback to the web server
    default            127.0.0.1:4443;
    }

    server {
        listen 443;
        #listen [::]:443;
        ssl_preread on;
        proxy_pass $backend_name;
    }
}

BUILTIN_NGINX_EOF
}

builtin_proxy_conf() {
    cat <<'BUILTIN_PROXY_EOF'
# --------------------------------------------------------
# 0. BLOCK DIRECT IP SCANNERS (Anti-GFW Stealth)
# --------------------------------------------------------
server {
    listen 80 default_server;
    listen 4443 ssl default_server;
    server_name _;

    # Instantly drops the connection without showing your certificate
    ssl_reject_handshake on;
    
    # Returns an empty response for plain HTTP scans
    return 444; 
}

# --------------------------------------------------------
# 1. Main Website & Root Domain (DOMAIN)
# --------------------------------------------------------
server {
    listen 4443 ssl;
    http2 on;
    server_name DOMAIN www.DOMAIN;

    ssl_certificate /root/cert/DOMAIN/fullchain.pem;
    ssl_certificate_key /root/cert/DOMAIN/privkey.pem;

    server_tokens off;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    add_header Referrer-Policy strict-origin-when-cross-origin;

    location / {
        root /var/www/goldcalc/;
        index index.html index.htm;
        try_files $uri $uri/ =404;
    }

    location ~* (vpn|proxy|trojan|vless|vmess|conf|config) {
        return 403;
    }

    location ^~ /assets-video-2021 {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location ^~ /assets-stream-2022 {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:20000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location ^~ /assets-stream-2023 {
        proxy_pass http://127.0.0.1:30000;
        proxy_redirect off;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Connection "keep-alive"; 
        gzip off;
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 0;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location ^~ /cdn2cdn {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:40000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    location ^~ /mobile/api/v3/config {
        proxy_pass http://127.0.0.1:8443/s/sub;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}

# --------------------------------------------------------
# 2. Panel, Subscriptions & Inbounds (SUB.DOMAIN)
# --------------------------------------------------------
server {
    listen 4443 ssl;
    http2 on;
    server_name SUB.DOMAIN;

    ssl_certificate /root/cert/DOMAIN/fullchain.pem;
    ssl_certificate_key /root/cert/DOMAIN/privkey.pem;

    server_tokens off;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    add_header Referrer-Policy strict-origin-when-cross-origin;

    # Fallback dummy page for root access
    location / {
        default_type text/html;
        return 200 'Site is under maintenance Please check back later.';
    }

    # Block sensitive paths
    location ~* (vpn|proxy|trojan|vless|vmess|conf|config) {
        return 403;
    }

    # 3x-ui Panel Route
    location = /xuipanel {
        return 301 /xuipanel/;
    }

    location ^~ /xuipanel/ {
        proxy_pass http://127.0.0.1:PANELPORT; 
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # Subscription Route
    location ^~ /s/ {
        proxy_pass http://127.0.0.1:8443;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # WebSocket Proxy Endpoint (Port 10000)
    location ^~ /assets-video-2021 {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    # WebSocket Proxy Endpoint (Port 20000)
    location ^~ /assets-stream-2022 {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:20000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    # HTTPUpgrade / gRPC Endpoint (Port 30000)
    location ^~ /assets-stream-2023 {
        proxy_pass http://127.0.0.1:30000;
        proxy_redirect off;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Connection "keep-alive"; 
        gzip off;
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 0;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    # WebSocket CDN Endpoint (Port 40000)
    location ^~ /cdn2cdn {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:40000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # Mobile Subscription Mirror
    location ^~ /mobile/api/v3/config {
        proxy_pass http://127.0.0.1:8443/s/sub;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}

# --------------------------------------------------------
# 3. Direct Domain Camouflage (SUBoff.DOMAIN)
# --------------------------------------------------------
server {
    listen 4443 ssl;
    http2 on;
    server_name SUBoff.DOMAIN;

    ssl_certificate /root/cert/DOMAIN/fullchain.pem;
    ssl_certificate_key /root/cert/DOMAIN/privkey.pem;

    server_tokens off;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    add_header Referrer-Policy strict-origin-when-cross-origin;

    # The Dummy Maintenance Page
    location / {
        default_type text/html;
        return 200 'Site is under maintenance Please check back later.';
    }

    location ~* (vpn|proxy|trojan|vless|vmess|conf|config) {
        return 403;
    }

    location ^~ /assets-stream-2024 {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:40000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}

# --------------------------------------------------------
# 4. Global HTTP to HTTPS Redirect
# --------------------------------------------------------
server {
    listen 80;
    server_name DOMAIN www.DOMAIN SUB.DOMAIN SUBoff.DOMAIN ;
    
    return 301 https://$host$request_uri;
}
BUILTIN_PROXY_EOF
}

# --- config rendering and deployment -----------------------------------------
count_occurrences() {   # $1 = pattern, $2 = file
    grep -o "$1" "$2" 2>/dev/null | wc -l | tr -d ' '
}

render_template() (   # $1 = template, $2 = output, $3 = label, $4 = expects a sub port
    _rt_builtin=''
    trap '[ -z "$_rt_builtin" ] || rm -f "$_rt_builtin"' 0
    trap 'exit 130' INT
    trap 'exit 143' TERM
    _rt_in=$1
    _rt_out=$2
    _rt_label=$3
    _rt_expect=${4:-}

    if [ ! -f "$_rt_in" ]; then
        _rt_use_builtin=0
        if [ "$_rt_label" = nginx.conf ] && [ "$NGINX_CONF_EXPLICIT" = 0 ]; then
            _rt_use_builtin=1
        fi
        if [ "$_rt_label" = proxy.conf ] && [ "$PROXY_CONF_EXPLICIT" = 0 ]; then
            _rt_use_builtin=1
        fi
        if [ "$_rt_use_builtin" != 1 ]; then
            die "$_rt_label not found: $_rt_in"
        fi
        _rt_builtin=$(mktemp) || die 'Could not create a temporary file.'
        if [ "$_rt_label" = nginx.conf ]; then
            builtin_nginx_conf > "$_rt_builtin" || die 'Could not extract the built-in nginx.conf.'
        else
            builtin_proxy_conf > "$_rt_builtin" || die 'Could not extract the built-in proxy.conf.'
        fi
        info "$_rt_label: template file not found next to the script, using the built-in copy"
        _rt_in=$_rt_builtin
    fi
    if [ ! -s "$_rt_in" ]; then
        die "$_rt_label is empty: $_rt_in"
    fi

    _rt_n_camo=$(count_occurrences 'SUBoff\.DOMAIN' "$_rt_in")
    _rt_n_sub=$(count_occurrences 'SUB\.DOMAIN' "$_rt_in")
    _rt_n_dom=$(count_occurrences 'DOMAIN' "$_rt_in")
    _rt_n_panel=$(count_occurrences 'PANELPORT' "$_rt_in")
    _rt_n_subport=$(count_occurrences 'SUBPORT' "$_rt_in")
    _rt_n_8443=$(count_occurrences '127\.0\.0\.1:8443' "$_rt_in")
    # "DOMAIN" also matches inside the longer placeholders, so subtract those.
    _rt_n_dom_only=$((_rt_n_dom - _rt_n_sub - _rt_n_camo))

    # Order matters: the longest placeholders are replaced first so that the
    # bare DOMAIN rule cannot eat the SUB. / SUBoff. prefixes.
    sed \
        -e "s|SUBoff\.DOMAIN|$CAMO_FQDN|g" \
        -e "s|SUB\.DOMAIN|$SUB_FQDN|g" \
        -e "s|DOMAIN|$DOMAIN|g" \
        -e "s|127\.0\.0\.1:8443|127.0.0.1:$SUB_PORT|g" \
        -e "s|PANELPORT|$PANEL_PORT|g" \
        -e "s|SUBPORT|$SUB_PORT|g" \
        "$_rt_in" > "$_rt_out" || die "Could not render $_rt_label."

    _rt_left=$(grep -nE 'SUBoff\.DOMAIN|SUB\.DOMAIN|DOMAIN|PANELPORT|SUBPORT' "$_rt_out" || true)
    if [ -n "$_rt_left" ]; then
        err "Unreplaced placeholders are left in $_rt_label:"
        printf '%s\n' "$_rt_left" >&2
        die 'Aborting, the rendered configuration would be inconsistent.'
    fi

    info "$_rt_label: $((_rt_n_camo + _rt_n_sub + _rt_n_dom_only)) domain, $_rt_n_panel panel-port, $((_rt_n_subport + _rt_n_8443)) subscription-port replacements"

    if [ "$_rt_expect" = 'subport' ] && [ "$_rt_n_subport" = 0 ] && [ "$_rt_n_8443" = 0 ]; then
        warn "$_rt_label has no SUBPORT token and no 127.0.0.1:8443 upstream,"
        warn "so the subscription port $SUB_PORT could not be applied to it."
    fi
)

write_index_page() {
    if [ ! -d "$WEB_ROOT" ]; then
        mkdir -p "$WEB_ROOT"
    fi
    if [ ! -f "$WEB_ROOT/index.html" ]; then
        cat > "$WEB_ROOT/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Under construction</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{font-family:system-ui,-apple-system,sans-serif;max-width:40rem;margin:18vh auto;padding:0 1.5rem;color:#222}</style>
</head>
<body>
<h1>Under construction</h1>
<p>This site is being prepared. Please check back later.</p>
</body>
</html>
EOF
        ok "Created a placeholder page: $WEB_ROOT/index.html"
    else
        info "Keeping the existing $WEB_ROOT/index.html"
    fi
    chmod 755 "$WEB_ROOT" 2>/dev/null || true
}

restore_backup() {
    _rb_failed=0
    if [ "$MAIN_CONF_EXISTED" = 0 ]; then
        rm -f "$NGINX_MAIN_CONF" || _rb_failed=1
    elif [ -n "$BACKUP_DIR" ] && [ -f "$BACKUP_DIR/nginx.conf" ]; then
        if cp -a "$BACKUP_DIR/nginx.conf" "$NGINX_MAIN_CONF"; then
            info "Previous $NGINX_MAIN_CONF restored."
        else
            _rb_failed=1
        fi
    else
        err 'Main configuration backup is missing.'
        _rb_failed=1
    fi
    if [ -n "$BACKUP_DIR" ]; then
        for _rb in "$BACKUP_DIR"/conf.d-*; do
            if [ -f "$_rb" ]; then
                if cp -a "$_rb" "$NGINX_CONF_D/${_rb#"$BACKUP_DIR/conf.d-"}"; then
                    info "Previous conf.d entry restored: ${_rb#"$BACKUP_DIR/conf.d-"}"
                else
                    _rb_failed=1
                fi
            fi
        done
    fi
    if [ "$PROXY_CONF_EXISTED" = 0 ]; then
        if rm -f "$NGINX_CONF_D/proxy.conf"; then
            info 'Removed the newly written proxy.conf.'
        else
            _rb_failed=1
        fi
    fi
    [ "$_rb_failed" = 0 ]
}

stage_deploy() {
    hdr 'Deploying the nginx configuration'

    if [ ! -f "$CERT_DIR/fullchain.pem" ] || [ ! -f "$CERT_DIR/privkey.pem" ]; then
        warn "The certificate files are missing in $CERT_DIR."
        warn 'nginx will refuse this configuration (ssl_certificate), so the deployment'
        warn 'would be rolled back. Issue the certificate first.'
        die 'Certificate files are required before deployment; nginx files were not changed.'
    fi

    _stamp=$(date +%Y%m%d-%H%M%S)
    BACKUP_DIR=$(mktemp -d "$BACKUP_BASE/vpn-setup-backup-$_stamp-XXXXXX") || die 'Could not create backup directory.'
    PROXY_CONF_EXISTED=0
    MAIN_CONF_EXISTED=0

    # Render everything before touching the live files, so a broken template
    # cannot leave the machine half configured.
    _rendered_main=$(mktemp) || die 'Could not create a temporary file.'
    _rendered_proxy=$(mktemp) || die 'Could not create a temporary file.'
    render_template "$NGINX_TEMPLATE" "$_rendered_main" 'nginx.conf'
    render_template "$PROXY_TEMPLATE" "$_rendered_proxy" 'proxy.conf' subport

    if [ -f "$NGINX_MAIN_CONF" ]; then
        cp -a "$NGINX_MAIN_CONF" "$BACKUP_DIR/nginx.conf"
        MAIN_CONF_EXISTED=1
    fi
    if [ ! -d "$NGINX_CONF_D" ]; then
        mkdir -p "$NGINX_CONF_D"
    fi
    # conf.d is included by the new nginx.conf, so anything already there
    # (for example the package default server on port 80) would clash with
    # proxy.conf. Those files are moved aside, not deleted.
    for _existing in "$NGINX_CONF_D"/*.conf; do
        if [ -f "$_existing" ]; then
            _base=${_existing##*/}
            cp -a "$_existing" "$BACKUP_DIR/conf.d-$_base"
            if [ "$_base" = 'proxy.conf' ]; then
                PROXY_CONF_EXISTED=1
            fi
        fi
    done
    DEPLOY_ACTIVE=1
    for _existing in "$NGINX_CONF_D"/*.conf; do
        [ -f "$_existing" ] || continue
        rm -f "$_existing"
        info "moved aside: ${_existing##*/}"
    done

    _main_dir=${NGINX_MAIN_CONF%/*}
    _tmp_main="$_main_dir/.nginx.conf.new.$$"
    if [ -n "$STREAM_LOAD_LINE" ]; then
        # load_module has to be the first directive in the file.
        {
            printf '%s\n' "$STREAM_LOAD_LINE"
            cat "$_rendered_main"
        } > "$_tmp_main" || die 'Could not write the new nginx.conf.'
    else
        cat "$_rendered_main" > "$_tmp_main" || die 'Could not write the new nginx.conf.'
    fi
    mv "$_tmp_main" "$NGINX_MAIN_CONF" || die 'Could not replace nginx.conf.'

    _tmp_proxy="$NGINX_CONF_D/.proxy.conf.new.$$"
    cat "$_rendered_proxy" > "$_tmp_proxy" || die 'Could not write proxy.conf.'
    mv "$_tmp_proxy" "$NGINX_CONF_D/proxy.conf" || die 'Could not install proxy.conf.'

    chmod 644 "$NGINX_MAIN_CONF" "$NGINX_CONF_D/proxy.conf" 2>/dev/null || true
    rm -f "$_rendered_main" "$_rendered_proxy"

    write_index_page

    ok "nginx.conf -> $NGINX_MAIN_CONF"
    ok "proxy.conf -> $NGINX_CONF_D/proxy.conf"
    ok "backups -> $BACKUP_DIR"

    info 'Testing the configuration'
    if ! nginx -t; then
        err 'nginx rejected the new configuration, restoring the previous files.'
        DEPLOY_ACTIVE=0
        restore_backup || die "Rollback failed; restore files from $BACKUP_DIR manually."
        die 'Previous nginx configs restored. Fix the templates and run the script again.'
    fi
    if ! systemctl reload nginx 2>/dev/null; then
        if ! systemctl restart nginx 2>/dev/null; then
            DEPLOY_ACTIVE=0
            restore_backup || die "Rollback failed; restore files from $BACKUP_DIR manually."
            systemctl restart nginx 2>/dev/null || warn 'Previous nginx configuration also failed to start.'
            die 'Could not activate nginx; previous configuration files were restored.'
        fi
    fi
    DEPLOY_ACTIVE=0
    ok 'nginx reloaded with the new configuration.'
}

# --- Cloudflare DNS A records -------------------------------------------------
# The panel/subscription and camouflage hostnames only work when the zone has
# proxied A records pointing at this server. These helpers create or verify
# them with the same token the certificate stage uses.
detect_public_ip() {
    _dp=''
    if have curl; then
        _dp=$(curl -4 -s -m 10 https://api.ipify.org 2>/dev/null | tr -d '[:space:]') || _dp=''
        v_ipv4 "$_dp" >/dev/null 2>&1 || _dp=''
        if [ -z "$_dp" ]; then
            _dp=$(curl -4 -s -m 10 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]') || _dp=''
            v_ipv4 "$_dp" >/dev/null 2>&1 || _dp=''
        fi
    fi
    printf '%s' "$_dp"
}

# cf_api METHOD PATH [JSON-BODY]: performs the request and sets _cf_status;
# the response body is left in "$_CF_OUT" for the caller to parse.
# The body goes through a file (not stdout) so the status survives command
# substitution, and the token goes through a mode-600 header file instead of
# the curl argv so other local users cannot read it from ps/proc.
cf_api() {
    _cf_method=$1
    _cf_path=$2
    _cf_data=${3:-}
    if [ -z "$_CF_OUT" ]; then
        _CF_OUT=$(mktemp) || { _cf_status=000; return 1; }
        export _CF_OUT
    fi
    if [ -z "$_CF_HDR" ]; then
        _CF_HDR=$(mktemp) || { _cf_status=000; return 1; }
        chmod 600 "$_CF_HDR" 2>/dev/null || true
        export _CF_HDR
    fi
    printf 'Authorization: Bearer %s\n' "$CF_API_TOKEN" > "$_CF_HDR" || { _cf_status=000; return 1; }
    if [ "$_cf_method" = GET ]; then
        _cf_status=$(curl -sS -m 20 -o "$_CF_OUT" -w '%{http_code}' \
            -H "@$_CF_HDR" \
            "https://api.cloudflare.com/client/v4$_cf_path" 2>/dev/null) || _cf_status=000
    else
        _cf_status=$(curl -sS -m 20 -X "$_cf_method" -o "$_CF_OUT" -w '%{http_code}' \
            -H "@$_CF_HDR" \
            -H 'Content-Type: application/json' --data "$_cf_data" \
            "https://api.cloudflare.com/client/v4$_cf_path" 2>/dev/null) || _cf_status=000
    fi
    [ -n "$_cf_status" ] || _cf_status=000
}

cf_api_error() {   # first API error message from the last response, if any
    jq -r '.errors[0].message // empty' "$_CF_OUT" 2>/dev/null
}

cf_zone_id_for() {   # $1 = domain; prints the zone id, empty on any failure
    cf_api GET "/zones?name=$1"
    if [ "$_cf_status" != 200 ]; then
        warn "Zone lookup failed (HTTP $_cf_status)$( [ -s "$_CF_OUT" ] && printf ': %s' "$(cf_api_error)" )." >&2
        return 1
    fi
    jq -r '.result[0].id // empty' "$_CF_OUT" 2>/dev/null
}

dns_record_get() {   # $1 = fqdn; prints the count, then "id|content|proxied"
    cf_api GET "/zones/$DNS_ZONE_ID/dns_records?type=A&name=$1"
    if [ "$_cf_status" != 200 ]; then
        warn "DNS lookup for $1 failed (HTTP $_cf_status)$( [ -s "$_CF_OUT" ] && printf ': %s' "$(cf_api_error)" )." >&2
        return 1
    fi
    jq -r '(.result | length | tostring),
           (.result[0] // {} | ((.id // "") + "|" + (.content // "") + "|" + ((.proxied // false) | tostring)))' \
        "$_CF_OUT" 2>/dev/null
}

dns_record_create() {   # $1 = fqdn, $2 = ip
    _dc_data=$(printf '{"type":"A","name":"%s","content":"%s","ttl":1,"proxied":true}' "$1" "$2")
    cf_api POST "/zones/$DNS_ZONE_ID/dns_records" "$_dc_data"
    if [ "$_cf_status" != 200 ] && [ "$_cf_status" != 201 ]; then
        err "Could not create the A record for $1 (HTTP $_cf_status)$( [ -s "$_CF_OUT" ] && printf ': %s' "$(cf_api_error)" )."
        return 1
    fi
    ok "Created A record: $1 -> $2 (proxied)"
}

dns_record_update() {   # $1 = record id, $2 = fqdn, $3 = ip
    _du_data=$(printf '{"content":"%s","ttl":1,"proxied":true}' "$3")
    cf_api PATCH "/zones/$DNS_ZONE_ID/dns_records/$1" "$_du_data"
    if [ "$_cf_status" != 200 ]; then
        err "Could not update the A record for $2 (HTTP $_cf_status)$( [ -s "$_CF_OUT" ] && printf ': %s' "$(cf_api_error)" )."
        return 1
    fi
    ok "Updated A record: $2 -> $3 (proxied)"
}

dns_upsert_a() {   # $1 = fqdn, $2 = ip; existing records are never silently overwritten
    _dua_name=$1
    _dua_ip=$2
    _dua_raw=$(dns_record_get "$_dua_name") || return 1
    _dua_count=$(printf '%s\n' "$_dua_raw" | sed -n '1p')
    _dua_rec=$(printf '%s\n' "$_dua_raw" | sed -n '2p')
    _dua_id=${_dua_rec%%|*}
    _dua_rest=${_dua_rec#*|}
    _dua_content=${_dua_rest%%|*}
    _dua_proxied=${_dua_rest##*|}
    case $_dua_count in
        ''|*[!0-9]*) _dua_count=0 ;;
    esac
    if [ -z "$_dua_id" ]; then
        dns_record_create "$_dua_name" "$_dua_ip"
        return $?
    fi
    if [ "$_dua_count" -gt 1 ]; then
        warn "$_dua_count A records exist for $_dua_name; only the first one is managed here."
    fi
    if [ "$_dua_content" = "$_dua_ip" ] && [ "$_dua_proxied" = true ]; then
        ok "A record already correct: $_dua_name -> $_dua_ip (proxied)"
        return 0
    fi
    if [ "$_dua_content" = "$_dua_ip" ]; then
        warn "A record $_dua_name points at $_dua_ip but is DNS-only (grey cloud)."
        _dua_question="Enable the Cloudflare proxy (orange cloud) for $_dua_name?"
    else
        warn "A record $_dua_name exists with content $_dua_content, not $_dua_ip."
        _dua_question="Update $_dua_name to $_dua_ip (proxied)?"
    fi
    if [ "$ASSUME_YES" = 1 ] || [ "$NONINTERACTIVE" = 1 ]; then
        warn 'Leaving it unchanged (unattended runs never modify existing records).'
        return 0
    fi
    if confirm "$_dua_question"; then
        dns_record_update "$_dua_id" "$_dua_name" "$_dua_ip" || return 1
    else
        info "Left $_dua_name unchanged."
    fi
    return 0
}

stage_dns_records() {   # $1 = 'pre-approved' skips the up-front confirmation
    hdr 'Cloudflare DNS A records'
    if ! have jq; then
        warn 'jq is required for the Cloudflare API. Install jq, then run this action again.'
        warn 'DNS records were not changed.'
        return 1
    fi
    if [ -z "${CF_API_TOKEN:-}" ]; then
        warn 'A Cloudflare API token is required to manage DNS records; DNS was not changed.'
        return 1
    fi
    _sd_hosts=''
    if [ -n "${SUB_FQDN:-}" ]; then _sd_hosts="$_sd_hosts $SUB_FQDN"; fi
    if [ -n "${CAMO_FQDN:-}" ]; then _sd_hosts="$_sd_hosts $CAMO_FQDN"; fi
    if [ -z "$_sd_hosts" ]; then
        info 'No panel or camouflage hostnames to configure.'
        return 0
    fi
    say "  hostnames:$_sd_hosts"
    _sd_ip=${DNS_IP:-}
    if [ -n "$_sd_ip" ] && ! v_ipv4 "$_sd_ip"; then
        warn 'The DNS_IP value is not a valid IPv4 address; DNS records were not changed.'
        return 1
    fi
    if [ -z "$_sd_ip" ]; then
        _sd_ip=$(detect_public_ip)
        if [ -n "$_sd_ip" ]; then
            info "Detected this server's public IPv4: $_sd_ip"
        fi
    fi
    if [ "$NONINTERACTIVE" != 1 ] && [ "$ASSUME_YES" != 1 ]; then
        while :; do
            if [ -n "$_sd_ip" ]; then
                menu_ask "Public IPv4 for the A records [$_sd_ip]: "
                [ -n "$_choice" ] || break
            else
                menu_ask 'Public IPv4 for the A records: '
                if [ -z "$_choice" ]; then
                    warn 'An IPv4 address is required.'
                    continue
                fi
            fi
            if v_ipv4 "$_choice"; then
                _sd_ip=$_choice
                break
            fi
            if [ -n "$_sd_ip" ]; then
                warn 'Not a valid IPv4 address. Press Enter to keep the detected value.'
            else
                warn 'Not a valid IPv4 address.'
            fi
        done
    fi
    if [ -z "$_sd_ip" ]; then
        warn 'No public IPv4 address was detected or provided; DNS records were not changed.'
        warn 'Set DNS_IP (or answer the prompt) and run the DNS action again.'
        return 1
    fi
    v_ipv4 "$_sd_ip" || { warn 'Invalid IPv4 address; DNS records were not changed.'; return 1; }
    info "Using IPv4 $_sd_ip for the A records (proxied through Cloudflare)."

    # One pair of scratch files for every request this stage makes. They are
    # created here (not inside a command substitution) and exported so nested
    # subshells reuse them; the exit trap removes them.
    if [ -z "$_CF_OUT" ]; then
        _CF_OUT=$(mktemp) || { warn 'Could not create a temporary file; DNS was not changed.'; return 1; }
        export _CF_OUT
    fi
    if [ -z "$_CF_HDR" ]; then
        _CF_HDR=$(mktemp) || { warn 'Could not create a temporary file; DNS was not changed.'; return 1; }
        chmod 600 "$_CF_HDR" 2>/dev/null || true
        export _CF_HDR
    fi
    if ! printf 'Authorization: Bearer %s\n' "$CF_API_TOKEN" > "$_CF_HDR"; then
        warn 'Could not write the API token header file; DNS was not changed.'
        return 1
    fi

    DNS_ZONE_ID=${CF_ZONE_ID:-}
    if [ -z "$DNS_ZONE_ID" ]; then
        info "Looking up the Cloudflare zone for $DOMAIN."
        DNS_ZONE_ID=$(cf_zone_id_for "$DOMAIN") || DNS_ZONE_ID=''
    fi
    if [ -z "$DNS_ZONE_ID" ]; then
        warn 'Could not resolve the Cloudflare zone id. The token needs Zone -> Read,'
        warn 'or set CF_ZONE_ID so no lookup is required. DNS records were not changed.'
        return 1
    fi

    if [ "${1:-}" != 'pre-approved' ]; then
        if ! confirm "Create missing A records for$_sd_hosts -> $_sd_ip (proxied)?"; then
            info 'Cancelled; DNS was not changed.'
            return 0
        fi
    fi

    _sd_failed=0
    for _sd_name in $_sd_hosts; do
        dns_upsert_a "$_sd_name" "$_sd_ip" || _sd_failed=1
    done
    if [ "$_sd_failed" = 0 ]; then
        ok 'DNS A records are in place.'
    else
        warn 'Some DNS records need attention; check the messages above.'
    fi
    return "$_sd_failed"
}

ensure_dns_base_config() {   # root domain and Cloudflare token only
    MISSING_ENV=''
    collect DOMAIN 'Root domain (e.g. example.com)' '' v_domain
    DOMAIN=$(printf '%s' "${DOMAIN:-}" | tr '[:upper:]' '[:lower:]')
    DOMAIN=${DOMAIN%.}
    collect_secret CF_API_TOKEN 'Cloudflare API token' v_token
    [ -z "$MISSING_ENV" ] || die "--non-interactive needs these environment variables:$MISSING_ENV"
    DNS_ZONE_ID=${CF_ZONE_ID:-${DNS_ZONE_ID:-}}
    if [ -z "$DNS_ZONE_ID" ]; then
        info "Looking up the Cloudflare zone for $DOMAIN."
        DNS_ZONE_ID=$(cf_zone_id_for "$DOMAIN") || DNS_ZONE_ID=''
        if [ -z "$DNS_ZONE_ID" ]; then
            warn "Could not find the zone ID for $DOMAIN; check token permissions."
            return 1
        fi
    fi
    return 0
}

render_dns_table() {   # $1 = file containing Cloudflare dns_records JSON response
    jq -r '.result[] | [ (.name // "-"), (.type // "-"), (.content // "-"), ((.proxied // false) | tostring) ] | @tsv' "$1" 2>/dev/null | \
    awk -F '\t' '
    BEGIN {
        printf "%-32s  %-8s  %-36s\n", "DNS RECORD", "TYPE", "FORWARD TO"
        printf "%-32s  %-8s  %-36s\n", "--------------------------------", "--------", "------------------------------------"
    }
    {
        rec_name = $1
        rec_type = $2
        rec_target = $3
        is_proxied = $4
        if (is_proxied == "true") {
            target_str = rec_target " (Proxied)"
        } else if (rec_type == "A" || rec_type == "AAAA" || rec_type == "CNAME") {
            target_str = rec_target " (DNS only)"
        } else {
            target_str = rec_target
        }
        printf "%-32s  %-8s  %-36s\n", rec_name, rec_type, target_str
    }
    END {
        printf "%-32s  %-8s  %-36s\n", "--------------------------------", "--------", "------------------------------------"
    }'
}

dns_records_list() {
    hdr 'Cloudflare DNS records'
    ensure_dns_base_config || return 1
    info "Fetching DNS records for zone $DOMAIN..."
    cf_api GET "/zones/$DNS_ZONE_ID/dns_records?per_page=100"
    if [ "$_cf_status" != 200 ]; then
        err "Could not fetch DNS records (HTTP $_cf_status)$( [ -s "$_CF_OUT" ] && printf ': %s' "$(cf_api_error)" )."
        return 1
    fi
    _rec_count=$(jq -r '.result | length' "$_CF_OUT" 2>/dev/null) || _rec_count=0
    case $_rec_count in
        ''|*[!0-9]*) _rec_count=0 ;;
    esac
    if [ "$_rec_count" -eq 0 ]; then
        info "No DNS records found for zone $DOMAIN."
        return 0
    fi
    say ''
    render_dns_table "$_CF_OUT"
    say ''
    ok "Total records: $_rec_count"
    return 0
}

show_dns_records() {
    hdr 'Show DNS Records'
    if [ -n "${DOMAIN:-}" ]; then
        menu_ask "Domain name [$DOMAIN]: "
        _sd_name=${_choice:-$DOMAIN}
    else
        menu_ask 'Domain name (e.g. example.com) [required]: '
        _sd_name=${_choice:-}
    fi
    [ -n "$_sd_name" ] || { warn 'Domain name cannot be empty.'; return 1; }
    _sd_name=$(printf '%s' "$_sd_name" | tr '[:upper:]' '[:lower:]')
    _sd_name=${_sd_name%.}
    v_domain "$_sd_name" || { warn "Invalid domain name: $_sd_name"; return 1; }
    if [ "$_sd_name" != "${DOMAIN:-}" ]; then
        DOMAIN=$_sd_name
        DNS_ZONE_ID=''
    fi
    if [ -n "${CF_API_TOKEN:-}" ]; then
        menu_ask "Cloudflare API token [press Enter to use cached token]: "
        if [ -n "$_choice" ]; then
            v_token "$_choice" || { warn 'Invalid token.'; return 1; }
            CF_API_TOKEN=$_choice
            DNS_ZONE_ID=''
        fi
    else
        collect_secret CF_API_TOKEN 'Cloudflare API token' v_token
    fi
    dns_records_list
}

show_all_domains() {
    hdr 'Show All Domains'
    if [ -n "${CF_API_TOKEN:-}" ]; then
        menu_ask "Cloudflare API token [press Enter to use cached token]: "
        if [ -n "$_choice" ]; then
            v_token "$_choice" || { warn 'Invalid token.'; return 1; }
            CF_API_TOKEN=$_choice
        fi
    else
        collect_secret CF_API_TOKEN 'Cloudflare API token' v_token
    fi
    menu_ask 'Cloudflare Account ID or Zone ID (optional, press Enter to list all zones): '
    _cf_input_id=${_choice:-}

    info 'Looking up domains from Cloudflare...'
    if [ -n "$_cf_input_id" ]; then
        cf_api GET "/zones?account.id=$_cf_input_id&per_page=50"
        if [ "$_cf_status" != 200 ] || [ "$(jq -r 'if (.result | type) == "array" then (.result | length) else 0 end' "$_CF_OUT" 2>/dev/null || printf 0)" = 0 ]; then
            cf_api GET "/zones/$_cf_input_id"
        fi
    else
        cf_api GET '/zones?per_page=50'
    fi

    if [ "$_cf_status" != 200 ]; then
        err "Could not lookup domains (HTTP $_cf_status)$( [ -s "$_CF_OUT" ] && printf ': %s' "$(cf_api_error)" )."
        return 1
    fi

    _zone_list_tmp=$(mktemp) || { warn 'Cannot create temporary file.'; return 1; }
    jq -r 'if (.result | type) == "array" then .result[] | "\(.id)\t\(.name)" elif (.result | type) == "object" and .result.id then "\(.result.id)\t\(.result.name)" else empty end' "$_CF_OUT" 2>/dev/null > "$_zone_list_tmp"

    if [ ! -s "$_zone_list_tmp" ]; then
        rm -f "$_zone_list_tmp"
        info 'No domains found for this Cloudflare account/token.'
        return 0
    fi

    _total_zones=$(wc -l < "$_zone_list_tmp" | tr -d ' ')
    ok "Found $_total_zones domain(s)."

    while IFS="$(printf '\t')" read -r _zid _zname; do
        [ -n "$_zid" ] || continue
        say ''
        say "${C_BLD}========================================================================${C_RST}"
        say "${C_BLD}Domain: ${_zname} (Zone ID: ${_zid})${C_RST}"
        say "${C_BLD}========================================================================${C_RST}"
        cf_api GET "/zones/$_zid/dns_records?per_page=100"
        if [ "$_cf_status" != 200 ]; then
            warn "Could not fetch records for $_zname (HTTP $_cf_status)$( [ -s "$_CF_OUT" ] && printf ': %s' "$(cf_api_error)" )."
            continue
        fi
        _rcnt=$(jq -r '.result | length' "$_CF_OUT" 2>/dev/null) || _rcnt=0
        case $_rcnt in
            ''|*[!0-9]*) _rcnt=0 ;;
        esac
        if [ "$_rcnt" -eq 0 ]; then
            info "No DNS records found for $_zname."
        else
            render_dns_table "$_CF_OUT"
            ok "Total records for $_zname: $_rcnt"
        fi
    done < "$_zone_list_tmp"
    rm -f "$_zone_list_tmp"
    return 0
}

dns_record_add_interactive() {
    hdr 'Add Cloudflare DNS record'
    ensure_dns_base_config || return 1
    menu_ask 'Record type [A/AAAA/CNAME/TXT, default A]: '
    _add_type=${_choice:-A}
    _add_type=$(printf '%s' "$_add_type" | tr '[:lower:]' '[:upper:]')
    case $_add_type in
        A|AAAA|CNAME|TXT) ;;
        *) warn "Unsupported record type: $_add_type (supported: A, AAAA, CNAME, TXT)"; return 1 ;;
    esac
    menu_ask "Record name (subdomain or '@' for root) [required]: "
    _add_name=${_choice:-}
    [ -n "$_add_name" ] || { warn 'Record name cannot be empty.'; return 1; }
    if [ "$_add_name" = '@' ] || [ "$_add_name" = "$DOMAIN" ]; then
        _add_fqdn="$DOMAIN"
    elif case "$_add_name" in *."$DOMAIN") true ;; *) false ;; esac; then
        _add_fqdn="$_add_name"
    else
        _add_fqdn="${_add_name}.${DOMAIN}"
    fi
    _add_fqdn=$(printf '%s' "$_add_fqdn" | tr '[:upper:]' '[:lower:]')

    _def_target=''
    if [ "$_add_type" = A ]; then
        _def_target=$(detect_public_ip)
    fi
    if [ -n "$_def_target" ]; then
        menu_ask "Forward to (IPv4 target) [$_def_target]: "
        _add_target=${_choice:-$_def_target}
    else
        menu_ask 'Forward to (target IP / hostname / value) [required]: '
        _add_target=${_choice:-}
    fi
    [ -n "$_add_target" ] || { warn 'Forward target cannot be empty.'; return 1; }
    if [ "$_add_type" = A ]; then
        v_ipv4 "$_add_target" || { warn "Invalid IPv4 address: $_add_target"; return 1; }
    fi

    _add_proxied=false
    if [ "$_add_type" = A ] || [ "$_add_type" = AAAA ] || [ "$_add_type" = CNAME ]; then
        if confirm 'Enable Cloudflare proxy (orange cloud)?'; then
            _add_proxied=true
        else
            _add_proxied=false
        fi
    fi

    _add_payload=$(jq -nc \
        --arg type "$_add_type" \
        --arg name "$_add_fqdn" \
        --arg content "$_add_target" \
        --argjson proxied "$_add_proxied" \
        '{type: $type, name: $name, content: $content, ttl: 1, proxied: $proxied}')
    cf_api POST "/zones/$DNS_ZONE_ID/dns_records" "$_add_payload"
    if [ "$_cf_status" = 200 ] || [ "$_cf_status" = 201 ]; then
        ok "Created $_add_type record: $_add_fqdn -> $_add_target (proxied: $_add_proxied)"
    else
        err "Could not create DNS record (HTTP $_cf_status)$( [ -s "$_CF_OUT" ] && printf ': %s' "$(cf_api_error)" )."
        return 1
    fi
}

ensure_dns_config() {   # scoped answers for the DNS action: hosts + token
    hdr 'DNS configuration'
    MISSING_ENV=''
    collect DOMAIN 'Root domain (e.g. example.com)' '' v_domain
    DOMAIN=$(printf '%s' "${DOMAIN:-}" | tr '[:upper:]' '[:lower:]')
    DOMAIN=${DOMAIN%.}
    collect SUB 'Sub-domain prefix for the panel and subscription (e.g. sub)' 'sub' v_label
    SUB=$(printf '%s' "$SUB" | tr '[:upper:]' '[:lower:]')
    collect CAMO_SUB 'Sub-domain prefix for the camouflage site (e.g. suboff)' 'suboff' v_label
    CAMO_SUB=$(printf '%s' "$CAMO_SUB" | tr '[:upper:]' '[:lower:]')
    collect_secret CF_API_TOKEN 'Cloudflare API token' v_token
    [ -z "$MISSING_ENV" ] || die "--non-interactive needs these environment variables:$MISSING_ENV"
    derive_names
}

dns_manage() {
    ensure_dns_config
    if stage_dns_records; then
        ok 'DNS records are configured.'
    else
        warn 'DNS records may need manual attention in the Cloudflare dashboard.'
    fi
    return 0
}

stage_firewall() {
    hdr 'Firewall'
    if ! have ufw; then
        warn 'ufw is not installed, so nothing was opened automatically.'
        warn 'Only 80 and 443 need to be reachable from the internet.'
        return 0
    fi
    if ! ufw status 2>/dev/null | grep -q 'Status: active'; then
        info 'ufw is installed but not active, leaving it alone.'
        info 'When you enable it, only allow 80 and 443 - the panel and the'
        info 'subscription service must stay bound to loopback; do not expose their ports.'
        return 0
    fi
    ufw allow 80/tcp || die 'Could not allow HTTP in ufw.'
    ufw allow 443/tcp || die 'Could not allow HTTPS in ufw.'
    ok 'ufw: 80 and 443 allowed. Panel and subscription use loopback listeners; other firewall rules were preserved.'
}

# --- verification ------------------------------------------------------------
check() {   # $1 = ok|warn|fail, $2 = label, $3 = detail
    case $1 in
        ok)   printf '  %s[ ok ]%s %-26s %s\n' "$C_GRN" "$C_RST" "$2" "$3"; PASS_COUNT=$((PASS_COUNT + 1)) ;;
        warn) printf '  %s[warn]%s %-26s %s\n' "$C_YLW" "$C_RST" "$2" "$3"; FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
        *)    printf '  %s[fail]%s %-26s %s\n' "$C_RED" "$C_RST" "$2" "$3"; FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    esac
}

http_code() {   # extra curl arguments are appended by the caller
    _hc=''
    _hc=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null) || _hc='000'
    printf '%s' "$_hc"
}

stage_verify() {
    PASS_COUNT=0
    FAIL_COUNT=0
    hdr 'Verification'

    _ver=$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9][0-9.]*\).*|\1|p')
    if [ -n "$_ver" ]; then
        check ok 'nginx version' "$_ver"
    else
        check warn 'nginx version' 'could not be read'
    fi

    if nginx -t >/dev/null 2>&1; then
        check ok 'nginx -t' 'configuration is valid'
    else
        check fail 'nginx -t' 'configuration is invalid'
    fi

    if systemctl is-active nginx >/dev/null 2>&1; then
        check ok 'nginx service' 'active'
    else
        check fail 'nginx service' 'not running'
    fi

    if have ss; then
        _listen=$(ss -lnt 2>/dev/null | awk 'NR>1 {print $4}' | grep -E ':(80|443|4443)$' | tr '\n' ' ')
        if [ -n "$_listen" ]; then
            check ok 'nginx listeners' "$_listen"
        else
            check fail 'nginx listeners' 'nothing on 80/443/4443'
        fi
    fi

    _tls=$(openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *//p') || _tls=''
    if [ -f "$CERT_DIR/fullchain.pem" ] && [ -f "$CERT_DIR/privkey.pem" ]; then
        check ok 'certificate files' "$CERT_DIR (CN=${_tls:-unknown})"
    else
        check fail 'certificate files' "$CERT_DIR is incomplete"
    fi

    _code=$(http_code --resolve "$DOMAIN:80:127.0.0.1" "http://$DOMAIN/")
    case $_code in
        301|302|307|308) check ok 'http -> https redirect' "port 80 answers $_code" ;;
        000) check warn 'http -> https redirect' 'no answer on port 80' ;;
        *) check warn 'http -> https redirect' "unexpected code $_code" ;;
    esac

    _code=$(http_code --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/")
    case $_code in
        200) check ok 'camouflage site (443)' "https://$DOMAIN/ answers 200" ;;
        000) check fail 'camouflage site (443)' 'no TLS answer on 443 (stream module?)' ;;
        *) check warn 'camouflage site (443)' "answers $_code" ;;
    esac

    _code=$(http_code --resolve "$SUB_FQDN:443:127.0.0.1" "https://$SUB_FQDN$PANEL_PATH")
    case $_code in
        200|302|303) check ok 'panel through nginx' "https://$SUB_FQDN$PANEL_PATH answers $_code" ;;
        000) check fail 'panel through nginx' 'no answer, check nginx logs and the panel port' ;;
        502|504) check fail 'panel through nginx' "upstream error $_code, the panel is not on 127.0.0.1:$PANEL_PORT" ;;
        404) check warn 'panel through nginx' "404, the panel base path is not $PANEL_PATH"
             warn "  either set the panel base path to $PANEL_PATH, or re-run with PANEL_PATH set to the actual one" ;;
        *) check warn 'panel through nginx' "answers $_code" ;;
    esac

    _code=$(http_code "http://127.0.0.1:$SUB_PORT$SUB_PATH")
    case $_code in
        000) check fail 'subscription service' "127.0.0.1:$SUB_PORT does not answer" ;;
        *) check ok 'subscription service' "127.0.0.1:$SUB_PORT answers $_code" ;;
    esac

    _verify_cert_mode=$(certificate_mode_on_disk)
    if [ "$_verify_cert_mode" = origin ]; then
        check warn 'Origin CA trust' 'Cloudflare-proxied HTTPS only; track certificate expiry yourself'
    elif [ "$_verify_cert_mode" = le ]; then
        if grep -q 'CF_Token' "$ACME_HOME/account.conf" 2>/dev/null; then
            check ok 'renewal credentials' 'Cloudflare token stored by acme.sh; renewal job not verified'
        else
            check warn 'renewal credentials' 'CF_Token not found in account.conf'
        fi
    else
        check warn 'certificate type' 'No Origin CA or acme.sh metadata found; renewal method unknown'
    fi
}

print_final_notes() {
    hdr 'Done'
    say "  panel          https://$SUB_FQDN$PANEL_PATH"
    say "  login          $PANEL_USER / $PANEL_PASS"
    say "  subscription   https://$SUB_FQDN$SUB_PATH<subId>"
    say "  certificate    $CERT_DIR/fullchain.pem"
    say "  backups        $BACKUP_DIR"
    say ''
    say "${C_BLD}Next steps${C_RST}"
    say "  1. Cloudflare DNS: the panel/camouflage A records were created by this"
    say "     run (or check option 9). Add the apex record for $DOMAIN yourself if"
    say '     it does not exist yet.'
    say '     Proxied (orange) works only for HTTP based transports'
    say '     (ws / grpc / httpupgrade); REALITY and other raw TCP inbounds need a'
    say '     DNS-only (grey) record, and the client connects straight to the IP.'
    say '     If you proxy through Cloudflare, set SSL/TLS mode to Full (strict).'
    say "  2. In 3x-ui, create inbounds listening on 127.0.0.1 with the ports your"
    say '     nginx.conf stream map expects (10001, 10002, 10003, 10000, 20000,'
    say '     30000, 40000). Do not bind anything to 443: nginx owns 443 and routes'
    say '     by SNI.'
    say "  3. Subscription: the panel is configured for port $SUB_PORT and path $SUB_PATH."
    if [ "$SUB_PORT" != '8443' ]; then
        say "     proxy.conf was patched to proxy /s/ to 127.0.0.1:$SUB_PORT."
    fi
    say '  4. The panel listens on 127.0.0.1 only. If nginx is ever down, use an SSH'
    say "     tunnel: ssh -L 8080:127.0.0.1:$PANEL_PORT root@<server> and open"
    say "     http://127.0.0.1:8080$PANEL_PATH"
    say ''
    if [ "$FAIL_COUNT" -gt 0 ]; then
        warn "$FAIL_COUNT check(s) need attention, see the list above."
    else
        ok 'All checks passed.'
    fi
    if [ "$GENERATED_PASSWORD" = 1 ]; then
        warn 'The panel password was generated for you, store it somewhere safe now.'
    fi
    say ''
    say 'Logs: journalctl -u nginx -u x-ui -n 50 --no-pager'
}

# --- dry run -----------------------------------------------------------------
render_only() {
    hdr 'Dry run: rendering the configuration only'
    if [ -z "$RENDER_OUT" ]; then
        RENDER_OUT="$PWD/rendered-configs"
    fi
    mkdir -p "$RENDER_OUT" || die "Could not create $RENDER_OUT"
    render_template "$NGINX_TEMPLATE" "$RENDER_OUT/nginx.conf" 'nginx.conf'
    render_template "$PROXY_TEMPLATE" "$RENDER_OUT/proxy.conf" 'proxy.conf' subport
    ok "rendered: $RENDER_OUT/nginx.conf"
    ok "rendered: $RENDER_OUT/proxy.conf"
    say ''
    info 'Subscription and panel upstream lines:'
    grep -nE 'proxy_pass http://127\.0\.0\.1:(8443|[0-9]+)' "$RENDER_OUT/proxy.conf" | sed 's/^/    /' || true
    say ''
    ok 'Nothing on this system was changed.'
}

# --- interactive menu ---------------------------------------------------------
CONFIG_LOADED=0
CERT_CONFIG_LOADED=0
CERT_CONFIG_MODE=''

validate_live_paths() {
    if [ "$NGINX_MAIN_CONF" != /etc/nginx/nginx.conf ] ||
       [ "$NGINX_CONF_D" != /etc/nginx/conf.d ] ||
       [ "$CERT_BASE" != /root/cert ] || [ "$WEB_ROOT" != /var/www/goldcalc ] ||
       [ "$ACME_HOME" != /root/.acme.sh ]; then
        die 'Nondefault live NGINX_MAIN_CONF, NGINX_CONF_D, CERT_BASE, WEB_ROOT or ACME_HOME paths are unsupported. Use defaults; overrides are for dry-run/library tests only.'
    fi
}

require_root() {
    validate_live_paths
    if [ "$(id -u)" != 0 ]; then
        die 'This action needs root privileges. Re-run as root.'
    fi
}

ensure_os() {
    if [ -z "$OS_FAMILY" ]; then
        detect_os
        ok "distribution: ${PRETTY_NAME:-$OS_ID} ($OS_FAMILY packages)"
    fi
}

ensure_config() {   # ask the configuration questions once per menu session
    if [ "$CONFIG_LOADED" = 0 ]; then
        collect_inputs
        validate_combination
        CONFIG_LOADED=1
        CERT_CONFIG_MODE=$CERT_MODE
    fi
    derive_names
}

# Certificate actions: domain + certificate answers only. The cached answers
# are tied to the certificate mode they were collected for, so switching
# between origin and le clears the mode-specific answers (the LE email) and
# re-asks them; the token is kept since it belongs to the zone, not the mode.
ensure_cert_config() {
    if [ "$CERT_CONFIG_MODE" = "$CERT_MODE" ]; then
        if [ "$CONFIG_LOADED" = 1 ] || [ "$CERT_CONFIG_LOADED" = 1 ]; then
            derive_names
            return 0
        fi
    fi
    if [ -n "$CERT_CONFIG_MODE" ]; then
        ACME_EMAIL=''
        info "Certificate mode changed to $CERT_MODE; answering its questions again."
    fi
    collect_cert_inputs
    CERT_CONFIG_LOADED=1
    CERT_CONFIG_MODE=$CERT_MODE
}

reset_config() {
    DOMAIN=''; SUB=''; CAMO_SUB=''; PANEL_PORT=''; SUB_PORT=''
    PANEL_USER=''; PANEL_PASS=''; CF_API_TOKEN=''; CF_ZONE_ID=''
    ACME_EMAIL=''; CERT_MODE=''
    SUB_FQDN=''; CAMO_FQDN=''
    unset CF_Token CF_Zone_ID 2>/dev/null || :
    CF_Token=''; CF_Zone_ID=''; DNS_ZONE_ID=''
    [ -z "$_CF_HDR" ] || rm -f "$_CF_HDR"
    _CF_HDR=''
    [ -z "$_CF_OUT" ] || rm -f "$_CF_OUT"
    _CF_OUT=''
    GENERATED_PASSWORD=0
    PASS_COUNT=0
    FAIL_COUNT=0
    CONFIG_LOADED=0
    CERT_CONFIG_LOADED=0
    CERT_CONFIG_MODE=''
    info 'Answers cleared; the questions are asked again when they are needed.'
}

ensure_domain() {   # light context for certificate status: domain only
    MISSING_ENV=''
    collect DOMAIN 'Root domain (the certificate owner, e.g. example.com)' '' v_domain
    [ -z "$MISSING_ENV" ] || die "--non-interactive needs these environment variables:$MISSING_ENV"
    DOMAIN=$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]')
    CERT_DIR="$CERT_BASE/$DOMAIN"
}

install_base_tools() {
    for _tool in curl sed awk grep jq; do
        if ! have "$_tool"; then
            info "installing missing tool: $_tool"
            pkg_install "$_tool" || die "Could not install $_tool."
        fi
    done
}

menu_ask() {
    printf '%s' "$1"
    if ! IFS= read -r _choice; then
        say ''
        die 'Input ended; leaving the menu.'
    fi
}

menu_item() {   # $1 = number, $2 = label; numbers bold cyan, 0 bold red
    if [ "$1" = 0 ]; then
        printf '  %s%s%s)%s %s\n' "${C_BLD}${C_RED}" "$1" "$C_RST" "$C_RST" "$2"
    else
        printf '  %s%s%s)%s %s\n' "${C_BLD}${C_CYN}" "$1" "$C_RST" "$C_RST" "$2"
    fi
}

# --- nginx menu actions -------------------------------------------------------
# Edit only the inline stream map used by this project. Unknown map syntax is
# rejected rather than risking edits to another context or an included file.
sni_map() {   # $1 = list|add|remove, $2 = input, $3/$4 = hostname/port
    awk -v action="$1" -v name="${3:-}" -v port="${4:-}" '
    function fail(message) { print "SNI map: " message > "/dev/stderr"; bad=1; exit 1 }
    function lex(line,    i,c,q,word,n,started) {
        n=0; q=""; word=""; started=0
        for (i=1; i<=length(line); i++) {
            c=substr(line,i,1)
            if (q!="") {
                if (c=="\\") { word=word c substr(line,++i,1); continue }
                if (c==q) { q=""; continue }
                word=word c; continue
            }
            if (c=="#") break
            if (c=="\"" || c==sprintf("%c",39)) { q=c; started=1; continue }
            if (c ~ /[ \t\r]/ || c ~ /[{};]/) {
                if (started) { t[++n]=word; structural[n]=0; word=""; started=0 }
                if (c ~ /[{};]/) { t[++n]=c; structural[n]=1 }
            } else { word=word c; started=1 }
        }
        if (q!="") fail("multiline quotes are not supported; edit this configuration manually.")
        if (started) { t[++n]=word; structural[n]=0 }
        return n
    }
    {
        raw[NR]=$0
        n=lex($0)
        if (inside) {
            if (n==1 && structural[1] && t[1]=="}") { inside=0; closing=NR }
            else if (n>0) {
                if (n==2 && t[1]=="hostnames" && structural[2] && t[2]==";") { }
                else if (n==3 && !structural[1] && !structural[2] && structural[3] && t[3]==";") {
                    key=tolower(t[1]); backend=t[2]
                    if (key=="include") fail("included map entries are not supported; edit the map manually.")
                    if (key!="default") {
                        if (key !~ /^[a-z0-9*.-]+$/) fail("only literal hostname entries are supported.")
                        if (seen[key]++) fail("duplicate hostname: " key)
                        display=backend
                        if (backend ~ /:[0-9]+$/) sub(/^.*:/,"",display)
                        count++; names[count]=t[1]; ports[count]=display; backends[count]=backend; rows[count]=NR
                        if (key==name) { found=NR; oldbackend=backend }
                    }
                } else fail("expected one hostname/backend entry per line.")
            }
        } else if (n>=2 && t[1]=="map" && t[2]=="$ssl_preread_server_name" && context[depth]=="stream") {
            if (n!=4 || t[3]!="$backend_name" || !structural[4] || t[4]!="{")
                fail("expected map $ssl_preread_server_name $backend_name { on one line.")
            maps++; inside=1
        }
        for (j=1; j<=n; j++) {
            if (!structural[j]) continue
            if (t[j]=="{") { depth++; context[depth]=(j>1 ? t[j-1] : "") }
            if (t[j]=="}") { delete context[depth]; depth--; if (depth<0) fail("unbalanced braces.") }
        }
    }
    END {
        if (bad) exit 1
        if (maps!=1 || inside || depth!=0) fail("expected exactly one complete inline SNI stream map.")
        if (action=="list" || action=="selection") {
            for (i=1; i<=count; i++) printf "%d. %s %s\n",i,names[i],(action=="selection" ? backends[i] : ports[i])
            exit
        }
        if (action=="add" && found) fail("hostname already exists; remove it before changing its port.")
        if (action=="remove" && !found) fail("hostname no longer exists; refresh the list.")
        if (action=="remove" && port!="" && oldbackend!=port) fail("the selected backend changed; refresh the list.")
        for (i=1; i<=NR; i++) {
            if (action=="add" && i==closing) printf "        %s    127.0.0.1:%s;\n",name,port
            if (action!="remove" || i!=found) print raw[i]
        }
    }' "$2"
}

sni_restore() {
    if cp -p "$_sni_backup" "$_sni_candidate" && mv -f "$_sni_candidate" "$NGINX_MAIN_CONF"; then
        _sni_active=0
        warn "Previous nginx.conf restored. Backup: $_sni_backup"
    else
        err "Could not restore nginx.conf! Restore $_sni_backup manually."
        return 1
    fi
}

sni_transaction_cleanup() {
    _sni_cleanup_failed=0
    if [ "$_sni_active" = 1 ]; then
        if sni_restore; then
            if [ "$_sni_reload_attempted" = 1 ]; then
                systemctl reload nginx || err 'Could not reload the restored config; check nginx service status.'
            fi
        else
            _sni_cleanup_failed=1
        fi
    fi
    if [ -n "$_sni_candidate" ]; then rm -f "$_sni_candidate" || _sni_cleanup_failed=1; fi
    if [ -n "$_sni_work" ]; then rm -rf "$_sni_work" || _sni_cleanup_failed=1; fi
    if [ "$_sni_locked" = 1 ]; then rmdir "$NGINX_MAIN_CONF.sni-lock" || _sni_cleanup_failed=1; fi
    [ "$_sni_cleanup_failed" = 0 ]
}

sni_update() (   # Isolate transaction state and traps from the installer.
    require_root
    _sni_active=0 _sni_candidate='' _sni_work='' _sni_locked=0 _sni_reload_attempted=0
    trap 'sni_transaction_cleanup' 0
    trap 'exit 130' INT
    trap 'exit 143' TERM
    [ ! -L "$NGINX_MAIN_CONF" ] || { err 'SNI editing does not replace symlinked configs.'; exit 1; }
    [ -f "$NGINX_MAIN_CONF" ] || { err "Config not found: $NGINX_MAIN_CONF"; exit 1; }
    have nginx || { err 'nginx is not installed.'; exit 1; }
    case $1 in
        add) v_domain "$2" && v_port "$3" || exit 1 ;;
        remove) : ;;
        *) exit 1 ;;
    esac
    if ! mkdir "$NGINX_MAIN_CONF.sni-lock"; then
        err "SNI editing is locked: $NGINX_MAIN_CONF.sni-lock. Another edit may be running."
        exit 1
    fi
    _sni_locked=1
    _sni_name=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
    _sni_work=$(mktemp -d) || exit 1
    cp -p "$NGINX_MAIN_CONF" "$_sni_work/original" || exit 1
    sni_map "$1" "$_sni_work/original" "$_sni_name" "${3:-}" > "$_sni_work/rendered" || exit 1
    cmp -s "$NGINX_MAIN_CONF" "$_sni_work/original" || { err 'nginx.conf changed; try again.'; exit 1; }
    nginx -t -c "$NGINX_MAIN_CONF" || { err 'Existing nginx config is invalid; nothing changed.'; exit 1; }
    mkdir -p "$BACKUP_BASE" || exit 1
    _sni_backup_dir=$(mktemp -d "$BACKUP_BASE/nginx-sni-backup-$(date +%Y%m%d-%H%M%S)-XXXXXX") || exit 1
    _sni_backup="$_sni_backup_dir/nginx.conf"
    cp -p "$_sni_work/original" "$_sni_backup" || exit 1
    _sni_candidate=$(mktemp "${NGINX_MAIN_CONF%/*}/.nginx-sni-XXXXXX") || exit 1
    cp -p "$_sni_work/original" "$_sni_candidate" || exit 1
    cat "$_sni_work/rendered" > "$_sni_candidate" || exit 1
    cmp -s "$NGINX_MAIN_CONF" "$_sni_work/original" || { err 'nginx.conf changed; try again.'; exit 1; }
    _sni_active=1
    mv -f "$_sni_candidate" "$NGINX_MAIN_CONF" || exit 1
    nginx -t -c "$NGINX_MAIN_CONF" || { err 'New config failed validation; rolling back.'; exit 1; }
    if systemctl is-active --quiet nginx; then
        _sni_reload_attempted=1
        if ! systemctl reload nginx; then
            err 'nginx reload failed; rolling back.'
            sni_restore || exit 1
            systemctl reload nginx || err 'Could not reload the restored config; check nginx service status.'
            exit 1
        fi
        ok 'SNI configuration saved and nginx reloaded.'
    else
        warn 'SNI configuration saved and validated. nginx is stopped; it was not started.'
    fi
    _sni_active=0
    ok "Backup: $_sni_backup"
)

sni_show() {
    hdr "SNI entries in $NGINX_MAIN_CONF"
    if [ ! -f "$NGINX_MAIN_CONF" ]; then
        warn "Config not found: $NGINX_MAIN_CONF"
        return 1
    fi
    _sni_list=$(sni_map selection "$NGINX_MAIN_CONF") || return 1
    if [ -n "$_sni_list" ]; then
        printf '%s\n' "$_sni_list" | awk '{ backend=$3; if (backend ~ /:[0-9]+$/) sub(/^.*:/,"",backend); print $1, $2, backend }'
    else
        info 'No SNI entries. The default fallback is not listed or removed.'
    fi
}

sni_remove() {
    sni_show || return 0
    [ -n "$_sni_list" ] || return 0
    menu_ask 'Select an SNI number to remove (0 = back): '
    case $_choice in
        0|q|Q) return 0 ;;
        ''|*[!0-9]*) warn 'Enter a number from the list.'; return 0 ;;
    esac
    _sni_selected=$(printf '%s\n' "$_sni_list" | awk -v pick="$_choice." '$1==pick {print $2}')
    [ -n "$_sni_selected" ] || { warn 'No SNI with that number.'; return 0; }
    warn "Removing $_sni_selected changes its routing to the default fallback."
    confirm "Remove $_sni_selected?" || { info 'Cancelled.'; return 0; }
    _sni_selected_backend=$(printf '%s\n' "$_sni_list" | awk -v pick="$_choice." '$1==pick {print $3}')
    sni_update remove "$_sni_selected" "$_sni_selected_backend" || warn 'SNI removal did not complete.'
}

sni_add() {
    menu_ask 'SNI hostname (e.g. play.google.com; 0 = back): '
    [ "$_choice" != 0 ] || return 0
    _sni_add_name=$_choice
    v_domain "$_sni_add_name" || return 0
    menu_ask 'Local upstream port (1-65535; 0 = back): '
    [ "$_choice" != 0 ] || return 0
    v_port "$_choice" || return 0
    sni_update add "$_sni_add_name" "$_choice" || warn 'SNI addition did not complete.'
}

sni_menu() {
    while :; do
        say ''
        say "${C_BLD}--- SNI management ---${C_RST}"
        menu_item 1 'Show all (select an SNI to remove)'
        menu_item 2 'Add new'
        menu_item 3 'Remove'
        menu_item 0 'Back'
        menu_ask 'Select: '
        case $_choice in
            1|3) sni_remove ;;
            2) sni_add ;;
            0|q|Q) return 0 ;;
            *) warn "unknown option: $_choice" ;;
        esac
    done
}

nginx_status() {
    hdr 'nginx status'
    if ! have nginx; then
        err 'nginx is not installed, please install it first to continue.'
        return 0
    fi
    say "  version   $(nginx -v 2>&1)"
    if nginx -t >/dev/null 2>&1; then
        ok 'configuration test (nginx -t) passes'
    else
        err 'configuration test FAILS:'
        nginx -t 2>&1 || true
    fi
    if systemctl is-active --quiet nginx 2>/dev/null; then
        ok 'service is active'
    else
        warn 'service is not running (systemctl status nginx)'
    fi
    if have ss; then
        _ns_l=$(ss -lntp 2>/dev/null | awk '/nginx/ {print $4}' | grep -E ':(80|443|4443)$' | tr '\n' ' ')
        if [ -z "$_ns_l" ] && systemctl is-active --quiet nginx 2>/dev/null; then
            _ns_l=$(ss -lnt 2>/dev/null | awk '{print $4}' | grep -E ':(80|443|4443)$' | tr '\n' ' ')
        fi
        if [ -n "$_ns_l" ]; then
            ok "listening on: $_ns_l"
        else
            warn 'no nginx listeners on 80/443/4443'
        fi
    fi
    return 0
}

nginx_install_menu() {
    require_root
    ensure_os
    install_base_tools
    stage_nginx
}

nginx_uninstall() {
    if ! have nginx; then
        warn 'nginx is not installed.'
        return 0
    fi
    require_root
    warn 'This removes the nginx package and the nginx.org repository files.'
    warn 'Rendered configs stay in /etc/nginx; VPN routing stops until nginx is back.'
    confirm 'Really uninstall nginx?' || { info 'Cancelled.'; return 0; }
    ensure_os
    case $OS_FAMILY in
        deb)
            if apt-get remove -y -qq nginx; then
                rm -f /etc/apt/sources.list.d/nginx.list /etc/apt/preferences.d/99nginx
            else
                die 'Removing the nginx package failed; the repository files were kept.'
            fi ;;
        rpm)
            if dnf remove -y -q nginx; then
                rm -f /etc/yum.repos.d/nginx.repo
            else
                die 'Removing the nginx package failed; the repository files were kept.'
            fi ;;
    esac
    ok 'nginx removed. Files under /etc/nginx were kept.'
}

# --- 3x-ui menu actions -------------------------------------------------------
xui_status() {
    hdr '3x-ui status'
    if ! xui_installed; then
        warn '3x-ui is not installed.'
        return 0
    fi
    if systemctl is-active --quiet x-ui 2>/dev/null; then
        ok 'service is active'
    else
        warn 'service is not running (journalctl -u x-ui)'
    fi
    if have ss; then
        _xs_l=$(ss -lntp 2>/dev/null | awk '/x-ui|xray/ {print $4}' | tr '\n' ' ')
        if [ -z "$_xs_l" ] && systemctl is-active --quiet x-ui 2>/dev/null; then
            _xs_l=$(ss -lnt 2>/dev/null | awk -v pp="${PANEL_PORT:-}" -v sp="${SUB_PORT:-}" '
                (pp != "" && $4 ~ ":" pp "$") || (sp != "" && $4 ~ ":" sp "$") {print $4}
            ' | tr '\n' ' ')
        fi
        if [ -n "$_xs_l" ]; then
            ok "listening on: $_xs_l"
        else
            warn 'x-ui has no listening sockets'
        fi
    fi
    return 0
}

xui_install_menu() {
    require_root
    ensure_xui_config
    ensure_os
    install_base_tools
    stage_xui
}

xui_manage() {
    if ! have x-ui; then
        warn '3x-ui is not installed.'
        return 0
    fi
    x-ui
}

xui_conf_exists() { [ -d /etc/x-ui ]; }

xui_uninstall() {
    if ! xui_installed; then
        warn '3x-ui is not installed.'
        return 0
    fi
    require_root
    warn 'This stops the panel and deletes the binary, database and service.'
    warn 'All inbounds and settings are lost. A backup of /etc/x-ui is kept.'
    confirm 'Really uninstall 3x-ui?' || { info 'Cancelled.'; return 0; }
    # Stop first so the SQLite database is closed and the copy is consistent.
    systemctl disable --now x-ui >/dev/null 2>&1 \
        || systemctl stop x-ui >/dev/null 2>&1 \
        || true
    if xui_conf_exists; then
        _xu_stamp=$(date +%Y%m%d-%H%M%S)
        _xu_bak="$BACKUP_BASE/x-ui-backup-$_xu_stamp"
        mkdir -p "$BACKUP_BASE" \
            || die "Could not create $BACKUP_BASE; nothing was removed."
        if ! cp -a /etc/x-ui "$_xu_bak"; then
            die 'Backing up /etc/x-ui failed; nothing was removed. Free some disk space and retry.'
        fi
        if [ -f /etc/x-ui/x-ui.db ] && [ ! -f "$_xu_bak/x-ui.db" ]; then
            die 'The backup of /etc/x-ui is incomplete (x-ui.db missing); nothing was removed.'
        fi
        ok "Panel data backed up to $_xu_bak (service was stopped first)."
    else
        warn 'No /etc/x-ui directory found; there was nothing to back up.'
    fi
    rm -f /usr/bin/x-ui /etc/systemd/system/x-ui.service
    rm -rf /usr/local/x-ui /etc/x-ui
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed x-ui >/dev/null 2>&1 || true
    ok '3x-ui removed.'
}

# --- certificate menu actions -------------------------------------------------
cert_status() {
    hdr 'Certificate status'
    ensure_domain
    if [ ! -f "$CERT_DIR/fullchain.pem" ] || [ ! -f "$CERT_DIR/privkey.pem" ]; then
        warn "no certificate files in $CERT_DIR"
        return 0
    fi
    ls -l "$CERT_DIR"
    if ! have openssl; then
        warn 'openssl is not available; skipping the detailed check.'
        return 0
    fi
    openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -subject -issuer -dates
    openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -ext subjectAltName 2>/dev/null || true
    if openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -checkend 2592000 >/dev/null 2>&1; then
        ok 'valid for more than 30 days'
    else
        warn 'expires within 30 days!'
    fi
    case $(certificate_mode_on_disk) in
        origin) info 'type: Cloudflare Origin CA - no automatic renewal, reissue before expiry' ;;
        le)
            info 'type: acme.sh domain metadata found; check renewal job and credentials'
            if [ -x "$ACME_HOME/acme.sh" ]; then
                "$ACME_HOME/acme.sh" --list 2>/dev/null || true
            else
                warn "acme.sh is missing from $ACME_HOME; automatic renewal is unavailable"
            fi ;;
        *) warn 'no domain-specific certificate metadata; renewal method unknown' ;;
    esac
    return 0
}

cert_issue() {   # $1 = origin|le
    require_root
    CERT_MODE=$1
    ensure_cert_config
    ensure_os
    install_base_tools
    menu_install_attempt stage_certs
    if [ "$MENU_INSTALL_STATUS" -ne 0 ]; then
        err 'Certificate issuance did not complete.'
        return 1
    fi
    cert_status
}

deploy_configs() {
    require_root
    if ! have nginx; then
        warn 'nginx is not installed. It is required before deploying the VPN configs.'
        if ! confirm 'Install nginx now, then continue deployment?'; then
            info 'Deployment cancelled; nothing was changed.'
            return 0
        fi
        menu_install_attempt nginx_install_menu
        if [ "$MENU_INSTALL_STATUS" -ne 0 ]; then
            err 'nginx installation failed; deployment cancelled.'
            return 0
        fi
        if ! have nginx; then
            err 'nginx is still not available after the installation; deployment cancelled.'
            return 0
        fi
    fi
    nginx_check_version
    ensure_os
    nginx_stream_support
    ensure_render_config
    print_render_plan
    if ! confirm 'Deploy the nginx configuration now?'; then
        info 'Deployment cancelled.'
        return 0
    fi
    stage_deploy
    stage_verify
    ok 'Configuration deployment complete; existing panel credentials were not changed.'
}

# Isolate fatal installer errors from the interactive parent. Run this helper
# as a simple command (not an if/|| condition), preserving child errexit.
menu_install_attempt() {
    set +e
    (set -e; "$@")
    MENU_INSTALL_STATUS=$?
    set -e
}

xui_installed() { [ -x /usr/local/x-ui/x-ui ] || have x-ui; }

# --- the menus ----------------------------------------------------------------
nginx_menu() {
    if ! have nginx; then
        hdr 'nginx'
        err "nginx is not installed, please install it first to continue."
        if confirm 'Install nginx now?'; then
            menu_install_attempt nginx_install_menu
            if [ "$MENU_INSTALL_STATUS" -ne 0 ]; then
                err 'nginx installation failed; returning to the main menu.'
                return 0
            fi
            if ! have nginx; then
                err "nginx is not installed, please install it first to continue."
                return 0
            fi
            ok 'nginx is ready; opening the nginx menu.'
        else
            info 'Cancelled; nothing was changed.'
            return 0
        fi
    fi
    while :; do
        say ''
        say "${C_BLD}--- nginx ---${C_RST}"
        menu_item 1 'Install or update (nginx.org mainline)'
        menu_item 2 'Status (version, config test, service, ports)'
        menu_item 3 'Deploy the VPN configs (render, nginx -t, reload)'
        menu_item 4 'Uninstall'
        menu_item 5 'SNI management'
        menu_item 0 'Back'
        menu_ask 'Select: '
        case $_choice in
            1) menu_install_attempt nginx_install_menu
               [ "$MENU_INSTALL_STATUS" = 0 ] || err 'nginx installation failed.' ;;
            2) nginx_status ;;
            3) deploy_configs ;;
            4) nginx_uninstall ;;
            5) sni_menu ;;
            0|q|Q) return 0 ;;
            *) warn "unknown option: $_choice" ;;
        esac
    done
}

xui_menu() {
    if ! xui_installed; then
        hdr '3x-ui'
        err "3x-ui is not installed, please install it first to continue."
        if confirm 'Install 3x-ui now?'; then
            menu_install_attempt xui_install_menu
            if [ "$MENU_INSTALL_STATUS" -ne 0 ]; then
                err '3x-ui installation failed; returning to the main menu.'
                return 0
            fi
            if ! xui_installed; then
                err "3x-ui is not installed, please install it first to continue."
                return 0
            fi
            ok '3x-ui is ready; opening the 3x-ui menu.'
        else
            info 'Cancelled; nothing was changed.'
            return 0
        fi
    fi
    while :; do
        say ''
        say "${C_BLD}--- 3x-ui ---${C_RST}"
        menu_item 1 'Install or update (latest release)'
        menu_item 2 'Status (service, ports)'
        menu_item 3 'Open the x-ui management menu'
        menu_item 4 'Uninstall'
        menu_item 0 'Back'
        menu_ask 'Select: '
        case $_choice in
            1) menu_install_attempt xui_install_menu
               [ "$MENU_INSTALL_STATUS" = 0 ] || err '3x-ui installation failed.' ;;
            2) xui_status ;;
            3) xui_manage ;;
            4) xui_uninstall ;;
            0|q|Q) return 0 ;;
            *) warn "unknown option: $_choice" ;;
        esac
    done
}

cert_menu() {
    while :; do
        say ''
        say "${C_BLD}--- certificates ---${C_RST}"
        menu_item 1 'Status (expiry, SANs, renewal method)'
        menu_item 2 "Issue a Cloudflare Origin CA certificate (15 years)"
        menu_item 3 "Issue a Let's Encrypt wildcard certificate"
        menu_item 0 'Back'
        menu_ask 'Select: '
        case $_choice in
            1) cert_status ;;
            2) cert_issue origin ;;
            3) cert_issue le ;;
            0|q|Q) return 0 ;;
            *) warn "unknown option: $_choice" ;;
        esac
    done
}

domain_manager_menu() {
    while :; do
        say ''
        say "${C_BLD}--- Domain Manager ---${C_RST}"
        menu_item 1 'Show All Domains'
        menu_item 2 'Show DNS Records'
        menu_item 3 'Add Record'
        menu_item 4 'Auto-configure panel and camouflage A records'
        menu_item 0 'Back'
        menu_ask 'Select: '
        case $_choice in
            1) show_all_domains ;;
            2) show_dns_records ;;
            3) dns_record_add_interactive ;;
            4) menu_install_attempt dns_manage
               [ "$MENU_INSTALL_STATUS" = 0 ] || warn 'The DNS action stopped early; see the messages above.' ;;
            0|q|Q) return 0 ;;
            *) warn "unknown option: $_choice" ;;
        esac
    done
}

dns_records_menu() { domain_manager_menu; }

cloudflare_menu() {
    while :; do
        say ''
        say "${C_BLD}--- Cloudflare Management ---${C_RST}"
        menu_item 1 'Certificate manager'
        menu_item 2 'Domain Manager'
        menu_item 0 'Back'
        menu_ask 'Select: '
        case $_choice in
            1) cert_menu ;;
            2) domain_manager_menu ;;
            0|q|Q) return 0 ;;
            *) warn "unknown option: $_choice" ;;
        esac
    done
}

menu_full_install() {
    ensure_config
    print_plan
    if ! confirm 'Start the installation now?'; then
        info 'Aborted, nothing was changed.'
        return 0
    fi
    hdr 'Pre-flight checks'
    require_root
    menu_install_attempt run_install_stages
    if [ "$MENU_INSTALL_STATUS" -ne 0 ]; then
        err 'Installation did not complete.'
        return 1
    fi
}

menu_loop() {
    while :; do
        say ''
        say "${C_BLD}================ CloudXUI ================${C_RST}"
        menu_item 1 'Full install (nginx + 3x-ui + certificate)'
        menu_item 2 'Nginx: install / status / deploy / uninstall'
        menu_item 3 'Cloudflare Management'
        menu_item 4 '3x-ui: install / status / manage / uninstall'
        menu_item 5 'Firewall (ufw: open 80 and 443)'
        menu_item 6 'Verify the whole setup'
        menu_item 7 'Show the current configuration summary'
        menu_item 8 'Re-answer the configuration questions'
        menu_item 0 'Exit'
        menu_ask 'Select: '
        case $_choice in
            1) menu_full_install ;;
            2) nginx_menu ;;
            3) cloudflare_menu ;;
            4) xui_menu ;;
            5) require_root; stage_firewall ;;
            6) ensure_verify_config; stage_verify ;;
            7) print_summary ;;
            8) reset_config ;;
            9) menu_install_attempt dns_manage
               [ "$MENU_INSTALL_STATUS" = 0 ] || warn 'The DNS action stopped early; see the messages above.' ;;
            0|q|Q) say 'Bye.'; return 0 ;;
            *) warn "unknown option: $_choice" ;;
        esac
    done
}

# --- argument parsing --------------------------------------------------------
usage() {
    cat <<EOF
CloudXUI — VPS VPN front-end bootstrap $SCRIPT_VERSION

Usage: $0 [options]
       $0              run without options in a terminal: interactive menu

Options:
      --menu               open the interactive menu (default with no options);
                           cannot be combined with --dry-run, --non-interactive
                           or --configs-only
  -y, --yes               assume "yes" for every confirmation
      --dry-run           render the configs into ./rendered-configs and stop
      --configs-only      only re-render and deploy the configs, install nothing
      --non-interactive   take all answers from environment variables
      --config-dir DIR    directory that holds the nginx.conf / proxy.conf templates
                          (strict: missing files there abort, no built-in fallback)
                          Without --config-dir/--nginx-conf/--proxy-conf and without
                          template files next to the script, built-in copies are used.
      --nginx-conf FILE   path to the nginx.conf template
      --proxy-conf FILE   path to the proxy.conf template
      --render-out DIR    output directory for --dry-run
  -h, --help              this text
  -V, --version           print the version

Environment variables (all optional, they skip the matching question):
  DOMAIN SUB CAMO_SUB PANEL_PORT SUB_PORT PANEL_USER PANEL_PASS
  CERT_MODE (origin|le) CF_API_TOKEN CF_ZONE_ID ACME_EMAIL
  DNS_IP (public IPv4 used for the Cloudflare A records)
  PANEL_PATH SUB_PATH XUI_DB_TYPE XUI_ENABLE_FAIL2BAN ACME_DNSSLEEP
EOF
}

parse_args() {
    _arg_count=$#
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes) ASSUME_YES=1 ;;
            --dry-run|--render-only) DRY_RUN=1 ;;
            --configs-only) CONFIGS_ONLY=1 ;;
            -n|--non-interactive) NONINTERACTIVE=1 ;;
            --menu) MENU=1 ;;
            --config-dir)
                shift
                if [ $# -eq 0 ]; then die '--config-dir needs a value.'; fi
                CONFIG_DIR=$1 ;;
            --config-dir=*) CONFIG_DIR=${1#*=} ;;
            --nginx-conf)
                shift
                if [ $# -eq 0 ]; then die '--nginx-conf needs a value.'; fi
                NGINX_TEMPLATE=$1 ;;
            --nginx-conf=*) NGINX_TEMPLATE=${1#*=} ;;
            --proxy-conf)
                shift
                if [ $# -eq 0 ]; then die '--proxy-conf needs a value.'; fi
                PROXY_TEMPLATE=$1 ;;
            --proxy-conf=*) PROXY_TEMPLATE=${1#*=} ;;
            --render-out)
                shift
                if [ $# -eq 0 ]; then die '--render-out needs a value.'; fi
                RENDER_OUT=$1 ;;
            --render-out=*) RENDER_OUT=${1#*=} ;;
            -h|--help) usage; exit 0 ;;
            -V|--version) say "$SCRIPT_VERSION"; exit 0 ;;
            *) die "Unknown option: $1 (try --help)" ;;
        esac
        shift
    done

    # The menu is interactive; these flags describe non-interactive runs.
    if [ "$MENU" = 1 ]; then
        [ "$DRY_RUN" = 0 ] || die '--menu cannot be combined with --dry-run.'
        [ "$NONINTERACTIVE" = 0 ] || die '--menu cannot be combined with --non-interactive.'
        [ "$CONFIGS_ONLY" = 0 ] || die '--menu cannot be combined with --configs-only.'
    fi

    # A template location chosen by the user (flag or environment) is strict:
    # a missing file there must abort, not silently fall back to the built-in
    # copies. Only the default location (next to the script) may fall back.
    if [ -n "$CONFIG_DIR" ] || [ -n "$NGINX_TEMPLATE" ]; then
        NGINX_CONF_EXPLICIT=1
    fi
    if [ -n "$CONFIG_DIR" ] || [ -n "$PROXY_TEMPLATE" ]; then
        PROXY_CONF_EXPLICIT=1
    fi

    # Templates live next to this script unless they are given explicitly.
    if [ -z "$CONFIG_DIR" ]; then
        _self_dir=$(dirname "$0")
        if [ -d "$_self_dir" ]; then
            CONFIG_DIR=$_self_dir
        else
            CONFIG_DIR=$PWD
        fi
    fi
    if [ -z "$NGINX_TEMPLATE" ]; then
        NGINX_TEMPLATE="$CONFIG_DIR/nginx.conf"
    fi
    if [ -z "$PROXY_TEMPLATE" ]; then
        PROXY_TEMPLATE="$CONFIG_DIR/proxy.conf"
    fi

    # No arguments at all + a terminal: open the interactive menu. Any flag
    # keeps the classic single-purpose behavior (scripts, cron, docs).
    if [ "$_arg_count" -eq 0 ] && [ -t 0 ]; then
        MENU=1
    fi
}

# --- credit banner ------------------------------------------------------------
# Big gradient title, ASCII-only so every terminal renders it. The shimmer
# animation runs only on a color terminal; piped output gets the static box.
_cb_ramp='201 207 213 219 225 231 159 153 147 141 135 129 99 93 87 81 75 69 63 57 51'

_cb_pick() {   # $1 = index into _cb_ramp
    _cb_i=0
    for _cb_c in $_cb_ramp; do
        if [ "$_cb_i" = "$1" ]; then
            printf '%s' "$_cb_c"
            return 0
        fi
        _cb_i=$((_cb_i + 1))
    done
    printf '%s' "$_cb_c"
}

_cb_center() {   # $1 text -> "| centered in 57 columns |"
    _cb_txt=$1
    _cb_len=${#_cb_txt}
    if [ "$_cb_len" -ge 57 ]; then
        printf '|%s|' "$_cb_txt"
        return 0
    fi
    _cb_left=$(( (57 - _cb_len) / 2 ))
    printf '|%*s%s%*s|' "$_cb_left" '' "$_cb_txt" "$((57 - _cb_len - _cb_left))" ''
}

_cb_right() {   # $1 text -> "| right-aligned in 57 columns |"
    _cb_txt=$1
    _cb_len=${#_cb_txt}
    _cb_left=$(( 57 - _cb_len - 1 ))
    [ "$_cb_left" -lt 0 ] && _cb_left=0
    printf '|%*s%s |' "$_cb_left" '' "$_cb_txt"
}

_cb_render() {   # $1 = color phase, $2 = 1 for color, 0 for plain; sets _cb_n
    _cb_n=0
    for _cb_line in "$_cb_l1" "$_cb_l2" "$_cb_l3" "$_cb_l4" "$_cb_l5" \
                    "$_cb_l6" "$_cb_l7" "$_cb_l8" "$_cb_l9" "$_cb_l10" "$_cb_l11"; do
        if [ "$2" = 1 ]; then
            printf '\033[1;38;5;%sm%s\033[0m\n' \
                "$(_cb_pick "$(( (_cb_n + $1) % 21 ))")" "$_cb_line"
        else
            printf '%s\n' "$_cb_line"
        fi
        _cb_n=$((_cb_n + 1))
    done
}

_cb_glyph() {   # $1 = letter -> 5 block rows joined by ':' (equal width rows)
    case $1 in
        H) printf '%s' '#   #:#   #:#####:#   #:#   #' ;;
        E) printf '%s' '####:#   :### :#   :####' ;;
        S) printf '%s' '####:#   :####:   #:####' ;;
        A) printf '%s' ' ## :#  #:####:#  #:#  #' ;;
        M) printf '%s' '#   #:## ##:# # #:#   #:#   #' ;;
        T) printf '%s' '#####:  #  :  #  :  #  :  #  ' ;;
        D) printf '%s' '#### :#   #:#   #:#   #:#### ' ;;
        R) printf '%s' '#### :#   #:#### :#  # :#   #' ;;
    esac
}

_cb_big_word() {   # $@ = letters -> builds _cb_w1.._cb_w5, one block-letter row each
    _cb_w1=''; _cb_w2=''; _cb_w3=''; _cb_w4=''; _cb_w5=''
    for _cb_L in "$@"; do
        _cb_g=$(_cb_glyph "$_cb_L")
        _cb_saved=$IFS
        IFS=:
        # shellcheck disable=SC2086
        set -- $_cb_g
        IFS=$_cb_saved
        _cb_i=1
        for _cb_row in "$@"; do
            eval "_cb_prev=\${_cb_w$_cb_i}"
            if [ -n "$_cb_prev" ]; then
                eval "_cb_w$_cb_i=\"\$_cb_prev \$_cb_row\""
            else
                eval "_cb_w$_cb_i=\$_cb_row"
            fi
            _cb_i=$((_cb_i + 1))
        done
    done
}

credit_banner() {
    _cb_big_word H E S A M T H E D R
    _cb_blank=$(_cb_center '')
    _cb_border="+$(printf '%*s' 57 '' | tr ' ' '=')+"
    _cb_l1=$_cb_border
    _cb_l2=$(_cb_center 'm a d e   b y')
    _cb_l3=$_cb_blank
    _cb_l4=$(_cb_center "$_cb_w1")
    _cb_l5=$(_cb_center "$_cb_w2")
    _cb_l6=$(_cb_center "$_cb_w3")
    _cb_l7=$(_cb_center "$_cb_w4")
    _cb_l8=$(_cb_center "$_cb_w5")
    _cb_l9=$_cb_blank
    _cb_l10=$(_cb_right 'with Power Of AI')
    _cb_l11=$_cb_border

    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
        _cb_render 16 1
        # Redraw in place: move the cursor up by exactly the number of lines
        # _cb_render printed, so the box height can never desynchronize again.
        for _cb_phase in 12 8 4 0; do
            printf '\033[%sA' "$_cb_n"
            _cb_render "$_cb_phase" 1
            sleep 0.1 2>/dev/null || true
        done
    else
        _cb_render 0 0
    fi
}

banner() {
    credit_banner
    say 'Installs nginx + 3x-ui, issues a Cloudflare certificate and'
    say 'deploys the nginx configs of this folder. Ctrl-C aborts at any prompt.'
}

run_install_stages() {
    detect_os
    ok "distribution: ${PRETTY_NAME:-$OS_ID} ($OS_FAMILY packages)"
    case $OS_FAMILY in
        deb)
            apt-get update -qq || warn 'Could not refresh the package indexes, using the cached ones.'
            pkg_install curl ca-certificates openssl tar cron sqlite3 jq >/dev/null 2>&1 || true
            systemctl enable --now cron >/dev/null 2>&1 || true ;;
        rpm)
            pkg_install curl ca-certificates openssl tar cronie sqlite jq >/dev/null 2>&1 || true
            systemctl enable --now crond >/dev/null 2>&1 || true ;;
    esac
    install_base_tools
    check_connectivity
    check_cloudflare_token

    # The panel and camouflage hostnames need proxied A records; create them
    # while the token is in hand (the plan above already announced this).
    stage_dns_records pre-approved || warn 'Continuing without complete DNS configuration.'

    stage_nginx
    stage_xui
    stage_certs
    stage_deploy
    stage_firewall
    stage_verify
    print_final_notes
}

main() {
    parse_args "$@"
    banner

    if [ "$MENU" = 1 ]; then
        menu_loop
        return 0
    fi

    if [ "$DRY_RUN" = 1 ]; then
        ensure_render_config
        print_render_plan
        render_only
        exit 0
    fi

    if [ "$CONFIGS_ONLY" = 1 ]; then
        # deploy_configs collects the render answers, shows the plan, asks one
        # confirmation and deploys; no second confirmation here.
        info 'Config-only run: nginx, 3x-ui and the certificate stay as they are.'
        deploy_configs
        return 0
    fi

    collect_inputs
    validate_combination
    print_plan

    if ! confirm 'Start the installation now?'; then
        info 'Aborted, nothing was changed.'
        exit 0
    fi

    hdr 'Pre-flight checks'
    require_root
    run_install_stages
}

# Set VPN_SETUP_LIB_ONLY=1 to source this file and use its functions without
# starting the installer.
if [ "${VPN_SETUP_LIB_ONLY:-0}" != 1 ]; then
    main "$@"
fi
