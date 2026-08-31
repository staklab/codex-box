#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE' >&2
Usage:
  scripts/package_dmg.sh --app /path/to/codex-box.app --version 1.2.10 [--output /path/to/file.dmg]

Creates a release DMG containing:
  - codex-box.app
  - Applications -> /Applications
USAGE
}

app_path=""
version=""
output_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      app_path="${2:-}"
      shift 2
      ;;
    --version)
      version="${2:-}"
      shift 2
      ;;
    --output)
      output_path="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "${app_path}" || -z "${version}" ]]; then
  usage
  exit 2
fi

if [[ ! -d "${app_path}" ]]; then
  echo "App bundle not found: ${app_path}" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${output_path}" ]]; then
  output_path="${repo_root}/dist/${version}/codex-box-${version}-macOS.dmg"
fi

if [[ "${output_path}" != *.dmg ]]; then
  echo "Output path must end with .dmg: ${output_path}" >&2
  exit 2
fi

staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-box-dmg.XXXXXX")"
cleanup() {
  rm -rf "${staging_dir}"
}
trap cleanup EXIT

mkdir -p "$(dirname "${output_path}")"

ditto "${app_path}" "${staging_dir}/codex-box.app"
ln -s /Applications "${staging_dir}/Applications"

hdiutil create \
  -volname "codex-box ${version}" \
  -srcfolder "${staging_dir}" \
  -ov \
  -format UDZO \
  "${output_path}"

hdiutil verify "${output_path}"
