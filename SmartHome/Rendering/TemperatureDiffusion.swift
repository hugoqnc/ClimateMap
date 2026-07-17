import Foundation

struct DiffusionField: Sendable {
    let width: Int
    let height: Int
    let normalized: [Double]
    let minimum: Double
    let maximum: Double
}

enum TemperatureDiffusion {
    private static let gridWidth = 120
    private static let gridHeight = Int(Double(gridWidth) / ApartmentFloorPlan.aspectRatio)
    private static let doorResistance = 4.5
    private static let wallResistance = 120.0

    private struct Source {
        let position: PlanPoint
        let temperature: Double
        let strength: Double
    }

    private struct HeapNode {
        let index: Int
        let distance: Double
    }

    private struct MinHeap {
        private var items: [HeapNode] = []
        var isEmpty: Bool { items.isEmpty }

        mutating func push(_ item: HeapNode) {
            items.append(item)
            var index = items.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard items[parent].distance > item.distance else { break }
                items[index] = items[parent]
                index = parent
            }
            items[index] = item
        }

        mutating func pop() -> HeapNode? {
            guard !items.isEmpty else { return nil }
            let first = items[0]
            let last = items.removeLast()
            guard !items.isEmpty else { return first }
            var index = 0
            while true {
                let left = index * 2 + 1
                let right = left + 1
                guard left < items.count else { break }
                let child = right < items.count && items[right].distance < items[left].distance ? right : left
                guard items[child].distance < last.distance else { break }
                items[index] = items[child]
                index = child
            }
            items[index] = last
            return first
        }
    }

    static func make(
        meters: [MeterReading],
        positions: [String: PlanPoint]
    ) -> DiffusionField? {
        guard !meters.isEmpty, meters.allSatisfy(\.isAvailable) else { return nil }
        let sources = meters.compactMap { meter -> Source? in
            guard let position = positions[meter.id] else { return nil }
            return Source(position: position, temperature: meter.temperature, strength: 1)
        }

        guard !sources.isEmpty else { return nil }
        var minimum = sources.map(\.temperature).min() ?? 20
        var maximum = sources.map(\.temperature).max() ?? 25
        if maximum - minimum < 0.5 {
            let middle = (minimum + maximum) / 2
            minimum = middle - 0.75
            maximum = middle + 0.75
        }

        let mask = makeInsideMask()
        let distanceFields = sources.map { distances(from: $0.position, mask: mask) }
        var values = Array(repeating: Double.nan, count: gridWidth * gridHeight)

        for index in values.indices where mask[index] {
            var weightedTemperature = 0.0
            var totalWeight = 0.0
            for sourceIndex in sources.indices {
                let distance = distanceFields[sourceIndex][index]
                guard distance.isFinite else { continue }
                let weight = sources[sourceIndex].strength
                    * exp(-distance / 90)
                    / pow(distance + 2.5, 1.25)
                weightedTemperature += sources[sourceIndex].temperature * weight
                totalWeight += weight
            }
            guard totalWeight > 0 else { continue }
            let temperature = weightedTemperature / totalWeight
            values[index] = min(max((temperature - minimum) / (maximum - minimum), 0), 1)
        }
        return DiffusionField(width: gridWidth, height: gridHeight, normalized: values, minimum: minimum, maximum: maximum)
    }

    private static func makeInsideMask() -> [Bool] {
        var mask = Array(repeating: false, count: gridWidth * gridHeight)
        for y in 0..<gridHeight {
            for x in 0..<gridWidth {
                mask[y * gridWidth + x] = ApartmentFloorPlan.contains(gridPoint(x: x, y: y))
            }
        }
        return mask
    }

    private static func distances(from position: PlanPoint, mask: [Bool]) -> [Double] {
        var result = Array(repeating: Double.infinity, count: gridWidth * gridHeight)
        guard let start = nearestGridPoint(to: position, mask: mask) else { return result }
        let startIndex = start.y * gridWidth + start.x
        result[startIndex] = 0
        var heap = MinHeap()
        heap.push(HeapNode(index: startIndex, distance: 0))
        let directions = [(1, 0), (-1, 0), (0, 1), (0, -1)]

        while let current = heap.pop() {
            guard current.distance == result[current.index] else { continue }
            let x = current.index % gridWidth
            let y = current.index / gridWidth
            for (dx, dy) in directions {
                let nextX = x + dx
                let nextY = y + dy
                guard nextX >= 0, nextY >= 0, nextX < gridWidth, nextY < gridHeight else { continue }
                let nextIndex = nextY * gridWidth + nextX
                guard mask[nextIndex] else { continue }
                let resistance = edgeResistance(
                    from: gridPoint(x: x, y: y),
                    to: gridPoint(x: nextX, y: nextY)
                )
                let distance = current.distance + resistance
                guard distance < result[nextIndex] else { continue }
                result[nextIndex] = distance
                heap.push(HeapNode(index: nextIndex, distance: distance))
            }
        }
        return result
    }

    private static func nearestGridPoint(to position: PlanPoint, mask: [Bool]) -> (x: Int, y: Int)? {
        let targetX = min(max(Int((position.x * Double(gridWidth) - 0.5).rounded()), 0), gridWidth - 1)
        let targetY = min(max(Int((position.y * Double(gridHeight) - 0.5).rounded()), 0), gridHeight - 1)
        for radius in 0..<12 {
            for y in max(0, targetY - radius)...min(gridHeight - 1, targetY + radius) {
                for x in max(0, targetX - radius)...min(gridWidth - 1, targetX + radius) where mask[y * gridWidth + x] {
                    return (x, y)
                }
            }
        }
        return nil
    }

    private static func gridPoint(x: Int, y: Int) -> PlanPoint {
        PlanPoint(
            x: (Double(x) + 0.5) / Double(gridWidth),
            y: (Double(y) + 0.5) / Double(gridHeight)
        )
    }

    private static func edgeResistance(from: PlanPoint, to: PlanPoint) -> Double {
        if ApartmentFloorPlan.doors.contains(where: { crosses(from: from, to: to, segment: $0) }) {
            return doorResistance
        }
        if ApartmentFloorPlan.walls.contains(where: { crosses(from: from, to: to, segment: $0) }) {
            return wallResistance
        }
        return 1
    }

    private static func crosses(from: PlanPoint, to: PlanPoint, segment: PlanSegment) -> Bool {
        let edgeIsVertical = abs(from.x - to.x) < 0.000_001
        let segmentIsVertical = abs(segment.start.x - segment.end.x) < 0.000_001
        guard edgeIsVertical != segmentIsVertical else { return false }
        if edgeIsVertical {
            let y = segment.start.y
            return y >= min(from.y, to.y) && y <= max(from.y, to.y)
                && from.x >= min(segment.start.x, segment.end.x)
                && from.x <= max(segment.start.x, segment.end.x)
        }
        let x = segment.start.x
        return x >= min(from.x, to.x) && x <= max(from.x, to.x)
            && from.y >= min(segment.start.y, segment.end.y)
            && from.y <= max(segment.start.y, segment.end.y)
    }
}
