---
name: build-verify
description: Build the iOS project, run tests, and report results.
allowed-tools: Bash
user-invocable: true
---

# Build & Verify

1. Clean build the project:
   ```bash
   xcodebuild -project Vision_clother/Vision_clother/Vision_clother.xcodeproj -scheme Vision_clother -sdk iphonesimulator clean build
   ```
2. Run the test suite:
   ```bash
   xcodebuild -project Vision_clother/Vision_clother/Vision_clother.xcodeproj -scheme Vision_clother -sdk iphonesimulator test
   ```
3. Report: number of tests run, passed, failed. If any failures, show the failing test names and error messages.