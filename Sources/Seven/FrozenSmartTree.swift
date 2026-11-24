import Foundation

/// 以可替换的系统边界读取树；测试使用内存节点。
protocol FrozenSmartTreeReading {
    associatedtype Node: Hashable
    func windows() -> [Node]
    func hit(at point: CGPoint) -> Node?
    func role(_ node: Node) -> String?
    func frame(_ node: Node) -> CGRect?
    func children(_ node: Node) -> [Node]
    func parent(_ node: Node) -> Node?
}

struct FrozenSmartTree<Reader: FrozenSmartTreeReading> {
    let reader: Reader
    func query(at point: CGPoint, in target: CGRect,
                 withinBudget: () -> Bool = { true }) -> FrozenSmartSelectionResult {
        typealias Node = Reader.Node
        var snapshots: [Node: FrozenSmartRegion] = [:]
        var missing: Set<Node> = []
        var childrenCache: [Node: [Node]] = [:]
        func snapshot(_ node: Node) -> FrozenSmartRegion? {
            if let cached = snapshots[node] { return cached }
            if missing.contains(node) { return nil }
            guard withinBudget(), let role = reader.role(node), let frame = reader.frame(node) else { missing.insert(node); return nil }
            let region = FrozenSmartRegion(role: role, frame: frame)
            snapshots[node] = region
            return region
        }
        func children(_ node: Node) -> [Node] {
            if let cached = childrenCache[node] { return cached }
            guard withinBudget() else { return [] }
            let values = reader.children(node)
            childrenCache[node] = values
            return values
        }
        let windows = reader.windows()
        var matched=windows.first {node in
            guard let region=snapshot(node) else{return false}
            return FrozenSmartRegion.matchesWindow(region.frame,target)
        }
        // sheet/独立popover不一定出现在AXWindows顶层；仅匹配真实窗口表面，不能拿同框控件冒充原窗口。
        if matched == nil {
            var queue=windows.map{($0,0)},visited=Set<Node>(),index=0
            while index<queue.count,visited.count<64,withinBudget() {
                let (node,depth)=queue[index];index+=1
                guard visited.insert(node).inserted,depth<=8,let region=snapshot(node) else{continue}
                if FrozenSmartRegion.surfaces.contains(region.role),FrozenSmartRegion.matchesWindow(region.frame,target) {matched=node;break}
                if FrozenSmartRegion.surfaces.contains(region.role) || region.isContainer {
                    queue += children(node).prefix(64).map{($0,depth+1)}
                }
            }
        }
        guard let root=matched else { return FrozenSmartSelectionResult() }

        // 坐标命中可能落到同进程的截图覆盖层，只有确属原窗口才采用。
        var path: [Node] = []
        if let hit = reader.hit(at: point) {
            var node: Node? = hit
            var visited: Set<Node> = []
            while let current = node, visited.count < 64, withinBudget(), visited.insert(current).inserted {
                path.append(current)
                if current == root { break }
                node = reader.parent(current)
            }
            if path.last != root { path = [] }
        }
        if path.isEmpty { path = [root] }

        // 仅从角色和几何判断紧贴文字的内容容器，不读取文字、标题或输入值。
        // 同框包装继续穿透；不同段落间的大空白不能合成一整条消息。
        var textBlockCache:[Node:Bool]=[:]
        func textLeaves(_ node:Node,depth:Int=0,visited:Set<Node>=[])->[CGRect]? {
            guard depth<16,!visited.contains(node),withinBudget(),let region=snapshot(node),region.hasValidFrame else{return nil}
            if region.role == "AXStaticText" {return [region.frame]}
            guard region.role == "AXGroup" || FrozenSmartRegion.textBlocks.contains(region.role) else{return nil}
            var seen=visited;seen.insert(node)
            let items=children(node)
            guard !items.isEmpty else{return nil}
            var leaves:[CGRect]=[]
            for child in items {
                guard let values=textLeaves(child,depth:depth+1,visited:seen),leaves.count+values.count<=64 else{return nil}
                leaves += values
            }
            return leaves
        }
        func isTextBlock(_ node:Node)->Bool {
            if let cached=textBlockCache[node] {return cached}
            guard let region=snapshot(node),region.role == "AXGroup" else{return false}
            textBlockCache[node]=false
            let items=children(node)
            // 有不同边界的子内容块时保留其层级，不把整张消息/会话抬高成一个段落。
            guard items.contains(where:{child in
                guard let value=snapshot(child) else{return false}
                if value.role == "AXStaticText" {return true}
                guard let leaves=textLeaves(child) else{return false}
                return value.frame == leaves.reduce(CGRect.null){$0.union($1)}
            }),
                  let leaves=textLeaves(node),!leaves.isEmpty else{return false}
            let content=leaves.reduce(CGRect.null){$0.union($1)}
            let lineHeight=leaves.map(\.height).min() ?? 0
            guard lineHeight>0,region.frame.contains(content),region.frame != content else{return false}
            let insets=[content.minX-region.frame.minX,region.frame.maxX-content.maxX,
                        content.minY-region.frame.minY,region.frame.maxY-content.maxY]
            guard insets.allSatisfy({$0<=lineHeight}) else{return false}
            let lines=leaves.sorted{$0.minY<$1.minY}
            var previous=lines[0]
            for line in lines.dropFirst() {
                if line.minY-previous.maxY>min(line.height,previous.height) {return false}
                previous=previous.union(line)
            }
            textBlockCache[node]=true;return true
        }
        func regions(_ path: [Node]) -> [FrozenSmartRegion] {
            path.compactMap { node in
                guard var region = snapshot(node) else { return nil }
                region.isTextBlock = isTextBlock(node)
                return region
            }
        }
        func result(_ path: [Node], _ ancestry: [FrozenSmartRegion]) -> FrozenSmartSelectionResult {
            var siblings: [FrozenSmartRegion] = []
            // 从已确认目标向上找同级控件，收集可见行边界；不保存 AX 对象。
            for index in path.indices.dropFirst() {
                guard withinBudget() else { break }
                let parent = path[index]
                var terminals: [FrozenSmartRegion] = []
                var distinctFrames: [CGRect] = []
                for child in children(parent) {
                    guard withinBudget(), let region = regions([child]).first,
                          FrozenSmartRegion.selectable.contains(region.role), !region.isContainer else { continue }
                    let branch = [region] + regions(Array(path[index...]))
                    let targets=FrozenSmartRegion.candidates(at:nil,in:target,ancestry:branch).filter{!$0.isContainer}
                    for target in targets where !distinctFrames.contains(where:{$0.intersects(target.frame)}) {distinctFrames.append(target.frame)}
                    terminals += targets
                }
                for region in terminals where !siblings.contains(region) { siblings.append(region) }
                if distinctFrames.count >= 2 { break }
            }
            return FrozenSmartSelectionResult(ancestry: ancestry, siblings: siblings)
        }
        var best = regions(path)
        var bestNodes = path
        var bestElement = FrozenSmartRegion.preferred(FrozenSmartRegion.candidates(at: point, in: target, ancestry: best))
        if let bestElement, bestElement.priority <= 1 { return result(path, best) }

        // 从命中的容器继续向下找；叶控件直接停止，避免把按钮的图标拆出来。
        // 不理想的命中分支可能是空包装节点；同时保留原窗口的补查入口。
        var stack: [[Node]] = path == [root] ? [path] : [[root], path]
        var explored: Set<Node> = []
        while let currentPath = stack.popLast(), explored.count < 256, withinBudget() {
            guard currentPath.count <= 64, let node = currentPath.first, explored.insert(node).inserted else { continue }
            let branch = regions(currentPath)
            let element = FrozenSmartRegion.preferred(FrozenSmartRegion.candidates(at: point, in: target, ancestry: branch))
            if let element {
                let isBetter = bestElement.map {
                    element.precedes($0)
                } ?? true
                if isBetter {
                    best = branch; bestNodes = currentPath; bestElement = element
                }
                if element.priority <= 1 { break }
            }
            let next = children(node).filter { child in
                guard let region = snapshot(child) else { return true }
                if region.role == "AXScrollArea" || FrozenSmartRegion.surfaces.contains(region.role) || !region.isContainer {
                    return region.frame.contains(point)
                }
                // 分组常用内容边界，容许其子输入框的原生边框略微溢出。
                let margin = FrozenSmartRegion.windowMatchTolerance
                return region.frame.insetBy(dx: -margin, dy: -margin).contains(point)
            }.sorted { (snapshot($0)?.area ?? .infinity) > (snapshot($1)?.area ?? .infinity) }
            for child in next { stack.append([child] + currentPath) }
        }
        return result(bestNodes, best)
    }
}
