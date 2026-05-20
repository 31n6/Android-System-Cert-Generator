#!/system/bin/sh

LOGFILE="/data/local/tmp/cacert.log"
exec > "$LOGFILE" 2>&1
set -x

MODDIR=${0%/*}
CERT_DIR="/data/adb/android-cacert"
CA_KEY="$CERT_DIR/ca.key"
CA_CRT="$CERT_DIR/ca.crt"
CA_CNF="$CERT_DIR/ca.cnf"
VALIDITY_DAYS=180

# ------------------------------------------------------------------
# Find openssl binary
# Priority: bundled > system path
# Bundled binary is copied to /data/local/tmp to avoid SELinux exec denial
# ------------------------------------------------------------------
find_openssl() {
    if [ -f "$MODDIR/bin/openssl" ]; then
        DEST="/data/local/tmp/openssl-static"
        cp -f "$MODDIR/bin/openssl" "$DEST"
        chmod 755 "$DEST"
        chcon u:object_r:system_file:s0 "$DEST" 2>/dev/null
        echo "$DEST"
        return 0
    fi

    for bin in /system/bin/openssl /system_ext/bin/openssl; do
        [ -x "$bin" ] && echo "$bin" && return 0
    done

    return 1
}

OPENSSL=$(find_openssl)
if [ -z "$OPENSSL" ]; then
    echo "[e] openssl binary not found."
    echo "[e] Place a static ARM64 openssl binary at: $MODDIR/bin/openssl"
    echo "[e] then reinstall the module."
    exit 1
fi
echo "[i] openssl: $OPENSSL  version: $($OPENSSL version 2>/dev/null)"

# ------------------------------------------------------------------
# SELinux context helper
# ------------------------------------------------------------------
set_context() {
    [ "$(getenforce)" = "Enforcing" ] || return 0
    default_ctx=u:object_r:system_file:s0
    ctx=$(ls -Zd "$1" 2>/dev/null | awk '{print $1}')
    if [ -n "$ctx" ] && [ "$ctx" != "?" ]; then
        chcon -R "$ctx" "$2"
    else
        chcon -R "$default_ctx" "$2"
    fi
}

# ------------------------------------------------------------------
# Returns 0 if the stored cert is valid (not expired)
# ------------------------------------------------------------------
cert_is_valid() {
    [ -f "$CA_CRT" ] && [ -f "$CA_KEY" ] || return 1
    $OPENSSL x509 -in "$CA_CRT" -noout -checkend 0 2>/dev/null
}

# ------------------------------------------------------------------
# Generate a new self-signed CA certificate
# ------------------------------------------------------------------
generate_cert() {
    echo "[i] generating new CA certificate (validity: ${VALIDITY_DAYS} days)"
    mkdir -p "$CERT_DIR"

    cat > "$CA_CNF" << 'CNFEOF'
[req]
default_bits       = 2048
prompt             = no
distinguished_name = dn
x509_extensions    = v3_ca

[dn]
C  = KR
O  = Security
CN = Android CA Certificate

[v3_ca]
basicConstraints     = critical,CA:true
keyUsage             = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
CNFEOF

    $OPENSSL genrsa -out "$CA_KEY" 2048
    $OPENSSL req -new -x509 \
        -key "$CA_KEY" \
        -out "$CA_CRT" \
        -days "$VALIDITY_DAYS" \
        -config "$CA_CNF"

    chmod 600 "$CA_KEY"
    chmod 644 "$CA_CRT"

    echo "[i] cert generated:"
    $OPENSSL x509 -in "$CA_CRT" -noout -subject -issuer -dates
}

# ------------------------------------------------------------------
# Get expiry date as YYYYMMDD for use in the p12 filename
# Parses OpenSSL enddate format: "Nov 19 12:00:00 2026 GMT"
# Uses awk instead of 'date -d' — Android toybox cannot parse this format
# ------------------------------------------------------------------
get_expiry_yyyymmdd() {
    ENDDATE=$($OPENSSL x509 -in "$CA_CRT" -noout -enddate 2>/dev/null | cut -d= -f2)
    echo "$ENDDATE" | awk '{
        split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " ")
        for (i=1; i<=12; i++) if (m[i]==$1) { mo=sprintf("%02d",i); break }
        printf "%s%s%02d\n", $4, mo, $2
    }'
}

# ------------------------------------------------------------------
# Export PKCS#12 for Burp Suite
#
# Output : /data/local/tmp/cacert_exp<YYYYMMDD>.p12
# Password is set in P12_PASS below.
# ------------------------------------------------------------------
export_pkcs12() {
    # ================================================================
    # PKCS#12 password — change this value before building the module
    # ================================================================
    P12_PASS='password1!'

    EXPIRY_DATE=$(get_expiry_yyyymmdd)
    P12_FILE="/data/local/tmp/cacert_exp${EXPIRY_DATE}.p12"

    rm -f /data/local/tmp/cacert_exp*.p12

    $OPENSSL pkcs12 -export \
        -in "$CA_CRT" \
        -inkey "$CA_KEY" \
        -out "$P12_FILE" \
        -passout "pass:${P12_PASS}" \
        -name 'Android CA Certificate'

    chmod 644 "$P12_FILE"
    echo "[i] PKCS#12 exported: $P12_FILE"
}

# ------------------------------------------------------------------
# Install cert into the system trust store
# ------------------------------------------------------------------
install_system_cert() {
    CERT_HASH=$($OPENSSL x509 -inform PEM -subject_hash_old -in "$CA_CRT" 2>/dev/null | head -1)
    if [ -z "$CERT_HASH" ]; then
        echo "[e] failed to compute cert hash"
        return 1
    fi
    CERT_FILE="${CERT_HASH}.0"
    echo "[i] cert hash: $CERT_HASH  ->  $CERT_FILE"

    # ---- Magisk system overlay (Android < 14) ----
    mkdir -p "$MODDIR/system/etc/security/cacerts"
    rm -f "$MODDIR/system/etc/security/cacerts"/*.0
    cp "$CA_CRT" "$MODDIR/system/etc/security/cacerts/$CERT_FILE"
    chown -R 0:0 "$MODDIR/system/etc/security/cacerts"
    chmod 644 "$MODDIR/system/etc/security/cacerts/$CERT_FILE"
    set_context /system/etc/security/cacerts "$MODDIR/system/etc/security/cacerts"

    # ---- Android 14 / 15 : APEX conscrypt bind-mount ----
    if [ -d /apex/com.android.conscrypt/cacerts ]; then
        echo "[i] Android 14+ APEX detected, bind-mounting cert"

        APEX_COPY="/data/local/tmp/apex-cacert-copy"
        rm -rf "$APEX_COPY"
        mkdir -p "$APEX_COPY"
        mount -t tmpfs tmpfs "$APEX_COPY"

        cp -f /apex/com.android.conscrypt/cacerts/* "$APEX_COPY/"
        cp -f "$CA_CRT" "$APEX_COPY/$CERT_FILE"

        chown -R 0:0 "$APEX_COPY"
        chmod 644 "$APEX_COPY"/*
        set_context /apex/com.android.conscrypt/cacerts "$APEX_COPY"

        mount --bind "$APEX_COPY" /apex/com.android.conscrypt/cacerts

        for pid in 1 $(pgrep zygote) $(pgrep zygote64); do
            nsenter --mount=/proc/"${pid}"/ns/mnt -- \
                /bin/mount --bind "$APEX_COPY" /apex/com.android.conscrypt/cacerts \
                2>/dev/null
        done

        umount "$APEX_COPY"
        rmdir "$APEX_COPY"
        echo "[i] APEX bind-mount complete"
    else
        echo "[i] APEX not found, using Android < 14 overlay only"
    fi
}

# ==================================================================
# Main
# ==================================================================
echo "[i] ===== Android CA Cert Module - $(date) ====="

NEED_GENERATE=0
if cert_is_valid; then
    echo "[i] existing cert is valid, skipping generation"
else
    echo "[i] cert missing or expired — generating new cert"
    NEED_GENERATE=1
    generate_cert
fi

EXPIRY_DATE=$(get_expiry_yyyymmdd)
P12_FILE="/data/local/tmp/cacert_exp${EXPIRY_DATE}.p12"
if [ "$NEED_GENERATE" = "1" ] || [ ! -f "$P12_FILE" ]; then
    export_pkcs12
else
    echo "[i] PKCS#12 already present: $P12_FILE"
fi

install_system_cert

echo "[i] ===== Android CA Cert Module done - $(date) ====="
