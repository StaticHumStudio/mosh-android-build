#!/usr/bin/env bash
#
# Assert the shipped native artifacts are what the exec model requires.
#
# Runs against the committed jniLibs tree, so it is meaningful long after the
# build that produced them. build.sh calls it, and so can CI or a human:
#
#   native/mosh/verify.sh androidApp/src/androidMain/jniLibs
#   native/mosh/verify.sh --selftest
#
# Every assertion below covers a failure mode that is invisible from a
# successful build and only shows up on a device:
#
#   machine    a copied build tree gets re-stripped under another ABI's name
#              (v1.4.md hazard 1) and nothing complains until dlopen/exec
#   DYN+INTERP -static is rejected by bionic at runtime and -static-pie
#              segfaults, both of which pass CI. -static-pie is ALSO DYN, so
#              checking the ELF type alone does not distinguish it. The INTERP
#              segment is what actually proves dynamic linkage against bionic.
#   alignment  16 KB page compliance is mandatory for new Play apps with no
#              extension path, and NDK 27.2 does not align by default
#   NEEDED     the loader searches system paths, not the binary's own
#              directory, so a NEEDED entry we neither ship nor find on the
#              device is a "CANNOT LINK EXECUTABLE" at exec time
#
# --selftest proves each assertion can fail, because an assertion nobody has
# watched fail is not an assertion. See CLAUDE.md.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/versions.env"

# Digest of versions.env with comments, blank lines and ordering removed, so a
# comment edit or a reordering does not force a rebuild but any actual setting
# change does. Shared by build.sh and verify.sh, which must agree exactly.
normalized_config_digest() {
  grep -vE '^[[:space:]]*(#|$)' "$SCRIPT_DIR/versions.env" | sed 's/[[:space:]]*$//' | sort | sha256sum | cut -d' ' -f1
}

ANDROID_HOME=${ANDROID_HOME:-$HOME/.local/opt/android-sdk}
TOOLCHAIN=$ANDROID_HOME/ndk/$NDK_VERSION/toolchains/llvm/prebuilt/linux-x86_64/bin

# Prefer the pinned NDK's readelf, fall back to the system one so this runs on a
# CI machine with no NDK installed. Verified 2026-07-26 that GNU readelf reports
# byte-identical Machine strings, a Type of "DYN (...)" which the DYN* pattern
# below matches, and an identical NEEDED list for all three shipped artifacts.
# The two disagree only about LOAD line breaks, which load_alignments handles
# and --selftest exercises against both.
#
# Missing BOTH is a hard failure, never a skip. A verifier that quietly does
# nothing when its tool is absent is the exact defect this script exists to
# catch, one level up.
if [ -x "$TOOLCHAIN/llvm-readelf" ]; then
  READELF=$TOOLCHAIN/llvm-readelf
elif command -v readelf > /dev/null 2>&1; then
  READELF=$(command -v readelf)
else
  echo "verify: no readelf available. Install binutils, or the NDK $NDK_VERSION." >&2
  exit 2
fi

# Machine string llvm-readelf prints for each ABI.
machine_for() {
  case $1 in
    arm64-v8a)   echo "AArch64" ;;
    armeabi-v7a) echo "ARM" ;;
    x86_64)      echo "Advanced Micro Devices X86-64" ;;
    *) return 1 ;;
  esac
}

# Libraries the binary may depend on. Every one of these is part of bionic and
# present on every supported device. Nothing else is allowed, because we ship
# no libraries beside the binary and an exec'd binary's loader searches system
# paths rather than its own directory: any other NEEDED entry is a
# "CANNOT LINK EXECUTABLE" at exec time, not a build failure.
#
# libc++_shared.so is deliberately NOT on this list. build.sh links the C++
# runtime statically (-static-libstdc++) precisely so this dependency does not
# exist. See check_needed for why that is worth a megabyte.
ALLOWED_NEEDED="libm.so libz.so liblog.so libdl.so libc.so"

FAILURES=0
QUIET=${QUIET:-0}

fail() { echo "  FAIL  $*"; FAILURES=$((FAILURES + 1)); return 1; }
pass() { [ "$QUIET" = 1 ] || echo "  ok    $*"; return 0; }

# Each check_* returns 0 on pass and non-zero on failure, and reports either
# way. They take a path that may not exist: "file missing" must be a FAILURE
# and never a silent skip. A check that scans for mismatches finds none in
# empty output, which is how the spike's first archive check passed for a
# library that was never built.

check_present() {
  local f=$1
  [ -f "$f" ] || { fail "$(basename "$f"): missing"; return 1; }
  [ -s "$f" ] || { fail "$(basename "$f"): empty"; return 1; }
  pass "$(basename "$f"): present ($(stat -c%s "$f") bytes)"
}

check_machine() {
  local f=$1 abi=$2 want got
  want=$(machine_for "$abi") || { fail "unknown ABI $abi"; return 1; }
  got=$("$READELF" -h "$f" 2>/dev/null | awk -F: '/^ *Machine:/{sub(/^ +/,"",$2); print $2; exit}')
  [ -n "$got" ] || { fail "$(basename "$f"): not an ELF file (no machine)"; return 1; }
  [ "$got" = "$want" ] || { fail "$(basename "$f"): machine '$got', expected '$want' for $abi"; return 1; }
  pass "$(basename "$f"): machine $got"
}

check_dynamic() {
  local f=$1 type interp
  type=$("$READELF" -h "$f" 2>/dev/null | awk -F: '/^ *Type:/{sub(/^ +/,"",$2); print $2; exit}')
  case "$type" in
    DYN*) ;;
    "") fail "$(basename "$f"): not an ELF file (no type)"; return 1 ;;
    *) fail "$(basename "$f"): ELF type '$type', expected DYN. A non-PIE static build is rejected by bionic at runtime"; return 1 ;;
  esac
  # -static-pie also reports DYN. Only the INTERP segment proves the binary
  # will actually be handed to bionic's loader, and -static-pie segfaults.
  interp=$("$READELF" -l "$f" 2>/dev/null | grep -c 'INTERP')
  [ "$interp" -gt 0 ] || { fail "$(basename "$f"): DYN but no INTERP segment, which is a static-pie build. It segfaults on device"; return 1; }
  pass "$(basename "$f"): DYN with INTERP"
}

# The two readelf implementations disagree about line breaks, and getting this
# wrong is silent:
#
#   llvm-readelf  LOAD 0x000000 0x... 0x... 0x266320 0x266320 R 0x4000
#   GNU readelf   LOAD 0x0000000000000000 0x... 0x...
#                      0x0000000000266320 0x0000000000266320  R   0x4000
#
# Under GNU's format the last field of the LOAD line is the FILE SIZE, not the
# alignment. A naive $NF reads something like 0x266320, compares it against
# 16384, finds it larger, and passes every binary ever built. Detect the format
# from the field count instead of assuming one. --selftest exercises both.
load_alignments() {
  "$READELF" -l "$1" 2>/dev/null | awk '
    /^ *LOAD/ {
      if (NF >= 8) { print $NF; next }   # llvm: one line, align last
      if (getline > 0) { print $NF }     # GNU: align is last on the next line
    }' | sort -u
}

check_alignment() {
  local f=$1 aligns bad
  aligns=$(load_alignments "$f")
  [ -n "$aligns" ] || { fail "$(basename "$f"): no LOAD segments found, cannot verify 16 KB alignment"; return 1; }
  bad=""
  for a in $aligns; do
    # Alignments print as hex (0x4000). Anything under 16384 fails Play's
    # 16 KB page-size requirement.
    if [ "$((a))" -lt 16384 ] 2>/dev/null; then bad="$bad $a"; fi
  done
  [ -z "$bad" ] || { fail "$(basename "$f"): LOAD alignment$bad is under 16 KB (0x4000)"; return 1; }
  pass "$(basename "$f"): LOAD aligned $(echo "$aligns" | tr '\n' ' ')"
}

check_needed() {
  local f=$1 needed unexpected=""
  needed=$("$READELF" -d "$f" 2>/dev/null | sed -n 's/.*NEEDED.*\[\(.*\)\].*/\1/p')
  [ -n "$needed" ] || { fail "$(basename "$f"): no NEEDED entries, which a dynamically linked binary must have"; return 1; }
  for lib in $needed; do
    case " $ALLOWED_NEEDED " in
      *" $lib "*) ;;
      *) unexpected="$unexpected $lib" ;;
    esac
  done
  case " $needed " in
    *" libc++_shared.so "*)
      fail "$(basename "$f"): NEEDED libc++_shared.so. The C++ runtime is not part of bionic, so this binary will not exec unless we also ship that library AND set LD_LIBRARY_PATH to nativeLibraryDir, because an exec'd binary's loader does not search its own directory. Build with -static-libstdc++ instead"
      return 1 ;;
  esac
  [ -z "$unexpected" ] || { fail "$(basename "$f"): depends on$unexpected, which is not part of bionic and is not shipped"; return 1; }
  pass "$(basename "$f"): NEEDED $(echo "$needed" | tr '\n' ' ')"
}

verify_artifact() {
  local f=$1 abi=$2
  echo "$abi/$(basename "$f")"
  check_present "$f" || return 1
  check_machine "$f" "$abi"
  check_dynamic "$f"
  check_alignment "$f"
  check_needed "$f"
}

# Tie the committed binaries to the pins that produced them.
#
# Every other check here reads the ELF shape, which says nothing about
# provenance. Without this, bumping OPENSSL_VERSION for a CVE and forgetting to
# rebuild leaves a stale binary that passes every assertion, while README's
# mapping between the source package and shipped binary quietly becomes false.
# build.sh writes the manifest, and this compares
# BOTH directions: the recorded pins against versions.env, and the recorded
# hashes against the files on disk.
check_provenance() {
  local root=$1
  local manifest="$SCRIPT_DIR/artifacts.sha256"
  echo "provenance"
  [ -f "$manifest" ] || { fail "native/mosh/artifacts.sha256 is missing. Run native/mosh/build.sh"; return 1; }

  # The digest is the real gate. The human-readable pin line below it exists so
  # a mismatch says WHICH versions differ instead of just showing two hashes,
  # but it is not what is compared: an enumerated list only covers the settings
  # whoever wrote it thought of. NCURSES_FALLBACKS is the case in point, since
  # adding a terminal type changes what is compiled into the binary while every
  # named version stays put. ANDROID_API and the source checksums behave the
  # same way.
  local want_config recorded_config
  want_config=$(normalized_config_digest)
  recorded_config=$(sed -n 's/^# config: //p' "$manifest")
  [ -n "$recorded_config" ] || { fail "artifacts.sha256 records no config digest. Re-run native/mosh/build.sh"; return 1; }
  if [ "$recorded_config" != "$want_config" ]; then
    local want_pins recorded_pins
    want_pins="mosh=$MOSH_VERSION openssl=$OPENSSL_VERSION protobuf=$PROTOBUF_VERSION ncurses=$NCURSES_VERSION ndk=$NDK_VERSION"
    recorded_pins=$(sed -n 's/^# pins: //p' "$manifest")
    fail "versions.env has changed since these binaries were built.
        versions.env now: $want_pins
        artifacts built from: ${recorded_pins:-unknown}
        config digest ${want_config:0:16} vs recorded ${recorded_config:0:16}
        If the version lines above look identical, something else in
        versions.env changed that still affects the binary, for example
        NCURSES_FALLBACKS, ANDROID_API, ABIS or a source checksum.
        The committed binaries are stale. Re-run native/mosh/build.sh."
    return 1
  fi
  pass "config digest matches versions.env (${want_config:0:16})"

  local hash rel
  local seen=""
  while read -r hash rel; do
    case "$hash" in ''|'#'*) continue ;; esac
    seen="$seen$rel
"
    local f="$root/$rel"
    [ -f "$f" ] || { fail "$rel: recorded in artifacts.sha256 but not present"; continue; }
    local got
    got=$(sha256sum "$f" | cut -d' ' -f1)
    if [ "$got" != "$hash" ]; then
      fail "$rel: sha256 $got does not match the recorded $hash. The binary and the manifest disagree"
    else
      pass "$rel: sha256 matches"
    fi
  done < "$manifest"

  # Compare the manifest's PATHS against the exact expected set, not their
  # count. A manifest that lists one ABI twice and omits another has the right
  # number of lines and every hash in it still matches a real file, so a count
  # check passes while the omitted binary is tied to nothing. Deliberately not
  # `sort -u`, so a duplicate shows up as a difference rather than collapsing.
  local expected_list seen_list
  expected_list=$(for abi in $ABIS; do echo "$abi/libmosh_client_exec.so"; done | sort)
  seen_list=$(printf '%s' "$seen" | sed '/^$/d' | sort)
  if [ "$expected_list" != "$seen_list" ]; then
    fail "artifacts.sha256 does not list exactly one entry per shipped ABI.
        expected: $(echo "$expected_list" | tr '\n' ' ')
        found:    $(echo "$seen_list" | tr '\n' ' ')"
    return 1
  fi
  pass "one manifest entry per shipped ABI"
}

verify_tree() {
  local root=$1
  [ -d "$root" ] || { echo "verify: no such directory: $root" >&2; exit 2; }
  # VERIFY_ABIS lets a single-ABI build check only what it produced. Without it,
  # the documented `build.sh arm64-v8a` form builds one ABI and then fails
  # verification on the two it was never asked to build.
  local checking=${VERIFY_ABIS:-$ABIS}
  local partial=0
  [ "$checking" = "$ABIS" ] || partial=1
  echo "Verifying $root"
  echo "readelf: $READELF"
  echo "NDK $NDK_VERSION, mosh $MOSH_VERSION, OpenSSL $OPENSSL_VERSION, protobuf $PROTOBUF_VERSION, ncurses $NCURSES_VERSION"
  echo
  # An empty list must fail rather than iterate zero times and report success.
  [ -n "$checking" ] || { echo "verify: no ABIs to check" >&2; exit 2; }
  for abi in $checking; do
    verify_artifact "$root/$abi/libmosh_client_exec.so" "$abi"
    echo
  done

  # Provenance covers the whole committed set at once, so it is only meaningful
  # on a full run. build.sh deliberately does not rewrite artifacts.sha256 after
  # a partial build, because a manifest describing one freshly built ABI and two
  # left over from some earlier pin set is worse than no manifest.
  if [ "$partial" -eq 1 ]; then
    echo "provenance"
    echo "  SKIP  partial verification ($checking). Provenance covers the full set."
    echo
  else
    check_provenance "$root"
    echo
  fi

  if [ "$FAILURES" -ne 0 ]; then
    echo "FAIL: $FAILURES assertion(s) failed"
    return 1
  fi
  if [ "$partial" -eq 1 ]; then
    # Deliberately not the word PASS. This run did not check the shipped set and
    # must not read like it did in a log someone skims later.
    echo "PARTIAL: verified $checking. Run a full build before committing."
    return 0
  fi
  echo "PASS: all artifacts verified for: $ABIS"
  return 0
}

# Prove the assertions can fail. Each case below is a real defect this script
# exists to catch, fed in deliberately. If any of these come back "would pass",
# the corresponding assertion is decorative and the build is unguarded.
selftest() {
  local tmp expected_fails=0 actual_fails=0
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  echo "Selftest: every assertion must reject a known-bad input."
  echo

  # 1. Missing file.
  # 2. Empty file (a truncated copy, which is not an ELF at all).
  # 3. A host binary: correct ELF, wrong machine for every Android ABI.
  : > "$tmp/empty.so"
  cp /bin/true "$tmp/host.so"

  local cases=(
    "missing file|check_present $tmp/does-not-exist.so"
    "empty file|check_present $tmp/empty.so"
    "wrong machine (x86-64 host binary as arm64)|check_machine $tmp/host.so arm64-v8a"
    "not an ELF (machine)|check_machine $tmp/empty.so arm64-v8a"
    "not an ELF (type)|check_dynamic $tmp/empty.so"
    "no LOAD segments|check_alignment $tmp/empty.so"
    "4 KB-aligned real ELF (the exact 16 KB defect)|check_alignment $tmp/host.so"
    "no NEEDED entries|check_needed $tmp/empty.so"
  )

  for c in "${cases[@]}"; do
    local label=${c%%|*} cmd=${c#*|}
    expected_fails=$((expected_fails + 1))
    FAILURES=0
    QUIET=1
    # shellcheck disable=SC2086
    if $cmd >/dev/null 2>&1; then
      QUIET=0
      echo "  NOT CAUGHT  $label  <-- this assertion cannot fail"
    else
      QUIET=0
      actual_fails=$((actual_fails + 1))
      echo "  caught      $label"
    fi
  done

  # The host binary case above is the important one. /bin/true is a perfectly
  # valid dynamically linked ELF with LOAD segments and NEEDED entries, and it
  # is 0x1000 aligned. So it must PASS check_dynamic while FAILING
  # check_alignment. That asymmetry is what proves check_alignment reads the
  # alignment rather than just answering "is this an ELF".
  # The alignment parser has to survive BOTH readelf formats. Under GNU's
  # two-line layout the last field of the LOAD line is the file size, so a
  # parser that assumes llvm's one-line layout silently passes everything.
  # Re-run the 4 KB case against each available implementation.
  echo
  local saved_readelf=$READELF impl
  for impl in "$TOOLCHAIN/llvm-readelf" "$(command -v readelf || true)"; do
    [ -x "$impl" ] || continue
    READELF=$impl
    expected_fails=$((expected_fails + 1))
    FAILURES=0; QUIET=1
    if check_alignment "$tmp/host.so" >/dev/null 2>&1; then
      QUIET=0; echo "  NOT CAUGHT  4 KB alignment via $(basename "$impl")  <-- parser reads the wrong field in this format"
    else
      QUIET=0; actual_fails=$((actual_fails + 1))
      echo "  caught      4 KB alignment via $(basename "$impl") ($(load_alignments "$tmp/host.so" | tr '\n' ' '))"
    fi
  done
  READELF=$saved_readelf
  QUIET=0

  echo
  FAILURES=0; QUIET=1
  if check_dynamic "$tmp/host.so" >/dev/null 2>&1; then
    QUIET=0; echo "  sanity      a real dynamic host binary passes check_dynamic (assertion is not a blanket reject)"
  else
    QUIET=0; echo "  BROKEN      a real dynamic host binary FAILED check_dynamic"
    actual_fails=-1
  fi
  QUIET=0

  echo
  if [ "$actual_fails" -eq "$expected_fails" ]; then
    echo "PASS: $actual_fails/$expected_fails assertions rejected their bad input."
    return 0
  fi
  echo "FAIL: only $actual_fails/$expected_fails assertions rejected their bad input."
  return 1
}

case "${1:-}" in
  --selftest) selftest ;;
  "") verify_tree "$SCRIPT_DIR/../../androidApp/src/androidMain/jniLibs" ;;
  *) verify_tree "$1" ;;
esac
