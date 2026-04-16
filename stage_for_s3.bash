#!/usr/bin/env bash

mkdir stage
cd stage || exit

TIMESTAMP=$(date '+%Y%m%d.%H%M')

echo "Current timestamp is $TIMESTAMP"

gh release download -p "*.gz"
gh release download -p "*.xz"

# Separate packages tarballs — these are uploaded to S3 by the build-node-packages.yml
# workflow (with content-hashed keys like packages_amd64_node22-bb5ac136.tar.gz) and
# consumed by Bazel via http_file in codez. They should NOT be mixed into the fibers archive.
echo ""
echo "=== Native packages (node-gyp) ==="
echo "These are uploaded to s3://asana-oss-cache/node-gyp/ by the build-node-packages.yml workflow"
echo "with content-hashed S3 keys. Each build produces an immutable artifact."
for pkg in packages_*.tar.gz; do
  if [ -f "$pkg" ]; then
    echo "  $pkg: sha256=$(sha256sum "$pkg" | awk '{print $1}')"
    rm "$pkg"
  fi
done
echo "No manual action needed for packages — they are already in S3."
echo ""

curl "https://asana-oss-cache.s3.us-east-1.amazonaws.com/node-fibers/fibers-5.0.4.pc.tgz"  --output fibers-5.0.4.tar.gz
tar -xzf fibers-5.0.4.tar.gz

find . -name "*.gz" | while read -r a
do
	tar -xzf "$a" -C package/bin
	rm "$a"
done

tar -czf temp.tgz package/
rm -fr package
SHORT_HASH=$(cat temp.tgz | sha1sum | cut -c1-4)
echo "HASH: $SHORT_HASH"
UNIQUE="pc-${TIMESTAMP}-${SHORT_HASH}"

mv temp.tgz "fibers-5.0.4-${UNIQUE}.tgz"

for file in *.tar.xz; do
  if [[ "$file" == *-LATEST.tar.xz ]]; then
    base="${file%-LATEST.tar.xz}"
    new_name="${base}-${UNIQUE}.tar.xz"

    echo "Renaming: $file -> $new_name"
    mv "$file" "$new_name"

    if [[ "$new_name" =~ node-v([0-9.]+)-(darwin|linux)-(arm64|x64)-pc.*\.tar\.xz$ ]]; then
      version="${BASH_REMATCH[1]}"
      os="${BASH_REMATCH[2]}"
      arch="${BASH_REMATCH[3]}"
      target_dir="node-v${version}-${os}-${arch}"

      echo "Target Dir: $target_dir"
      mkdir "$target_dir"
      tar -xzf "$new_name" -C "$target_dir"
      mv "$target_dir/usr/local/*" "$target_dir"
      rm -fr "$target_dir/usr/local"

      tar -cJf "$new_name" "$target_dir"

      rm -fr "$target_dir"

      echo "✅ Done: Archive now contains:"
      tar -tf "$new_name" | head

    else
      echo "Warning: Skipped $new_name due to unexpected filename format."
    fi
  fi
done


cd ..
mv stage "node-${UNIQUE}"

echo "Files are in node-${UNIQUE}, please upload to s3"



