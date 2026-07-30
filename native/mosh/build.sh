#!/usr/bin/env bash
#
# Build mosh-client from source for every shipped ABI.
#
#   native/mosh/build.sh                 build all ABIs into jniLibs
#   native/mosh/build.sh arm64-v8a       build one
#   NATIVE_MOSH_CACHE=~/src build.sh     reuse a tarball cache
#
# Output: androidApp/src/androidMain/jniLibs/<abi>/libmosh_client_exec.so
#
# The .so name is deliberate and is not a library. Android extracts and marks
# executable everything under jniLibs, and nativeLibraryDir is the one place an
# app may exec from under W^X, so the client ships as libmosh_client_exec.so
# and is exec'd, not loaded.
#
# This script, versions.env, and the four tarballs it names are part of the
# Corresponding Source package for the mosh-client binary. See README.md.
#
# ---------------------------------------------------------------------------
# Four things here look like paranoia and are not. Each produced a convincing
# false pass during the Stage 2.0 spike before it was caught:
#
#   1. Pristine sources per ABI, never a copied build tree. Copying the arm64
#      tree and re-running configure+make left stale arm64 objects: mosh-client
#      was never rebuilt and got re-stripped under another ABI's name, and
#      libcrypto.a ended up holding a mix of arm64 and x86_64 members. A mixed
#      archive passes readelf -h, which reads only the first member.
#   2. Reset the environment between ABIs. LDFLAGS/LIBS/PKG_CONFIG_* exported
#      for one ABI's mosh step leak into the next ABI's dependency builds,
#      which then link against the wrong sysroot. It surfaces three layers
#      away as ncurses reporting "C compiler cannot create executables".
#   3. Assert on every artifact, and make the assertion fail on a MISSING file.
#      A check that scans for mismatches finds none in an empty result, so the
#      obvious spelling reports OK for a library that was never built.
#   4. Check exit status explicitly. `make > log 2>&1 && make install > log`
#      followed by `echo $?` reports the status of the ECHO's predecessor, not
#      of the build, which is how a failed step got logged as success.
# ---------------------------------------------------------------------------

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/versions.env"

# Digest of versions.env with comments, blank lines and ordering removed, so a
# comment edit or a reordering does not force a rebuild but any actual setting
# change does. Shared by build.sh and verify.sh, which must agree exactly.
normalized_config_digest() {
  grep -vE '^[[:space:]]*(#|$)' "$SCRIPT_DIR/versions.env" | sed 's/[[:space:]]*$//' | sort | sha256sum | cut -d' ' -f1
}

ANDROID_HOME=${ANDROID_HOME:-$HOME/.local/opt/android-sdk}
NDK=$ANDROID_HOME/ndk/$NDK_VERSION
TOOLCHAIN=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin
CMAKE_BIN=$ANDROID_HOME/cmake/3.22.1/bin
JNILIBS=$REPO_ROOT/androidApp/src/androidMain/jniLibs

WORK=${NATIVE_MOSH_WORK:-${TMPDIR:-/tmp}/slipshell-mosh-build}
CACHE=${NATIVE_MOSH_CACHE:-$WORK/dl}

TARGET_ABIS=${*:-$ABIS}

die() { echo "build.sh: $*" >&2; exit 1; }
step() { echo; echo "=== $* ==="; }

[ -d "$NDK" ] || die "NDK $NDK_VERSION not found at $NDK. Install it with sdkmanager 'ndk;$NDK_VERSION'."
[ -x "$CMAKE_BIN/cmake" ] || die "cmake not found at $CMAKE_BIN. Install it with sdkmanager 'cmake;3.22.1'."
command -v g++ >/dev/null || die "a host g++ is required to build protoc for the build machine"

mkdir -p "$WORK" "$CACHE"

# --- sources ---------------------------------------------------------------
#
# Verify BEFORE extracting, and re-verify a cached file every run. A cache that
# is trusted because it exists is a cache that silently serves a corrupted or
# swapped tarball forever.

fetch() {
  local name=$1 url=$2 want=$3
  # Separate statement: under set -u, bash localizes every name in a `local`
  # command before evaluating any right-hand side, so "$CACHE/$name" on the
  # same line reads an unset variable.
  local f="$CACHE/$name"
  local got
  if [ -f "$f" ]; then
    got=$(sha256sum "$f" | cut -d' ' -f1)
    if [ "$got" = "$want" ]; then echo "  cached  $name"; return 0; fi
    echo "  cache miss (sha256 $got != $want), refetching $name"
    rm -f "$f"
  fi
  echo "  fetch   $name"
  curl -sfL --retry 3 -o "$f" "$url" || die "download failed: $url"
  got=$(sha256sum "$f" | cut -d' ' -f1)
  [ "$got" = "$want" ] || die "sha256 mismatch for $name
  expected $want
  got      $got
This is either a corrupted download or a substituted tarball. Do not proceed."
  echo "  ok      $name sha256 verified"
}

step "Sources"
fetch "mosh-$MOSH_VERSION.tar.gz"          "$MOSH_URL"     "$MOSH_SHA256"
fetch "openssl-$OPENSSL_VERSION.tar.gz"    "$OPENSSL_URL"  "$OPENSSL_SHA256"
fetch "protobuf-cpp-$PROTOBUF_VERSION.tar.gz" "$PROTOBUF_URL" "$PROTOBUF_SHA256"
fetch "ncurses-$NCURSES_VERSION.tar.gz"    "$NCURSES_URL"  "$NCURSES_SHA256"

# --- host protoc -----------------------------------------------------------
#
# mosh's build compiles a .proto, which needs a protoc that runs on the BUILD
# machine, from the same protobuf release as the target library. A mismatched
# protoc produces generated code the target libprotobuf rejects.

# Built in place and used from the build tree. There is no `cmake --install`
# step because installing pulls in targets we never build: `ninja protoc`
# produces the compiler and libprotoc, but the install rules also want
# libprotobuf-lite.a, so installing fails on a build that otherwise succeeded.
HOST_PROTOC=$WORK/host-build-$PROTOBUF_VERSION/protoc
if [ ! -x "$HOST_PROTOC" ]; then
  step "Host protoc $PROTOBUF_VERSION"
  rm -rf "$WORK/host-src" "$WORK/host-build-$PROTOBUF_VERSION"
  mkdir -p "$WORK/host-src" "$WORK/host-build-$PROTOBUF_VERSION"
  tar xzf "$CACHE/protobuf-cpp-$PROTOBUF_VERSION.tar.gz" -C "$WORK/host-src" --strip-components=1 || die "extract protobuf (host)"
  (
    cd "$WORK/host-build-$PROTOBUF_VERSION" &&
    "$CMAKE_BIN/cmake" "$WORK/host-src" -G Ninja \
      -DCMAKE_MAKE_PROGRAM="$CMAKE_BIN/ninja" \
      -DCMAKE_BUILD_TYPE=Release \
      -Dprotobuf_BUILD_TESTS=OFF \
      -Dprotobuf_BUILD_SHARED_LIBS=OFF > cmake.log 2>&1 &&
    "$CMAKE_BIN/ninja" -j"$(nproc)" protoc > build.log 2>&1
  ) || { tail -n 20 "$WORK/host-build-$PROTOBUF_VERSION"/cmake.log "$WORK/host-build-$PROTOBUF_VERSION"/build.log 2>/dev/null; die "host protoc build failed"; }
  [ -x "$HOST_PROTOC" ] || die "host protoc build reported success but produced no binary at $HOST_PROTOC"
fi
# Run it AND check the version, rather than trusting that the file exists.
#
# The work directory persists between runs, so an existence-only check hands a
# previous pin's protoc to a build whose target libprotobuf came from the new
# one. protoc and libprotobuf must be the same release: mismatched generated
# code either fails to compile three layers down or, worse, compiles. The cache
# path is version-keyed so this cannot normally happen, and the assertion below
# still catches a hand-placed or half-written binary at that path.
HOST_PROTOC_VERSION=$("$HOST_PROTOC" --version 2>/dev/null) || die "host protoc at $HOST_PROTOC does not run"
case "$HOST_PROTOC_VERSION" in
  *"$PROTOBUF_VERSION"*) ;;
  *) die "host protoc reports '$HOST_PROTOC_VERSION' but versions.env pins $PROTOBUF_VERSION.
protoc and libprotobuf must come from the same release. Remove $WORK and rebuild." ;;
esac
echo "  ok      host protoc $HOST_PROTOC_VERSION"

# --- per-ABI ---------------------------------------------------------------

openssl_target_for() {
  case $1 in
    arm64-v8a)   echo android-arm64 ;;
    armeabi-v7a) echo android-arm ;;
    x86_64)      echo android-x86_64 ;;
  esac
}
cc_prefix_for() {
  case $1 in
    arm64-v8a)   echo aarch64-linux-android ;;
    armeabi-v7a) echo armv7a-linux-androideabi ;;
    x86_64)      echo x86_64-linux-android ;;
  esac
}
# configure --host triple. armeabi-v7a's compiler prefix and its autotools host
# triple differ (armv7a-linux-androideabi vs arm-linux-androideabi), which is
# why these are two separate functions and not one.
host_triple_for() {
  case $1 in
    arm64-v8a)   echo aarch64-linux-android ;;
    armeabi-v7a) echo arm-linux-androideabi ;;
    x86_64)      echo x86_64-linux-android ;;
  esac
}

build_abi() {
  local abi=$1
  local prefix="$WORK/sysroot-$abi" w="$WORK/work-$abi"
  local osslt cc host
  osslt=$(openssl_target_for "$abi") || die "unknown ABI $abi"
  cc=$(cc_prefix_for "$abi")
  host=$(host_triple_for "$abi")

  step "$abi"

  # Hazard 1: pristine every time. Never reuse or copy a build tree.
  rm -rf "$prefix" "$w"
  mkdir -p "$prefix/lib" "$prefix/include" "$w"

  # Hazard 2: reset every variable the mosh step exports, so the previous ABI's
  # flags cannot leak into this one's dependency builds.
  unset CPPFLAGS CXXFLAGS CFLAGS LDFLAGS LIBS PKG_CONFIG_LIBDIR PKG_CONFIG_PATH
  export PATH="$CMAKE_BIN:$TOOLCHAIN:$PATH"
  export CC="$TOOLCHAIN/${cc}${ANDROID_API}-clang"
  export CXX="$TOOLCHAIN/${cc}${ANDROID_API}-clang++"
  export AR="$TOOLCHAIN/llvm-ar" RANLIB="$TOOLCHAIN/llvm-ranlib" STRIP="$TOOLCHAIN/llvm-strip"
  [ -x "$CC" ] || die "$abi: no compiler at $CC"

  # OpenSSL. no-shared so it links statically into the client. no-tests and
  # build_libs keep it to the two libraries mosh needs.
  echo "  openssl $OPENSSL_VERSION"
  mkdir -p "$w/ossl"
  tar xzf "$CACHE/openssl-$OPENSSL_VERSION.tar.gz" -C "$w/ossl" --strip-components=1 || die "$abi: extract openssl"
  (
    cd "$w/ossl" &&
    ANDROID_NDK_ROOT=$NDK PATH="$TOOLCHAIN:$PATH" \
      ./Configure "$osslt" -D__ANDROID_API__="$ANDROID_API" no-shared no-tests no-docs \
      --prefix="$prefix" > configure.log 2>&1 &&
    make -j"$(nproc)" build_libs > build.log 2>&1 &&
    make install_dev > install.log 2>&1
  ) || { tail -n 20 "$w/ossl"/*.log 2>/dev/null; die "$abi: openssl build failed"; }

  # protobuf, static, no protoc for the target (we use the host one above).
  echo "  protobuf $PROTOBUF_VERSION"
  mkdir -p "$w/pb-src" "$w/pb"
  tar xzf "$CACHE/protobuf-cpp-$PROTOBUF_VERSION.tar.gz" -C "$w/pb-src" --strip-components=1 || die "$abi: extract protobuf"
  (
    cd "$w/pb" &&
    "$CMAKE_BIN/cmake" "$w/pb-src" -G Ninja \
      -DCMAKE_MAKE_PROGRAM="$CMAKE_BIN/ninja" \
      -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
      -DANDROID_ABI="$abi" -DANDROID_PLATFORM="android-$ANDROID_API" \
      -DCMAKE_BUILD_TYPE=Release \
      -Dprotobuf_BUILD_TESTS=OFF -Dprotobuf_BUILD_SHARED_LIBS=OFF \
      -Dprotobuf_BUILD_PROTOC_BINARIES=OFF \
      -DCMAKE_INSTALL_PREFIX="$prefix" > cmake.log 2>&1 &&
    "$CMAKE_BIN/ninja" -j"$(nproc)" > build.log 2>&1 &&
    "$CMAKE_BIN/cmake" --install . --prefix "$prefix" > install.log 2>&1
  ) || { tail -n 20 "$w/pb"/*.log 2>/dev/null; die "$abi: protobuf build failed"; }

  # ncurses, static and wide, with the terminfo entries we need COMPILED IN.
  # Android carries no terminfo database, and without fallbacks mosh-client
  # exits with "Terminfo database could not be found. [mosh is exiting.]"
  # before it does anything else. --with-build-cc builds the tic/infocmp that
  # generate the fallback table on this machine.
  echo "  ncurses $NCURSES_VERSION (fallbacks compiled in)"
  mkdir -p "$w/nc"
  tar xzf "$CACHE/ncurses-$NCURSES_VERSION.tar.gz" -C "$w/nc" --strip-components=1 || die "$abi: extract ncurses"
  (
    cd "$w/nc" &&
    ./configure --host="$host" --prefix="$prefix" \
      --with-build-cc=gcc \
      --without-shared --without-debug --without-ada --without-cxx-binding \
      --without-manpages --without-progs --without-tests \
      --enable-widec --disable-stripping \
      --with-fallbacks="$NCURSES_FALLBACKS" > configure.log 2>&1 &&
    make -j"$(nproc)" > build.log 2>&1 &&
    make install > install.log 2>&1
  ) || { tail -n 25 "$w/nc"/configure.log "$w/nc"/build.log 2>/dev/null; die "$abi: ncurses build failed"; }

  # mosh-client.
  #
  # -llog: ncurses on Android pulls in __android_log_write, so the link fails
  # without it. One line, and the only error in an otherwise clean build.
  #
  # -static-libstdc++: links the NDK C++ runtime INTO the binary. The
  # alternative is shipping libc++_shared.so beside it, which does not work on
  # its own: an exec'd binary's loader searches system paths, not its own
  # directory, so it also needs LD_LIBRARY_PATH set to nativeLibraryDir at exec
  # time. Static drops the dependency, the extra artifact, and that entire
  # runtime failure mode for about a megabyte.
  #
  # -Wl,-z,max-page-size=16384: 16 KB page alignment, mandatory for new Play
  # apps with no extension path. NDK r28+ does this by default, 27.2 does not.
  # Do NOT add -static-pie here. It segfaults on device and passes every build
  # and CI check on the way there.
  echo "  mosh $MOSH_VERSION"
  mkdir -p "$w/mosh"
  tar xzf "$CACHE/mosh-$MOSH_VERSION.tar.gz" -C "$w/mosh" --strip-components=1 || die "$abi: extract mosh"
  sed -i "s|^prefix=.*|prefix=$prefix|" "$prefix"/lib/pkgconfig/*.pc 2>/dev/null
  (
    cd "$w/mosh" &&
    export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH="$prefix/lib/pkgconfig" &&
    export PROTOC="$HOST_PROTOC" &&
    export CPPFLAGS="-I$prefix/include" &&
    export CXXFLAGS="-I$prefix/include -O2 -std=gnu++17 -ffunction-sections -fdata-sections" &&
    export LDFLAGS="-L$prefix/lib -static-libstdc++ -Wl,--gc-sections -Wl,-z,max-page-size=16384" &&
    export LIBS="-lprotobuf -lssl -lcrypto -lncursesw -lz -llog" &&
    ./configure --host="$host" --prefix="$prefix" --disable-server --enable-client > configure.log 2>&1 &&
    make -j"$(nproc)" > build.log 2>&1
  ) || {
    grep -m5 -E "error:|Error" "$w/mosh"/configure.log "$w/mosh"/build.log 2>/dev/null
    die "$abi: mosh build failed"
  }

  # Hazard 3: this must fail on a missing file, not skip.
  local built="$w/mosh/src/frontend/mosh-client"
  [ -f "$built" ] || die "$abi: mosh reported success but produced no src/frontend/mosh-client"

  mkdir -p "$JNILIBS/$abi"
  "$TOOLCHAIN/llvm-strip" -o "$JNILIBS/$abi/libmosh_client_exec.so" "$built" || die "$abi: strip failed"
  echo "  built   $abi $(stat -c%s "$JNILIBS/$abi/libmosh_client_exec.so") bytes"
}

# No per-ABI failure aggregation: die() exits on the spot, so the first failing
# ABI ends the run. An earlier revision collected failures into a list and
# reported them after the loop, which read well and could never execute, because
# nothing ever reached the second iteration after a failure. Failing fast is the
# honest behaviour for a build script, so it is now the only behaviour.
for abi in $TARGET_ABIS; do
  build_abi "$abi"
done

# Record which pins produced these artifacts, and their hashes.
#
# Only written on a FULL build. A single-ABI run would otherwise leave a
# manifest describing one artifact while the other two on disk came from some
# earlier pin set, which is worse than no manifest.
if [ "$TARGET_ABIS" = "$ABIS" ]; then
  step "Manifest"
  MANIFEST=$SCRIPT_DIR/artifacts.sha256
  {
    echo "# Written by native/mosh/build.sh. Checked by native/mosh/verify.sh."
    echo "# Ties the committed binaries to the pins that produced them, so a"
    echo "# version bump without a rebuild fails instead of shipping quietly."
    echo "# pins: mosh=$MOSH_VERSION openssl=$OPENSSL_VERSION protobuf=$PROTOBUF_VERSION ncurses=$NCURSES_VERSION ndk=$NDK_VERSION"
    # A digest of the WHOLE normalized config, not an enumerated list of the
    # settings someone remembered to include. Enumerating is how NCURSES_FALLBACKS
    # gets missed: adding a terminal type to it changes what is compiled into the
    # binary, but every named version stays put, so an enumerated pin line still
    # matches and stale artifacts verify clean while versions.env claims the new
    # TERM works. ANDROID_API and the source checksums have the same property.
    echo "# config: $(normalized_config_digest)"
    for abi in $ABIS; do
      ( cd "$JNILIBS" && sha256sum "$abi/libmosh_client_exec.so" )
    done
  } > "$MANIFEST" || die "could not write $MANIFEST"
  echo "  ok      $MANIFEST"
else
  echo
  echo "NOTE: partial build ($TARGET_ABIS), artifacts.sha256 NOT updated."
  echo "      Run with no arguments before committing, or verify.sh will fail."
fi

step "Verify"
# Only what this invocation built. Checking the full set after a single-ABI run
# fails on artifacts it was never asked to produce.
VERIFY_ABIS="$TARGET_ABIS" "$SCRIPT_DIR/verify.sh" "$JNILIBS" || die "artifacts built but failed verification"

step "Done"
echo "Artifacts in $JNILIBS"
