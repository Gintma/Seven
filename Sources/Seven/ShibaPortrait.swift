import AppKit
import SceneKit

/// 模型使用原图的面纹。头、眼球和角膜反光分别在各自的坐标系中运动。
@MainActor
final class ShibaPortrait {
    private let head = SCNNode()
    private let nodPivot = SCNNode()
    private var lids: [SCNNode] = []
    private var irises: [SCNNode] = []
    private var catchlights: [SCNNode] = []

    func makeView() -> SCNView? {
        let bundle = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main : Bundle.module
        guard let url = bundle.url(forResource: "Shiba", withExtension: "usdz"),
              let model = try? SCNScene(url: url),
              let skull = model.rootNode.childNode(withName: "skull", recursively: true) else { return nil }

        let scene = SCNScene()
        head.name = "head"
        head.addChildNode(skull)
        nodPivot.name = "nodPivot"
        nodPivot.addChildNode(head)
        scene.rootNode.addChildNode(nodPivot)
        skull.geometry?.firstMaterial?.lightingModel = .lambert
        func light(_ type: SCNLight.LightType, intensity: CGFloat, position: SCNVector3) {
            let node = SCNNode()
            let lamp = SCNLight()
            lamp.type = type
            lamp.intensity = intensity
            node.light = lamp
            node.position = position
            if type == .directional { node.look(at: SCNVector3Zero) }
            scene.rootNode.addChildNode(node)
        }
        light(.ambient, intensity: 855, position: SCNVector3Zero)
        light(.directional, intensity: 220, position: SCNVector3(-220, 280, 480))
        for x in [-49.0, 50.0] { addEye(at: SCNVector3(x, 8, 68)) }

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 151
        camera.camera?.zFar = 1200
        camera.position = SCNVector3(0, 4, 580)
        scene.rootNode.addChildNode(camera)

        let view = SCNView(frame: .zero)
        view.backgroundColor = ThemePalette.clear
        view.antialiasingMode = .multisampling4X
        view.scene = scene
        view.pointOfView = camera
        view.setAccessibilityElement(false)
        look(toward: .zero, animated: false)
        return view
    }

    private func addEye(at position: SCNVector3) {
        let globe = SCNSphere(radius: 1)
        globe.segmentCount = 48
        globe.firstMaterial = material(0xF7DFBE)
        let socket = SCNNode(geometry: globe)
        socket.name = "socket"
        socket.position = position
        socket.scale = SCNVector3(17.5, 16, 12.5)
        head.addChildNode(socket)

        let iris = cap(angle: 1.41, radius: 1.009, color: 0x573018)
        iris.name = "iris"
        iris.addChildNode(cap(angle: 0.72, radius: 1.017, color: 0x2D170E))
        socket.addChildNode(iris)
        irises.append(iris)

        let reflection = cap(angle: 0.29, radius: 1.034, color: 0xFFFDF5)
        reflection.name = "catchlight"
        socket.addChildNode(reflection)
        catchlights.append(reflection)

        // 单独的上眼皮贴在角膜外侧，沿眼球曲面向下扫过虹膜和反光。
        let lid = cap(angle: .pi / 2, radius: 1.055, color: 0xF4A23E)
        lid.addChildNode(lidCrease())
        lid.name = "upperLid"
        lid.isHidden = true
        socket.addChildNode(lid)
        lids.append(lid)
    }

    /// 闭眼时，沿上眼皮球面的一条细弧线勾出眼睑，双端逐渐收细。
    private func lidCrease() -> SCNNode {
        var points: [SCNVector3] = []
        var indices: [UInt16] = []
        for i in 0...24 {
            let t = Double(i) / 24
            let x = (2 * t - 1) * 0.82
            let arc = sin(.pi * t)
            let y = -0.08 - 0.23 * arc
            for edge in [-1.0, 1.0] {
                let v = y + edge * 0.052 * arc
                points.append(SCNVector3(x, v, sqrt(1.061 * 1.061 - x * x - v * v)))
            }
            if i > 0 {
                let j = UInt16(i * 2)
                indices.append(contentsOf: [j-2, j, j-1, j-1, j, j+1])
            }
        }
        let mesh = SCNGeometry(sources: [SCNGeometrySource(vertices: points)],
                               elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        mesh.firstMaterial = material(0x93552B)
        return SCNNode(geometry: mesh)
    }

    func tilt(_ side: CGFloat) {
        let lean = SCNAction.rotateTo(x: 0, y: 0, z: side * 0.105, duration: 0.36)
        let upright = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.48)
        lean.timingMode = .easeInEaseOut
        upright.timingMode = .easeInEaseOut
        nodPivot.runAction(.sequence([lean, .wait(duration: 0.28), upright]), forKey: "idleTilt")
    }

    func stopIdleTilt() {
        guard nodPivot.action(forKey: "idleTilt") != nil else { return }
        nodPivot.removeAction(forKey: "idleTilt")
        nodPivot.runAction(.rotateTo(x: 0, y: 0, z: 0, duration: 0.18), forKey: "settle")
    }

    func blink() {
        for lid in lids {
            lid.eulerAngles.x = -.pi
            lid.isHidden = false
            lid.runAction(.sequence([
                pitch(to: -0.025, duration: 0.10), .wait(duration: 0.045),
                pitch(to: -.pi, duration: 0.16), .hide()
            ]), forKey: "blink")
        }
    }

    func nod() {
        nodPivot.runAction(.sequence([
            .wait(duration: 0.17), pitch(to: -0.07, duration: 0.12),
            pitch(to: 0.17, duration: 0.19), pitch(to: 0, duration: 0.24)
        ]), forKey: "nod")
    }

    private func pitch(to angle: CGFloat, duration: TimeInterval) -> SCNAction {
        let action = SCNAction.rotateTo(x: angle, y: 0, z: 0, duration: duration)
        action.timingMode = .easeInEaseOut
        return action
    }

    func cancelExpression() {
        nodPivot.removeAllActions()
        nodPivot.eulerAngles = SCNVector3Zero
        for lid in lids {
            lid.removeAction(forKey: "blink")
            lid.isHidden = true
        }
    }

    private func material(_ rgb: UInt32) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = ThemeColor(rgb: rgb).nsColor
        return material
    }

    /// 球冠贴合眼球曲率；转到边缘时虹膜自然变窄，露出另一侧眼白。
    private func cap(angle: Double, radius: Double, color: UInt32) -> SCNNode {
        var vertices: [SCNVector3] = []
        var indices: [UInt16] = []
        let rings = 10
        let slices = 40
        for i in 0...rings {
            let latitude = angle * Double(i) / Double(rings)
            for j in 0..<slices {
                let longitude = 2 * Double.pi * Double(j) / Double(slices)
                vertices.append(SCNVector3(radius * sin(latitude) * cos(longitude),
                                           radius * sin(latitude) * sin(longitude),
                                           radius * cos(latitude)))
                guard i < rings else { continue }
                let a = UInt16(i * slices + j)
                let b = UInt16(i * slices + (j + 1) % slices)
                let step = UInt16(slices)
                indices.append(contentsOf: [a, a + step, b + step, a, b + step, b])
            }
        }
        let mesh = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)],
                               elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        mesh.firstMaterial = material(color)
        return SCNNode(geometry: mesh)
    }

    func look(toward direction: CGPoint, animated: Bool) {
        let yaw = Double(direction.x) * 0.24
        let pitch = -Double(direction.y) * 0.14
        turn(head, pitch: pitch, yaw: yaw, duration: animated ? Design.Onboarding.headResponse : 0)
        for iris in irises {
            turn(iris, pitch: -Double(direction.y) * 0.16, yaw: Double(direction.x) * 0.20,
                 duration: animated ? Design.Onboarding.eyeResponse : 0)
        }
        // 固定左上光源，反光相对瞳孔滑过，并在头转动时沿角膜弧面偏移。
        for reflection in catchlights {
            turn(reflection, pitch: -0.39 - pitch * 0.75, yaw: -0.26 - yaw * 0.75,
                 duration: animated ? Design.Onboarding.headResponse : 0)
        }
    }

    private func turn(_ node: SCNNode, pitch: Double, yaw: Double, duration: TimeInterval) {
        let target = SCNVector3(pitch, yaw, 0)
        if duration == 0 { node.removeAllAnimations() }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = duration
        SCNTransaction.disableActions = duration == 0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
        node.eulerAngles = target
        SCNTransaction.commit()
    }
}
