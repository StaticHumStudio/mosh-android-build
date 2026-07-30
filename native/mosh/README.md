# mosh-client, built for Android

SlipShell runs Mosh by exec'ing the C reference client as a child process on a
PTY, not by linking it. This directory is how that binary gets built.

```bash
native/mosh/build.sh                  # all ABIs
native/mosh/build.sh arm64-v8a        # one
native/mosh/verify.sh                 # assert the committed artifacts
native/mosh/verify.sh --selftest      # assert the assertions can fail
```

Output lands in `androidApp/src/androidMain/jniLibs/<abi>/libmosh_client_exec.so`
and is committed, so an ordinary clone builds a working APK without an NDK.

Requires the NDK and cmake pinned in `versions.env`, plus a host `g++` (protoc
has to run on the build machine). No sudo, no autotools: mosh's release tarball
ships a pre-generated `configure`.

## Why the binary is named like a library

Android extracts and marks executable everything under `jniLibs`, and
`nativeLibraryDir` is the only place an app may exec from under W^X. Naming the
client `libmosh_client_exec.so` is what gets it there. It is a program. Nothing
loads it.

Two consequences that are easy to lose:

- **`packaging { jniLibs { useLegacyPackaging = true } }` is mandatory.** AGP
  defaults `extractNativeLibs=false` for `minSdk >= 23`, which leaves native
  libs compressed inside the APK. Under that default `nativeLibraryDir`
  installs *empty* and the exec path does not exist at install time. There is
  no build error. Verified both ways on an API 36 emulator.
- **A debug sideload can mask this.** The release-build install check is the
  one that means anything. An AAB cannot be installed directly, so go through
  `bundletool build-apks --mode=universal` then `install-apks`.

## Link mode: dynamic against bionic, static for everything else

Measured on a Galaxy SM-S948U, Android 16, arm64:

| Link mode | ELF type | Result |
|---|---|---|
| dynamic (NDK default) | `DYN` | runs |
| dynamic + `-Wl,-z,max-page-size=16384` | `DYN` | runs, and is 16 KB aligned |
| `-static-pie` | `DYN` | **segfaults** on startup |
| `-static-pie` + 16 KB flag | `DYN` | **segfaults** on startup |
| `-static` (non-PIE) | `EXEC` | **rejected by bionic**: TLS segment underaligned |

Both static modes fail at *runtime*. They build clean and pass CI. That is why
`verify.sh` asserts `DYN` **and** the presence of an `INTERP` segment: a
`-static-pie` binary is also `DYN`, so the ELF type alone does not tell the two
apart.

## The C++ runtime is linked statically, on purpose

The spike shipped `libc++_shared.so` next to the client and it still failed with
`CANNOT LINK EXECUTABLE ... library "libc++_shared.so" not found`, *with the
file sitting right beside the binary*. An exec'd binary's loader searches system
paths, not its own directory, so it also needed `LD_LIBRARY_PATH` pointed at
`nativeLibraryDir` at exec time.

`-static-libstdc++` removes the dependency, the second artifact, the extra
alignment surface, and that whole failure mode, for roughly a megabyte.
`verify.sh` fails the build if `libc++_shared.so` ever reappears in `NEEDED`.

## Terminfo is compiled in

Android ships no terminfo database at all, so a stock build exits immediately
with `Error: Terminfo database could not be found. [mosh is exiting.]`. ncurses
is built `--with-fallbacks=` the entries in `versions.env`, which compiles them
into the binary and removes the need to bundle a terminfo tree and set
`TERMINFO`. `TERM` in the child environment must be one of those entries,
because there is nothing on disk to fall back to.

## GPL obligations

mosh is GPLv3+ (with an OpenSSL linking exception). Exec'ing it as a separate
program creates no combined work, so the obligation attaches to the mosh binary
alone and not to SlipShell. It is discharged by a written offer of Corresponding
Source, published at `StaticHumStudio/mosh-android-build` and linked from the
app's open source licences screen.

**Corresponding Source is everything needed to regenerate the conveyed
executable**, which is more than mosh's own source. The shipped binary
statically incorporates protobuf, ncurses, and OpenSSL. So the build repo has to
carry:

- the four source tarballs named in `versions.env`, mirrored, not linked
- `versions.env`, `build.sh`, and `verify.sh` as shipped
- the NDK version, recorded
- a mapping from each SlipShell release to the exact set it was built from

Pointing at upstream download URLs does not discharge the obligation. Those
locations are not ours to keep available and exact versions do disappear.

## Version pins

Live in `versions.env` with their checksums and the reasoning. The one worth
repeating: **OpenSSL is linked statically into a shipped binary**, so Android
cannot patch it and every install stays on whatever we embedded until the next
app update. Re-verify it at every release rather than treating the pin as
settled. v1.4 ships 3.5.x LTS rather than the spike's 3.0.21, because the 3.0
branch goes end-of-life on 2026-09-07, before SlipShell's first Play release.

## The build script is defensive for earned reasons

Each of these produced a convincing false pass during the Stage 2.0 spike:

1. **Pristine sources per ABI, never a copied build tree.** Copying the arm64
   tree and re-running `configure` + `make` left stale arm64 objects.
   `mosh-client` was never rebuilt and got re-stripped under another ABI's
   name, and `libcrypto.a` ended up holding a mix of arm64 and x86_64 members.
   A mixed archive passes `readelf -h`, which reads only the first member, and
   fails three steps later at link time.
2. **Reset the environment between ABIs.** `LDFLAGS`, `LIBS` and `PKG_CONFIG_*`
   exported for one ABI's mosh step leak into the next ABI's dependency builds,
   which then link against the wrong sysroot. It surfaces as ncurses reporting
   "C compiler cannot create executables".
3. **Assertions must fail on a missing file.** A check that scans for
   mismatches finds none in an empty result, so the obvious spelling reports OK
   for a library that was never built.

`verify.sh --selftest` feeds every assertion a known-bad input and fails if any
of them accepts it. Run it if you change `verify.sh`. An assertion nobody has
watched fail is not an assertion.
