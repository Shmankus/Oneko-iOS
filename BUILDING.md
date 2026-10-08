# Building Oneko for iOS

Build with Theos on macOS (SpringBoard on A12+ needs arm64e). `resources.m` is generated from
`Resources/*.gif` by `bundle.sh` automatically (`pv` shows progress if it's installed).

```
make package install                 # debug build: logs to syslog, /var/tmp/oneko-dump support
make package install FINALPACKAGE=1  # release build
```

Put `THEOS_DEVICE_IP = <phone>` in a `Makefile.local` (gitignored) to install over SSH.
