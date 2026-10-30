#!/bin/sh
# Xcode Cloud, after the clone: the project is generated, not committed, so XcodeGen makes it
# here (ci_scripts sits next to where Ohana.xcodeproj will be).
set -eu
cd "$CI_PRIMARY_REPOSITORY_PATH/apple"
brew install xcodegen
xcodegen generate
