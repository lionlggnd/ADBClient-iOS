# Third-party notices

## BoringSSL

The app binary (IPA) statically links BoringSSL (libcrypto and libssl), built from
https://github.com/google/boringssl by `scripts/build-boringssl.sh`. BoringSSL is not
included in this repository's source.

BoringSSL is licensed under the Apache License, Version 2.0:
https://github.com/google/boringssl/blob/main/LICENSE

Apache-2.0 is compatible with the GPL-3.0 under which this project is distributed.

## Android Debug Bridge protocol

This project contains an independent implementation of the ADB wire protocol and the
wireless debugging pairing protocol, written from the public AOSP documentation and
sources (https://android.googlesource.com/platform/packages/modules/adb/). No AOSP code
is copied. Android is a trademark of Google LLC; this project is not affiliated with or
endorsed by Google.
