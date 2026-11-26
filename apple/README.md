# GitSync for macOS

Swift package containing the macOS app and the git engine.

- `Sources/GitSyncCore`: engine (no UI)
- `Sources/GitSyncApp`: SwiftUI app
- `Tests/GitSyncCoreTests`: Swift Testing suite
- `Scripts/bundle.sh`: builds `build/GitSync.app`

Requires macOS 14+ and Xcode (for the SwiftUI macro plugins):

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # if xcode-select points at CLT
swift build && swift test && swift run GitSync
```
