#!/bin/bash
# One-liner setup for new computers:
# curl -sL https://raw.githubusercontent.com/buzzboxmedia/claudehub/main/setup.sh | bash
#
# Note: After Dropbox syncs, use ~/Dropbox/claudehub/go.sh instead

set -e

echo "Setting up ClaudeHub..."

# Clone if not exists
if [ ! -d ~/Code/claudehub ]; then
    mkdir -p ~/Code
    git clone git@github.com:buzzboxmedia/claudehub.git ~/Code/claudehub
fi

# Run install
~/Code/claudehub/install.sh

echo ""
echo "Done! Once Dropbox syncs, use: ~/Dropbox/claudehub/go.sh"
