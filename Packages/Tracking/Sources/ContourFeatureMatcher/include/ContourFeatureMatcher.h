// Contour — Tracking / Visual features (issue #81)
//
// Narrow C interface to the OpenCV panel matcher. Swift calls this; nothing
// OpenCV-typed crosses it. All coordinates are processing-image pixels of the
// grayscale buffer passed in (x right, y down, origin top-left). Converting to
// normalized upright ImagePoint/PanelQuad is the Swift wrapper's job (#82).
//
// Ownership: the caller owns every buffer it passes and may free it as soon as
// the call returns. The tracker owns its reference features. A tracker is not
// thread-safe; callers serialize access (the Swift actor does).
//
// Every entry point catches C++ exceptions and reports CFT_STATUS_INTERNAL_ERROR.

#ifndef CONTOUR_FEATURE_MATCHER_H
#define CONTOUR_FEATURE_MATCHER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CFTTracker CFTTracker;

typedef struct {
    float x;
    float y;
} CFTPoint;

/// 8-bit single-channel image. `bytesPerRow` may exceed `width` (row padding).
typedef struct {
    const uint8_t *pixels;
    int32_t width;
    int32_t height;
    int32_t bytesPerRow;
} CFTGrayImage;

typedef enum {
    CFT_STATUS_OK = 0,
    /// The call ran correctly but found no trustworthy panel; see the loss reason.
    CFT_STATUS_LOST = 1,
    CFT_STATUS_INVALID_ARGUMENT = 2,
    CFT_STATUS_INVALID_BUFFER = 3,
    CFT_STATUS_NOT_REGISTERED = 4,
    /// The marked reference panel has too little texture to register.
    CFT_STATUS_INSUFFICIENT_FEATURES = 5,
    CFT_STATUS_INTERNAL_ERROR = 6,
} CFTStatus;

typedef enum {
    CFT_LOSS_NONE = 0,
    CFT_LOSS_TOO_FEW_FRAME_FEATURES = 1,
    CFT_LOSS_TOO_FEW_MATCHES = 2,
    CFT_LOSS_NO_HOMOGRAPHY = 3,
    CFT_LOSS_TOO_FEW_INLIERS = 4,
    CFT_LOSS_LOW_INLIER_RATIO = 5,
    CFT_LOSS_LOW_COVERAGE = 6,
    /// Nonfinite, folded, mirrored, or behind-the-camera projected corners.
    CFT_LOSS_INVALID_GEOMETRY = 7,
    CFT_LOSS_IMPLAUSIBLE_AREA = 8,
} CFTLossReason;

/// Starting values from #81. Tune with representative cases; document changes.
typedef struct {
    int32_t maxFeatures;              // ORB nfeatures (1800)
    int32_t pyramidLevels;            // ORB nlevels (8)
    int32_t fastThreshold;            // ORB fastThreshold (12)
    int32_t minReferenceFeatures;     // registration floor (40)
    int32_t maxHammingDistance;       // match distance ceiling (64)
    float ratioTest;                  // best / second-best must be below (0.75)
    int32_t mutualMatching;           // nonzero: keep only cross-checked matches (1)
    float ransacThreshold;            // processing pixels (2.5)
    int32_t minInliers;               // (20)
    float minInlierRatio;             // inliers / ratio-and-mutual matches (0.45)
    float minCoverage;                // inlier hull area / reference panel area (0.12)
    float minAreaFraction;            // projected quad area / image area (0.005)
    float maxAreaFraction;            // (4.0)
    int32_t minDimension;             // buffer width/height bounds (32)
    int32_t maxDimension;             // (4096)
} CFTConfig;

typedef struct {
    int32_t referenceFeatures;
} CFTRegistrationInfo;

/// Evidence is filled in for lost frames too, as far as matching got.
typedef struct {
    /// TL, TR, BR, BL. Zeroed unless the call returned CFT_STATUS_OK.
    CFTPoint corners[4];
    /// Heuristic evidence score in [0, 0.95]; 0 when lost. Not a probability.
    float confidence;
    CFTLossReason lossReason;
    int32_t referenceFeatures;  // active reference features matched against
    int32_t frameFeatures;
    int32_t matchCount;         // after distance, ratio, and mutual filters
    int32_t inlierCount;
    float inlierRatio;
    float coverage;
    float reprojectionError;    // mean inlier error, processing pixels
    float processingMilliseconds;
} CFTMatchResult;

void cft_default_config(CFTConfig *config);

/// NULL config uses the defaults. Returns NULL on invalid config or allocation failure.
CFTTracker *cft_create(const CFTConfig *config);
/// Safe to call with NULL.
void cft_destroy(CFTTracker *tracker);

/// Replaces any previous reference. `corners` are the panel's TL, TR, BR, BL in
/// the reference image, forming a convex quad of the same orientation. Only
/// features inside the quad are kept. On failure the tracker is unregistered.
CFTStatus cft_register_reference(CFTTracker *tracker, const CFTGrayImage *reference,
                                 const CFTPoint corners[4], CFTRegistrationInfo *info);

/// Matches one live frame against the registered original reference. Never
/// reports a previous frame's corners. `result` may be NULL.
CFTStatus cft_match_frame(CFTTracker *tracker, const CFTGrayImage *frame, CFTMatchResult *result);

/// Drops the reference and its features.
void cft_reset(CFTTracker *tracker);

// MARK: Evidence of the most recent cft_match_frame. Cleared by every match,
// registration and reset, so it always describes the latest attempt only.

/// Inlier locations in the live frame. Returns the total count; copies at most
/// `capacity` (pass NULL/0 to query the count).
int32_t cft_copy_inlier_points(const CFTTracker *tracker, CFTPoint *points, int32_t capacity);

/// Stable reference feature IDs (0 ..< reference count) of those inliers, in
/// the same order as cft_copy_inlier_points.
int32_t cft_copy_inlier_feature_ids(const CFTTracker *tracker, int32_t *ids, int32_t capacity);

// MARK: Feature-selection hooks (#84 chooses the subset; this only applies it).

/// Total original reference features; 0 when unregistered.
int32_t cft_reference_feature_count(const CFTTracker *tracker);

/// Restricts matching to these original feature IDs. Descriptors are never
/// modified or learned from live frames. Rejects unknown/duplicate IDs and
/// subsets smaller than minReferenceFeatures, leaving the current set unchanged.
CFTStatus cft_set_active_features(CFTTracker *tracker, const int32_t *ids, int32_t count);

/// Matches against every original feature again (recovery).
void cft_restore_all_features(CFTTracker *tracker);

/// Number of features currently used for matching.
int32_t cft_active_feature_count(const CFTTracker *tracker);

const char *cft_status_description(CFTStatus status);
const char *cft_loss_reason_description(CFTLossReason reason);

#ifdef __cplusplus
}
#endif

#endif
