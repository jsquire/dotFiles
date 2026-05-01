#!/bin/bash

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <container>" >&2
  exit 1
fi

docker exec -it "$1" /bin/bash || docker exec -it "$1" /bin/sh
