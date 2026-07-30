# SlipShell Mosh source mapping

This mapping covers the Mosh executable set prepared for the SlipShell v1.4
milestone.

* Corresponding source tag: `slipshell-source-v1.4.0-r4`
* SlipShell native artifact commit: `580aeb1c97d4ff5fe6da5ed098ff98940b9a3371`
* Mosh: `1.4.0`
* OpenSSL: `3.5.7`
* protobuf: `3.21.12`
* ncurses: `6.6`
* Android NDK: `27.2.12479018`
* Android API: `26`

SlipShell links this protected source tag from its About section. Its open
source licences screen displays a selectable copy of the same URL and bundles
the exact Mosh GPLv3 text and applicable Mosh client notice.

The source set includes SlipShell's downstream readiness patch. It emits a
private PTY record only after the first authenticated UDP packet arrives, so
the app can keep terminal input deferred until Mosh is reachable.

## Shipped executable provenance

```text
93f9dfe784ae09527632bb859f3eae236d07406b935d0f8f3477d4b37a964951  arm64-v8a/libmosh_client_exec.so
4d9836d87d413fbb9f7a597f19397a1eb65b21be2b80a47a8f903a3719d9aa7d  armeabi-v7a/libmosh_client_exec.so
a06ce3d4a158ea8a5acbce43d10c79ca477433856998eb9b35e2701ae22a38f7  x86_64/libmosh_client_exec.so
```

These hashes match `native/mosh/artifacts.sha256` in the SlipShell artifact
commit named above. Rebuilding this tag with the pinned toolchain must produce
the same manifest before the executables are accepted for release.
