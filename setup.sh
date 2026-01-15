#!/bin/bash
# One-liner setup for new computers:
# curl -sL https://raw.githubusercontent.com/buzzboxmedia/claudehub/main/setup.sh | bash

set -e

echo "Setting up ClaudeHub..."

# Clone if not exists
if [ ! -d ~/code/claudehub ]; then
    mkdir -p ~/code
    git clone https://github.com/buzzboxmedia/claudehub.git ~/code/claudehub
fi

# Run install
~/code/claudehub/install.sh

echo ""
echo "Done! Type 'build' anytime to update."
