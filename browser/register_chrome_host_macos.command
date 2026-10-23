#!/bin/sh
set -eu

app_path="/Applications/Internet Download Manager.app"
host_path="$app_path/Contents/Resources/idm_native_host"
setup_script="$app_path/Contents/Resources/setup_chrome_host_macos.sh"

if [ ! -x "$host_path" ] || [ ! -f "$setup_script" ]; then
  echo "Move Internet Download Manager.app to /Applications first."
  printf 'Press Return to close... '
  read -r _
  exit 1
fi

printf 'Paste the IDM Chrome extension ID from chrome://extensions: '
read -r extension_id
if /bin/sh "$setup_script" "$host_path" "$extension_id"; then
  printf '\nChrome native host registered. Restart Chrome to use IDM downloads.\n'
else
  printf '\nNative host registration failed. Check the extension ID and try again.\n'
  printf 'Press Return to close... '
  read -r _
  exit 1
fi
printf 'Press Return to close... '
read -r _
