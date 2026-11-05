#!/bin/sh
# Run the app's recognition contracts without UIKit, the editor or an iOS simulator.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/Sources/OpenNotes" "$work/Tests/OpenNotesTests"
cp "$repo/OpenNotes/Editor/ShapeRecognition.swift" "$work/Sources/OpenNotes/"
cp "$repo/OpenNotesTests/ShapeRecognitionTests.swift" "$work/Tests/OpenNotesTests/"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "RecognitionContract",
    targets: [
        .target(name: "OpenNotes"),
        .testTarget(name: "OpenNotesTests", dependencies: ["OpenNotes"])
    ]
)
SWIFT
swift test --package-path "$work"
