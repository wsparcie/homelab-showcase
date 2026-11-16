#!/bin/sh
# Prints a tar (gzip, base64 if $B64=1) of small config files under the given paths. Run inside a guest.
for pat in "$@"; do for p in $pat; do
  [ -e "$p" ] || continue
  find "$p" \( -path '*/node_modules' -o -path '*/.git' -o -path '*/cache' -o -path '*/Cache' -o -path '*/logs' -o -path '*/log' \
    -o -path '*/MediaCover' -o -path '*/Metadata' -o -path '*/metadata' -o -path '*/transcodes' -o -path '*/Backups' -o -path '*/backups' \
    -o -path '*/thumbs' -o -path '*/model_cache' -o -path '*/.storage' -o -path '*/deps' -o -path '*/tts' -o -path '*/certs' \
    -o -path '*/ssl' -o -path '*/letsencrypt' -o -path '*/keys' -o -path '*/secrets' -o -path '*/workspace' -o -path '*/.local' \
    -o -path '*/.cache' -o -path '*/asp' -o -path '*/Definitions' -o -path '*/html' -o -path '*/pgdata' -o -path '*/db' -o -path '*/model-cache' -o -path '*/world' -o -path '*/prometheus/data' -o -path '*/models' -o -path '*/transcriber/data' -o -path '*/.vscode-server' -o -path '*/extensions' -o -path '*/User/History' -o -path '*/tracearr-db' \) -prune -o \
    -type f -size -256k \( -name '*.yml' -o -name '*.yaml' -o -name '*.conf' -o -name '*.cfg' -o -name '*.ini' -o -name '*.toml' \
    -o -name '*.json' -o -name '*.xml' -o -name '*.env' -o -name '.env' -o -name '*.sh' -o -name '*.py' -o -name '*.service' \
    -o -name '*.timer' -o -name '*.nft' -o -name '*.fw' -o -name 'Dockerfile' -o -name '*.zeek' -o -name '*.rules' -o -name '*.alloy' \
    -o -name '*.lua' -o -name '*.css' -o -name 'Caddyfile' -o -name '*.md' -o -name 'fstab' -o -name 'exports' -o -name 'smb.conf' \
    -o -name 'urbackupsrv' -o -name 'node.cfg' -o -name 'networks.cfg' \) \
    ! -name '*.db' ! -name '*.sqlite*' ! -name '*.pem' ! -name '*.key' ! -name '*.crt' ! -name 'id_*' ! -name '*.kdbx' \
    ! -name 'package-lock.json' ! -name '*.min.js' ! -name '*.bak*' ! -name '*.orig' -print
done; done | tar -cf - -T - 2>/dev/null | { [ "${B64:-0}" = 1 ] && base64 | tr -d '
' || cat; }
