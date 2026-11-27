# GitWolf for macOS

Swift package containing the macOS app and the git engine.

- `Sources/GitWolfCore`: engine (no UI)
- `Sources/GitWolfApp`: SwiftUI app
- `Tests/GitWolfCoreTests`: Swift Testing suite
- `Scripts/bundle.sh`: builds `build/GitWolf.app`

Requires macOS 15+ and Xcode (for the SwiftUI macro plugins):

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # if xcode-select points at CLT
swift build && swift test && swift run GitWolf
```
