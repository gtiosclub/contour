import ContourCore
import ContourMocks
import Foundation
import Testing
@testable import SurfaceUnderstanding

// MARK: - Mock microwave

@Test("stop and clear both find Stop/Clear on the mock")
func stopAndClear() throws {
    let map = MockSurfaceMaps.microwave
    let target = try #require(map.button(labelled: "Stop/Clear"))
    #expect(TargetMatcher().match("stop", in: map)?.button.id == target.id)
    #expect(TargetMatcher().match("clear", in: map)?.button.id == target.id)
}

@Test("\"add thirty\" finds Add 30 Sec")
func addThirtyFindsAdd30Sec() throws {
    let map = MockSurfaceMaps.microwave
    let target = try #require(map.button(labelled: "Add 30 Sec"))
    let match = TargetMatcher().match("add thirty", in: map)
    #expect(match?.button.id == target.id)
    #expect(match?.confidence == 0.9)
}

@Test("the exact label \"Add 30 Sec\" matches with full confidence")
func exactLabelMatches() throws {
    let map = MockSurfaceMaps.microwave
    let target = try #require(map.button(labelled: "Add 30 Sec"))
    let match = TargetMatcher().match("Add 30 Sec", in: map)
    #expect(match?.button.id == target.id)
    #expect(match?.confidence == 1.0)
}

@Test("a spelled-out number word resolves: \"add thirty seconds\" finds Add 30 Sec")
func numberWordResolves() throws {
    let map = MockSurfaceMaps.microwave
    let target = try #require(map.button(labelled: "Add 30 Sec"))
    #expect(TargetMatcher().match("add thirty seconds", in: map)?.button.id == target.id)
}

@Test("a control that isn't on the panel returns nil")
func missingControlReturnsNil() {
    let map = MockSurfaceMaps.microwave
    #expect(TargetMatcher().match("bake", in: map) == nil)
}

// MARK: - Issue #73: real panel labels
// Each row becomes its own test, named like: #10 "pause" on Neat2.jpeg

struct PanelRow: Sendable, CustomTestStringConvertible {
    let n: Int
    let panel: String
    let say: String
    let expect: String?
    var testDescription: String { "#\(n) \"\(say)\" on \(panel)" }
}

@Test("#73 real panel labels", arguments: [
    // Words inside a longer label
    PanelRow(n: 1,  panel: "normal_microwave.jpg", say: "start",       expect: "Start Pause"),
    PanelRow(n: 2,  panel: "microwave2-neat2.jpg", say: "start",       expect: "START →vûsec."),
    PanelRow(n: 3,  panel: "normal_microwave.jpg", say: "go",          expect: "Start Pause"),
    PanelRow(n: 4,  panel: "Neat2.jpeg",           say: "power",       expect: "Power Level"),
    PanelRow(n: 5,  panel: "Neat2.jpeg",           say: "defrost",     expect: "Defrost time/weight"),
    PanelRow(n: 6,  panel: "hand-labelled microwave-01.jpg", say: "power level", expect: "Power"),
    PanelRow(n: 7,  panel: "Neat2.jpeg",           say: "cook time",   expect: "Time Cook"),

    // Stop, pause, cancel
    PanelRow(n: 8,  panel: "normal_microwave.jpg", say: "stop",   expect: "Cancel Off"),
    PanelRow(n: 9,  panel: "normal_microwave.jpg", say: "pause",  expect: "Start Pause"),
    PanelRow(n: 10, panel: "Neat2.jpeg",           say: "pause",  expect: "Start Pause"),
    PanelRow(n: 11, panel: "glare_microwave.jpg",  say: "stop",   expect: "Cancel Off"),
    PanelRow(n: 12, panel: "glare_microwave.jpg",  say: "cancel", expect: "Cancel Off"),
    PanelRow(n: 13, panel: "hand-labelled microwave-01.jpg", say: "pause", expect: "Start/Pause"),
    PanelRow(n: 14, panel: "hand-labelled microwave-01.jpg", say: "stop",  expect: "Cancel/Off"),
    PanelRow(n: 15, panel: "hand-labelled microwave-04.jpg", say: "pause", expect: "Stop/Cancel"),
    PanelRow(n: 16, panel: "microwave1_neat.heif", say: "pause",  expect: nil),
    // No Stop or Cancel key: stop must not fall back to Start Pause.
    // PanelRow(n: 44, panel: "angle_microwave.jpg",  say: "stop",   expect: nil),

    // Time, timer, clock
    PanelRow(n: 17, panel: "microwave1_neat.heif", say: "timer",         expect: "Timer Set/Off"),
    PanelRow(n: 18, panel: "microwave1_neat.heif", say: "time",          expect: "Time Cook"),
    PanelRow(n: 19, panel: "Neat2.jpeg",           say: "kitchen timer", expect: "Timer on/off"),
    PanelRow(n: 20, panel: "hand-labelled microwave-04.jpg", say: "timer", expect: "Timer"),
    PanelRow(n: 21, panel: "hand-labelled microwave-04.jpg", say: "clock", expect: "Clock"),
    PanelRow(n: 22, panel: "hand-labelled microwave-04.jpg", say: "time",  expect: "Time Cook"),
    PanelRow(n: 23, panel: "neat-microwave.heif",  say: "clock",         expect: "Clock"),
    PanelRow(n: 24, panel: "microwave2-glare.jpg", say: "time",          expect: nil),
    PanelRow(n: 25, panel: "Angle.jpeg",           say: "timer",         expect: nil),
    PanelRow(n: 26, panel: "neat-oven.heif",       say: "time",          expect: "Cook Time"),
    PanelRow(n: 27, panel: "Neat2.jpeg",           say: "time",          expect: "Time Cook"),
    PanelRow(n: 28, panel: "Angle.jpeg",           say: "time",          expect: "Cook Time"),
    PanelRow(n: 29, panel: "Angle.jpeg",           say: "clock",         expect: nil),

    // +30 sec
    PanelRow(n: 30, panel: "Neat2.jpeg",           say: "add 30 seconds", expect: "30 Add Sec"),
    PanelRow(n: 31, panel: "normal_microwave.jpg", say: "+30 sec",        expect: "30 Sec"),
    PanelRow(n: 32, panel: "microwave1_neat.heif", say: "add 30 seconds", expect: "+ 30 Sec"),
    PanelRow(n: 33, panel: "microwave1_neat.heif", say: "30 seconds",     expect: "+ 30 Sec"),
    PanelRow(n: 34, panel: "hand-labelled microwave-01.jpg", say: "plus thirty seconds", expect: "Add 30 Sec"),
    PanelRow(n: 35, panel: "hand-labelled microwave-04.jpg", say: "add 30 seconds",      expect: "Start/+30 Sec"),

    // Other
    PanelRow(n: 36, panel: "glare_microwave.jpg",   say: "start",   expect: "Start"),
    PanelRow(n: 37, panel: "hand-labelled microwave-04.jpg", say: "start", expect: "Start/+30 Sec"),
    PanelRow(n: 38, panel: "microwave1_neat.heif",  say: "three",   expect: nil),
    PanelRow(n: 39, panel: "microwave1_glare.heif", say: "three",   expect: "3"),
    PanelRow(n: 40, panel: "microwave2-neat2.jpg",  say: "one",     expect: nil),
    PanelRow(n: 41, panel: "angle_microwave.jpg",   say: "popcorn", expect: nil),
    PanelRow(n: 42, panel: "OvenStraight.heif",     say: "start",   expect: nil),
    PanelRow(n: 43, panel: "microwave2-neat2.jpg",  say: "defrost", expect: nil),
    PanelRow(n: 45, panel: "Neat1.jpeg",            say: "start",   expect: "Start Pause"),
    PanelRow(n: 46, panel: "neat-oven.heif",        say: "start",   expect: nil),
])
func realPanelRow(_ row: PanelRow) {
    let result = TargetMatcher().match(row.say, in: RealPanelLabels.map(row.panel))
    #expect(result?.button.label == row.expect)
}

// MARK: - Merged labels

/// Ordinary 0.1-tall keys plus the label under test.
private func panel(with label: String, width: Double, height: Double) -> SurfaceMap {
    let others = ["Popcorn", "Time Cook", "Cancel Off", "Clock", "Power"].enumerated().map { i, text in
        SurfaceMap.Button(label: text, bounds: PanelRect(x: 0.6, y: Double(i) * 0.15, width: 0.3, height: 0.1), confidence: 1)
    }
    let target = SurfaceMap.Button(label: label, bounds: PanelRect(x: 0.1, y: 0.2, width: width, height: height), confidence: 1)
    return SurfaceMap(buttons: others + [target], confidence: 1)
}

@Test("a label taller than a quarter of the panel isn't Start (TestSet microwave-02)")
func tallMergedLabelIsSkipped() {
    let map = panel(with: "Start Pause Door Unlock", width: 0.27, height: 0.62)
    #expect(TargetMatcher().match("start", in: map) == nil)
}

@Test("a normal-height Start Pause still matches (normal_microwave)")
func normalStartPauseStays() {
    let map = panel(with: "Start Pause", width: 0.33, height: 0.11)
    #expect(TargetMatcher().match("start", in: map)?.button.label == "Start Pause")
}

@Test("Start Cancel read as one label isn't Start (neat-oven at 720x1280)")
func startCancelIsSkipped() {
    let map = panel(with: "Start Cancel", width: 0.22, height: 0.11)
    #expect(TargetMatcher().match("start", in: map) == nil)
}

@Test("the height rule only applies to start")
func heightRuleIsStartOnly() {
    let map = panel(with: "Start Pause Door Unlock", width: 0.27, height: 0.62)
    #expect(TargetMatcher().match("unlock", in: map)?.button.label == "Start Pause Door Unlock")
}

