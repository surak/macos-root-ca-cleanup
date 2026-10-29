#!/usr/bin/env bash
#
#  macOS trust-bundle cleanup
#  Removes two root CAs from Apple's OpenSSL bundle: /etc/ssl/cert.pem
#
#    curl -fsSL https://surak.github.io/macos-root-ca-cleanup/fix.sh | bash
#
#  - reversible: the untouched bundle is preserved at /etc/ssl/cert.pem.orig
#  - idempotent: run it twice, nothing happens the second time
#  - refuses to write anything it cannot verify afterwards
#
#  MIT licensed. Read it before you run it: /fix.sh
#
#  modes:  (default) apply     --verify   --revert   --help

set -u

BUNDLE=${BUNDLE:-/etc/ssl/cert.pem}
BACKUP="${BUNDLE}.orig"

# The two roots we consider no longer trustworthy.
C1='=== /C=IN/OU=emSign PKI/O=eMudhra Technologies Limited/CN=emSign ECC Root CA - G3'
C2='=== /C=GB/ST=Greater Manchester/L=Salford/O=Comodo CA Limited/CN=AAA Certificate Services'

# Pinned SHA-256 fingerprints. If a block with the expected name has a
# different fingerprint, we abort instead of guessing.
F1='86:A1:EC:BA:08:9C:4A:8D:3B:BE:27:34:C6:12:BA:34:1D:81:3E:04:3C:F9:E8:A8:62:CD:5C:57:A3:6B:BE:6B'
F2='D7:A7:A0:FB:5D:7E:27:31:D7:71:E9:48:4E:BC:DE:F7:1D:5F:0C:3E:0A:29:48:78:2B:C8:3E:E0:EA:69:9E:F4'

MODE=apply
case "${1:-}" in
  --verify|-v) MODE=verify ;;
  --revert|-r) MODE=revert ;;
  --help|-h)
    sed -n '2,14p' "$0" 2>/dev/null | sed 's/^#  \{0,1\}//'
    exit 0 ;;
  "") ;;
  *) printf 'unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
esac

if [ -t 1 ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'
else
  R=''; G=''; Y=''; B=''; D=''; N=''
fi

say()  { printf '%s\n' "$*"; }
head_() { printf '\n%s%s%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$R" "$N" "$*"; }
die()  { printf '\n%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

count_certs() { grep -c '^=== ' "$1" 2>/dev/null || printf '0'; }

# Print the PEM block whose Apple-style header line is exactly $2.
extract_block() {
  awk -v s="$2" '/^(===|###) /{ if (f && $0 != s) exit; if ($0 == s) f = 1 } f' "$1" 2>/dev/null \
    | awk '/-----BEGIN CERTIFICATE-----/{b=1} b{print} b && /-----END CERTIFICATE-----/{exit}'
}

fp_of() { openssl x509 -noout -fingerprint -sha256 -in "$1" 2>/dev/null | sed 's/^.*=//'; }

have_openssl=0
command -v openssl >/dev/null 2>&1 && have_openssl=1

# ------------------------------------------------------------------ preflight
[ "$(uname -s)" = Darwin ] || die "this is macOS-specific (uname -s = $(uname -s))"
[ -f "$BUNDLE" ] || die "not found: $BUNDLE"
[ -r "$BUNDLE" ] || die "cannot read: $BUNDLE"

if [ "$MODE" != verify ]; then
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "need root: sudo not found"
    # stdin is the curl pipe here, so authenticate against the terminal.
    if [ -c /dev/tty ] && ( : </dev/tty ) 2>/dev/null; then
      say "${D}sudo is needed for one write to $BUNDLE${N}"
      sudo -p '[sudo] password for %u: ' -v </dev/tty || die "sudo authentication failed"
    else
      sudo -n -v 2>/dev/null || die "no terminal available for the sudo password prompt"
    fi
    SUDO=sudo
  else
    SUDO=''
  fi
else
  SUDO=''
fi

# 1.2 MB of temp space, cleaned up no matter how we exit.
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/certbundle.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$TMPD"' EXIT INT TERM

before=$(count_certs "$BUNDLE")

# --------------------------------------------------------------------- verify
present_dn() { grep -qxF "$1" "$BUNDLE"; }

if [ "$MODE" = verify ]; then
  head_ "bundle   $BUNDLE"
  say "  $(wc -l < "$BUNDLE" | tr -d ' ') lines, $before certificates"
  shasum -a 256 "$BUNDLE" | awk '{print "  sha256   "$1}'
  [ -f "$BACKUP" ] && say "  backup   $BACKUP ($(count_certs "$BACKUP") certificates)"

  head_ "the two roots"
  i=0
  for dn in "$C1" "$C2"; do
    i=$((i+1))
    eval "want=\$F$i"
    name=$(printf '%s' "$dn" | sed 's/^=== //; s#.*/CN=##')
    if present_dn "$dn"; then
      extract_block "$BUNDLE" "$dn" > "$TMPD/v$i.pem"
      got=$(fp_of "$TMPD/v$i.pem")
      if [ -z "$got" ]; then
        warn "$name — present (fingerprint unreadable)"
      elif [ "$got" = "$want" ]; then
        bad "$name — present, fingerprint matches the pinned value"
      else
        bad "$name — present, but fingerprint DIFFERS from the pinned value"
        say "      ${D}expected $want${N}"
        say "      ${D}found    $got${N}"
      fi
    else
      ok "$name — not present"
    fi
  done

  head_ "does the bundle still work?"
  say "  ${D}live handshake with the bundle in use:${N}"
  if curl -sS -o /dev/null -w '  %{http_code}  %{time_total}s  https://www.apple.com\n' --max-time 15 https://www.apple.com 2>/dev/null; then :; else
    bad "curl could not reach https://www.apple.com"
  fi
  if [ "$have_openssl" = 1 ]; then
    n=$(openssl crl2pkcs7 -nocrl -certfile "$BUNDLE" 2>/dev/null | openssl pkcs7 -print_certs -noout 2>/dev/null | grep -c '^subject')
    if [ "$n" = "$before" ]; then
      ok "openssl parses all $n certificates"
    else
      warn "openssl sees $n of $before certificates"
    fi
  fi
  say ""
  exit 0
fi

# --------------------------------------------------------------------- revert
if [ "$MODE" = revert ]; then
  [ -f "$BACKUP" ] || die "no backup at $BACKUP — nothing to restore"
  restore=$(count_certs "$BACKUP")
  head_ "restoring the original bundle"
  say "  $BACKUP -> $BUNDLE ($restore certificates)"
  $SUDO install -m 0644 -o root -g wheel "$BACKUP" "$BUNDLE.new.$$" \
    && $SUDO mv -f "$BUNDLE.new.$$" "$BUNDLE" || die "restore failed"
  after=$(count_certs "$BUNDLE")
  [ "$after" = "$restore" ] || die "restored bundle has $after certificates, expected $restore"
  ok "bundle restored, $after certificates"
  say ""
  exit 0
fi

# ---------------------------------------------------------------------- apply
head_ "macOS trust-bundle cleanup"
say "  bundle    $BUNDLE"
say "  $before certificates, $(wc -l < "$BUNDLE" | tr -d ' ') lines"

[ -f "$BACKUP" ] || say "  ${D}no backup yet — one will be created${N}"

# Work on a copy, never in place.
cp "$BUNDLE" "$TMPD/work.pem" || die "cannot copy the bundle"

removed=0
skipped=0
head_ "removing"
i=0
for dn in "$C1" "$C2"; do
  i=$((i+1))
  eval "want=\$F$i"
  name=$(printf '%s' "$dn" | sed 's/^=== //; s#.*/CN=##')

  if ! grep -qxF "$dn" "$TMPD/work.pem"; then
    ok "$name — already absent"
    skipped=$((skipped+1))
    continue
  fi

  # Identify before deleting: a DN match alone is not proof of identity.
  if [ "$have_openssl" = 1 ]; then
    extract_block "$TMPD/work.pem" "$dn" > "$TMPD/probe.pem"
    got=$(fp_of "$TMPD/probe.pem")
    [ -n "$got" ] || die "$name: cannot read the certificate, refusing to touch the bundle"
    [ "$got" = "$want" ] || die "$name: fingerprint mismatch
    expected $want
    found    $got
This is not the certificate this script was written for. Nothing was changed."
    say "  ${D}fingerprint verified${N}"
  fi

  awk -v s="$dn" '/^(===|###) /{skip=0} $0==s{skip=1} !skip' "$TMPD/work.pem" > "$TMPD/next.pem" \
    || die "$name: awk failed, nothing was changed"
  [ -s "$TMPD/next.pem" ] || die "$name: filtering produced an empty file, nothing was changed"
  mv "$TMPD/next.pem" "$TMPD/work.pem"
  ok "$name — removed"
  removed=$((removed+1))
done

# ------------------------------------------------------------------ validate
head_ "validating the result"
after=$(count_certs "$TMPD/work.pem")
expected=$((before - removed))
if [ "$after" = "$expected" ]; then
  ok "$after certificates ($before - $removed), as expected"
else
  die "bundle would hold $after certificates, expected $expected — nothing was changed"
fi

for dn in "$C1" "$C2"; do
  grep -qxF "$dn" "$TMPD/work.pem" && die "a target block survived filtering — nothing was changed"
done
ok "neither target remains"

if [ "$have_openssl" = 1 ]; then
  parsed=$(openssl crl2pkcs7 -nocrl -certfile "$TMPD/work.pem" 2>/dev/null | openssl pkcs7 -print_certs -noout 2>/dev/null | grep -c '^subject')
  [ "$parsed" = "$after" ] || die "openssl can only parse $parsed of $after certificates — nothing was changed"
  ok "openssl parses all $parsed certificates"
else
  warn "openssl not available, PEM integrity not double-checked"
fi

# -------------------------------------------------------------------- install
head_ "installing"
if [ ! -f "$BACKUP" ]; then
  $SUDO cp -p "$BUNDLE" "$BACKUP" && ok "backup saved to $BACKUP" || die "could not create the backup"
else
  ok "backup already exists at $BACKUP, left untouched"
fi

# Write beside the target, then rename: the bundle is never half-written.
$SUDO install -m 0644 -o root -g wheel "$TMPD/work.pem" "$BUNDLE.new.$$" \
  && $SUDO mv -f "$BUNDLE.new.$$" "$BUNDLE" || die "install failed — original bundle untouched"

installed=$(count_certs "$BUNDLE")
[ "$installed" = "$expected" ] || die "after install the bundle holds $installed certificates, expected $expected — restore with --revert"
ok "$BUNDLE now holds $installed certificates"

# --------------------------------------------------------------- final check
head_ "final check"
if command -v openssl >/dev/null 2>&1; then
  if openssl crl2pkcs7 -nocrl -certfile "$BUNDLE" 2>/dev/null \
     | openssl pkcs7 -print_certs -noout 2>/dev/null \
     | grep -qE 'emSign ECC Root CA - G3|AAA Certificate Services'; then
    bad "one of the two roots is still listed"
    exit 1
  else
    ok "the test command finds neither root"
  fi
fi
if curl -sS -o /dev/null -w '' --max-time 15 https://www.apple.com 2>/dev/null; then
  ok "curl still negotiates TLS (https://www.apple.com)"
else
  warn "curl could not reach https://www.apple.com — check your network"
fi

printf '\n%sDone.%s Restore at any time with:\n  curl -fsSL %s | bash -s -- --revert\n\n' \
  "$G" "$N" "https://surak.github.io/macos-root-ca-cleanup/fix.sh"
