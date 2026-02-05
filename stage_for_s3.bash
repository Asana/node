#!/usr/bin/env bash

set -e

mkdir stage
cd stage || exit

TIMESTAMP=$(date '+%Y%m%d.%H%M')

echo "Current timestamp is $TIMESTAMP"

# Download node tarballs from the latest release
gh release download -R Asana/node -p "*.xz"

# Generate unique identifier from timestamp and hash of downloaded files
SHORT_HASH=$(cat *.xz | sha1sum | cut -c1-4)
echo "HASH: $SHORT_HASH"
UNIQUE="pc-${TIMESTAMP}-${SHORT_HASH}"

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
