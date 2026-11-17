#!/bin/sh
# Install hand on macOS, Linux, and Termux.
#
#   curl -fsSL https://raw.githubusercontent.com/0DukePan/handmedown/main/install.sh | sh
#
# Downloads the release binary for this platform, verifies it against the published SHA256SUMS.txt, and
# installs it into ~/.local/bin. No root, no package manager, no machine-wide change.
#
# Environment:
#   HAND_VERSION      pin a release tag (default: latest)
#   HAND_REPO         override the source repository (default: 0DukePan/handmedown)
#   HAND_INSTALL_DIR  override the install directory (default: ~/.local/bin)
#   HAND_BASE_URL     override the release base URL (used by the installer tests)
#   HAND_TARGET       force a <goos>/<goarch> instead of detecting it (testing, or wrapping)

set -eu

REPO="${HAND_REPO:-0DukePan/handmedown}"
VERSION="${HAND_VERSION:-latest}"
INSTALL_DIR="${HAND_INSTALL_DIR:-$HOME/.local/bin}"
BASE_URL="${HAND_BASE_URL:-}"

say() { printf '%s\n' "$*"; }
die() { printf 'hand: %s\n' "$*" >&2; exit 1; }

# --- target detection ---------------------------------------------------------
# Termux reports itself as Linux with an Android kernel; the correct artefact is linux/arm64, which is
# also why there is no GOOS=android build: Android is a Linux userland and needs no cgo here.
detect_target() {
    if [ -n "${HAND_TARGET:-}" ]; then
        printf '%s' "$HAND_TARGET"
        return
    fi

    os="$(uname -s)"
    case "$os" in
        Linux*)  goos="linux" ;;
        Darwin*) goos="darwin" ;;
        MINGW*|MSYS*|CYGWIN*) goos="windows" ;;
        *) die "unsupported operating system: $os (build from source instead)" ;;
    esac

    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64)   goarch="amd64" ;;
        aarch64|arm64)  goarch="arm64" ;;
        armv7l|armv8l|arm) goarch="arm" ;;
        *) die "unsupported architecture: $machine (build from source instead)" ;;
    esac

    # Only arm64 and amd64 are published for macOS; there is no 32-bit mac in the matrix.
    if [ "$goos" = "darwin" ] && [ "$goarch" = "arm" ]; then
        die "32-bit macOS is not supported; build from source instead"
    fi

    printf '%s/%s' "$goos" "$goarch"
}

target="$(detect_target)"
goos="${target%%/*}"
goarch="${target##*/}"

case "$goos" in
    windows) ext='.exe' ;;
    *)       ext='' ;;
esac
asset="hand_${goos}_${goarch}${ext}"

if [ -z "$BASE_URL" ]; then
    if [ "$VERSION" = "latest" ]; then
        BASE_URL="https://github.com/$REPO/releases/latest/download"
    else
        BASE_URL="https://github.com/$REPO/releases/download/$VERSION"
    fi
fi
BASE_URL="$(printf '%s' "$BASE_URL" | sed 's:/*$::')"

say "handmedown installer"
say "  repository: $REPO"
say "  version:    $VERSION"
say "  asset:      $asset"
say "  target:     $INSTALL_DIR"

# --- transport ----------------------------------------------------------------
# curl is present on macOS and virtually every Linux; wget is the fallback for minimal images.
fetch() {
    url="$1"
    dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 300 -o "$dest" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$dest" "$url"
    else
        die "neither curl nor wget is available"
    fi
}

tmp="$(mktemp -d 2>/dev/null || mktemp -d -t hand)"
trap 'rm -rf "$tmp"' EXIT INT TERM

# --- checksum first -----------------------------------------------------------
# Fetched before the binary so a broken release fails cheaply, and so the expected hash never comes
# from the artefact being checked.
sums_url="$BASE_URL/SHA256SUMS.txt"
fetch "$sums_url" "$tmp/SHA256SUMS.txt" || die "could not download $sums_url (check your connection, or pass HAND_VERSION to pin a release)"

expected="$(awk -v want="$asset" '$2 == want { print tolower($1); exit }' "$tmp/SHA256SUMS.txt")"
[ -n "$expected" ] || die "SHA256SUMS.txt has no entry for $asset; the release is incomplete, do not install it"

say "  downloading..."
fetch "$BASE_URL/$asset" "$tmp/$asset" || die "could not download $BASE_URL/$asset"

if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$tmp/$asset" | awk '{ print tolower($1) }')"
elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$tmp/$asset" | awk '{ print tolower($1) }')"
elif command -v openssl >/dev/null 2>&1; then
    actual="$(openssl dgst -sha256 "$tmp/$asset" | sed 's/.*= *//' | tr 'A-F' 'a-f')"
else
    die "no SHA-256 tool available (need sha256sum, shasum, or openssl)"
fi

if [ "$actual" != "$expected" ]; then
    printf 'hand: checksum mismatch for %s\n  expected: %s\n  actual:   %s\n  Refusing to install. The download is corrupt or was tampered with.\n' \
        "$asset" "$expected" "$actual" >&2
    exit 1
fi
say "  checksum:   ok"

# --- install ------------------------------------------------------------------
mkdir -p "$INSTALL_DIR" || die "could not create $INSTALL_DIR"
name="hand${ext}"
cp "$tmp/$asset" "$INSTALL_DIR/$name"
chmod +x "$INSTALL_DIR/$name"

say "  installed:  $INSTALL_DIR/$name"
say ""

case ":${PATH:-}:" in
    *":$INSTALL_DIR:"*) : ;;
    *) say "  note: $INSTALL_DIR is not on your PATH. Add it, for example:"
       say "        export PATH=\"$INSTALL_DIR:\$PATH\"" ;;
esac

say "Installed."
say ""
say "  hand demo             prove the recovery guarantee on this machine"
say "  hand run --help       run one command across a list of inputs"
say "  hand --help           everything else"
