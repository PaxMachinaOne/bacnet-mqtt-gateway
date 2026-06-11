#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_DIR="${TMPDIR:-/tmp}/bacnet-mqtt-gateway-codeql-db"
OUT_DIR="${ROOT_DIR}/artifacts/codeql"
OUT_FILE="${OUT_DIR}/results.sarif"

if ! command -v codeql >/dev/null 2>&1; then
  echo "codeql CLI not found in PATH" >&2
  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "On macOS install with:  brew install --cask codeql" >&2
    echo "  (or download codeql-osx64.zip from https://github.com/github/codeql-cli-binaries/releases)" >&2
  fi
  exit 1
fi

# macOS: clear com.apple.quarantine (Homebrew cask shim issue)
if [[ "$(uname -s)" == "Darwin" ]]; then
  _codeql_bin="$(command -v codeql)"
  _i=0
  _target=""
  _has_quarantine=0
  _f=""

  if command -v readlink >/dev/null 2>&1; then
    _i=0
    while [[ -L "$_codeql_bin" ]] && [[ $_i -lt 10 ]]; do
      _target="$(readlink "$_codeql_bin")"
      if [[ "$_target" != /* ]]; then
        _target="$(dirname "$_codeql_bin")/$_target"
      fi
      _codeql_bin="$_target"
      ((_i++)) || true
    done
  fi

  _codeql_dist="$(dirname "$_codeql_bin")"

  # resolve thin shim (e.g. /opt/homebrew/bin/codeql) to real dist in Caskroom
  if [[ ! -d "$_codeql_dist/tools" || ! -x "$_codeql_dist/codeql" ]]; then
    if [[ -r "$_codeql_bin" ]]; then
      for _pat in \
        'exec[[:space:]]+["'"'"']([^"'"'"']+)["'"'"']' \
        '["'"'"']([^"'"'"']+codeql/codeql)["'"'"']' \
        '["'"'"']([^"'"'"']+/Caskroom/[^"'"'"']+/codeql)["'"'"']'; do
        _match="$(grep -oE "$_pat" "$_codeql_bin" 2>/dev/null | head -1 | sed -E 's/.*["'"'"']([^"'"'"']+)["'"'"']/\1/' || true)"
        if [[ -n "$_match" && -x "$_match" ]]; then
          _codeql_bin="$_match"
          _codeql_dist="$(dirname "$_codeql_bin")"
          break
        fi
      done
    fi
  fi

  # upward search fallback
  if [[ ! -d "$_codeql_dist/tools" || ! -x "$_codeql_dist/codeql" ]]; then
    _search_dir="$(dirname "$_codeql_bin")"
    for _up in 1 2 3 4 5; do
      _search_dir="$(dirname "$_search_dir")"
      if [[ -d "$_search_dir/codeql/tools" && -x "$_search_dir/codeql/codeql" ]]; then
        _codeql_dist="$_search_dir/codeql"
        _codeql_bin="$_codeql_dist/codeql"
        break
      fi
      if [[ -d "$_search_dir/tools" && -x "$_search_dir/codeql" ]]; then
        _codeql_dist="$_search_dir"
        _codeql_bin="$_codeql_dist/codeql"
        break
      fi
    done
  fi

  if [[ -x "$_codeql_bin" && -d "$_codeql_dist/tools" ]]; then
    _has_quarantine=0

    for _f in \
      "$_codeql_dist" \
      "$_codeql_dist/tools/osx64/java-aarch64/bin/java" \
      "$_codeql_dist/tools/osx64/java-aarch64/lib/libjli.dylib" \
      "$_codeql_dist/tools/osx64/libtrace.dylib" \
      "$_codeql_dist/tools/osx64/java-aarch64/lib/server/libjvm.dylib"; do
      if [[ -e "$_f" ]] && xattr -p com.apple.quarantine "$_f" >/dev/null 2>&1; then
        _has_quarantine=1
        break
      fi
    done

    if [[ $_has_quarantine -eq 0 ]]; then
      if [[ -d "$_codeql_dist/tools/osx64" ]] && \
         find "$_codeql_dist/tools/osx64" -maxdepth 5 -type f -exec xattr -p com.apple.quarantine {} + 2>/dev/null | grep -q .; then
        _has_quarantine=1
      fi
    fi

    if [[ $_has_quarantine -eq 1 ]]; then
      echo "macOS: com.apple.quarantine detected on CodeQL installation at $_codeql_dist"
      echo "macOS: clearing it now..."

      # Best-effort removal (per-file find is tolerant of individual files that refuse the op).
      find "$_codeql_dist" -exec xattr -d com.apple.quarantine {} + 2>/dev/null || true
      xattr -cr "$_codeql_dist" 2>/dev/null || true

      # If some remain (e.g. permission), try sudo.
      if xattr -p com.apple.quarantine "$_codeql_dist" >/dev/null 2>&1 || \
         find "$_codeql_dist/tools/osx64" -maxdepth 6 -type f -exec xattr -p com.apple.quarantine {} + 2>/dev/null | grep -q .; then
        echo "macOS: trying sudo..."
        sudo find "$_codeql_dist" -exec xattr -d com.apple.quarantine {} + 2>/dev/null || true
        sudo xattr -cr "$_codeql_dist" 2>/dev/null || true
      fi

      # Final verification
      if xattr -p com.apple.quarantine "$_codeql_dist" >/dev/null 2>&1 || \
         find "$_codeql_dist/tools/osx64" -maxdepth 6 -type f -exec xattr -p com.apple.quarantine {} + 2>/dev/null | grep -q .; then
        echo "macOS: automatic clearance failed." >&2
        echo "Run (without sudo first):" >&2
        echo "  xattr -dr com.apple.quarantine '$_codeql_dist'" >&2
        echo "If needed:" >&2
        echo "  sudo xattr -dr com.apple.quarantine '$_codeql_dist'" >&2
        echo "Then re-run 'make codeql'." >&2
        exit 1
      fi

      echo "macOS: quarantine attributes cleared."
    fi
  fi

  unset _codeql_bin _codeql_dist _has_quarantine _f _i _target _match _search_dir _pat _up _cand 2>/dev/null || true
fi

mkdir -p "${OUT_DIR}"
rm -rf "${DB_DIR}"

cd "${ROOT_DIR}"

rm -rf coverage

codeql database create "${DB_DIR}" \
  --language=javascript-typescript \
  --source-root="${ROOT_DIR}" \
  --command="${ROOT_DIR}/scripts/codeql_build.sh"

codeql database analyze "${DB_DIR}" \
  codeql/javascript-queries:codeql-suites/javascript-code-scanning.qls \
  --format=sarif-latest \
  --output="${OUT_FILE}"

echo "CodeQL results written to ${OUT_FILE}"
