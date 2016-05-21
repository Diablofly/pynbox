#!/bin/bash

# Change to the directory of this script, and get the absolute path to it.
cd `dirname "$0"`
mkdir -p software/ build/
source scripts/util.sh

ROOT=`pwd`
NACL_SDK_PEPPER_VERSION=50
WEBPORTS_PEPPER_VERSION=49
ARCHD=x86-64
NACL_ARCH=x86_64
TOOLCHAIN_ARCH=x86
OS_SUBDIR=mac

DEPOT_TOOLS_PATH=$ROOT/software/depot_tools
NACL_SDK_ROOT=$ROOT/software/nacl_sdk/pepper_$NACL_SDK_PEPPER_VERSION
WEBPORTS_DIR=$ROOT/software/webports/src

NACL_TOOLCHAIN_DIR=$NACL_SDK_ROOT/toolchain/${OS_SUBDIR}_${TOOLCHAIN_ARCH}_glibc/${NACL_ARCH}-nacl

if [ -n "$INSTALL_PYTHON_MODULE" ]; then
  pushdir "$WEBPORTS_DIR"
    # NACL_BARE=1 is a variable added by our own patch, to omit certain
    # Chrome-specific libraries from the Python build.
    run_oneline make NACL_SDK_ROOT="$NACL_SDK_ROOT" V=2 "F=$BUILD_PYTHON_FORCE" \
      NACL_BARE=1 NACL_ARCH=$NACL_ARCH FROM_SOURCE=1 TOOLCHAIN=glibc "python_modules/$INSTALL_PYTHON_MODULE"

    SUBDIR="lib/python2.7/site-packages/$INSTALL_PYTHON_MODULE"
    SANDBOX_DEST_DIR="$ROOT/build/sandbox_root/python/$SUBDIR"
    EXPECTED_DIR="${NACL_TOOLCHAIN_DIR}/usr/${SUBDIR}"
    if [ ! -e "${EXPECTED_DIR}" ]; then
      echo "Installed package not found in $EXPECTED_DIR"
      exit 1
    fi
    echo "Package installed to $EXPECTED_DIR"
    run_oneline copy_dir "$EXPECTED_DIR"/ "$SANDBOX_DEST_DIR"
  popdir
  exit 0
fi

#----------------------------------------------------------------------
# Fetch Google's depot_tools, used to check out webports and native_client from source.
# See http://dev.chromium.org/developers/how-tos/depottools
#----------------------------------------------------------------------
header "--- fetch depot_tools"
if [ ! -d "$DEPOT_TOOLS_PATH" ]; then
  run git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_TOOLS_PATH"
elif [ "$BUILD_SYNC" = "yes" ]; then
  run git -C "$DEPOT_TOOLS_PATH" pull
fi

# All we need to do to use them is make them accessible in PATH.
export PATH=$DEPOT_TOOLS_PATH:$PATH


#----------------------------------------------------------------------
# Fetch Chrome's NaCl SDK. It's big, but needed to build webports (NaCl tools built
# from sources above aren't enough).
# See https://developer.chrome.com/native-client/sdk/download.
#----------------------------------------------------------------------
header "--- fetch NaCl SDK"
NACL_SDK_BASE_DIR=`dirname "$NACL_SDK_ROOT"`
if [ ! -d "$NACL_SDK_BASE_DIR" ]; then
  run curl -O -L https://storage.googleapis.com/nativeclient-mirror/nacl/nacl_sdk/nacl_sdk.zip
  run unzip -d nacl_tmp nacl_sdk.zip
  run mv nacl_tmp/nacl_sdk "$NACL_SDK_BASE_DIR"
  run rmdir nacl_tmp
  run rm nacl_sdk.zip
fi
if [ "$BUILD_SYNC" = "yes" ]; then
  pushdir "$NACL_SDK_BASE_DIR"
    run_oneline ./naclsdk update ${VERBOSE:+-v} pepper_$NACL_SDK_PEPPER_VERSION
  popdir
fi


#----------------------------------------------------------------------
# Maybe fetch Native Client source code (disabled by default because not currently needed).
# See https://www.chromium.org/nativeclient/how-tos/how-to-use-git-svn-with-native-client
#----------------------------------------------------------------------
if [ "$BUILD_NACL_SRC" = "yes" ]; then
  header "--- fetch native_client source code"
  NACL_DIR="$ROOT"/software/nacl/native_client
  NACL_SRC_SYNC=$BUILD_SYNC
  if [ ! -d "$NACL_DIR" ]; then
    mkdir -p software/nacl
    pushdir software/nacl
      run python -u $DEPOT_TOOLS_PATH/fetch.py --no-history nacl
    popdir
    NACL_SRC_SYNC=yes
  fi
  pushdir "$NACL_DIR"
    run git checkout master
    run git pull
    if [ "$NACL_SRC_SYNC" = "yes" ]; then
      run_oneline gclient sync
    fi
  popdir
fi


#----------------------------------------------------------------------
# Build from source Native Client's sel_ldr, the stand-alone "Secure ELF Loader"
#----------------------------------------------------------------------
if [ "$BUILD_NACL_SRC" = "yes" ]; then
  header "--- build native_client's sel_ldr"
  pushdir "$NACL_DIR"

    # Workaround for only having XCode command-line tools without full SDK (which is fine)
    apply_patch $ROOT/patches/SConstruct.patch

    run_oneline ./scons ${VERBOSE:+--verbose} platform=$ARCHD sel_ldr

    BUILT_SEL_LDR_BINARY=`pwd`/scons-out/opt-mac-$ARCHD/staging/sel_ldr
    echo "Build result should be here: $BUILT_SEL_LDR_BINARY"
  popdir
fi


#----------------------------------------------------------------------
# Fetch webports.
# See instructions here: https://chromium.googlesource.com/webports/
#----------------------------------------------------------------------
header "--- fetch webports"
WEBPORTS_SYNC=$BUILD_SYNC
if [ ! -d "$WEBPORTS_DIR" ]; then
  WEBPORTS_BASE_DIR=`dirname "$WEBPORTS_DIR"`
  mkdir -p "$WEBPORTS_BASE_DIR"
  pushdir "$WEBPORTS_BASE_DIR"
    # Use a clone of webports that includes changes we need. The clone is of https://chromium.googlesource.com/webports/.
    run gclient config --unmanaged --name=src https://github.com/dsagal/webports.git
    run gclient sync --with_branch_heads
    #run git -C src checkout -b pepper_$WEBPORTS_PEPPER_VERSION origin/pepper_$WEBPORTS_PEPPER_VERSION
  popdir
  WEBPORTS_SYNC=yes
fi
pushdir "$WEBPORTS_DIR"
  if [ "$WEBPORTS_SYNC" = "yes" ]; then
    run_oneline gclient sync
  fi
popdir


#----------------------------------------------------------------------
# Build python webport
#----------------------------------------------------------------------
header "--- build python webport"
pushdir "$WEBPORTS_DIR"

  # NACL_BARE=1 is a variable added to our webports clone, to omit certain
  # Chrome-specific libraries from the Python build.
  run_oneline make NACL_SDK_ROOT="$NACL_SDK_ROOT" V=2 "F=$BUILD_PYTHON_FORCE" \
    NACL_BARE=1 NACL_ARCH=$NACL_ARCH FROM_SOURCE=1 TOOLCHAIN=glibc python

popdir


#----------------------------------------------------------------------
# Collect files for sandbox
#----------------------------------------------------------------------
header "--- collect files for sandbox"

mkdir -p build/sandbox_root build/sandbox_root/usr/lib

# Copy the outer binaries and libraries needed to run python in the sandbox.
copy_file $NACL_SDK_ROOT/tools/sel_ldr_$NACL_ARCH       build/sel_ldr
copy_file $NACL_SDK_ROOT/tools/irt_core_$NACL_ARCH.nexe build/irt_core.nexe
copy_file $NACL_TOOLCHAIN_DIR/lib/runnable-ld.so        build/runnable-ld.so

# Copy all of python installation into the sandbox.
run_oneline copy_dir "$WEBPORTS_DIR"/out/build/python/install_${ARCHD}_glibc/payload/ build/sandbox_root/python

# This command shows most of the shared libraries the python binary needs.
# echo "$NACL_TOOLCHAIN_DIR/bin/objdump -p build/sandbox_root/python/bin/python2.7.nexe | grep NEEDED"
copy_file $NACL_TOOLCHAIN_DIR/lib/libdl.so.11835d88         build/sandbox_root/usr/lib/
copy_file $NACL_TOOLCHAIN_DIR/lib/libpthread.so.11835d88    build/sandbox_root/usr/lib/
copy_file $NACL_TOOLCHAIN_DIR/lib/libstdc++.so.6            build/sandbox_root/usr/lib/
copy_file $NACL_TOOLCHAIN_DIR/lib/libutil.so.11835d88       build/sandbox_root/usr/lib/
copy_file $NACL_TOOLCHAIN_DIR/lib/libm.so.11835d88          build/sandbox_root/usr/lib/
copy_file $NACL_TOOLCHAIN_DIR/lib/libc.so.11835d88          build/sandbox_root/usr/lib/
copy_file $NACL_TOOLCHAIN_DIR/lib/librt.so.11835d88         build/sandbox_root/usr/lib/

# Additional libraries required generally or for some python modules.
copy_file $NACL_TOOLCHAIN_DIR/lib/libgcc_s.so.1             build/sandbox_root/usr/lib/
copy_file $NACL_TOOLCHAIN_DIR/lib/libcrypt.so.11835d88      build/sandbox_root/usr/lib/
copy_file $NACL_TOOLCHAIN_DIR/usr/lib/libz.so.1             build/sandbox_root/usr/lib/
copy_file $NACL_TOOLCHAIN_DIR/usr/lib/libncurses.so.5       build/sandbox_root/usr/lib/
copy_file $NACL_TOOLCHAIN_DIR/usr/lib/libpanel.so.5         build/sandbox_root/usr/lib/
copy_file $NACL_TOOLCHAIN_DIR/usr/lib/libssl.so.1.0.0       build/sandbox_root/usr/lib/
copy_file $NACL_TOOLCHAIN_DIR/usr/lib/libbz2.so.1.0         build/sandbox_root/usr/lib/
copy_file $NACL_TOOLCHAIN_DIR/usr/lib/libreadline.so        build/sandbox_root/usr/lib/
copy_file $NACL_TOOLCHAIN_DIR/usr/lib/libcrypto.so.1.0.0    build/sandbox_root/usr/lib/

#----------------------------------------------------------------------
# Demonstrate and test the building of C++ code for the sandbox.
#----------------------------------------------------------------------
# Build a sample C++ program, which tests a few things about the sandbox.
mkdir -p build/sandbox_root/test
echo "Here is how you can build C++ code for use in the sandbox"
NACL_LIBDIR=$NACL_SDK_ROOT/lib/glibc_${NACL_ARCH}/Release
run_oneline $NACL_TOOLCHAIN_DIR/bin/g++ -I$NACL_SDK_ROOT/include -L$NACL_LIBDIR -o build/sandbox_root/test/test_hello.nexe test/test_hello.cc -ldl
run ./sandbox_run test/test_hello.nexe

#----------------------------------------------------------------------
# Run a bunch of python tests under the sandbox.
#----------------------------------------------------------------------
# Copy to the sandbox and run a Python test script which tests various things about the sandbox.
run cp test/test_nacl.py build/sandbox_root/test/test_nacl.py
run ./pynbox test/test_nacl.py