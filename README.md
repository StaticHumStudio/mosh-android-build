# Mosh Android build source

This public repository provides network access to the Corresponding Source for
the `mosh-client` executables shipped with SlipShell, following GPLv3 section
6(d). SlipShell recipients also receive Mosh's GPL text and applicable notice
inside the app. SlipShell itself is a separate private work and is not included
here.

The source tree contains:

* exact mirrored release tarballs for Mosh, OpenSSL, protobuf, and ncurses
* SHA256 checksums and version pins in `native/mosh/versions.env`
* the exact `build.sh` and `verify.sh` used for the shipped executables
* the pinned Android NDK version and Android API level
* the artifact hash manifest used to map shipped binaries back to this source
* one release mapping file per SlipShell release

No Mosh session keys, SSH credentials, signing material, or SlipShell source
belong in this repository.

## Licensing

The top-level [`LICENSE`](LICENSE) applies only to the build scripts,
verification scripts, release mappings, and documentation authored by Static
Hum Studio in this repository.

The mirrored third-party source archives keep their own license terms. Mosh's
exact GPLv3 text is in `mosh-1.4.0/COPYING` inside the mirrored Mosh tarball.
The Mosh client source headers state GPLv3 or later and include the applicable
OpenSSL linking exception. Nothing in the top-level MIT license replaces or
alters those upstream terms.

## Reproduce the Android executables

Install Android NDK `27.2.12479018`, Android SDK CMake `3.22.1`, a host `g++`,
`curl`, `make`, `perl`, `pkg-config`, and standard archive tools. Then run:

```bash
export ANDROID_HOME=/path/to/android-sdk
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export NATIVE_MOSH_CACHE="$PWD/native/mosh/sources"
native/mosh/build.sh
native/mosh/verify.sh
native/mosh/verify.sh --selftest
```

The build writes the three executables under
`androidApp/src/androidMain/jniLibs/`. A successful full build rewrites
`native/mosh/artifacts.sha256`. Compare those hashes with the release mapping
for the SlipShell version being audited.

The build script verifies every mirrored tarball against the pinned checksum
before extraction. It can fetch from upstream when the cache is absent, but the
mirrors in this repository are the durable Corresponding Source and should be
used for reproduction.

## Release mapping

* [`slipshell-source-v1.4.0-r3`](releases/slipshell-source-v1.4.0-r3.md)

The Git tag with the same name freezes the source package for that shipped
binary set.
