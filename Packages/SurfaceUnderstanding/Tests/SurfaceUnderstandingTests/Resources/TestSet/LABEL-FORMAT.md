# Test-set label format

Store source photos in `photos/` and answer keys in `labels/`. Each photo has
exactly one JSON file with the same basename:

```text
photos/microwave-01.jpg
labels/microwave-01.json
```

Use lowercase appliance names, a hyphen, and a two-digit sequence number. Keep
the real image encoding in the extension (`.jpg` or `.heic`). Each contributor
submits five real appliance photos taken under ordinary use conditions, including
angled views and typical room lighting; do not use product images.

## JSON

```json
{
  "photo": "microwave-01.jpg",
  "panel": [
    [0.24, 0.02],
    [0.70, 0.02],
    [0.70, 0.86],
    [0.24, 0.86]
  ],
  "buttons": [
    {
      "label": "Start",
      "bounds": [0.72, 0.85, 0.14, 0.08]
    }
  ]
}
```

`photo` is the filename only, including its extension. `buttons` contains every
pressable control on the panel. `label` preserves the visible button text.

`panel` records the four corners of the panel outline used while drawing the
button boxes. The points are normalized against the upright source image and
must be ordered top-left, top-right, bottom-right, bottom-left. Keeping this
outline with the labels makes the panel-space boxes reproducible and comparable
to a detector's output.

`bounds` is `[x, y, width, height]` in normalized coordinates on the
**straightened panel**, not the original photo:

- `(0, 0)` is the straightened panel's top-left corner.
- `(1, 1)` is its bottom-right corner.
- `x` increases to the right and `y` increases downward.
- `x` and `y` locate the button's top-left corner.
- `width` and `height` are fractions of the panel dimensions.
- All four values must be between `0` and `1`; `x + width` and `y + height`
  must not exceed `1`.

This follows [`ContourCore/COORDINATES.md`](../../../../../ContourCore/COORDINATES.md).
