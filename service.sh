#!/system/bin/sh

LOGFILE="/data/local/tmp/cacert-svc.log"
exec > "$LOGFILE" 2>&1
set -x

MODDIR=${0%/*}
CERT_DIR="/data/adb/android-cacert"
CA_CRT="$CERT_DIR/ca.crt"
OPENSSL="/data/local/tmp/openssl-static"

echo "[i] ===== service.sh start - $(date) ====="

# Wait for full boot
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 1; done
sleep 3

# Ensure openssl is available
if [ ! -x "$OPENSSL" ]; then
    cp -f "$MODDIR/bin/openssl" "$OPENSSL"
    chmod 755 "$OPENSSL"
    chcon u:object_r:system_file:s0 "$OPENSSL" 2>/dev/null
fi

[ -f "$CA_CRT" ] || { echo "[e] ca.crt not found, skipping"; exit 1; }

# Get cert hash
CERT_HASH=$($OPENSSL x509 -inform PEM -subject_hash_old -in "$CA_CRT" 2>/dev/null | head -1)
[ -z "$CERT_HASH" ] && { echo "[e] failed to compute cert hash"; exit 1; }
CERT_FILE="${CERT_HASH}.0"
echo "[i] cert: $CERT_FILE"

# ------------------------------------------------------------------
# Build a fresh tmpfs: all existing system certs + our CA cert
# ------------------------------------------------------------------
APEX_COPY="/data/local/tmp/apex-cacert-svc"
rm -rf "$APEX_COPY" 2>/dev/null
mkdir -p "$APEX_COPY"
mount -t tmpfs tmpfs "$APEX_COPY"
cp -f /apex/com.android.conscrypt/cacerts/* "$APEX_COPY/" 2>/dev/null
cp -f "$CA_CRT" "$APEX_COPY/$CERT_FILE"
chown -R 0:0 "$APEX_COPY"
chmod 644 "$APEX_COPY"/*
chcon -R u:object_r:system_security_cacerts_file:s0 "$APEX_COPY" 2>/dev/null

# ------------------------------------------------------------------
# Mount into zygote namespaces so all future-forked apps inherit it
# ------------------------------------------------------------------
for pid in $(pgrep zygote) $(pgrep zygote64); do
    nsenter --mount=/proc/$pid/ns/mnt -- \
        /bin/mount --bind "$APEX_COPY" /apex/com.android.conscrypt/cacerts \
        2>/dev/null && echo "[i] mounted into zygote pid=$pid" \
                     || echo "[w] failed for zygote pid=$pid"
done

# Also ensure PID 1 namespace is updated
nsenter --mount=/proc/1/ns/mnt -- \
    /bin/mount --bind "$APEX_COPY" /apex/com.android.conscrypt/cacerts \
    2>/dev/null

umount "$APEX_COPY" 2>/dev/null
rmdir "$APEX_COPY" 2>/dev/null

# ------------------------------------------------------------------
# Also register as user cert so TrustedCertificateStore finds it
# via both system and user cert paths
# ------------------------------------------------------------------
USER_CERT_DIR="/data/misc/user/0/cacerts-added"
mkdir -p "$USER_CERT_DIR"
cp -f "$CA_CRT" "$USER_CERT_DIR/$CERT_FILE"
chown 1000:1000 "$USER_CERT_DIR/$CERT_FILE"
chmod 640 "$USER_CERT_DIR/$CERT_FILE"
echo "[i] registered in user cert store: $USER_CERT_DIR/$CERT_FILE"

# ------------------------------------------------------------------
# Clear Chrome's dynamic HSTS cache
# Removes site-learned HSTS policies (e.g. naver.com)
# Does NOT affect Chrome's built-in preload list (e.g. google.com)
# ------------------------------------------------------------------
CHROME_HSTS="/data/data/com.android.chrome/app_chrome/Default/Network/TransportSecurity"
if [ -f "$CHROME_HSTS" ]; then
    rm -f "$CHROME_HSTS"
    echo "[i] Chrome HSTS cache cleared"
else
    echo "[i] Chrome HSTS cache not found (skipping)"
fi

# ------------------------------------------------------------------
# Kill Chrome so next launch forks from updated zygote
# User just needs to tap Chrome icon after boot
# ------------------------------------------------------------------
am force-stop com.android.chrome 2>/dev/null
echo "[i] Chrome force-stopped — reopen Chrome after boot"

echo "[i] ===== service.sh done - $(date) ====="
