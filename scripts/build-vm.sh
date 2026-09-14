#!/bin/bash

set -e
set -o pipefail
set -u

export DEB_IMAGE_KIND="vm"
exec "$(dirname "$0")/build-img.sh" "$@"
