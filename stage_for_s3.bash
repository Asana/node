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
curl "https://asana-oss-cache.asana.biz/node-fibers/fibers-5.0.4.pc.tgz" --output fibers-5.0.4.tar.gz
tar -xzf fibers-5.0.4.tar.gz
rm fibers-5.0.4.tar.gz

# Extract linux fibers binaries into the package
find . -name "linux-*.gz" | while read -r a
do
	tar -xzf "$a" -C package/bin
	rm "$a"
done

# Repackage fibers with combined binaries
tar -czf temp.tgz package/
rm -rf package
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
