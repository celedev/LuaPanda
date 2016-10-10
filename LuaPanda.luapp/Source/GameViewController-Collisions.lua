-----------------------------------------------------------------------
-- A GameViewControlller class extension that handles collisions (and treasures collection) in the scene
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- Declare shortcuts and import required modules
-----------------------------------------------------------------------
local ScnPhysicsShape= require "SceneKit.SCNPhysicsShape"

local SCNNode = objc.SCNNode
local SCNPhysicsBody = objc.SCNPhysicsBody
local SCNPhysicsShape = objc.SCNPhysicsShape
local SCNAction = objc.SCNAction
local SCNVector3 = struct.SCNVector3


-----------------------------------------------------------------------
-- Define a class extension
-----------------------------------------------------------------------
local GameViewController = class.extendClass (objc.GameViewController, "Collisions")

-----------------------------------------------------------------------
-- Configure collisions in the scene's Physics World
-----------------------------------------------------------------------

-- Note: physics body category bits 0 and 1 are defined by the system
local physicsBodyCategory = { Collision   =  4, -- 1 << 2
                              Collectable =  8, -- 1 << 3
                              Treasure    = 16, -- 1 << 4
                              Enemy       = 32, -- 1 << 5
                              Water       = 64 -- 1 << 6
                            }


GameViewController.physicsBodyCategories = physicsBodyCategory -- store the enum as a class field, so it can be accessed from other modules

function GameViewController:setupSceneCollisionNodes (scene--[[@type objc.SCNScene]], gameStateData)
    
    -- Retrieve various contact nodes in one traversal
    local collisionNodes = {}
    local flameNodes = {}
    local enemyNodes = {}
    
    scene.rootNode:enumerateChildNodesUsingBlock (function (node)
                                                      local nodeName = node.name
                                                      if nodeName then
                                                          if nodeName == 'flame' then
                                                              node.physicsBody.categoryBitMask = physicsBodyCategory.Enemy
                                                              table.insert (flameNodes, node)
                                                          elseif nodeName == 'enemy' then
                                                              table.insert (enemyNodes, node)
                                                          elseif nodeName:find('collision') then
                                                              table.insert (collisionNodes, node)
                                                          end
                                                      end
                                                  end)
    
    self.flameNodes = flameNodes
    self.enemyNodes = enemyNodes
    
    for _, node in ipairs(collisionNodes) do
        self:setupCollisionNode (node)
    end
    
    -- update the scene to restore already-collected items
    self:restoreCollectedItems (scene)
    
    -- set self as the scene's SCNPhysicsContactDelegate
    scene.physicsWorld.contactDelegate = self
end

function GameViewController:setupCollisionNode (node)
    
    local nodeGeometry = node.geometry
    
    if nodeGeometry then
        -- Add a concave static physics-body to the node
        local physicsBody = SCNPhysicsBody:staticBody()
        physicsBody.physicsShape = SCNPhysicsShape:shapeWithNode_options(node, { [ScnPhysicsShape.TypeKey] = ScnPhysicsShape.TypeConcavePolyhedron })
        
        if node.name == 'water' then
            physicsBody.categoryBitMask = physicsBodyCategory.Water -- specific categoryBitMask for water
        else
            physicsBody.categoryBitMask = physicsBodyCategory.Collision
        end
        
        node.physicsBody = physicsBody
    end
    
    --[[ -- "Temporary workaround because concave shape created from geometry instead of node fails" ??
    do
        local geometryChildNode = SCNNode:new()
        node:addChildNode(geometryChildNode)
        geometryChildNode.hidden = true
        geometryChildNode.geometry = node.geometry
        node.geometry = nil
        node.hidden = false
    end]]
    
    -- Recurse to child nodes
    for childNode in node.childNodes do
        if not childNode.hidden then
            self:setupCollisionNode(childNode)
        end
    end
end

function GameViewController.class:setCollisionMaskForCharacterNode (characterNode --[[@type objc.SCNNode]] )
    
    -- Set the appropriate contact test mask in character's child nodes with a physics body 
    characterNode:enumerateChildNodesUsingBlock (function (childNode)
                                                     if childNode.physicsBody then
                                                         childNode.physicsBody.contactTestBitMask = physicsBodyCategory.Collision + 
                                                                                                    physicsBodyCategory.Collectable + 
                                                                                                    physicsBodyCategory.Treasure + 
                                                                                                    physicsBodyCategory.Enemy
                                                     end
                                                 end)
end

-----------------------------------------------------------------------
-- SCNPhysicsContactDelegate Protocol
-----------------------------------------------------------------------

GameViewController:publishObjcProtocols ('SCNPhysicsContactDelegate')

local function contactNodeWithCategory(contact--[[@type objc.SCNPhysicsContact]], category)
    local contactNodeWIthCategory, otherNode
    if contact.nodeA.physicsBody.categoryBitMask == category then
        contactNodeWIthCategory, otherNode = contact.nodeA, contact.nodeB
    elseif contact.nodeB.physicsBody.categoryBitMask == category then
        contactNodeWIthCategory, otherNode = contact.nodeB, contact.nodeA
    end
    return contactNodeWIthCategory, otherNode
end

function GameViewController:physicsWorld_didBeginContact (world --[[@type objc.SCNPhysicsWorld]], contact --[[@type objc.SCNPhysicsContact]])
    -- Colisions
    local collidedNode, colliderNode = contactNodeWithCategory(contact, physicsBodyCategory.Collision)
    if collidedNode and (colliderNode.parentNode == self.pandaCharacter.node) then
        self:character_didHitWall_withContact(colliderNode, collidedNode, contact)
    end
    
    -- Items collection
    local collidedNode, colliderNode = contactNodeWithCategory(contact, physicsBodyCategory.Collectable)
    if collidedNode and (colliderNode.parentNode == self.pandaCharacter.node) then
        self:collectPearl (collidedNode)
    end
    
    local collidedNode, colliderNode = contactNodeWithCategory(contact, physicsBodyCategory.Treasure)
    if collidedNode and (colliderNode.parentNode == self.pandaCharacter.node) then
        self:collectFlower(collidedNode)
    end
    
    -- Contact with enemy
    local collidedNode, colliderNode = contactNodeWithCategory(contact, physicsBodyCategory.Enemy)
    if collidedNode  and (colliderNode.parentNode == self.pandaCharacter.node) then
        self.pandaCharacter:catchFire()
    end
end

function GameViewController:physicsWorld_didUpdateContact (world --[[@type objc.SCNPhysicsWorld]], contact --[[@type objc.SCNPhysicsContact]])
    -- Colisions
    local collidedNode, coliderNode = contactNodeWithCategory(contact, physicsBodyCategory.Collision)
    if collidedNode then
        self:character_didHitWall_withContact(coliderNode, collidedNode, contact)
    end
end

-----------------------------------------------------------------------
-- Stopping at walls and borders
-----------------------------------------------------------------------

function GameViewController:character_didHitWall_withContact (contactNode, wallNode, contact --[[@type objc.SCNPhysicsContact]])
    local character = self.pandaCharacter
    
    if contactNode.parentNode == character.node then
        
        local contactPenetrationDistance = contact.penetrationDistance
        
        if contactPenetrationDistance > character.maxPenetrationDistance then
            character.maxPenetrationDistance = contactPenetrationDistance
            
            local characterPosition = character.node.position
            local contactNormal = contact.contactNormal
            character.replacementPosition = SCNVector3(characterPosition.x + contactNormal.x * contactPenetrationDistance,
                                                       characterPosition.y + contactNormal.y * contactPenetrationDistance,
                                                       characterPosition.z + contactNormal.z * contactPenetrationDistance)
        end
    end
end


-----------------------------------------------------------------------
-- Collecting items in the scene
-----------------------------------------------------------------------

function GameViewController:restoreCollectedItems (scene)
    -- Remove the contact nodes of already collected items
    if self.collectedItems then
        local sceneRootNode = scene.rootNode
        
        for collectedItemName in pairs(self.collectedItems) do
            local collectedItemNode = sceneRootNode:childNodeWithName_recursively (collectedItemName, true)
            if collectedItemNode ~= nil then
                -- print ("Removing collected node " .. collectedItemName)
                local itemContactNode = collectedItemNode:childNodesPassingTest (function (childNode)
                                                                                     local isContactNode = (childNode.physicsBody ~= nil)
                                                                                     if isContactNode then
                                                                                         return isContactNode, true -- stop enumeration after the first found matching node
                                                                                     else
                                                                                         return isContactNode
                                                                                     end
                                                                                 end)
                                        .firstObject
                if itemContactNode then
                    itemContactNode:removeFromParentNode()
                end
            end
        end
    end
end

function GameViewController:collectItem_withSound (itemContactNode, soundAudioSource)
    if itemContactNode.parentNode ~= nil then
        -- This item is not already collected
        local itemNode = itemContactNode.parentNode.parentNode -- collectable items are reference nodes, so the contact node's parent is a reference root, and its parent is the collectable item node in the scene
        if itemNode then
            -- mark the item as collected
            if self.collectedItems == nil then self.collectedItems = {} end
            self.collectedItems [itemNode.name] = true
        end
        
        if soundAudioSource then
            -- Emit a sound from the item contact node
            local soundEmitter = SCNNode:new()
            soundEmitter.position = itemContactNode.position
            itemContactNode.parentNode:addChildNode (soundEmitter)
            
            soundEmitter:runAction (SCNAction:sequence { SCNAction:playAudioSource_waitForCompletion(soundAudioSource, true),
                                                         SCNAction:removeFromParentNode() })
        end
        
        itemContactNode:removeFromParentNode()
    end
end

function GameViewController:collectPearl (pearlContactlNode)
    if pearlContactlNode.parentNode ~= nil then
        -- Collect the pearl graphically
        self:collectItem_withSound (pearlContactlNode, self.collectPearlSound)
        
        -- Increment collected pearls count and update the gameView property
        self.collectedPearlsCount = (self.collectedPearlsCount or 0) + 1
        self.gameView.collectedPearlsCount = self.collectedPearlsCount
    end
end

function GameViewController:collectFlower (flowerContactNode)
    if flowerContactNode.parentNode ~= nil then
        
        if self.collectFlowerParticleSystem then
            -- Emit the particules
            local flowerParticlesTransform = flowerContactNode.worldTransform
            flowerParticlesTransform.m42 = flowerParticlesTransform.m42 + 0.2
            self.gameView.scene:addParticleSystem_withTransform (self.collectFlowerParticleSystem, flowerParticlesTransform)
            
            -- Collect the flower graphically
            self:collectItem_withSound (flowerContactNode, self.collectFlowerSound)
            
            -- Increment collected flowers count and update the gameView property
            self.collectedFlowersCount = (self.collectedFlowersCount or 0) + 1
            if self.collectedFlowersCount <= 3 then
                self.gameView.collectedFlowersCount = self.collectedFlowersCount
            end
            
            --[[ -- Accelerate the character walk speed for a while
            local originalSpeedup = self.pandaCharacter.walkSpeedup
            self.pandaCharacter.walkSpeedup = originalSpeedup * 2
            self.pandaCharacter.node:runAction (SCNAction:sequence { SCNAction:waitForDuration (10),
                                                                     SCNAction:runBlock (function ()
                                                                                            self.pandaCharacter.walkSpeedup = originalSpeedup
                                                                                         end) })]]
        end
    end
end

-----------------------------------------------------------------------
-- Return the extended class
-----------------------------------------------------------------------

return GameViewController