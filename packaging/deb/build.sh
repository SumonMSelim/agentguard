#!/bin/bash
# packaging/deb/build.sh — build agentguard_<version>_all.deb
#
# Usage: bash packaging/deb/build.sh [output-dir]
# Output: agentguard_<version>_all.deb in output-dir (default: dist/)
#
# Requires: dpkg-deb, fakeroot, lintian (all in dpkg-dev + lintian packages)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="$(cat "$SCRIPT_DIR/VERSION" | tr -d '[:space:]')"
OUT_DIR="${1:-$SCRIPT_DIR/dist}"
PKG_ROOT="$(mktemp -d)"
BUILD_DATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"

mkdir -p "$OUT_DIR"
trap 'rm -rf "$PKG_ROOT"' EXIT

# ── layout ────────────────────────────────────────────────────────────────────
# /usr/lib/agentguard/          — source tree (hooks/, agents/, skills/, install.sh, VERSION)
# /usr/bin/agentguard           — thin wrapper
# /usr/share/doc/agentguard/    — copyright, changelog.gz

LIB="$PKG_ROOT/usr/lib/agentguard"
BIN="$PKG_ROOT/usr/bin"
DOC="$PKG_ROOT/usr/share/doc/agentguard"
DEBIAN="$PKG_ROOT/DEBIAN"

mkdir -p "$LIB" "$BIN" "$DOC" "$DEBIAN"

# Copy only needed source files (exclude tests/, packaging/, .github/, etc.)
cp -r "$SCRIPT_DIR/hooks"      "$LIB/"
cp -r "$SCRIPT_DIR/agents"     "$LIB/"
cp -r "$SCRIPT_DIR/skills"     "$LIB/"
cp    "$SCRIPT_DIR/install.sh" "$LIB/"
cp    "$SCRIPT_DIR/VERSION"    "$LIB/"

chmod +x "$LIB/install.sh" "$LIB/hooks/"*.sh

# Wrapper at /usr/bin/agentguard — use env bash so system bash is not hardcoded
cat > "$BIN/agentguard" <<'SH'
#!/usr/bin/env bash
exec bash /usr/lib/agentguard/install.sh "$@"
SH
chmod +x "$BIN/agentguard"

# ── DEBIAN/control ────────────────────────────────────────────────────────────
# bash is an essential package on Debian/Ubuntu — must not be listed in Depends
cat > "$DEBIAN/control" <<EOF
Package: agentguard
Version: ${VERSION}
Architecture: all
Maintainer: Muhammad Sumon Molla Selim <sumon@cielara.com>
Depends: jq
Section: utils
Priority: optional
Homepage: https://github.com/SumonMSelim/agentguard
Description: Security guardrails for AI coding agents
 agentguard installs shell-level hooks that block dangerous operations
 performed by AI coding agents (Claude Code, Kiro, Cursor, Codex).
 .
 Enforced rules include: blocking .env reads, preventing force-pushes,
 blocking system package installs, blocking pipe-to-shell execution,
 and blocking destructive rm operations.
EOF

# ── /usr/share/doc/agentguard/copyright (Debian Policy §12.5) ────────────────
cat > "$DOC/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: agentguard
Upstream-Contact: Muhammad Sumon Molla Selim <sumon@cielara.com>
Source: https://github.com/SumonMSelim/agentguard

Files: *
Copyright: 2026 Muhammad Sumon Molla Selim
License: MIT

License: MIT
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:
 .
 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.
 .
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.
EOF

# ── /usr/share/doc/agentguard/changelog.gz ───────────────────────────────────
# Native packages use changelog.gz (not changelog.Debian.gz)
# Changelog lines must be <= 80 chars
changelog_tmp="$(mktemp)"
cat > "$changelog_tmp" <<EOF
agentguard (${VERSION}) stable; urgency=low

  * Release ${VERSION}. See GitHub releases for full changelog.

 -- Muhammad Sumon Molla Selim <sumon@cielara.com>  ${BUILD_DATE}
EOF
gzip -9 -n -c "$changelog_tmp" > "$DOC/changelog.gz"
rm -f "$changelog_tmp"

# ── DEBIAN/lintian-overrides ──────────────────────────────────────────────────
# no-manual-page: intentional — agentguard is a CLI tool without a man page
mkdir -p "$PKG_ROOT/usr/share/lintian/overrides"
cat > "$PKG_ROOT/usr/share/lintian/overrides/agentguard" <<'EOF'
agentguard: no-manual-page usr/bin/agentguard
EOF

# ── DEBIAN/postinst ───────────────────────────────────────────────────────────
cat > "$DEBIAN/postinst" <<'EOF'
#!/bin/bash
set -e
case "$1" in
  configure)
    echo ""
    echo "agentguard installed. Run it to set up guardrails for your AI agent:"
    echo ""
    echo "  agentguard claude        # Claude Code"
    echo "  agentguard kiro          # Kiro"
    echo "  agentguard cursor        # Cursor (run from project root)"
    echo "  agentguard codex         # Codex"
    echo "  agentguard all           # All agents"
    echo ""
    ;;
esac
exit 0
EOF
chmod 0755 "$DEBIAN/postinst"

# ── build (fakeroot ensures correct ownership without running as root) ─────────
DEB_FILE="$OUT_DIR/agentguard_${VERSION}_all.deb"
fakeroot dpkg-deb --build "$PKG_ROOT" "$DEB_FILE"
echo "Built: $DEB_FILE"

# ── lint ──────────────────────────────────────────────────────────────────────
if command -v lintian >/dev/null 2>&1; then
  echo "Running lintian..."
  lintian --fail-on error "$DEB_FILE"
else
  echo "lintian not found — skipping lint (install with: sudo apt-get install lintian)"
fi
