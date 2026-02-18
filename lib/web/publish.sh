#!/bin/bash
# Publish script for sourcehut pages
# Usage: ./publish.sh

set -e

# Configuration
SITE_DIR="$(dirname "$0")"
TARBALL="$SITE_DIR/site.tar.gz"
USERNAME="waozi"
DOMAINS=("$USERNAME.srht.site" "waozi.xyz" "www.waozi.xyz")

# Create tarball
echo "Creating tarball..."
cd "$SITE_DIR"
tar -cvz *.html style.css > site.tar.gz

# Check if hut is installed
if ! command -v hut &> /dev/null; then
    echo "Error: 'hut' command not found"
    echo "Install it with: nix-shell -p hut"
    exit 1
fi

# Upload to all domains
for domain in "${DOMAINS[@]}"; do
    echo "Uploading to $domain..."
    hut pages publish -d "$domain" site.tar.gz
    echo "✓ Published to https://$domain"
    echo ""
done

echo "✓ Site published successfully to all domains!"
echo "  - https://waozi.srht.site"
echo "  - https://waozi.xyz"
echo "  - https://www.waozi.xyz"
echo ""
echo "Note: First load may take a few seconds while TLS certificates are obtained"
