#!/bin/bash
# Publish script for sourcehut pages
# Usage: ./publish.sh

set -e

# Configuration
SITE_DIR="$(dirname "$0")"
USERNAME="waozi"

# Check if hut is installed
if ! command -v hut &> /dev/null; then
    echo "Error: 'hut' command not found"
    echo "Install it with: nix-shell -p hut"
    exit 1
fi

cd "$SITE_DIR"

# Publish main site (index.html + style.css + assets)
echo "Publishing main site to waozi.srht.site, waozi.xyz, www.waozi.xyz..."
tar -cvz index.html style.css wao.jpg > main.tar.gz
for domain in "$USERNAME.srht.site" "waozi.xyz" "www.waozi.xyz"; do
    echo "Uploading to $domain..."
    hut pages publish -d "$domain" main.tar.gz
    echo "✓ Published to https://$domain"
done
echo ""

# Publish Kryon Labs site
echo "Publishing Kryon Labs to kryonlabs.com and www.kryonlabs.com..."
cd kryon
tar -cvz index.html ../style.css logo.png 5bitcube.jpg icons/ manifest.json browserconfig.xml > ../kryonlabs.tar.gz
cd ..
for domain in "kryonlabs.com" "www.kryonlabs.com"; do
    echo "Uploading to $domain..."
    hut pages publish -d "$domain" kryonlabs.tar.gz
    echo "✓ Published to https://$domain"
done
echo ""

# Publish TaijiOS site
echo "Publishing TaijiOS to taijios.net and www.taijios.net..."
cd taiji
tar -cvz index.html ../style.css logo.png icons/ manifest.json browserconfig.xml > ../taiji.tar.gz
cd ..
for domain in "taijios.net" "www.taijios.net"; do
    echo "Uploading to $domain..."
    hut pages publish -d "$domain" taiji.tar.gz
    echo "✓ Published to https://$domain"
done
echo ""

# Clean up tar files
echo "Cleaning up tar files..."
rm -f main.tar.gz kryonlabs.tar.gz taiji.tar.gz
echo "✓ Cleanup complete"
echo ""

echo "✓ All sites published successfully!"
echo ""
echo "DNS Configuration (if not already set):"
echo "  - waozi.xyz: A record to 46.23.81.157"
echo "  - www.waozi.xyz: CNAME to pages.sr.ht."
echo "  - kryonlabs.com: A record to 46.23.81.157"
echo "  - www.kryonlabs.com: CNAME to pages.sr.ht."
echo "  - taijios.net: A record to 46.23.81.157"
echo "  - www.taijios.net: CNAME to pages.sr.ht."
echo ""
echo "Note: First load may take a few seconds while TLS certificates are obtained"
