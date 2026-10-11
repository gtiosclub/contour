import ContourCore
import ContourMocks
import Testing
@testable import SurfaceUnderstanding

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
