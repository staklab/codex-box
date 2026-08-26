#!/bin/zsh
set -euo pipefail

app_path="${1:-/Applications/codex-box.app}"
home_apps="${HOME}/Applications"

if [[ ! -d "${app_path}" ]]; then
  echo "app_not_found=${app_path}"
  exit 1
fi

if [[ "${app_path}" == /Applications/* ]]; then
  location_class="/Applications"
elif [[ "${app_path}" == "${home_apps}"/* ]]; then
  location_class="~/Applications"
else
  location_class="non-standard"
fi

echo "app_path=${app_path}"
echo "location_class=${location_class}"
echo
echo "===== codesign ====="
codesign -dv --verbose=4 "${app_path}" 2>&1 | sed -n '1,80p'
echo
echo "===== spctl ====="
spctl -a -vv "${app_path}" 2>&1 || true
echo
echo "===== mdfind ====="
mdfind "kMDItemCFBundleIdentifier == 'com.codexbox.app'" || true
echo
echo "===== lsregister ====="
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump \
  | rg -n "codex-box\\.app|com\\.codexbox\\.app|Identifier=codex-box" \
  | head -n 120 || true
