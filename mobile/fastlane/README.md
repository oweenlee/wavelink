fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

### bump_version

```sh
[bundle exec] fastlane bump_version
```

递增版本号（major/minor/patch，默认 patch），build number 同时 +1

### bump_build

```sh
[bundle exec] fastlane bump_build
```

仅递增 build number，版本号不变（如 1.0.0+1 → 1.0.0+2）

### build_ios

```sh
[bundle exec] fastlane build_ios
```

构建 iOS ipa（Release）

### build_android

```sh
[bundle exec] fastlane build_android
```

构建 Android AAB（Release）

### upload_testflight

```sh
[bundle exec] fastlane upload_testflight
```

构建并上传 iOS 到 TestFlight（需先在 App Store Connect 建好应用与证书）

### release

```sh
[bundle exec] fastlane release
```

一键发版：递增版本号（默认 patch，可用 kind:minor/major）+ 上传 TestFlight

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
