#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/install-cli.sh [--prefix <path>] [--debug]

Builds the penv CLI and installs it to <prefix>/bin/penv.

Options:
  --prefix <path>  Installation prefix. Defaults to $PENV_INSTALL_PREFIX or ~/.local.
  --debug          Build the debug binary instead of the release binary.
  --help           Show this help.
EOF
}

prefix="${PENV_INSTALL_PREFIX:-$HOME/.local}"
configuration="release"

while (($#)); do
  case "$1" in
    --prefix)
      if (($# < 2)); then
        echo "install-cli: --prefix requires a path" >&2
        exit 2
      fi
      prefix="$2"
      shift 2
      ;;
    --debug)
      configuration="debug"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "install-cli: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$prefix" in
  "~"|"~/"*) prefix="${HOME}${prefix#\~}" ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin_dir="${prefix%/}/bin"
target="${bin_dir}/penv"

if [[ "$configuration" == "release" ]]; then
  swift build -c release --product penv --package-path "$repo_root"
else
  swift build -c debug --product penv --package-path "$repo_root"
fi

built_binary="${repo_root}/.build/${configuration}/penv"
if [[ ! -x "$built_binary" ]]; then
  echo "install-cli: expected built binary at $built_binary" >&2
  exit 1
fi

mkdir -p "$bin_dir"
if [[ ! -w "$bin_dir" ]]; then
  echo "install-cli: $bin_dir is not writable. Choose another --prefix or run with appropriate permissions." >&2
  exit 1
fi

tmp="$(mktemp "${bin_dir}/.penv.XXXXXX")"
cleanup() {
  rm -f "$tmp"
}
trap cleanup EXIT

install -m 755 "$built_binary" "$tmp"
mv -f "$tmp" "$target"
trap - EXIT

echo "Installed penv to $target"

case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *)
    echo "Add this directory to PATH to run penv directly:"
    echo "  export PATH=\"$bin_dir:\$PATH\""
    ;;
esac
