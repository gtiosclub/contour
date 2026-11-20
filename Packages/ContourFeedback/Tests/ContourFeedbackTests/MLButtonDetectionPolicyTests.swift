import ContourCore
import CoreGraphics
import Foundation
import Testing
@testable import ContourFeedback

@Suite("ML control geometry and suppression")
struct MLButtonDetectionPolicyTests {
    private typealias Detector = MLButtonDetection

    private func candidate(_ bounds: PanelRect, _ score: Double, category: String = "touch") -> Detector.Candidate {
        .init(bounds: bounds, confidence: score, category: category, source: "Test", accepted: true)
    }

    @Test("A normalized class score of one does not imply a certain detection")
    func scores() throws {
        #expect(Detector.detectionScore(object: 0.12, classification: 1) == 0.12)
        let score = try #require(Detector.detectionScore(object: 0.8, classification: 0.75))
        #expect(abs(score - 0.6) < 1e-9)
        #expect(Detector.detectionScore(object: .nan, classification: 1) == nil)
        #expect(Detector.detectionScore(object: 0.5, classification: 1.1) == nil)
        #expect(Detector.detectionScore(object: -0.1, classification: 1) == nil)
    }

    @Test("Deduplication compares detection scores even when both class scores are one")
    func scoreRanking() throws {
        let weak = try #require(Detector.detectionScore(object: 0.12, classification: 1))
        let strong = try #require(Detector.detectionScore(object: 0.85, classification: 1))
        let a = PanelRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        let b = PanelRect(x: 0.11, y: 0.1, width: 0.2, height: 0.2)
        let result = Detector.mergeCandidates([candidate(a, weak), candidate(b, strong)], threshold: 0.45)
        #expect(result.count == 1)
        #expect(result.first?.bounds == b)
        #expect(result.first?.confidence == strong)
    }

    @Test("Class and crop duplicates keep the highest-score box without moving it")
    func duplicates() {
        let box = PanelRect(x: 0.2, y: 0.3, width: 0.2, height: 0.1)
        let shifted = PanelRect(x: 0.21, y: 0.3, width: 0.2, height: 0.1)
        let merged = Detector.mergeCandidates([candidate(shifted, 0.3), candidate(box, 0.9, category: "pushbutton")], threshold: 0.45)
        #expect(merged.count == 1)
        #expect(merged.first?.bounds == box)
        #expect(merged.first?.confidence == 0.9)
    }

    @Test("Nested same-centre duplicates merge even when their IoU is small")
    func containment() {
        let big = PanelRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4)
        let small = PanelRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)
        #expect(Detector.mergeCandidates([candidate(big, 0.8), candidate(small, 0.5)], threshold: 0.45).count == 1)
        let neighbouring = PanelRect(x: 0.4, y: 0.2, width: 0.2, height: 0.2)
        #expect(Detector.mergeCandidates([candidate(small, 0.8), candidate(neighbouring, 0.5)], threshold: 0.45).count == 2)
    }

    @Test("Conflicts drop the lower score; surviving and neighbouring boxes never shrink")
    func conflicts() {
        let a = PanelRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        let b = PanelRect(x: 0.25, y: 0.1, width: 0.2, height: 0.2)
        let c = PanelRect(x: 0.5, y: 0.1, width: 0.2, height: 0.2)
        let kept = Detector.removeConflictingControls([
            .init(bounds: b, confidence: 0.4), .init(bounds: a, confidence: 0.9), .init(bounds: c, confidence: 0.6)
        ])
        #expect(kept.map(\.bounds) == [a, c])
    }

    @Test("Tile coordinates map back into the original top-left image coordinate system")
    func mapping() throws {
        let crop = CGRect(x: 200, y: 400, width: 400, height: 800)
        let mapped = try #require(Detector.imageBounds(CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25), crop: crop, width: 1000, height: 2000))
        #expect(abs(mapped.minX - 0.3) < 1e-9)
        #expect(abs(mapped.minY - 0.3) < 1e-9)
        #expect(abs(mapped.width - 0.2) < 1e-9)
        #expect(abs(mapped.height - 0.1) < 1e-9)
        #expect(Detector.imageBounds(CGRect(x: Double.nan, y: 0, width: 1, height: 1), crop: crop, width: 1000, height: 2000) == nil)
    }

    @Test("Crop edges reject truncated boxes only at internal image boundaries")
    func edges() {
        let crop = CGRect(x: 0, y: 350, width: 1000, height: 650)
        let atTop = CGRect(x: 0.2, y: 0.9, width: 0.1, height: 0.1)
        let atBottom = CGRect(x: 0.2, y: 0, width: 0.1, height: 0.1)
        #expect(Detector.touchesInternalEdge(atTop, crop: crop, width: 1000, height: 1000))
        #expect(!Detector.touchesInternalEdge(atBottom, crop: crop, width: 1000, height: 1000))
    }

    @Test("Portrait, landscape and square tiles cover the image with overlapping integer crops")
    func regions() {
        for (w, h) in [(1200, 2000), (2000, 1200), (1000, 1000)] {
            let full = CGRect(x: 0, y: 0, width: w, height: h)
            #expect(Detector.inferenceRegions(width: w, height: h, mode: .wholeImage) == [full])
            let crops = Array(Detector.inferenceRegions(width: w, height: h, mode: .wholeImageAndTiles).dropFirst())
            #expect((2...9).contains(crops.count))
            #expect(crops.allSatisfy { full.contains($0) && $0 == $0.integral && $0.width == $0.height })
            for y in stride(from: 0.5, to: Double(h), by: Double(h) / 20) {
                for x in stride(from: 0.5, to: Double(w), by: Double(w) / 20) {
                    #expect(crops.contains { $0.contains(CGPoint(x: x, y: y)) })
                }
            }
        }
    }

    @Test("Edge correction follows a nearby button outline without raising the model score")
    func edgesRefine() {
        let original = PanelRect(x: 0.2, y: 0.2, width: 0.2, height: 0.1)
        let edge = PanelRect(x: 0.2, y: 0.22, width: 0.2, height: 0.1)
        let result = Detector.refineCandidates([candidate(original, 0.7)], edges: [edge])
        #expect(result.first?.bounds == edge)
        #expect(result.first?.confidence == 0.7)
        #expect(result.first?.source.contains("edge") == true)
    }

    @Test("Ambiguous adjacent outlines do not move the target between buttons")
    func ambiguousEdges() {
        let original = PanelRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)
        let top = PanelRect(x: 0.2, y: 0.14, width: 0.2, height: 0.2)
        let bottom = PanelRect(x: 0.2, y: 0.26, width: 0.2, height: 0.2)
        let result = Detector.refineCandidates([candidate(original, 0.7)], edges: [top, bottom])
        #expect(result.first?.bounds == original)
    }

    @Test("Panel borders and knob decorations cannot replace a button's geometry")
    func unsuitableEdges() {
        let original = PanelRect(x: 0.2, y: 0.2, width: 0.2, height: 0.1)
        let panel = PanelRect(x: 0, y: 0, width: 1, height: 1)
        #expect(Detector.refineCandidates([candidate(original, 0.7)], edges: [panel]).first?.bounds == original)
        let near = PanelRect(x: 0.2, y: 0.22, width: 0.2, height: 0.1)
        #expect(Detector.refineCandidates([candidate(original, 0.7, category: "knob")], edges: [near]).first?.bounds == original)
    }

    @Test("Weak isolated display candidates are removed, while weak neighbouring buttons survive")
    func weakOutliers() {
        let a = candidate(.init(x: 0.2, y: 0.5, width: 0.1, height: 0.05), 0.9)
        let b = candidate(.init(x: 0.4, y: 0.5, width: 0.1, height: 0.05), 0.8)
        let near = candidate(.init(x: 0.2, y: 0.57, width: 0.1, height: 0.05), 0.15)
        let far = candidate(.init(x: 0.2, y: 0.1, width: 0.05, height: 0.05), 0.12)
        let result = Detector.removeWeakOutliers([a, b, near, far], imageSize: .init(width: 1000, height: 2000))
        #expect(result.map(\.bounds) == [a.bounds, b.bounds, near.bounds])
        #expect(Detector.removeWeakOutliers([near, far], imageSize: .init(width: 1000, height: 2000)).count == 2)
    }

    @Test("Cancelled review stops before decoding or model inference")
    func cancellation() async {
        let detector = Detector()
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await detector.review(from: PanelPhoto(data: Data(), pixelSize: .init(width: 1, height: 1), timestamp: Date()))
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled review returned a result")
        } catch {
            #expect((error as? SurfaceUnderstandingError) == .cancelled)
        }
    }
}
