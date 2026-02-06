#!/usr/bin/env bash
set -euo pipefail

# Expected files that must be present after downloads
# Note: Only Linux builds come from CI releases; macOS must be built locally
EXPECTED_NODE_TARBALLS=(
  "node-*-linux-x64-LATEST.tar.xz"
  "node-*-linux-arm64-LATEST.tar.xz"
)

EXPECTED_FIBERS_BINARIES=(
  "linux-x64-*.tar.gz"
  "linux-arm64-*.tar.gz"
)

check_files_exist() {
  local pattern="$1"
  local description="$2"
  # shellcheck disable=SC2086
  if ! ls $pattern 1>/dev/null 2>&1; then
    echo "ERROR: Missing expected file matching pattern: $pattern ($description)" >&2
    return 1
  fi
  echo "✓ Found: $pattern"
}

mkdir stage
cd stage || exit 1

TIMESTAMP=$(date '+%Y%m%d.%H%M')

echo "Current timestamp is $TIMESTAMP"
echo ""
echo "=== Downloading Node.js release artifacts ==="

gh release download -p "*.gz"
gh release download -p "*.xz"

echo ""
echo "=== Validating Node.js tarballs ==="
for pattern in "${EXPECTED_NODE_TARBALLS[@]}"; do
  check_files_exist "$pattern" "Node.js tarball"
done

echo ""
echo "=== Validating fibers binaries from release ==="
for pattern in "${EXPECTED_FIBERS_BINARIES[@]}"; do
  check_files_exist "$pattern" "fibers binary"
done

echo ""
echo "=== Downloading fibers package via CloudFront ==="
# Download fibers base package via CloudFront (public S3 access was disabled)
curl --fail -sS "https://asana-oss-cache.asana.biz/node-fibers/fibers-5.0.4.pc.tgz" --output fibers-5.0.4.tar.gz

if [[ ! -f fibers-5.0.4.tar.gz ]]; then
  echo "ERROR: Failed to download fibers package from S3" >&2
  exit 1
fi
echo "✓ Downloaded fibers-5.0.4.tar.gz"

tar -xzf fibers-5.0.4.tar.gz
rm fibers-5.0.4.tar.gz

if [[ ! -d package ]]; then
  echo "ERROR: fibers tarball did not contain expected 'package' directory" >&2
  exit 1
fi

echo ""
echo "=== Extracting fibers binaries into package ==="
# Only extract linux fibers binaries (not all .gz files)
find . -name "linux-*.gz" | while read -r a
do
	echo "  Extracting: $a"
	tar -xzf "$a" -C package/bin
	rm "$a"
done

tar -czf temp.tgz package/
rm -fr package
SHORT_HASH=$(cat temp.tgz | sha1sum | cut -c1-4)
echo "HASH: $SHORT_HASH"
UNIQUE="pc-${TIMESTAMP}-${SHORT_HASH}"

mv temp.tgz "fibers-5.0.4-${UNIQUE}.tgz"

echo ""
echo "=== Processing Node.js tarballs ==="
processed_count=0
for file in *.tar.xz; do
  if [[ "$file" == *-LATEST.tar.xz ]]; then
    base="${file%-LATEST.tar.xz}"
    new_name="${base}-${UNIQUE}.tar.xz"

    echo "Renaming: $file -> $new_name"
    mv "$file" "$new_name"

    if [[ "$new_name" =~ node-v([0-9.]+)-(darwin|linux)-(arm64|x64).*\.tar\.xz$ ]]; then
      version="${BASH_REMATCH[1]}"
      os="${BASH_REMATCH[2]}"
      arch="${BASH_REMATCH[3]}"
      target_dir="node-v${version}-${os}-${arch}"

      echo "Target Dir: $target_dir"
      mkdir "$target_dir"
      tar -xJf "$new_name" -C "$target_dir"

      # Flatten directory structure if needed (handle both usr/local and direct layouts)
      if [ -d "$target_dir/usr/local" ]; then
        mv "$target_dir/usr/local/"* "$target_dir/"
        rm -rf "$target_dir/usr"
      fi

      tar -cJf "$new_name" "$target_dir"

      rm -fr "$target_dir"

      echo "✓ Done: Archive now contains:"
      tar -tf "$new_name" | head
      echo ""
      ((processed_count++))
    else
      echo "Warning: Skipped $new_name due to unexpected filename format."
    fi
  fi
done

if [[ $processed_count -lt 2 ]]; then
  echo "ERROR: Expected to process at least 2 Node.js tarballs, but only processed $processed_count" >&2
  exit 1
fi

cd ..
mv stage "node-${UNIQUE}"

echo ""
echo "=== SUCCESS ==="
echo "Files are in node-${UNIQUE}, please upload to s3"
echo ""
echo "Final contents:"
ls -la "node-${UNIQUE}/"
