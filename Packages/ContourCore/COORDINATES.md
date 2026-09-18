# Contour coordinate convention

**One convention. Every package. No exceptions.**

Button and guidance positions are expressed in **normalized panel
space**: a unit square laid over the front face of the detected control panel.

```
        x = 0                                   x = 1
 y = 0   +-------------------------------------+
         |  (0,0)                              |
         |   .-----.                           |
         |   |Popcn|   .-----.   .-----.       |
         |   '-----'   |Bevrg|   |Defrst|      |
         |             '-----'   '-----'       |
         |                                     |     y increases
         |   .-----.   .-----.   .-----.       |     DOWNWARD
         |   |+30s |   |Start|   |Stop |       |         |
         |   '-----'   '-----'   '-----'       |         v
         |                              (1,1)  |
 y = 1   +-------------------------------------+

         origin (0,0) = TOP-LEFT of the panel
         (1,1)        = BOTTOM-RIGHT of the panel
         x: 0 -> 1 left to right
         y: 0 -> 1 top to bottom   <-- y is DOWN, like UIKit, not like SceneKit
```

## The rules

1. **Origin is top-left.** `(0, 0)` is the top-left corner of the panel's front
   face as the user sees it, head-on and upright.
2. **`(1, 1)` is bottom-right.** Both axes are normalized to the panel's own
   extent, so the values are unitless and resolution-independent.
3. **`y` increases downward.** This matches UIKit / SwiftUI / Vision's flipped
   space. It does *not* match Core Image or SceneKit. If you are porting code
   from a `y`-up API, flip it at your package's edge — not in the contract.
4. **Values outside `0...1` are legal and meaningful.** A fingertip at
   `y = -0.08` is above the top edge of the panel. Do not clamp silently; the
   guidance layer needs to know the finger is off the panel. Use
   `PanelPoint.isOnPanel` when you need the in-bounds check.
5. **No pixel coordinates cross a package boundary.** Ever. If your package
   works in pixels internally (Vision does, ARKit does), convert at the edge and
   hand out `PanelPoint` / `PanelRect`. The only place a pixel count appears in
   the contract is `PixelSize` on `PanelPhoto`, which describes an image's
   *dimensions* — it is never used to express a *location*.
6. **The panel is the frame of reference, not the screen and not the camera.**
   When the phone moves and the panel does not, panel-space coordinates do not
   change. Camera-relative geometry lives in `PanelPose` and nowhere else.

## Why normalized, and why the panel

Three teams ship independently, across five packages. Surface Understanding sees
a still photo at whatever resolution the capture pipeline gave it. Tracking sees
live frames at a different resolution, rotated, cropped. Experience's feedback
side never sees an image at all, while its UI side lays out over a preview layer
at yet another size. The panel's own unit square is the only frame of reference
all of them can agree on without knowing anything about each other's internals.

## Types that use this convention

All of them, in `ContourCore`:

- `PanelPoint` — a position.
- `PanelVector` — a displacement between two positions.
- `PanelRect` — an axis-aligned box (`SurfaceMap.Button.bounds`).
- `TrackingFrame.fingertip` — where the user's finger is.
- `GuidanceState.vector` — fingertip to target.

`PanelPose` is a deliberate exception: it describes where the panel itself
sits **relative to the camera**, in metres, which is by definition not expressible
in panel space. It is the bridge between the two worlds, and Tracking / Spatial
owns it.

## Reference-image coordinates

Core's `ImagePoint` is normalized against the full upright, unmirrored image,
after applying its orientation: top-left origin, y down. It is not `PanelPoint`.
For quarter-turns use the oriented (swapped) image dimensions. Preview cropping
and screen coordinates stay outside the contract.

`PanelQuad` names the image positions of logical panel TL/TR/BR/BL, corresponding
to panel (0,0)/(1,0)/(1,1)/(0,1). Preserve these identities as the panel moves;
do not sort the corners again when it rotates. Convert Vision's y-up coordinates
at the package boundary. Image-space tracking diagnostics may use these types.

`PanelDetection` couples the quad and its button map to a reference photo ID.
`PanelReference` retains the matching pixels and orientation. Changing the
stored pixels/crop requires a new photo identity. The map and tracker must use
the same panel boundary, not independently chosen crops.
