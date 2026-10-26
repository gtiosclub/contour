// Contour — Tracking / Visual features (issue #81)
//
// ORB features from the marked reference panel are matched to every live frame,
// a RANSAC homography maps the reference corners into the frame, and the result
// is rejected unless the evidence is consistent, spread across the panel, and
// projectively sensible. Each frame is matched against the original reference,
// never against an earlier live frame, so a covered frame cannot become the
// recovery reference.

#include "ContourFeatureMatcher.h"

#include <opencv2/calib3d.hpp>
#include <opencv2/core.hpp>
#include <opencv2/features2d.hpp>
#include <opencv2/imgproc.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <exception>
#include <new>
#include <vector>

struct CFTTracker {
    CFTConfig config;
    cv::Ptr<cv::ORB> orb;
    cv::Ptr<cv::CLAHE> clahe;
    cv::BFMatcher matcher{cv::NORM_HAMMING, false};

    bool registered = false;
    CFTPoint referenceCorners[4] = {};
    double referenceArea = 0;
    /// +1 or -1: the winding of TL→TR→BR→BL in the reference image.
    int referenceWinding = 0;

    /// Original features, indexed by their stable ID. Never modified after registration.
    std::vector<cv::Point2f> referencePoints;
    cv::Mat referenceDescriptors;

    /// Original IDs currently matched against, and their descriptor rows.
    std::vector<int32_t> activeIDs;
    cv::Mat activeDescriptors;

    std::vector<CFTPoint> lastInlierPoints;
    std::vector<int32_t> lastInlierIDs;
    /// Whether the most recent match was accepted. Lost frames keep their
    /// inliers as diagnostics but never count as calibration evidence.
    bool lastTracked = false;

    void clearEvidence() {
        lastInlierPoints.clear();
        lastInlierIDs.clear();
        lastTracked = false;
    }

    void unregister() {
        registered = false;
        referencePoints.clear();
        referenceDescriptors.release();
        activeIDs.clear();
        activeDescriptors.release();
        referenceArea = 0;
        referenceWinding = 0;
        clearEvidence();
    }

    void activate(const std::vector<int32_t> &ids) {
        cv::Mat descriptors(static_cast<int>(ids.size()), referenceDescriptors.cols, referenceDescriptors.type());
        for (size_t row = 0; row < ids.size(); ++row) {
            referenceDescriptors.row(ids[row]).copyTo(descriptors.row(static_cast<int>(row)));
        }
        activeIDs = ids;
        activeDescriptors = descriptors;
    }
};

namespace {

template <typename Body>
CFTStatus guarded(Body body) {
    try {
        return body();
    } catch (...) {
        return CFT_STATUS_INTERNAL_ERROR;
    }
}

bool isFinite(CFTPoint point) {
    return std::isfinite(point.x) && std::isfinite(point.y);
}

double cross(CFTPoint origin, CFTPoint a, CFTPoint b) {
    return (static_cast<double>(a.x) - origin.x) * (static_cast<double>(b.y) - origin.y)
         - (static_cast<double>(a.y) - origin.y) * (static_cast<double>(b.x) - origin.x);
}

/// +1 or -1 when the quad is strictly convex with one consistent winding, else 0
/// (folded, self-intersecting, or degenerate).
int winding(const CFTPoint quad[4]) {
    int sign = 0;
    for (int i = 0; i < 4; ++i) {
        double turn = cross(quad[i], quad[(i + 1) % 4], quad[(i + 2) % 4]);
        if (!std::isfinite(turn) || turn == 0) return 0;
        int current = turn > 0 ? 1 : -1;
        if (sign == 0) sign = current;
        else if (sign != current) return 0;
    }
    return sign;
}

double area(const CFTPoint quad[4]) {
    double twice = 0;
    for (int i = 0; i < 4; ++i) {
        const CFTPoint &a = quad[i];
        const CFTPoint &b = quad[(i + 1) % 4];
        twice += static_cast<double>(a.x) * b.y - static_cast<double>(b.x) * a.y;
    }
    return std::abs(twice) / 2;
}

bool validConfig(const CFTConfig &c) {
    return c.maxFeatures > 0 && c.pyramidLevels >= 1 && c.pyramidLevels <= 16
        && c.fastThreshold >= 1 && c.fastThreshold <= 255
        && c.minReferenceFeatures >= 4 && c.maxHammingDistance >= 0 && c.maxHammingDistance <= 256
        && c.ratioTest > 0 && c.ratioTest <= 1
        && c.ransacThreshold > 0 && std::isfinite(c.ransacThreshold)
        && c.minInliers >= 4
        && c.minInlierRatio >= 0 && c.minInlierRatio <= 1
        && c.minCoverage >= 0 && c.minCoverage <= 1
        && c.minAreaFraction > 0 && c.maxAreaFraction > c.minAreaFraction && std::isfinite(c.maxAreaFraction)
        && c.minDimension >= 1 && c.maxDimension >= c.minDimension
        && c.saturationThreshold >= 1 && c.saturationThreshold <= 255
        && c.minHighlightArea >= 1
        && c.minHighlightFill >= 0 && c.minHighlightFill <= 1
        && c.maxHighlightAreaFraction > 0 && c.maxHighlightAreaFraction <= 1
        && c.claheClipLimit > 0 && std::isfinite(c.claheClipLimit)
        && c.claheGridSize >= 1 && c.claheGridSize <= 64;
}

/// What the extractor may use from one input image.
struct Prepared {
    cv::Mat image;     // possibly contrast-enhanced
    cv::Mat excluded;  // 255 where features may not look; empty when nothing is excluded
    float saturatedFraction = 0;
    float excludedFraction = 0;
};

/// Glare is judged on the raw pixels, before any contrast change, so CLAHE
/// can never redefine what was clipped.
Prepared prepare(const CFTTracker &tracker, const cv::Mat &raw) {
    const CFTConfig &config = tracker.config;
    Prepared prepared;
    const double total = static_cast<double>(raw.rows) * raw.cols;

    cv::Mat saturated;
    cv::compare(raw, cv::Scalar(config.saturationThreshold), saturated, cv::CMP_GE);
    int saturatedCount = cv::countNonZero(saturated);
    prepared.saturatedFraction = static_cast<float>(saturatedCount / total);

    if (config.excludeHighlights && saturatedCount >= config.minHighlightArea) {
        cv::Mat labels, stats, centroids;
        int count = cv::connectedComponentsWithStats(saturated, labels, stats, centroids, 8, CV_32S);
        std::vector<uchar> qualifies(static_cast<size_t>(count), 0);
        bool any = false;
        for (int label = 1; label < count; ++label) {
            int area = stats.at<int>(label, cv::CC_STAT_AREA);
            double box = static_cast<double>(stats.at<int>(label, cv::CC_STAT_WIDTH))
                       * stats.at<int>(label, cv::CC_STAT_HEIGHT);
            // Substantial, compact hotspots. Lettering is too small, a white
            // housing or washed-out frame too large, thin strokes too sparse.
            if (area >= config.minHighlightArea && area / box >= config.minHighlightFill
                && area <= config.maxHighlightAreaFraction * total) {
                qualifies[static_cast<size_t>(label)] = 1;
                any = true;
            }
        }
        if (any) {
            prepared.excluded = cv::Mat::zeros(raw.size(), CV_8UC1);
            for (int row = 0; row < raw.rows; ++row) {
                const int *label = labels.ptr<int>(row);
                uchar *out = prepared.excluded.ptr<uchar>(row);
                for (int column = 0; column < raw.cols; ++column) {
                    if (qualifies[static_cast<size_t>(label[column])]) out[column] = 255;
                }
            }
            prepared.excludedFraction = static_cast<float>(cv::countNonZero(prepared.excluded) / total);
        }
    }

    if (config.normalizeContrast) tracker.clahe->apply(raw, prepared.image);
    else prepared.image = raw;
    return prepared;
}

/// Drops every feature whose descriptor support touches an excluded pixel.
/// ORB's rotated BRIEF pattern lies in a 31×31 patch at the keypoint's pyramid
/// scale (keypoint.size = 31 × scale), smoothed first; a disc of radius
/// 0.75 × size covers that patch at any rotation plus the smoothing margin.
int excludeTouching(const cv::Mat &excluded, std::vector<cv::KeyPoint> &keypoints, cv::Mat &descriptors) {
    if (excluded.empty() || keypoints.empty()) return 0;
    cv::Mat integral;
    cv::integral(excluded, integral, CV_32S);
    auto boxSum = [&](int x0, int y0, int x1, int y1) {  // inclusive-exclusive
        return integral.at<int>(y1, x1) - integral.at<int>(y0, x1) - integral.at<int>(y1, x0) + integral.at<int>(y0, x0);
    };

    std::vector<cv::KeyPoint> kept;
    cv::Mat keptDescriptors;
    kept.reserve(keypoints.size());
    for (size_t i = 0; i < keypoints.size(); ++i) {
        const cv::KeyPoint &keypoint = keypoints[i];
        double radius = 0.75 * keypoint.size;
        int x0 = std::max(0, static_cast<int>(std::floor(keypoint.pt.x - radius)));
        int y0 = std::max(0, static_cast<int>(std::floor(keypoint.pt.y - radius)));
        int x1 = std::min(excluded.cols, static_cast<int>(std::ceil(keypoint.pt.x + radius)) + 1);
        int y1 = std::min(excluded.rows, static_cast<int>(std::ceil(keypoint.pt.y + radius)) + 1);
        bool touches = false;
        if (x0 < x1 && y0 < y1 && boxSum(x0, y0, x1, y1) > 0) {
            for (int y = y0; y < y1 && !touches; ++y) {
                const uchar *row = excluded.ptr<uchar>(y);
                for (int x = x0; x < x1; ++x) {
                    double dx = x - keypoint.pt.x, dy = y - keypoint.pt.y;
                    if (row[x] && dx * dx + dy * dy <= radius * radius) { touches = true; break; }
                }
            }
        }
        if (!touches) {
            kept.push_back(keypoint);
            keptDescriptors.push_back(descriptors.row(static_cast<int>(i)));
        }
    }
    int dropped = static_cast<int>(keypoints.size() - kept.size());
    keypoints = std::move(kept);
    descriptors = keptDescriptors;
    return dropped;
}

/// Wraps the caller's pixels without copying. Fails on any buffer we cannot
/// prove is well formed from its header; the caller vouches for the length.
bool view(const CFTConfig &config, const CFTGrayImage *image, cv::Mat &out) {
    if (image == nullptr || image->pixels == nullptr) return false;
    if (image->width < config.minDimension || image->width > config.maxDimension) return false;
    if (image->height < config.minDimension || image->height > config.maxDimension) return false;
    if (image->bytesPerRow < image->width) return false;
    out = cv::Mat(image->height, image->width, CV_8UC1,
                  const_cast<uint8_t *>(image->pixels), static_cast<size_t>(image->bytesPerRow));
    return true;
}

float clamp(float value, float low, float high) {
    return std::min(std::max(value, low), high);
}

float evidenceScore(float inlierRatio, float coverage, int32_t inliers) {
    float score = 0.4f + 0.2f * inlierRatio
                + 0.2f * std::min(1.0f, coverage / 0.5f)
                + 0.15f * std::min(1.0f, static_cast<float>(inliers) / 80.0f);
    return clamp(score, 0, 0.95f);
}

CFTStatus lost(CFTMatchResult &result, CFTLossReason reason) {
    std::fill(std::begin(result.corners), std::end(result.corners), CFTPoint{0, 0});
    result.confidence = 0;
    result.lossReason = reason;
    return CFT_STATUS_LOST;
}

CFTStatus matchFrame(CFTTracker &tracker, const cv::Mat &frame, CFTMatchResult &result) {
    const CFTConfig &config = tracker.config;
    result.referenceFeatures = static_cast<int32_t>(tracker.activeIDs.size());

    Prepared prepared = prepare(tracker, frame);
    result.saturatedFraction = prepared.saturatedFraction;
    result.excludedHighlightFraction = prepared.excludedFraction;

    std::vector<cv::KeyPoint> keypoints;
    cv::Mat descriptors;
    tracker.orb->detectAndCompute(prepared.image, cv::noArray(), keypoints, descriptors);
    result.excludedFeatures = excludeTouching(prepared.excluded, keypoints, descriptors);
    result.frameFeatures = static_cast<int32_t>(keypoints.size());
    if (descriptors.rows < config.minInliers) return lost(result, CFT_LOSS_TOO_FEW_FRAME_FEATURES);

    // Live → reference with a ratio test: a live feature that resembles two
    // reference features nearly equally (repeated controls) says nothing.
    std::vector<std::vector<cv::DMatch>> candidates;
    tracker.matcher.knnMatch(descriptors, tracker.activeDescriptors, candidates, 2);

    // Reference → live best match, for the mutual check: many live features
    // agreeing on one reference feature (a repeated pattern) keep only one.
    std::vector<cv::DMatch> reverse;
    if (config.mutualMatching) tracker.matcher.match(tracker.activeDescriptors, descriptors, reverse);

    std::vector<cv::Point2f> referencePoints, livePoints;
    std::vector<int32_t> matchedIDs;
    for (const auto &pair : candidates) {
        if (pair.empty()) continue;
        const cv::DMatch &best = pair[0];
        if (best.distance > config.maxHammingDistance) continue;
        if (pair.size() > 1 && !(best.distance < config.ratioTest * pair[1].distance)) continue;
        if (config.mutualMatching && reverse[best.trainIdx].trainIdx != best.queryIdx) continue;
        int32_t id = tracker.activeIDs[best.trainIdx];
        referencePoints.push_back(tracker.referencePoints[id]);
        livePoints.push_back(keypoints[best.queryIdx].pt);
        matchedIDs.push_back(id);
    }
    result.matchCount = static_cast<int32_t>(matchedIDs.size());
    if (result.matchCount < config.minInliers) return lost(result, CFT_LOSS_TOO_FEW_MATCHES);

    std::vector<uchar> mask;
    cv::Mat homography = cv::findHomography(referencePoints, livePoints, cv::RANSAC,
                                            config.ransacThreshold, mask, 2000, 0.995);
    if (homography.empty() || homography.type() != CV_64F || !cv::checkRange(homography)) {
        return lost(result, CFT_LOSS_NO_HOMOGRAPHY);
    }

    // Recount against the final refined homography so the inliers, their error
    // and the corners all describe the same model.
    std::vector<cv::Point2f> projected;
    cv::perspectiveTransform(referencePoints, projected, homography);
    std::vector<cv::Point2f> inlierReferencePoints;
    double errorSum = 0;
    for (size_t i = 0; i < projected.size(); ++i) {
        double error = cv::norm(projected[i] - livePoints[i]);
        if (!std::isfinite(error) || error > config.ransacThreshold) continue;
        errorSum += error;
        inlierReferencePoints.push_back(referencePoints[i]);
        tracker.lastInlierPoints.push_back({livePoints[i].x, livePoints[i].y});
        tracker.lastInlierIDs.push_back(matchedIDs[i]);
    }
    result.inlierCount = static_cast<int32_t>(inlierReferencePoints.size());
    result.inlierRatio = static_cast<float>(result.inlierCount) / static_cast<float>(result.matchCount);
    result.reprojectionError = result.inlierCount > 0 ? static_cast<float>(errorSum / result.inlierCount) : 0;

    if (result.inlierCount >= 3) {
        std::vector<cv::Point2f> hull;
        cv::convexHull(inlierReferencePoints, hull);
        result.coverage = clamp(static_cast<float>(cv::contourArea(hull) / tracker.referenceArea), 0, 1);
    }

    if (result.inlierCount < config.minInliers) return lost(result, CFT_LOSS_TOO_FEW_INLIERS);
    if (result.inlierRatio < config.minInlierRatio) return lost(result, CFT_LOSS_LOW_INLIER_RATIO);
    if (result.coverage < config.minCoverage) return lost(result, CFT_LOSS_LOW_COVERAGE);

    // Project the corners by hand so the homogeneous w can be checked. A
    // homography's overall sign is arbitrary, so only w's consistency matters:
    // w is affine across the panel, so one sign at all four corners means the
    // whole convex panel is on one side of the horizon. A sign change or a w
    // near zero means part of it maps through the horizon, not to visible points.
    const double *h = homography.ptr<double>();
    double w[4];
    double largest = 0;
    for (int i = 0; i < 4; ++i) {
        double x = tracker.referenceCorners[i].x, y = tracker.referenceCorners[i].y;
        w[i] = h[6] * x + h[7] * y + h[8];
        if (!std::isfinite(w[i])) return lost(result, CFT_LOSS_INVALID_GEOMETRY);
        largest = std::max(largest, std::abs(w[i]));
    }
    CFTPoint corners[4];
    for (int i = 0; i < 4; ++i) {
        if (std::abs(w[i]) <= std::max(1e-12, 1e-6 * largest) || (w[i] > 0) != (w[0] > 0)) {
            return lost(result, CFT_LOSS_INVALID_GEOMETRY);
        }
        double x = tracker.referenceCorners[i].x, y = tracker.referenceCorners[i].y;
        corners[i] = {static_cast<float>((h[0] * x + h[1] * y + h[2]) / w[i]),
                      static_cast<float>((h[3] * x + h[4] * y + h[5]) / w[i])};
        if (!isFinite(corners[i])) return lost(result, CFT_LOSS_INVALID_GEOMETRY);
    }
    // Folded or self-intersecting quads, and mirrored ones (TL/TR swapped),
    // cannot be the same flat panel viewed from the front.
    if (winding(corners) != tracker.referenceWinding) return lost(result, CFT_LOSS_INVALID_GEOMETRY);

    double fraction = area(corners) / (static_cast<double>(frame.cols) * frame.rows);
    if (!(fraction >= config.minAreaFraction && fraction <= config.maxAreaFraction)) {
        return lost(result, CFT_LOSS_IMPLAUSIBLE_AREA);
    }

    std::copy(std::begin(corners), std::end(corners), result.corners);
    result.confidence = evidenceScore(result.inlierRatio, result.coverage, result.inlierCount);
    result.lossReason = CFT_LOSS_NONE;
    return CFT_STATUS_OK;
}

}  // namespace

extern "C" {

void cft_default_config(CFTConfig *config) {
    if (config == nullptr) return;
    *config = CFTConfig{
        .maxFeatures = 1800,
        .pyramidLevels = 8,
        .fastThreshold = 12,
        .minReferenceFeatures = 40,
        .maxHammingDistance = 64,
        .ratioTest = 0.75f,
        .mutualMatching = 1,
        .ransacThreshold = 2.5f,
        .minInliers = 20,
        .minInlierRatio = 0.45f,
        .minCoverage = 0.12f,
        .minAreaFraction = 0.005f,
        .maxAreaFraction = 4.0f,
        .minDimension = 32,
        .maxDimension = 4096,
        .excludeHighlights = 1,
        .normalizeContrast = 0,
        .saturationThreshold = 250,
        .minHighlightArea = 256,
        .minHighlightFill = 0.7f,
        .maxHighlightAreaFraction = 0.25f,
        .claheClipLimit = 2.0f,
        .claheGridSize = 8,
    };
}

CFTTracker *cft_create(const CFTConfig *config) {
    try {
        CFTConfig resolved;
        if (config != nullptr) resolved = *config;
        else cft_default_config(&resolved);
        if (!validConfig(resolved)) return nullptr;

        auto *tracker = new CFTTracker();
        tracker->config = resolved;
        tracker->orb = cv::ORB::create(resolved.maxFeatures, 1.2f, resolved.pyramidLevels, 31, 0, 2,
                                       cv::ORB::HARRIS_SCORE, 31, resolved.fastThreshold);
        tracker->clahe = cv::createCLAHE(resolved.claheClipLimit,
                                         cv::Size(resolved.claheGridSize, resolved.claheGridSize));
        return tracker;
    } catch (...) {
        return nullptr;
    }
}

void cft_destroy(CFTTracker *tracker) {
    delete tracker;
}

CFTStatus cft_register_reference(CFTTracker *tracker, const CFTGrayImage *reference,
                                 const CFTPoint corners[4], CFTRegistrationInfo *info) {
    if (info != nullptr) *info = CFTRegistrationInfo{};
    if (tracker == nullptr) return CFT_STATUS_INVALID_ARGUMENT;
    // Any failed registration, including bad arguments, leaves no old reference behind.
    tracker->unregister();
    if (corners == nullptr) return CFT_STATUS_INVALID_ARGUMENT;
    return guarded([&] {

        cv::Mat image;
        if (!view(tracker->config, reference, image)) return CFT_STATUS_INVALID_BUFFER;

        CFTPoint quad[4];
        for (int i = 0; i < 4; ++i) {
            quad[i] = corners[i];
            if (!isFinite(quad[i])) return CFT_STATUS_INVALID_ARGUMENT;
            if (quad[i].x < -0.5f || quad[i].y < -0.5f
                || quad[i].x > image.cols + 0.5f || quad[i].y > image.rows + 0.5f) {
                return CFT_STATUS_INVALID_ARGUMENT;
            }
        }
        int quadWinding = winding(quad);
        double quadArea = area(quad);
        if (quadWinding == 0 || quadArea < tracker->config.minAreaFraction * image.cols * image.rows) {
            return CFT_STATUS_INVALID_ARGUMENT;
        }

        cv::Mat mask = cv::Mat::zeros(image.size(), CV_8UC1);
        std::vector<cv::Point> polygon;
        for (const auto &corner : quad) {
            polygon.emplace_back(cvRound(corner.x), cvRound(corner.y));
        }
        cv::fillConvexPoly(mask, polygon, cv::Scalar(255));

        Prepared prepared = prepare(*tracker, image);
        if (info != nullptr) {
            info->saturatedFraction = prepared.saturatedFraction;
            info->excludedHighlightFraction = prepared.excludedFraction;
        }

        std::vector<cv::KeyPoint> keypoints;
        cv::Mat descriptors;
        tracker->orb->detectAndCompute(prepared.image, mask, keypoints, descriptors);
        int excludedFeatures = excludeTouching(prepared.excluded, keypoints, descriptors);
        if (info != nullptr) info->excludedFeatures = excludedFeatures;
        if (descriptors.rows < tracker->config.minReferenceFeatures) {
            return CFT_STATUS_INSUFFICIENT_FEATURES;
        }

        tracker->referencePoints.reserve(keypoints.size());
        for (const auto &keypoint : keypoints) tracker->referencePoints.push_back(keypoint.pt);
        tracker->referenceDescriptors = descriptors.clone();
        std::copy(std::begin(quad), std::end(quad), tracker->referenceCorners);
        tracker->referenceArea = quadArea;
        tracker->referenceWinding = quadWinding;

        std::vector<int32_t> all(static_cast<size_t>(descriptors.rows));
        for (size_t id = 0; id < all.size(); ++id) all[id] = static_cast<int32_t>(id);
        tracker->activate(all);
        tracker->registered = true;

        if (info != nullptr) info->referenceFeatures = descriptors.rows;
        return CFT_STATUS_OK;
    });
}

CFTStatus cft_match_frame(CFTTracker *tracker, const CFTGrayImage *frame, CFTMatchResult *result) {
    CFTMatchResult local{};
    CFTMatchResult &out = result != nullptr ? *result : local;
    out = CFTMatchResult{};
    if (tracker == nullptr) return CFT_STATUS_INVALID_ARGUMENT;
    tracker->clearEvidence();

    auto start = std::chrono::steady_clock::now();
    CFTStatus status = guarded([&] {
        if (!tracker->registered) return CFT_STATUS_NOT_REGISTERED;
        cv::Mat image;
        if (!view(tracker->config, frame, image)) return CFT_STATUS_INVALID_BUFFER;
        return matchFrame(*tracker, image, out);
    });
    if (status != CFT_STATUS_OK && status != CFT_STATUS_LOST) {
        // Errors carry no partial evidence that could be mistaken for a frame result.
        out = CFTMatchResult{};
        tracker->clearEvidence();
    }
    tracker->lastTracked = status == CFT_STATUS_OK;
    if (status == CFT_STATUS_LOST) {
        std::fill(std::begin(out.corners), std::end(out.corners), CFTPoint{0, 0});
        out.confidence = 0;
    }
    out.processingMilliseconds = std::chrono::duration<float, std::milli>(
        std::chrono::steady_clock::now() - start).count();
    return status;
}

void cft_reset(CFTTracker *tracker) {
    if (tracker != nullptr) tracker->unregister();
}

int32_t cft_copy_inlier_points(const CFTTracker *tracker, CFTPoint *points, int32_t capacity) {
    if (tracker == nullptr) return 0;
    auto count = static_cast<int32_t>(tracker->lastInlierPoints.size());
    if (points != nullptr && capacity > 0) {
        std::copy_n(tracker->lastInlierPoints.begin(), std::min(count, capacity), points);
    }
    return count;
}

int32_t cft_copy_inlier_feature_ids(const CFTTracker *tracker, int32_t *ids, int32_t capacity) {
    if (tracker == nullptr) return 0;
    auto count = static_cast<int32_t>(tracker->lastInlierIDs.size());
    if (ids != nullptr && capacity > 0) {
        std::copy_n(tracker->lastInlierIDs.begin(), std::min(count, capacity), ids);
    }
    return count;
}

int32_t cft_reference_feature_count(const CFTTracker *tracker) {
    if (tracker == nullptr || !tracker->registered) return 0;
    return static_cast<int32_t>(tracker->referencePoints.size());
}

CFTStatus cft_set_active_features(CFTTracker *tracker, const int32_t *ids, int32_t count) {
    if (tracker == nullptr || (ids == nullptr && count > 0)) return CFT_STATUS_INVALID_ARGUMENT;
    if (!tracker->registered) return CFT_STATUS_NOT_REGISTERED;
    return guarded([&] {
        if (count < tracker->config.minReferenceFeatures) return CFT_STATUS_INSUFFICIENT_FEATURES;
        auto total = static_cast<int32_t>(tracker->referencePoints.size());
        std::vector<bool> seen(static_cast<size_t>(total), false);
        std::vector<int32_t> subset(ids, ids + count);
        for (int32_t id : subset) {
            if (id < 0 || id >= total || seen[static_cast<size_t>(id)]) return CFT_STATUS_INVALID_ARGUMENT;
            seen[static_cast<size_t>(id)] = true;
        }
        tracker->activate(subset);
        tracker->clearEvidence();
        return CFT_STATUS_OK;
    });
}

void cft_restore_all_features(CFTTracker *tracker) {
    if (tracker == nullptr || !tracker->registered) return;
    guarded([&] {
        std::vector<int32_t> all(tracker->referencePoints.size());
        for (size_t id = 0; id < all.size(); ++id) all[id] = static_cast<int32_t>(id);
        tracker->activate(all);
        tracker->clearEvidence();
        return CFT_STATUS_OK;
    });
}

int32_t cft_active_feature_count(const CFTTracker *tracker) {
    if (tracker == nullptr || !tracker->registered) return 0;
    return static_cast<int32_t>(tracker->activeIDs.size());
}

CFTStatus cft_observe_calibration_view(CFTTracker *tracker) {
    if (tracker == nullptr) return CFT_STATUS_INVALID_ARGUMENT;
    if (!tracker->registered) return CFT_STATUS_NOT_REGISTERED;
    // Counting persistent features is Visual tracking 4 (#84).
    return tracker->lastTracked ? CFT_STATUS_OK : CFT_STATUS_LOST;
}

int32_t cft_finish_calibration(CFTTracker *tracker) {
    (void)tracker;
    return -1;
}

void cft_reset_calibration(CFTTracker *tracker) {
    cft_restore_all_features(tracker);
}

const char *cft_status_description(CFTStatus status) {
    switch (status) {
    case CFT_STATUS_OK: return "ok";
    case CFT_STATUS_LOST: return "panel not found";
    case CFT_STATUS_INVALID_ARGUMENT: return "invalid argument";
    case CFT_STATUS_INVALID_BUFFER: return "invalid image buffer";
    case CFT_STATUS_NOT_REGISTERED: return "no reference registered";
    case CFT_STATUS_INSUFFICIENT_FEATURES: return "too few reference features";
    case CFT_STATUS_INTERNAL_ERROR: return "internal error";
    }
    return "unknown status";
}

const char *cft_loss_reason_description(CFTLossReason reason) {
    switch (reason) {
    case CFT_LOSS_NONE: return "tracked";
    case CFT_LOSS_TOO_FEW_FRAME_FEATURES: return "too few features in frame";
    case CFT_LOSS_TOO_FEW_MATCHES: return "too few unambiguous matches";
    case CFT_LOSS_NO_HOMOGRAPHY: return "no consistent homography";
    case CFT_LOSS_TOO_FEW_INLIERS: return "too few inliers";
    case CFT_LOSS_LOW_INLIER_RATIO: return "inlier ratio too low";
    case CFT_LOSS_LOW_COVERAGE: return "evidence covers too little of the panel";
    case CFT_LOSS_INVALID_GEOMETRY: return "invalid projected geometry";
    case CFT_LOSS_IMPLAUSIBLE_AREA: return "implausible projected size";
    }
    return "unknown loss reason";
}

}  // extern "C"
