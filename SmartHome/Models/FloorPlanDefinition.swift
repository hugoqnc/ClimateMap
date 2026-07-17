import CoreGraphics
import Foundation

struct PlanPoint: Codable, Hashable, Sendable {
    var x: Double
    var y: Double

    func point(in size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
    }

    static func normalized(_ x: Double, _ y: Double) -> PlanPoint {
        PlanPoint(x: x / ApartmentFloorPlan.sourceWidth, y: y / ApartmentFloorPlan.sourceHeight)
    }
}

enum PlanBarrierKind: String, Sendable {
    case wall
    case door
    case window
}

struct PlanSegment: Identifiable, Sendable {
    let id = UUID()
    let start: PlanPoint
    let end: PlanPoint
    let kind: PlanBarrierKind

    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, kind: PlanBarrierKind) {
        start = .normalized(x1, y1)
        end = .normalized(x2, y2)
        self.kind = kind
    }
}

struct PlanRoomLabel: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let position: PlanPoint

    init(_ name: String, _ x: Double, _ y: Double) {
        self.name = name
        position = .normalized(x, y)
    }
}

/// The only file that needs to change when the apartment layout changes.
/// All coordinates use the 804 × 1482 reference drawing and are normalized at runtime.
enum ApartmentFloorPlan {
    static let sourceWidth = 804.0
    static let sourceHeight = 1482.0
    static let aspectRatio = sourceWidth / sourceHeight

    static let outline: [PlanPoint] = [
        .normalized(28, 29), .normalized(758, 29), .normalized(758, 1365),
        .normalized(192, 1365), .normalized(192, 1456), .normalized(28, 1456),
    ]

    static let walls: [PlanSegment] = [
        PlanSegment(28, 29, 758, 29, kind: .wall),
        PlanSegment(758, 29, 758, 1365, kind: .wall),
        PlanSegment(758, 1365, 192, 1365, kind: .wall),
        PlanSegment(192, 1365, 192, 1456, kind: .wall),
        PlanSegment(192, 1456, 28, 1456, kind: .wall),
        PlanSegment(28, 1456, 28, 29, kind: .wall),
        PlanSegment(352, 29, 352, 313, kind: .wall),
        PlanSegment(28, 313, 758, 313, kind: .wall),
        PlanSegment(28, 747, 304, 747, kind: .wall),
        PlanSegment(192, 881, 758, 881, kind: .wall),
        PlanSegment(192, 881, 192, 1365, kind: .wall),
        PlanSegment(192, 1170, 758, 1170, kind: .wall),
        PlanSegment(589, 1170, 589, 1365, kind: .wall),
        PlanSegment(28, 1310, 192, 1310, kind: .wall),
    ]

    static let doors: [PlanSegment] = [
        PlanSegment(40, 313, 143, 313, kind: .door),
        PlanSegment(643, 313, 745, 313, kind: .door),
        PlanSegment(634, 881, 705, 881, kind: .door),
        PlanSegment(629, 1170, 728, 1170, kind: .door),
        PlanSegment(192, 1185, 192, 1285, kind: .door),
        PlanSegment(589, 1215, 589, 1318, kind: .door),
        PlanSegment(60, 1310, 163, 1310, kind: .door),
        PlanSegment(627, 1365, 728, 1365, kind: .door),
    ]

    static let windows: [PlanSegment] = [
        PlanSegment(758, 124, 758, 226, kind: .window),
        PlanSegment(758, 398, 758, 500, kind: .window),
        PlanSegment(758, 629, 758, 731, kind: .window),
        PlanSegment(758, 969, 758, 1070, kind: .window),
        PlanSegment(758, 1212, 758, 1312, kind: .window),
    ]

    static let rooms: [PlanRoomLabel] = [
        PlanRoomLabel("Bathroom", 190, 165),
        PlanRoomLabel("Kitchen", 550, 160),
        PlanRoomLabel("Living Room", 390, 545),
        PlanRoomLabel("Corridor", 104, 1060),
        PlanRoomLabel("Main Bedroom", 478, 1027),
        PlanRoomLabel("Small Bedroom", 388, 1272),
        PlanRoomLabel("Entrance", 674, 1272),
        PlanRoomLabel("WC", 108, 1390),
    ]

    static let suggestedMeterPositions: [PlanPoint] = [
        PlanPoint(x: 0.24, y: 0.34),
        PlanPoint(x: 0.67, y: 0.38),
        PlanPoint(x: 0.58, y: 0.69),
    ]


    static func contains(_ point: PlanPoint) -> Bool {
        var inside = false
        var previous = outline.count - 1
        for index in outline.indices {
            let a = outline[index]
            let b = outline[previous]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            previous = index
        }
        return inside
    }
}
