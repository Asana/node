#!/usr/bin/env bash
#
# Downloads this branch's release artifacts (standard + FIPS Node builds and the native
# packages) and stages them under a directory that mirrors their s3://asana-oss-cache keys.
# Every file gets a unique suffix so uploading never overwrites an existing object (the
# bucket is not versioned). Prints the codez Starlark to point at the new files.
#
# Usage: ./stage_for_s3.bash   (run from the root of this repository)

set -euo pipefail

NODE_MAJOR=$(grep '#define NODE_MAJOR_VERSION' src/node_version.h | awk '{print $3}')
NODE_MINOR=$(grep '#define NODE_MINOR_VERSION' src/node_version.h | awk '{print $3}')
NODE_PATCH=$(grep '#define NODE_PATCH_VERSION' src/node_version.h | awk '{print $3}')
VERSION="${NODE_MAJOR}.${NODE_MINOR}.${NODE_PATCH}"
REPO=Asana/node

DOWNLOAD_DIR=$(mktemp -d)
trap 'rm -rf "$DOWNLOAD_DIR"' EXIT

gh release download -R "$REPO" "node-v${VERSION}-release" -D "$DOWNLOAD_DIR" -p "*.tar.xz" -p "packages_*.tar.gz"
gh release download -R "$REPO" "node-v${VERSION}-fips-release" -D "$DOWNLOAD_DIR" -p "*.tar.xz"

ARCHIVE_HASH=$(cat "$DOWNLOAD_DIR"/*.tar.xz | shasum -a 1 | cut -c1-4)
UNIQUE="pc-$(date '+%Y%m%d.%H%M')-${ARCHIVE_HASH}"
STAGE="node-v${VERSION}-${UNIQUE}"
mkdir -p "$STAGE/node/fork/v${VERSION}" "$STAGE/node-fips/v${VERSION}" "$STAGE/node-gyp"

# Repackage each build so the archive has a single top-level node-v<version>-[fips-]linux-<arch>
# directory, the layout rules_nodejs expects, instead of the usr/local DESTDIR layout.
for flavor in "" "fips-"; do
  key_prefix=${flavor:+fips_}
  for arch in x64 arm64; do
    base="node-v${VERSION}-${flavor}linux-${arch}"
    src="$DOWNLOAD_DIR/${base}-LATEST.tar.xz"
    test -f "$src" || { echo "ERROR: missing $(basename "$src") in the release" >&2; exit 1; }

    work=$(mktemp -d)
    mkdir "$work/$base"
    tar -xJf "$src" -C "$work/$base"
    if [ -d "$work/$base/usr/local" ]; then
      mv "$work/$base"/usr/local/* "$work/$base"
      rm -rf "${work:?}/$base/usr"
    fi

    if [ -z "$flavor" ]; then dest_dir="$STAGE/node/fork/v${VERSION}"; else dest_dir="$STAGE/node-fips/v${VERSION}"; fi
    file="${base}-${UNIQUE}.tar.xz"
    tar -C "$work" -cJf "$dest_dir/$file" "$base"
    rm -rf "$work"

    printf -v "FILE_${key_prefix}${arch}" %s "$file"
    printf -v "SHA_${key_prefix}${arch}" %s "$(shasum -a 256 "$dest_dir/$file" | cut -d' ' -f1)"
  done
done

for arch in x64 arm64; do
  if [ "$arch" = x64 ]; then bazel_arch=amd64; else bazel_arch=arm64; fi
  src="$DOWNLOAD_DIR/packages_${arch}.tar.gz"
  if [ ! -f "$src" ]; then
    echo "WARNING: packages_${arch}.tar.gz is not in the release; run build-node-packages.yml first"
    continue
  fi
  sha=$(shasum -a 256 "$src" | cut -d' ' -f1)
  file="packages_${bazel_arch}_node${NODE_MAJOR}-${sha:0:8}.tar.gz"
  cp "$src" "$STAGE/node-gyp/$file"
  printf -v "FILE_packages_${bazel_arch}" %s "$file"
  printf -v "SHA_packages_${bazel_arch}" %s "$sha"
done

echo ""
echo "Staged files (upload with: aws s3 cp --recursive $STAGE/ s3://asana-oss-cache/):"
(cd "$STAGE" && find . -type f | sort)

# shellcheck disable=SC2154 # FILE_* and SHA_* are assigned with printf -v above.
cat <<EOF

=== asana2/third_party/node/node_toolchains_bzlmod.bzl ===

    node${NODE_MAJOR}pc_kwargs = dict(
        node_version = "${VERSION}",
        node_repositories = {
            "${VERSION}-linux_arm64": ("${FILE_arm64}", "node-v${VERSION}-linux-arm64", "${SHA_arm64}"),
            "${VERSION}-linux_amd64": ("${FILE_x64}", "node-v${VERSION}-linux-x64", "${SHA_x64}"),
        },
        node_urls = NODE_FORK_URLS,
    )

    node${NODE_MAJOR}fips_kwargs = dict(
        node_version = "${VERSION}",
        node_repositories = {
            "${VERSION}-linux_arm64": ("${FILE_fips_arm64}", "node-v${VERSION}-fips-linux-arm64", "${SHA_fips_arm64}"),
            "${VERSION}-linux_amd64": ("${FILE_fips_x64}", "node-v${VERSION}-fips-linux-x64", "${SHA_fips_x64}"),
        },
        node_urls = NODE_FIPS_URLS,
    )
EOF

for bazel_arch in amd64 arm64; do
  file_var="FILE_packages_${bazel_arch}"
  sha_var="SHA_packages_${bazel_arch}"
  if [ -n "${!file_var:-}" ]; then
    cat <<EOF

=== asana2/third_party/bazel_workspace/tools_repositories.bzl ===
        name = "node_gyp_packages_${bazel_arch}_node${NODE_MAJOR}",
        downloaded_file_path = "packages_${bazel_arch}_node${NODE_MAJOR}.tar.gz",
        urls = ["https://asana-oss-cache.s3.us-east-1.amazonaws.com/node-gyp/${!file_var}"],
        sha256 = "${!sha_var}",
EOF
  fi
done
