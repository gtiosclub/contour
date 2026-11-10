# Third-party notices — Tracking

## OpenCV 4.13.0

Used by the `ContourFeatureMatcher` target for ORB features, matching and
homography estimation, entirely on-device. Distributed as a prebuilt
xcframework by [yeatse/opencv-spm](https://github.com/yeatse/opencv-spm),
pinned exactly in `Package.swift` and `Package.resolved`.

- Project: https://opencv.org — source https://github.com/opencv/opencv
- License: Apache License 2.0 — https://www.apache.org/licenses/LICENSE-2.0
- Copyright: the OpenCV authors and contributors. The full notices are in
  OpenCV's LICENSE and COPYRIGHT files.

The opencv-spm packaging is also Apache 2.0 licensed. Any app build that ships this
code must carry the Apache 2.0 notice (for example in an acknowledgements screen).
