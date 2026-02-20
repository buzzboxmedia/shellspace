#!/bin/bash
# One-liner setup for new computers:
# curl -sL https://raw.githubusercontent.com/buzzboxmedia/shellspace/main/setup.sh | bash
#
# Note: After Dropbox syncs, use ~/Dropbox/shellspace/go.sh instead

set -e

echo "Setting up Shellspace..."

# Clone if not exists
if [ ! -d ~/Code/shellspace ]; then
    mkdir -p ~/Code
    git clone git@github.com:buzzboxmedia/shellspace.git ~/Code/shellspace
fi

# Run install
~/Code/shellspace/install.sh

echo ""
echo "Done! Once Dropbox syncs, use: ~/Dropbox/shellspace/go.sh"
