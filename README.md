# macOS trust-bundle cleanup

Remove two root CAs from Apple's OpenSSL trust bundle, `/etc/ssl/cert.pem`, on macOS.

```bash
curl -fsSL https://surak.github.io/macos-root-ca-cleanup/fix.sh | bash
```

Site: <https://surak.github.io/macos-root-ca-cleanup/>

## Why

macOS validates TLS against the Keychain, but `curl`, `git`, Python, Ruby and anything else
that wants a CA *file* read `/etc/ssl/cert.pem` instead. That bundle still contains:

| certificate | key | valid until | sha256 |
|---|---|---|---|
| `emSign ECC Root CA - G3` (eMudhra Technologies Limited, IN) | EC P-384 / ecdsa-with-SHA384 | 2043-02-18 | `86:A1:EC:BA:…:BE:6B` |
| `AAA Certificate Services` (Comodo CA Limited, GB) | RSA 2048 / **sha1WithRSA** | 2028-12-31 | `D7:A7:A0:FB:…:9E:F4` |

Both are self-signed roots that nothing above them vouches for. Removing them from the file is
a policy decision you make on purpose — see the "what is verified, and what is not" section of
the page for exactly which claims are checked and which are not.

## Apple's side

macOS has two trust stores and Apple maintains one of them:

| store | roots | maintained | read by |
|---|---|---|---|
| `SystemRootCertificates.keychain` | 158 | yes, updated with the OS, listed in [Apple's root certificate list](https://support.apple.com/en-us/103272) | Safari, anything using `SecTrust` |
| `/etc/ssl/cert.pem` | 128 | no — first line is `# $OpenBSD: cert.pem,v 1.22.2.1 2021/09/30` | `curl`, `git`, `python3`, `ruby`, `perl`, `/usr/bin/openssl` |

`security add-trusted-cert` / `remove-trusted-cert` only edit keychain trust settings, and `curl`
reports `CApath: none` — it never asks the Keychain. No man page on macOS mentions
`/etc/ssl/cert.pem` at all. Nothing Apple ships edits that file on your behalf, which is why this
script exists; and as of macOS 27.0.1 both roots are still in Apple's Keychain, so Apple has not
withdrawn either one.

## What it does

1. Verifies platform, bundle path, certificate count.
2. Matches each block by subject line **and** SHA-256 fingerprint; aborts if the name matches
   but the certificate does not.
3. Filters into a temp file, then validates: expected certificate count, OpenSSL parses every
   remaining certificate, neither target subject survives.
4. Preserves the original at `/etc/ssl/cert.pem.orig` (never overwrites an existing backup).
5. Installs atomically (write beside the target, `mv` into place) and re-runs the check.

Result on macOS 27: 128 → 126 certificates, 6263 → 6175 lines, nothing else touched.

## Modes

```bash
curl -fsSL https://surak.github.io/macos-root-ca-cleanup/fix.sh | bash            # apply
curl -fsSL https://surak.github.io/macos-root-ca-cleanup/fix.sh | bash -s -- --verify
curl -fsSL https://surak.github.io/macos-root-ca-cleanup/fix.sh | bash -s -- --revert
```

Or download and read it first:

```bash
curl -fsSLO https://surak.github.io/macos-root-ca-cleanup/fix.sh
less fix.sh && bash fix.sh
```

`BUNDLE=/path/to/cert.pem bash fix.sh` works against a copy — useful for testing.

## Verify

```bash
openssl crl2pkcs7 -nocrl -certfile /etc/ssl/cert.pem \
  | openssl pkcs7 -print_certs -noout \
  | grep -E 'emSign ECC Root CA - G3|AAA Certificate Services'
```

No output and exit code 1 is the expected result after the fix.

## Undo

```bash
curl -fsSL https://surak.github.io/macos-root-ca-cleanup/fix.sh | bash -s -- --revert
```

The backup is taken with `cp -p`, so mode and ownership survive, and `--revert` re-installs it
with `-m 0644 -o root -g wheel`.

## Requirements

macOS, `sudo`, `awk`, `openssl` (present by default). Linux is out of scope — different bundle,
different paths.

## Licence

MIT.
