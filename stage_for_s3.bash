#!/usr/bin/env bash

set -e

mkdir stage
cd stage || exit

TIMESTAMP=$(date '+%Y%m%d.%H%M')

echo "Current timestamp is $TIMESTAMP"

# Download packages and move to codez
gh release download -R Asana/node node-v22.21.1-release -p "packages_*.gz"
echo "Moving packages to $CODEZ/node/gyp"
mv packages_arm64.tar.gz $CODEZ/node/gyp/packages_arm64_node22.tar.gz
mv packages_x64.tar.gz $CODEZ/node/gyp/packages_amd64_node22.tar.gz

# Download fibers binaries and node tarballs (standard build)
gh release download -R Asana/node node-v22.21.1-release -p "linux-*.gz"
gh release download -R Asana/node node-v22.21.1-release -p "*.xz"

# Download FIPS node tarballs
gh release download -R Asana/node node-v22.21.1-fips-release -p "*.xz"

# Download fibers base package via CloudFront (public S3 access was disabled)
curl "https://asana-oss-cache.asana.biz/node-fibers/fibers-5.0.4-pc-20250515.1411-960a.tgz" --output fibers-5.0.4.tar.gz
tar -xzf fibers-5.0.4.tar.gz
rm fibers-5.0.4.tar.gz

# Extract linux fibers binaries into the package
LINUX_GZ_FILES=$(find . -name "linux-*.gz")
if [ -z "$LINUX_GZ_FILES" ]; then
	echo "WARNING: No linux-*.gz fibers archives were found to inject (check CI artifact names)"
else
	echo "$LINUX_GZ_FILES" | while read -r a; do
		echo "Injecting $(basename "$a") into package/bin..."
		tar -xzf "$a" -C package/bin
		rm "$a"
	done
fi
echo "Contents of package/bin after injection:"
ls package/bin/

# Repackage fibers with combined binaries
tar -czf temp.tgz package/
rm -rf package

# Validate combined archive contains Node 18, 20, and 22 binaries
echo "Validating combined fibers archive..."
echo "fibers.node entries in archive:"
tar -tzf temp.tgz | grep 'fibers\.node' || echo "  (none found)"
FOUND_VERSIONS=""
for bin_path in $(tar -tzf temp.tgz | grep 'fibers\.node$'); do
    abi_ver=$(echo "$bin_path" | cut -d/ -f3 | cut -d- -f3)
    case "$abi_ver" in
        109) FOUND_VERSIONS="$FOUND_VERSIONS Node18(abi=$abi_ver)" ;;
        115) FOUND_VERSIONS="$FOUND_VERSIONS Node20(abi=$abi_ver)" ;;
        127) FOUND_VERSIONS="$FOUND_VERSIONS Node22(abi=$abi_ver)" ;;
    esac
done
echo "Found binaries:${FOUND_VERSIONS}"
MISSING=""
echo "$FOUND_VERSIONS" | grep -q "Node18" || MISSING="$MISSING Node18(abi=109)"
echo "$FOUND_VERSIONS" | grep -q "Node20" || MISSING="$MISSING Node20(abi=115)"
echo "$FOUND_VERSIONS" | grep -q "Node22" || MISSING="$MISSING Node22(abi=127)"
if [ -n "$MISSING" ]; then
    echo "ERROR: Combined fibers archive is missing binaries for:$MISSING" >&2
    exit 1
fi
echo "Validation passed: archive contains binaries for Node 18, 20, and 22"

SHORT_HASH=$(cat temp.tgz | sha1sum | cut -c1-4)
echo "HASH: $SHORT_HASH"
UNIQUE="pc-${TIMESTAMP}-${SHORT_HASH}"

mv temp.tgz "fibers-5.0.4-${UNIQUE}.tgz"

# Process node tarballs
for file in *.tar.xz; do
  if [[ "$file" == *-LATEST.tar.xz ]]; then
    base="${file%-LATEST.tar.xz}"
    new_name="${base}-${UNIQUE}.tar.xz"

    echo "Renaming: $file -> $new_name"
    mv "$file" "$new_name"

    if [[ "$new_name" =~ node-v([0-9.]+)-(fips-)?(darwin|linux)-(arm64|x64).*\.tar\.xz$ ]]; then
      version="${BASH_REMATCH[1]}"
      fips="${BASH_REMATCH[2]}"
      os="${BASH_REMATCH[3]}"
      arch="${BASH_REMATCH[4]}"
      target_dir="node-v${version}-${fips}${os}-${arch}"

      echo "Target Dir: $target_dir"
      mkdir "$target_dir"
      tar -xJf "$new_name" -C "$target_dir"

      # Flatten directory structure if needed (handle both usr/local and direct layouts)
      if [ -d "$target_dir/usr/local" ]; then
        mv $target_dir/usr/local/* "$target_dir"
        rm -rf "$target_dir/usr"
      fi

      tar -cJf "$new_name" "$target_dir"

      rm -rf "$target_dir"

      echo "Done: Archive now contains:"
      tar -tf "$new_name" | head

    else
      echo "Warning: Skipped $new_name due to unexpected filename format."
    fi
  fi
done

cd ..
mv stage "node-${UNIQUE}"

echo "Files are in node-${UNIQUE}, please upload to s3"
echo "Packages were moved to $CODEZ/node/gyp/packages_{arm64,amd64}_node22.tar.gz"

# Compute SHA256 hashes for node archives
echo ""
echo "Computing SHA256 hashes..."
STAGE_DIR="node-${UNIQUE}"

SHA_LINUX_ARM64=$(shasum -a 256 "${STAGE_DIR}/node-v22.21.1-linux-arm64-${UNIQUE}.tar.xz" | cut -d' ' -f1)
SHA_LINUX_X64=$(shasum -a 256 "${STAGE_DIR}/node-v22.21.1-linux-x64-${UNIQUE}.tar.xz" | cut -d' ' -f1)
SHA_FIPS_LINUX_ARM64=$(shasum -a 256 "${STAGE_DIR}/node-v22.21.1-fips-linux-arm64-${UNIQUE}.tar.xz" | cut -d' ' -f1)
SHA_FIPS_LINUX_X64=$(shasum -a 256 "${STAGE_DIR}/node-v22.21.1-fips-linux-x64-${UNIQUE}.tar.xz" | cut -d' ' -f1)

echo "  Standard linux-arm64: $SHA_LINUX_ARM64"
echo "  Standard linux-x64:   $SHA_LINUX_X64"
echo "  FIPS linux-arm64:     $SHA_FIPS_LINUX_ARM64"
echo "  FIPS linux-x64:       $SHA_FIPS_LINUX_X64"

# Update package.json with new fibers URL
echo ""
echo "Updating $CODEZ/asana2/package.json..."
FIBERS_URL="https://asana-oss-cache.s3.us-east-1.amazonaws.com/node-fibers/fibers-5.0.4-${UNIQUE}.tgz"
sed -i '' "s|\"fibers\": \"https://asana-oss-cache.s3.us-east-1.amazonaws.com/node-fibers/fibers-5.0.4-[^\"]*\"|\"fibers\": \"${FIBERS_URL}\"|" "$CODEZ/asana2/package.json"
echo "  Updated fibers URL to: $FIBERS_URL"

# Update node_setup.bzl
echo ""
echo "Updating $CODEZ/asana2/third_party/node/node_setup.bzl..."
NODE_SETUP_FILE="$CODEZ/asana2/third_party/node/node_setup.bzl"

# Remove existing nodejs22pc and nodejs22fips blocks if present
python3 - "$NODE_SETUP_FILE" <<'PYEOF'
import sys

def remove_toolchain_block(lines, name):
    result = []
    i = 0
    while i < len(lines):
        if 'nodejs_register_toolchains(' in lines[i]:
            block = [lines[i]]
            j = i + 1
            while j < len(lines):
                block.append(lines[j])
                if lines[j].strip() == ')':
                    break
                j += 1
            if any(f'name = "{name}"' in l for l in block):
                i = j + 1  # skip the whole block
                continue
            else:
                result.extend(block)
                i = j + 1
        else:
            result.append(lines[i])
            i += 1
    return result

with open(sys.argv[1], 'r') as f:
    lines = f.read().splitlines(keepends=True)

for name in ['nodejs22pc', 'nodejs22fips']:
    lines = remove_toolchain_block(lines, name)

with open(sys.argv[1], 'w') as f:
    f.writelines(lines)
PYEOF

# Write the new toolchain blocks to a temp file
TEMP_BLOCKS=$(mktemp)
cat > "$TEMP_BLOCKS" << EOF

    nodejs_register_toolchains(
        name = "nodejs22pc",
        node_version = "22.21.1",
        node_repositories = {
            "22.21.1-linux_arm64": ("node-v22.21.1-linux-arm64-${UNIQUE}.tar.xz", "node-v22.21.1-linux-arm64", "${SHA_LINUX_ARM64}"),
            "22.21.1-linux_amd64": ("node-v22.21.1-linux-x64-${UNIQUE}.tar.xz", "node-v22.21.1-linux-x64", "${SHA_LINUX_X64}"),
        },
        node_urls = NODE_FORK_URLS,
    )

    nodejs_register_toolchains(
        name = "nodejs22fips",
        node_version = "22.21.1",
        node_repositories = {
            "22.21.1-linux_arm64": ("node-v22.21.1-fips-linux-arm64-${UNIQUE}.tar.xz", "node-v22.21.1-fips-linux-arm64", "${SHA_FIPS_LINUX_ARM64}"),
            "22.21.1-linux_amd64": ("node-v22.21.1-fips-linux-x64-${UNIQUE}.tar.xz", "node-v22.21.1-fips-linux-x64", "${SHA_FIPS_LINUX_X64}"),
        },
        node_urls = NODE_FIPS_URLS,
    )
EOF

# Find the line number of the closing paren after nodejs20pc and insert after it
LINE_NUM=$(awk '/name = "nodejs20pc"/{found=1} found && /^[[:space:]]*\)/{print NR; exit}' "$NODE_SETUP_FILE")
if [ -n "$LINE_NUM" ]; then
    head -n "$LINE_NUM" "$NODE_SETUP_FILE" > "${NODE_SETUP_FILE}.tmp"
    cat "$TEMP_BLOCKS" >> "${NODE_SETUP_FILE}.tmp"
    tail -n +$((LINE_NUM + 1)) "$NODE_SETUP_FILE" >> "${NODE_SETUP_FILE}.tmp"
    mv "${NODE_SETUP_FILE}.tmp" "$NODE_SETUP_FILE"
fi
rm "$TEMP_BLOCKS"

echo "  Added nodejs22pc and nodejs22fips toolchains"

echo ""
echo "=========================================="
echo "DONE! Please review the changes before committing:"
echo "  - $CODEZ/asana2/package.json"
echo "  - $CODEZ/asana2/third_party/node/node_setup.bzl"
echo "  - Files in ${STAGE_DIR}/ ready for S3 upload"
echo ""
echo "After uploading files to S3, run:"
echo "  cd $CODEZ/asana2 && z npm update-lockfile"
echo "=========================================="
