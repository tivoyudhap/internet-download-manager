#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 /absolute/path/to/idm_native_host CHROME_EXTENSION_ID" >&2
  exit 2
fi

host_path=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
extension_id=$2
case "$extension_id" in
  *[!a-p]*|'') echo "Extension ID must contain only letters a-p." >&2; exit 2 ;;
esac
if [ "${#extension_id}" -ne 32 ]; then
  echo "Extension ID must be 32 characters." >&2
  exit 2
fi
if [ ! -x "$host_path" ]; then
  echo "Native host is not executable: $host_path" >&2
  exit 2
fi

manifest_name=com.tivoyudhap.internet_download_manager
browser_dir="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
mkdir -p "$browser_dir"
cat > "$browser_dir/$manifest_name.json" <<EOF
{
  "name": "$manifest_name",
  "description": "Internet Download Manager browser bridge",
  "path": "$host_path",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$extension_id/"]
}
EOF

echo "Native host registered for Google Chrome."
