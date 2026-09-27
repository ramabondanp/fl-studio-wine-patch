# FL Studio 2026 on Wine — signature verification fix

FL Studio 2026 fails to start on Linux/Wine with:

```text
0x80096004 (TRUST_E_CERT_SIGNATURE)
```

This repository fixes that by repairing Wine's Authenticode verification while preserving digital signature checks.

## Root cause

FL Studio 2026's Authenticode signature stores its authenticated attributes in
**noncanonical DER `SET OF` order**. The RSA signature covers those exact bytes.

Wine re-encodes (sorts) the attributes before hashing them during verification. The
hashed bytes no longer match the signed bytes, so the signature check fails — even
though the signature, the file digest, and the certificate chain are all valid.

This is a Wine bug. It is **not** a missing certificate, an unsupported key size, or
an unsupported hash. Upgrading Wine or importing root certificates does not fix it.

---

## The fix: patch Wine's `crypt32`

[`wine-crypt32-signed-attrs.patch`](wine-crypt32-signed-attrs.patch) changes
`dlls/crypt32/msg.c` so that, during verification, Wine hashes the **received**
attribute bytes instead of a sorted re-encoding. Signing and the ASN.1 encoder are
untouched. Only one file changes.

### Install

```bash
./build-and-install.sh
```

The script detects your Wine version, downloads the matching source, applies the
patch, builds **only `crypt32.dll`**, backs up the original, and installs the result.

The script defaults to 1 compiler job. On multi-core CPUs, speed up the build with:

```bash
JOBS=$(nproc) ./build-and-install.sh
```

### Build requirements

- Build tools: `git`, `curl`, `tar`, `patch`, `make`, `python3`, `flex`, `bison`.
- C / PE toolchain: `clang`, `lld`, `llvm` (for `llvm-dlltool`) or `gcc` with `mingw-w64`.
- Your distribution's Wine build dependencies.

### Options

If version detection fails, pass the ref explicitly:

```bash
./build-and-install.sh --ref 9d17984f27b   # commit
./build-and-install.sh --ref wine-11.0     # release tag
```

If your distribution uses a non-standard Wine library path (e.g. `/usr/lib64/wine` on Fedora):

```bash
./build-and-install.sh --libdir /usr/lib64/wine
```

### What gets installed

Only `<libdir>/x86_64-windows/crypt32.dll` (default `/usr/lib/wine/x86_64-windows/crypt32.dll`) is replaced. The unix side (`crypt32.so`) is unchanged and does not need to be replaced. The original is kept as `crypt32.dll.dist-backup` in the same directory.

### Restore

```bash
./build-and-install.sh --restore
```

### After a Wine upgrade

A package update overwrites `crypt32.dll`, so the fix is lost. Re-run
`./build-and-install.sh` after upgrading Wine.

### Verification

With the patch installed, plain `wine` accepts the FL Studio binaries and reports the
full certificate chain:

```text
Image Line NV -> DigiCert Trusted G4 Code Signing RSA4096 SHA384 2021 CA1 -> DigiCert Trusted Root G4
```

Tampering is still rejected: changing a byte of the file yields `0x80096010`
(`TRUST_E_BAD_DIGEST`), and changing the signature or the signed attributes is
rejected outright.

> **Known pre-existing gap (not fixed here):** Wine does not check that the
> `messageDigest` signed attribute matches the actual content hash, so a file whose
> embedded Authenticode digest was rewritten to match modified content can still pass.
> This is true of stock Wine as well and is out of scope for this patch.

## Requirements

- Linux with a 64-bit Wine installation.
- Build toolchain (see [Build requirements](#build-requirements) above).
- `sudo` privileges to copy the built `crypt32.dll` to the system Wine library directory.
- Run the script as your normal user (it will prompt for `sudo` only when installing). Close FL Studio / Wine before installing.

## Troubleshooting

| Problem | What to check |
| --- | --- |
| `Could not detect the Wine source ref` | Pass `--ref <tag-or-commit>`. |
| `Missing required tool: <name>` | Install the missing tool (`git`, `curl`, `patch`, `tar`, `make`, `sudo`). |
| Target DLL or directory not found | Pass `--libdir <path>` if your distribution places Wine libraries elsewhere (e.g. `/usr/lib64/wine`). |
| Build fails in `configure` | Install the Wine build dependencies and toolchain listed above. |
| Signature errors return after an update | Re-run `./build-and-install.sh`. |
| Still exits for another reason | Check Wine console output (`WINEDEBUG=+loaddll,+crypt`); other startup errors need separate diagnosis. |

## Credits and scope

Tested against Wine `9d17984f27b` (staging) with the official FL Studio 2026 demo on
x86_64. The patch addresses the signed-attribute ordering bug only; it does not
implement the missing `messageDigest` binding described above.
