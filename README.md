# Android CA Certificate — Magisk Module

A Magisk module that automatically generates a self-signed CA certificate, installs it as a **system-trusted certificate**, and exports a **PKCS#12** file for Burp Suite import.

- **Android ≤ 13** — Magisk system overlay
- **Android 14 / 15** — APEX conscrypt bind-mount (post-fs-data) + zygote namespace re-mount (service)

---

## Features

- Generates a **2048-bit RSA CA certificate** valid for **180 days**
- **Auto-renews** on the next boot after expiry
- Installs into the system trust store — no manual user cert installation needed
- Exports a **PKCS#12 (.p12)** file to `/data/local/tmp/` for Burp Suite import
- Filename includes the expiry date (`cacert_exp<YYYYMMDD>.p12`) so you can tell at a glance when it was last renewed
- On Android 14/15, re-mounts into the running zygote namespace after boot and force-stops Chrome so the next launch picks up the updated trust store

---

## Requirements

- Rooted device with **Magisk v20.4+**
- A **static ARM64 OpenSSL binary** placed at `bin/openssl` before packaging (see below)

---

## Setup: Adding the OpenSSL Binary

Android 14/15 does not ship the `openssl` CLI tool, so this module bundles its own static binary.

### Option A — Build with Android NDK (recommended)

```bash
export ANDROID_NDK_ROOT=/path/to/android-ndk
export PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin:$PATH"

./Configure android-arm64 -D__ANDROID_API__=26 \
    --prefix=/tmp/openssl-out \
    no-shared no-tests

make -j$(nproc)
cp apps/openssl /path/to/AndroidCACert/bin/openssl
```

### Option B — Pull from a device that has it

```bash
adb shell ls /system/bin/openssl   # check if available
adb pull /system/bin/openssl bin/openssl
```

---

## Changing the PKCS#12 Password

Open `post-fs-data.sh` and find the `export_pkcs12` function.
The password is set in the **`P12_PASS`** variable at the top of that function:

```sh
export_pkcs12() {
    # ================================================================
    # PKCS#12 password — change this value before building the module
    # ================================================================
    P12_PASS='password1!'   # <-- change here
    ...
}
```

Change `P12_PASS` to your desired password, then rebuild the zip.

---

## Build

### Windows (PowerShell)

```powershell
# Place bin\openssl first, then:
.\create-zip.ps1
# Output: AndroidCACert.zip (in the parent directory)
```

### Linux / macOS / WSL

```bash
chmod +x create-zip.sh
./create-zip.sh
# Output: AndroidCACert.zip
```
 
---

## Installation

```bash
adb push AndroidCACert.zip /sdcard/
```

**Magisk app** → Modules → Install from storage → select `AndroidCACert.zip` → Reboot.

---

## After Reboot

### 1. Verify post-fs-data ran

```bash
adb shell su -c "cat /data/local/tmp/cacert.log"
# Should end with: ===== Android CA Cert Module done =====
```

### 2. Verify service ran (Android 14/15)

```bash
adb shell su -c "cat /data/local/tmp/cacert-svc.log"
# Should contain: mounted into zygote pid=XXX
# Should end with: ===== service.sh done =====
```

### 3. Retrieve the PKCS#12 file

```bash
adb shell su -c "ls /data/local/tmp/cacert_exp*.p12"
adb pull /data/local/tmp/cacert_exp<YYYYMMDD>.p12
```

> **Note (Android 14/15):** After reboot, `service.sh` automatically force-stops Chrome.
> Open Chrome once manually after boot — it will launch from the updated zygote and trust the new CA.

---

## Burp Suite Import

1. **Burp Suite** → Settings → Network → TLS
2. **Certificate Authority** → **Import / export CA certificate**
3. Select **Certificate and private key in PKCS12 keystore format**
4. Choose the `.p12` file → enter the password set in `P12_PASS`
5. Restart Burp Suite

---

## File Locations

| Path | Description |
|------|-------------|
| `/data/adb/android-cacert/ca.key` | Private key (root-only, mode 600) |
| `/data/adb/android-cacert/ca.crt` | CA certificate (PEM) |
| `/data/local/tmp/cacert_exp<YYYYMMDD>.p12` | PKCS#12 for Burp Suite |
| `/data/local/tmp/cacert.log` | post-fs-data log (overwritten each boot) |
| `/data/local/tmp/cacert-svc.log` | service log (overwritten each boot) |
| `/data/misc/user/0/cacerts-added/<hash>.0` | User cert store entry (Android 14/15) |

---

## How It Works

```
Boot
 ├─ post-fs-data.sh  (early boot, before zygote)
 │    ├─ Copy bundled openssl → /data/local/tmp/openssl-static
 │    │   └─ chcon system_file  (avoids SELinux exec denial)
 │    ├─ Check cert validity  (openssl x509 -checkend 0)
 │    │   ├─ Valid   → reuse existing cert
 │    │   └─ Expired/missing → generate new 180-day cert
 │    ├─ Export PKCS#12 → /data/local/tmp/cacert_exp<YYYYMMDD>.p12
 │    └─ Install into system trust store
 │         ├─ Android ≤ 13 : Magisk overlay on /system/etc/security/cacerts
 │         └─ Android 14/15 : tmpfs copy → bind-mount → /apex/com.android.conscrypt/cacerts
 │
 └─ service.sh  (after boot_completed, zygote already running)
      ├─ Re-mount cert tmpfs into each zygote namespace
      │   └─ Ensures all future-forked apps inherit the updated cert store
      ├─ Register cert in /data/misc/user/0/cacerts-added/
      └─ Force-stop Chrome
          └─ Next Chrome launch forks from updated zygote → trusts our CA
```

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| `cacert.log` ends with error | openssl binary missing or SELinux issue |
| `cacert-svc.log` has no zygote mount lines | zygote PIDs not found — check `pgrep zygote` |
| Chrome still shows cert error | Open Chrome manually after boot (service.sh kills it on boot) |
| `expunknown` in p12 filename | date parsing failed — check toybox `awk` availability |

---

## Reference

- [cert-fixer](https://github.com/pwnlogs/cert-fixer) — inspiration for the APEX conscrypt bind-mount approach
