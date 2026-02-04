#!/bin/bash
set -e

# Build Node.js with fibers and native packages locally
# Combines: Dockerfile.Node22, Dockerfile.Fibers, Dockerfile.Packages

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/local-build-output"
NODE_INSTALL_DIR="${OUTPUT_DIR}/node"
FIBERS_DIR="${OUTPUT_DIR}/node-fibers"
PACKAGES_DIR="${OUTPUT_DIR}/packages"

# Number of parallel jobs for make
JOBS=${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)}

echo "=== Local Node.js + Fibers Build Script ==="
echo "Output directory: ${OUTPUT_DIR}"
echo "Parallel jobs: ${JOBS}"
echo ""

# Clean previous output
rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"

# ============================================
# Stage 1: Build Node.js (Dockerfile.Node22)
# ============================================
echo "=== Stage 1: Building Node.js ==="

cd "${SCRIPT_DIR}"

# Configure if needed
if [ ! -f config.gypi ] || [ ! -f config.mk ]; then
    echo "Configuring Node.js with pointer compression..."
    ./configure --experimental-enable-pointer-compression
fi

# Build Node.js
echo "Building Node.js (this may take a while)..."
make -j${JOBS}

# Install to local directory
echo "Installing Node.js to ${NODE_INSTALL_DIR}..."
make install DESTDIR="${NODE_INSTALL_DIR}" PREFIX=""

# Verify installation
NODE_BIN="${NODE_INSTALL_DIR}/bin/node"
NPM_BIN="${NODE_INSTALL_DIR}/bin/npm"

echo "Verifying Node.js installation..."
"${NODE_BIN}" --version
"${NODE_BIN}" -p "process.arch"
echo "Node module version: $("${NODE_BIN}" -p "process.versions.modules")"

# IMPORTANT: Put our custom Node first in PATH so npm/node-gyp use it for native builds
export PATH="${NODE_INSTALL_DIR}/bin:${PATH}"
echo "Using node from: $(which node)"

# ============================================
# Stage 2: Build node-fibers (Dockerfile.Fibers)
# ============================================
echo ""
echo "=== Stage 2: Building node-fibers ==="

mkdir -p "${FIBERS_DIR}"
cd "${FIBERS_DIR}"

# Clone node-fibers if not already present
if [ ! -d "node-fibers" ]; then
    echo "Cloning node-fibers..."
    git clone --branch jackstrohm_node20_fibers --depth 1 https://github.com/asana/node-fibers.git node-fibers
fi

cd node-fibers

echo "Building node-fibers..."
"${NPM_BIN}" install --nodedir="${NODE_INSTALL_DIR}"

echo "Running node-fibers tests (failures allowed)..."
"${NPM_BIN}" test || true

# Remove repl as in Dockerfile
rm -f bin/repl

echo "node-fibers built successfully"

# ============================================
# Stage 3: Build native packages (Dockerfile.Packages)
# ============================================
echo ""
echo "=== Stage 3: Building native packages ==="

mkdir -p "${PACKAGES_DIR}"
cd "${PACKAGES_DIR}"

# Initialize a package.json if needed
if [ ! -f package.json ]; then
    echo '{"name": "native-packages", "private": true}' > package.json
fi

echo "Installing bcrypt@5.1.0..."
"${NPM_BIN}" install --nodedir="${NODE_INSTALL_DIR}" bcrypt@5.1.0

echo "Installing cld@2.9.1..."
"${NPM_BIN}" install --nodedir="${NODE_INSTALL_DIR}" cld@2.9.1

echo "Installing unix-dgram@2.0.6..."
"${NPM_BIN}" install --nodedir="${NODE_INSTALL_DIR}" unix-dgram@2.0.6

# ============================================
# Summary
# ============================================
echo ""
echo "=== Build Complete ==="
echo ""
echo "Output directory structure:"
echo "  ${OUTPUT_DIR}/"
echo "  ├── node/           # Node.js installation"
echo "  │   ├── bin/node"
echo "  │   ├── bin/npm"
echo "  │   └── ..."
echo "  ├── node-fibers/    # node-fibers addon"
echo "  │   └── node-fibers/"
echo "  └── packages/       # Native packages (bcrypt, cld, unix-dgram)"
echo "      └── node_modules/"
echo ""
echo "To use this Node.js:"
echo "  export PATH=\"${NODE_INSTALL_DIR}/bin:\$PATH\""
echo "  node --version"
echo ""
echo "To test fibers:"
echo "  cd ${FIBERS_DIR}/node-fibers && ${NODE_BIN} test.js"
