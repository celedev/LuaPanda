//
//  SceneKitExtensions.swift
//  LuaPanda
//

import SceneKit
import SpriteKit

// MARK: SceneKit

extension SCNNode {
    func normalizedDirectionInWorldXZPlane(_ relativeDirection: SCNVector3) -> SCNVector3 {
        let p1 = self.presentation.convertPosition(relativeDirection, to: nil)
        let p0 = self.presentation.convertPosition(SCNVector3Zero, to: nil)
        var direction = float3(Float(p1.x - p0.x), 0.0, Float(p1.z - p0.z))
        
        if direction.x != 0.0 || direction.z != 0.0 {
            direction = normalize(direction)
        }
        return SCNVector3(direction)
    }
}

// MARK: SpriteKit

extension SKSpriteNode {
    convenience init(imageNamed name: String, position: CGPoint, scale: CGFloat = 1.0) {
        self.init(imageNamed: name)
        self.position = position
        xScale = scale
        yScale = scale
    }
}

// MARK: Simd

extension float2 {
    init(_ v: CGPoint) {
        self.init(Float(v.x), Float(v.y))
    }
}
