#!/bin/bash
# Bake guix publish's cache for Roguix's items one at a time, so no guest
# request ever starts compression. Usage: roguix-prebake.sh HASH-LIST
while read -r h; do
  for i in $(seq 1 360); do
    code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8181/$h.narinfo)
    [ "$code" = 200 ] && break
    sleep 5
  done
  echo "$h $code"
done < "$1"
