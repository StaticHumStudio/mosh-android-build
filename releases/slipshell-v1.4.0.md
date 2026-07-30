# SlipShell v1.4.0 source mapping

This mapping covers the Mosh executables prepared for SlipShell v1.4.0.

* Corresponding source tag: `slipshell-v1.4.0`
* SlipShell native artifact commit: `7afada4726d0b01241e63beede894e49cb5291cf`
* Mosh: `1.4.0`
* OpenSSL: `3.5.7`
* protobuf: `3.21.12`
* ncurses: `6.6`
* Android NDK: `27.2.12479018`
* Android API: `26`

## Shipped executable provenance

```text
d136d853110cbd487056bbf2aef01fc9b720cc19d848e8c628a941f5a8a0be5c  arm64-v8a/libmosh_client_exec.so
528134a15ca2ec44008bfe8b44459875e57d6b3f506dea1c723d22f10eafc121  armeabi-v7a/libmosh_client_exec.so
ba98e158b495a4fb20fee11d3e82904ed166112d9ef72bca67f51b8d4d2668ed  x86_64/libmosh_client_exec.so
```

These hashes are copied from `native/mosh/artifacts.sha256` in the SlipShell
artifact commit named above. Rebuilding this tag with the pinned toolchain must
produce the same manifest before the executables are accepted for release.
