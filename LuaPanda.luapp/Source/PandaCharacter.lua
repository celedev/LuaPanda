-- The main character of this game

-----------------------------------------------------------------------
-- Shortcuts and imported modules
-----------------------------------------------------------------------
local SCNScene = objc.SCNScene
local SCNNode = objc.SCNNode
local SCNPhysicsWorld = objc.SCNPhysicsWorld
local SCNPhysicsBody = objc.SCNPhysicsBody
local SCNPhysicsShape = objc.SCNPhysicsShape
local SCNAction = objc.SCNAction
local SCNAudioPLayer = objc.SCNAudioPlayer
local SCNAudioSource = objc.SCNAudioSource

local SCNTransaction = objc.SCNTransaction

local SCNVector3 = struct.SCNVector3
local SCNVector4 = struct.SCNVector4

local ScnPhysicsWorld= require "SceneKit.SCNPhysicsWorld"
local SCNPhysicsTestCollisionBitMaskKey = ScnPhysicsWorld.SCNPhysicsTestCollisionBitMaskKey
local SCNPhysicsTestSearchModeKey = ScnPhysicsWorld.SCNPhysicsTestSearchModeKey
local SCNPhysicsTestSearchModeClosest = ScnPhysicsWorld.SCNPhysicsTestSearchModeClosest

local random = math.random

local CollisionsController = objc.GameViewController

local walkSpeedFactor = 1.2

-----------------------------------------------------------------------
-- Class creation
-----------------------------------------------------------------------
local PandaCharacter = class.createClass ('PandaCharacter')

-----------------------------------------------------------------------
-- Setup methods
-----------------------------------------------------------------------

function PandaCharacter:init()
    
    self.soundAssetsUrl = objc.NSBundle.mainBundle.resourceURL:URLByAppendingPathComponent "sounds"
    
    self.node = SCNNode:new()
    
    self:getResource ("GameScnAssets.panda", "scn", "updateCharacterFromScene")
    
    self:setupFootStepSounds (self.soundAssetsUrl)
    
    self:addMessageHandler(self.class, "handleCodeUpdate")
end

function PandaCharacter:updateCharacterFromScene (scene --[[@type objc.SCNScene]], sceneUrl --[[@type objc.NSURL]])
    
    if ((scene == nil) or not scene:isKindOfClass(SCNScene)) and (sceneUrl ~= nil) then
        -- no provided 'scene' parameter: unarchive the scene from the provided URL
        if sceneUrl ~= nil then
            scene = SCNScene:sceneWithURL_options_error (sceneUrl, nil)
        end
    end
    
    if scene:isKindOfClass(SCNScene) then
        
        local characterStateData = nil
        
        local pandaNode = scene.rootNode:childNodeWithName_recursively("panda", false)
       
        local oldPandaNode = self.node:childNodeWithName_recursively("panda", false)
        if oldPandaNode then
            -- Save character state data and remove the old panda node
            characterStateData = self:characterStateData()
            oldPandaNode:removeFromParentNode()
        end
        self.node:addChildNode(pandaNode)
        
        -- Remove the old colision volume if any
        local oldCollisionNode = self.node:childNodeWithName_recursively("collider", false)
        if oldCollisionNode then
            oldCollisionNode:removeFromParentNode()
        end
        
        -- Configure a colision volume (a capsule)
        local _, boxMin, boxMax = pandaNode:getBoundingBoxMin_max()
        local collisionCapsuleRadius = (boxMax.x - boxMin.x) * 0.4
        local collisionCapsuleHeight = boxMax.y - boxMin.y
        local collisionNode = SCNNode:new()
        collisionNode.name = "collider"
        collisionNode.position = SCNVector3(0.0, collisionCapsuleHeight * 0.51, 0.0) -- keep the capsule slightly above the floor
        collisionNode.physicsBody = SCNPhysicsBody:kinematicBody()
        collisionNode.physicsBody.physicsShape = SCNPhysicsShape:shapeWithGeometry_options(objc.SCNCapsule:capsuleWithCapRadius_height(collisionCapsuleRadius, collisionCapsuleHeight))
        self.node:addChildNode(collisionNode)
        
        CollisionsController:setCollisionMaskForCharacterNode (self.node)
        
        -- Configure animations
        do
            -- Some animations are already there and can be retrieved from the scene
            pandaNode:enumerateChildNodesUsingBlock (function(childNode)
                                                         for key in childNode.animationKeys do
                                                             local animation --[[@type objc.CAAnimation]] = childNode:animationForKey(key):copy()
                                                             animation.usesSceneTimeBase = false -- make it system-time-based
                                                             animation.repeatCount = math.huge -- repeat forever
                                                             childNode:addAnimation_forKey(animation, key) -- replace by the modified animation
                                                         end
                                                     end)
            
            -- if self.walkAnimation == nil then
            do
                -- The "walk" animation is loaded from a file, it is configured to play foot steps at specific times during the animation
                self:loadAnimationInSceneAtPath_withName_usingFunction
                                      ("GameScnAssets.walk", "panda_walk",
                                       function (walkAnimation)
                                           walkAnimation.usesSceneTimeBase = false
                                           walkAnimation.fadeInDuration = 0.3
                                           walkAnimation.fadeOutDuration = 0.3
                                           walkAnimation.repeatCount = math.huge -- repeat forever
                                           walkAnimation.animationEvents = { objc.SCNAnimationEvent:animationEventWithKeyTime_block (0.1, function() self:playFootStep() end),
                                                                             objc.SCNAnimationEvent:animationEventWithKeyTime_block (0.6, function() self:playFootStep() end)
                                                                           }
                                           self.walkAnimation = walkAnimation
                                       end)
                
                -- compute a character base speed from the walk animation and the character bounding box:
                -- the walk animation duration corresponds to two steps and the step length is the bounding box width
                self.baseWalkSpeed = (boxMax.x - boxMin.x) * 0.7 / self.walkAnimation.duration * 2 * walkSpeedFactor
                
                -- start the walk animation if needed
                self:refreshWalkingAnimation()
            end
        end
        
        -- Configure the fire particle emiters and sounds
        do
            -- Particle systems were configured in the SceneKit Scene Editor
            -- They are retrieved from the scene and their birth rate are stored for later use
            
            local function particleEmiterInfoWithName (name)
                local emiterNode = pandaNode:childNodeWithName_recursively (name, true)
                if emiterNode then
                    local particleSystem --[[@type objc.SCNParticleSystem]]  = emiterNode.particleSystems.firstObject
                    if particleSystem then
                        local emiterBirthRate = particleSystem.birthRate
                        particleSystem.birthRate = 0
                        
                        return { particleSystem = particleSystem, birthRate = emiterBirthRate }
                    end
                end
            end
            
            self.fireEmiter = particleEmiterInfoWithName("fire")
            self.graySmokeEmiter = particleEmiterInfoWithName("smoke")
            self.whiteSmokeEmiter = particleEmiterInfoWithName("whiteSmoke")
            
            -- tail-fire-related sounds
            self.reliefSound = SCNAudioSource:newWithURL(self.soundAssetsUrl:URLByAppendingPathComponent('aah_extinction.mp3'))
            self.haltFireSound = SCNAudioSource:newWithURL(self.soundAssetsUrl:URLByAppendingPathComponent('fire_extinction.mp3'))
            self.catchFireSound = SCNAudioSource:newWithURL(self.soundAssetsUrl:URLByAppendingPathComponent('ouch_firehit.mp3'))
            self.reliefSound.volume = 2.0
            self.haltFireSound.volume = 2.0
            self.catchFireSound.volume = 2.0
        end
    end
    
    -- apply character state
    if self.isBurning then
        self.fireEmiter.particleSystem.birthRate = self.fireEmiter.birthRate
        self.graySmokeEmiter.particleSystem.birthRate = self.graySmokeEmiter.birthRate
    end
end


function PandaCharacter:loadAnimationInSceneAtPath_withName_usingFunction(animationScenePath, animationKey, loadAnimationFunction)
    
    self:getResource (animationScenePath, 'scn', 
                      function (self, sceneData, sceneUrl)
                          
                          local animationScene = SCNScene:sceneWithURL_options_error (sceneUrl, nil)
                          
                          if animationScene ~= nil then
                              local loadedAnimation
                              animationScene.rootNode:enumerateChildNodesUsingBlock (function(childNode)
                                                                                         local childAnimationKeys = childNode.animationKeys
                                                                                         loadedAnimation = childNode:animationForKey(animationKey)
                                                                                         if loadedAnimation then
                                                                                             return true -- stop enumeration
                                                                                         end
                                                                                     end)
                              if loadedAnimation then
                                  loadAnimationFunction (loadedAnimation)
                              end
                          end
                      end)
end

function PandaCharacter:characterStateData()
    
end

-----------------------------------------------------------------------
-- Character walk methods
-----------------------------------------------------------------------
local maxCharacterClimb = 0.1
local maxCharacterFall = 10.0
local minCharacterFall = 0.001
local fallAcceleration = 0.18

function PandaCharacter:walkInScene_withDirection_atTime (scene --[[@type objc.SCNScene]], direction --[[@type struct.SCNVector3]], time)
    
    if self.previousUpdateTime == nil then
        self.previousUpdateTime = time
    end
    
    self.groundType = nil
    
    local currentGroundNode
    local walkDistance = 0.0
    
    local deltaTime = (time - self.previousUpdateTime)
    
    if (direction.x ~= 0.0) and (direction.z ~= 0.0) then
        walkDistance = deltaTime * self.baseWalkSpeed * self.walkSpeedup
        self.directionAngle = math.atan2(direction.x, direction.z)
     end
    
    if walkDistance > 0 then
        -- move the character
        local oldPosition = self.node.position
        local newPosition = SCNVector3(oldPosition.x + walkDistance * direction.x,
                                        oldPosition.y, -- Move only in the horizontal (x, z) plan
                                        oldPosition.z + walkDistance * direction.z)
        
        -- Compute the vertical position by doing a verical "ray test' with the scene
        local maxVerticalPosition = SCNVector3(newPosition.x, newPosition.y + maxCharacterClimb, newPosition.z)
        local minVerticalPosition = SCNVector3(newPosition.x, newPosition.y - maxCharacterFall, newPosition.z)
        
        local bodyKind = CollisionsController.physicsBodyCategories
        
        local hitTestResult --[[@type objc.SCNHitTestResult]] 
        hitTestResult = scene.physicsWorld:rayTestWithSegmentFromPoint_toPoint_options (maxVerticalPosition, minVerticalPosition,
                                                                                        { [SCNPhysicsTestCollisionBitMaskKey] = bodyKind.Collision +
                                                                                                                                bodyKind.Water,
                                                                                          [SCNPhysicsTestSearchModeKey] = SCNPhysicsTestSearchModeClosest }) .firstObject
        if hitTestResult and (hitTestResult.node.name == 'water') then
            -- Do special things when on water
            if self.isBurning then
                self:haltFire()
            end
            
            -- The ground type is the name of the node first material
            local groundMaterial = hitTestResult.node.geometry.firstMaterial
            self.groundType = groundMaterial and groundMaterial.name
            
            -- Find the collision below the water
            hitTestResult = scene.physicsWorld:rayTestWithSegmentFromPoint_toPoint_options (maxVerticalPosition, minVerticalPosition,
                                                                                            { [SCNPhysicsTestCollisionBitMaskKey] = bodyKind.Collision,
                                                                                              [SCNPhysicsTestSearchModeKey] = SCNPhysicsTestSearchModeClosest }) .firstObject

        end
        
        if hitTestResult then
            currentGroundNode = hitTestResult.node
            local groundAltitude = hitTestResult.worldCoordinates.y
            
            -- Set the current ground type (for steps sound)
            if (self.groundType == nil) and (newPosition.y < groundAltitude + 0.2) then
                -- The character is not on the ground
                -- The ground type is the name of the node first material
                local groundMaterial = currentGroundNode.geometry.firstMaterial
                self.groundType = groundMaterial and groundMaterial.name
            end
            
            -- if the character falls, simulate an acceleration
            if groundAltitude < newPosition.y - minCharacterFall then
                self.fallDistance = (self.fallDistance or 0.0) + deltaTime * fallAcceleration -- approximating of the gravity
                newPosition.y = newPosition.y - self.fallDistance
            else
                self.fallDistance = 0.0
            end
            
            if groundAltitude > newPosition.y then
                newPosition.y = groundAltitude
            end
            
            -- Update the character position
            self.node.position = newPosition
            self.isWalking = true
        else
            self.isWalking = false
        end
        
    else
        self.isWalking = false
    end
    
    self.previousUpdateTime = time
    
    return currentGroundNode
end

PandaCharacter.directionAngle = property { default = 0.0,
                                           set = function (self, directionAngle)
                                                     if directionAngle ~= self._directionAngle then
                                                         self._directionAngle = directionAngle
                                                         self.node:runAction (SCNAction:rotateToX_y_z_duration_shortestUnitArc(0.0, directionAngle, 0.0, 0.1, true))
                                                     end
                                                 end
                                         }

PandaCharacter.isWalking = property { default = false,
                                      set = function (self, isWalking)
                                                if isWalking ~= self._isWalking then
                                                    self._isWalking = isWalking
                                                    if isWalking then
                                                        self:startWalkAnimation()
                                                    else
                                                        self.node:removeAnimationForKey_fadeOutDuration ("walk", 0.2)
                                                    end
                                                end 
                                            end 
                                    }

PandaCharacter.walkSpeedup = property { default = 1.0,
                                      set = function (self, walkSpeedup)
                                                if walkSpeedup ~= self._walkSpeedup then
                                                    self._walkSpeedup = walkSpeedup
                                                    if self.isWalking then
                                                        self:startWalkAnimation() -- update the walk animation
                                                    end
                                                end
                                            end
                                    }

function PandaCharacter:startWalkAnimation ()
    self.walkAnimation.speed = self.walkSpeedup *  walkSpeedFactor
    self.node:addAnimation_forKey (self.walkAnimation, "walk")
end

function PandaCharacter:refreshWalkingAnimation ()
    if self._isWalking then
        self:startWalkAnimation()
    else
        self.node:removeAnimationForKey_fadeOutDuration ("walk", 0.2)
    end 
end

function PandaCharacter:setupFootStepSounds(stepSoundsDirUrl)
    
    -- Find sound files named like "Step_groundtype_...mp3" and create an audio source for each of them
    local stepAudioSources = {}
    local filesInDirectory = objc.NSFileManager.defaultManager:contentsOfDirectoryAtPath_error(stepSoundsDirUrl.path)
    
    for filename --[[@type objc.NSString]] in filesInDirectory do
        
        if filename:hasPrefix("Step_") and (filename.pathExtension == 'mp3' )then
            -- This is a step sound
            local _, _, groundType = filename:find ("Step_(%w+)_")
            if groundType then
                local groundTypeAudioSources = stepAudioSources [groundType]
                -- Create an array for the ground type if needed
                if groundTypeAudioSources == nil then
                    groundTypeAudioSources = objc.NSMutableArray:new()
                    stepAudioSources [groundType] = groundTypeAudioSources
                end
                local stepAudoSource = SCNAudioSource:newWithURL(stepSoundsDirUrl:URLByAppendingPathComponent(filename))
                stepAudoSource:load()
                groundTypeAudioSources:addObject (stepAudoSource)
            end
        end
    end
    
    self.stepAudioSources = stepAudioSources
end

function PandaCharacter:playFootStep()
    if self.groundType then
        -- Play a random step sound
        local groundAudioSources = self.stepAudioSources [self.groundType]
        if groundAudioSources and (#groundAudioSources > 0) then
            local selectedAudioSource = groundAudioSources[random(#groundAudioSources)]
            self.node:runAction (SCNAction:playAudioSource_waitForCompletion (selectedAudioSource, false))
        end
    end
end

-----------------------------------------------------------------------
-- Dealing with fire
-----------------------------------------------------------------------

function PandaCharacter:catchFire ()
    if not self.isBurning then
        self.isBurning = true
        
        -- run catch fire actions
        self.node:runAction (SCNAction:sequence { SCNAction:playAudioSource_waitForCompletion(self.catchFireSound, false),
                                                  SCNAction:repeatAction_count (SCNAction:sequence { SCNAction:fadeOpacityTo_duration(0.1, 0.1),
                                                                                                     SCNAction:fadeOpacityTo_duration(1.0, 0.1) },
                                                                                7),
                                                  })
        
        -- Start fire + smoke emiters
        self.fireEmiter.particleSystem.birthRate = self.fireEmiter.birthRate
        self.graySmokeEmiter.particleSystem.birthRate = self.graySmokeEmiter.birthRate
        
        -- walk faster
        self.walkSpeedup = 2.3
    end
end

function PandaCharacter:haltFire ()
    if self.isBurning then
        self.isBurning = false
        
        self.node:runAction (SCNAction:sequence { SCNAction:playAudioSource_waitForCompletion(self.haltFireSound, true),
                                                  SCNAction:playAudioSource_waitForCompletion(self.reliefSound, false) })
        
        -- stop fire
        self.fireEmiter.particleSystem.birthRate = 0
        
        -- stop smoke progressively
        SCNTransaction:begin()
        SCNTransaction:setAnimationDuration(1.0)
        self.graySmokeEmiter.particleSystem.birthRate = 0
        SCNTransaction:commit()
        
        -- emit a white smoke
         self.whiteSmokeEmiter.particleSystem.birthRate = self.whiteSmokeEmiter.birthRate
        
        -- stop the white smoke progressively
        SCNTransaction:begin()
        SCNTransaction:setAnimationDuration(5.0)
        self.whiteSmokeEmiter.particleSystem.birthRate = 0
        SCNTransaction:commit()
        
        -- walk at normal speed
        self.walkSpeedup = 1.0
    end
end
-----------------------------------------------------------------------
-- Handle code updates for this module
-----------------------------------------------------------------------

function PandaCharacter:handleCodeUpdate()
    self:getResource ("GameScnAssets.panda", "scn", "updateCharacterFromScene")
    -- self.walkSpeedup = 1.0
end

-----------------------------------------------------------------------
-- return the class defined by this module
-----------------------------------------------------------------------
return PandaCharacter