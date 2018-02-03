-----------------------------------------------------------------------
-- Declare shortcuts and import required modules
-----------------------------------------------------------------------
local SCNScene = objc.SCNScene
local SCNNode = objc.SCNNode
local SCNAction = objc.SCNAction
local SCNAudioPLayer = objc.SCNAudioPlayer
local SCNAudioSource = objc.SCNAudioSource
local SCNTransaction = objc.SCNTransaction

local CGPoint = struct.CGPoint
local SCNVector3 = struct.SCNVector3
local SCNVector4 = struct.SCNVector4

local CaMediaTimingFunction = require "QuartzCore.CAMediaTimingFunction"
local CaMediaTiming = require "QuartzCore.CAMediaTiming"
local CACurrentMediaTime = require "QuartzCore.CABase".CurrentMediaTime

local ScnSceneSource = require "SceneKit.SCNSceneSource"

local pi = math.pi
local min = math.min
local max = math.max
local abs = math.abs

local PandaCharacter = require "PandaCharacter"

-----------------------------------------------------------------------
-- Create a GameViewController class extension
-----------------------------------------------------------------------
local GameViewController = class.extendClass(objc.GameViewController)


-----------------------------------------------------------------------
-- Methods for dynamic update (see module MonitorControllerClass)
-----------------------------------------------------------------------

function GameViewController:configureView()
    -- This method will be called from viewDidLoad(), or when this module's code has changed
    -- Put here the code configuring the controller's view
    if self.pandaCharacter == nil then
        self.pandaCharacter = PandaCharacter:new()
    end
    
    self:getResource ("GameScnAssets.level", "scn", "updateLevelScene")
    self:getResource ("Particle systems.collect", "scnp", "updateCollectFlowerParticleSystem")
    
    self.gameView.delegate = self    
end

function GameViewController:refreshView()
    -- This method will be executed when the module is reloaded.
    self:configureView()
   
    --[[ -- Display statistics on the game view
    self.gameView.showsStatistics = true]]
    
    --[[ -- Return the panda to the starting point
    local startingPointNode = self.gameView.scene.rootNode:childNodeWithName_recursively ( 'startingPoint', true)
    self.pandaCharacter.node.transform = startingPointNode.transform]]
end

function GameViewController:viewControllerStateData()
    -- Return internal state information for the current View Controller, used to clone it
    -- into a replacement View Controller, in case of storyboard change.
    -- State data can be returned as a Lua table or as a function with a single parameter: the replacement view controller.
    
    local gameStateData = self:gameStateData()
    if gameStateData then
        return { savedGameStateData = gameStateData }
    end
end

GameViewController.storyboardIdentifier = "GameViewController"

function GameViewController:gameStateData()
    local gameStateData
    local levelScene = self.gameView.scene
    
    if levelScene ~= nil then
        gameStateData = { }
        
        -- Camera position
        if self.cameraXHandle then
            gameStateData.cameraXAngle = self.cameraXHandle.rotation.w * ((self.cameraXHandle.rotation.x > 0) and 1 or -1)
        end
        
        if self.cameraYHandle then
            gameStateData.cameraYAngle = self.cameraYHandle.rotation.w * ((self.cameraYHandle.rotation.y > 0) and 1 or -1)
        end
    end
    
    return gameStateData
end

function GameViewController:updateLevelScene (scene --[[@type objc.SCNScene]], sceneUrl --[[@type objc.NSURL]])
    
    if not (scene and scene:isKindOfClass(SCNScene)) and (sceneUrl ~= nil) then
        -- the 'scene' parameter is not a SCNSCene: unarchive the scene from the provided URL
        scene = SCNScene:sceneWithURL_options_error (sceneUrl, nil)
    end
    
    if scene and scene:isKindOfClass(SCNScene) then
        
        -- Save relevant state info before replacing the current scene (i.e. all changes done to the current scene geometry or structure)
        local gameStateData = self:gameStateData()
        if gameStateData == nil then
            -- Game state data may have been stored as ViewController state data
            gameStateData = self.savedGameStateData
        end
        
        -- Setup the level scene
        local gameView --[[@type objc.GameView]] = self.gameView
        
        gameView.scene = scene
        gameView.playing = true
        gameView.loops = true
        
        -- Various setups
        self:setupSceneCollisionNodes(scene, gameStateData)
        self:setupCameras(scene, gameStateData)
        self:setupSounds(scene, gameStateData)
        
        -- Add the panda character to the scene
        scene.rootNode:addChildNode(self.pandaCharacter.node)
        self.pandaCharacter:refreshWalkingAnimation()
        
        if gameStateData == nil then
            -- place the character at the starting point
            local startingPointNode = scene.rootNode:childNodeWithName_recursively ( 'startingPoint', true)
            self.pandaCharacter.node.transform = startingPointNode.transform
        end
    end
end

function GameViewController:updateCollectFlowerParticleSystem (_, particleSystemUrl)
    local particleSystem
    
    -- Get the particle system from the keyed archive at the specified URL, and fix the (relative) particle image path
    if particleSystemUrl ~= nil then
        particleSystem = objc.NSKeyedUnarchiver:unarchiveObjectWithFile (particleSystemUrl.path)
        if particleSystem:isKindOfClass(objc.SCNParticleSystem) then
            local unarchivedParticleImage = particleSystem.particleImage
            if unarchivedParticleImage:isKindOfClass(objc.NSURL) then
                local particleImagePath = unarchivedParticleImage.relativePath
                if not particleImagePath.isAbsolutePath then
                    particleSystem.particleImage = particleSystemUrl.URLByDeletingLastPathComponent:URLByAppendingPathComponent(particleImagePath)
                else -- absolute path
                    local mainBundleResourcePath = objc.NSBundle.mainBundle.resourceURL.path
                    if particleImagePath:hasPrefix (mainBundleResourcePath) then
                        -- The SCNParticleSystem unarchiver transforms relative paths in the archive into absolute URLs in the application's resource folder 
                        -- if the corresponding file exists. If a resource image exists at this relative path, point to this path to support dynamic
                        -- update of the particle image.
                        local relativeImagePath = particleImagePath:substringFromIndex(mainBundleResourcePath.length + 1) -- No traing '/' in a NSURL path
                        local particleImageResourceUrl = particleSystemUrl.URLByDeletingLastPathComponent:URLByAppendingPathComponent(relativeImagePath)
                        if objc.NSFileManager.defaultManager:fileExistsAtPath(particleImageResourceUrl.path) then
                            particleSystem.particleImage = particleImageResourceUrl
                        end
                    end
                end
            end
        else
            particleSystem = nil
        end
    end
    
    if particleSystem then
        particleSystem.loops = false
        self.collectFlowerParticleSystem = particleSystem
    end
        
end
-----------------------------------------------------------------------
-- Managing the camera
-----------------------------------------------------------------------
local cameraAltitude = 1.0
local cameraDistance = 9
local cameraDefaultAngleX = - pi / 30
local cameraDefaultAngleY = pi * 5 / 4
local cameraMoveDuration = 3.0

function GameViewController:panCameraWithDx_dy (panX, panY)
    if not self.lockCamera then
        local panScale = 0.005
        
        --  Make sure the camera handles are correctly reset (because automatic camera animations may have put the "rotation" in a weird state.
        SCNTransaction:begin()
        SCNTransaction:setAnimationDuration (0)
        do
            self.cameraYHandle:removeAllActions()
            self.cameraXHandle:removeAllActions()
            if self.cameraYHandle.rotation.y < 0 then
                self.cameraYHandle.rotation = SCNVector4(0.0, 1.0, 0.0, -self.cameraYHandle.rotation.w)
            end
            if self.cameraXHandle.rotation.x < 0 then
                self.cameraXHandle.rotation = SCNVector4(1.0, 0.0, 0.0, -self.cameraXHandle.rotation.w)
            end
        end
        SCNTransaction:commit()
        
        --  Update the camera position with some inertia.
        SCNTransaction:begin()
        SCNTransaction:setAnimationDuration (0.30)
        -- SCNTransaction:setAnimationTimingFunction (objc.CAMediaTimingFunction:functionWithName(CaMediaTimingFunction.EaseInEaseOut))
        do
            self.cameraYHandle.rotation = SCNVector4(0.0, 1.0, 0.0, self.cameraYHandle.rotation.y * (self.cameraYHandle.rotation.w - panX * panScale))
            self.cameraXHandle.rotation = SCNVector4(1.0, 0.0, 0.0, max(-pi / 2, min (0.15, self.cameraXHandle.rotation.w + panY * panScale)))
        end
        SCNTransaction:commit()
    end
end

function GameViewController:updateCameraForCurrentGroundNode (groundNode)
    
    if not self.gameIsComplete then
        
        if self.currentGroundNode == nil then
            self.currentGroundNode = groundNode
            
        elseif groundNode ~= self.currentGroundNode then
            self.currentGroundNode = groundNode
            
            local cameraPositionForNode = self.automaticCameraPositions[groundNode]
            if type(cameraPositionForNode) == 'function' then
                cameraPositionForNode = cameraPositionForNode(self.pandaCharacter.node)
            end
            
            if cameraPositionForNode then
                local cameraYAction = SCNAction:rotateToX_y_z_duration_shortestUnitArc (0, cameraPositionForNode.y, 0, cameraMoveDuration, true)
                local cameraXAction = SCNAction:rotateToX_y_z_duration_shortestUnitArc (cameraPositionForNode.x, 0, 0, cameraMoveDuration, true)
                self.cameraYHandle:runAction (cameraYAction)
                self.cameraXHandle:runAction (cameraXAction)
            end
        end
    end
end

-----------------------------------------------------------------------
-- Moving the character
-----------------------------------------------------------------------

function GameViewController:characterDirection ()
    local controllerDirectionPoint = self:controllerDirection()
    local characterDirection = SCNVector3(controllerDirectionPoint.x, 0.0, controllerDirectionPoint.y)
    
    if (characterDirection.x ~= 0.0) or (characterDirection.z ~= 0.0) then
        local pointOfView = self.gameView.pointOfView
        if pointOfView then
            -- convert the characterDirection considered in the coordinate system of the camera to the world coordinates space
            characterDirection = pointOfView:normalizedDirectionInWorldXZPlane(characterDirection)
        end
    end
    
    return characterDirection
end

-----------------------------------------------------------------------
-- SCNSceneRendererDelegate Protocol
-----------------------------------------------------------------------
GameViewController:publishObjcProtocols ("SCNSceneRendererDelegate")

function GameViewController:renderer_updateAtTime (renderer, time)
    local character = self.pandaCharacter
    
    -- Add state fields in the character for obstacle detection
    character.replacementPosition = nil
    character.maxPenetrationDistance = 0.0
    
    -- Evaluate the character direction 
    local controllerDirectionPoint = self:controllerDirection()
    local characterDirection = SCNVector3(controllerDirectionPoint.x, 0.0, controllerDirectionPoint.y)
    
    if (characterDirection.x ~= 0.0) or (characterDirection.z ~= 0.0) then
        local pointOfView = self.gameView.pointOfView
        if pointOfView then
            -- convert the characterDirection considered in the coordinate system of the camera to the world coordinates space
            characterDirection = pointOfView:normalizedDirectionInWorldXZPlane(characterDirection)
        end
    end
    
    -- Make the character walk
    local groundNode = character:walkInScene_withDirection_atTime(self.gameView.scene, characterDirection, time)
    
    if groundNode then
        self:updateCameraForCurrentGroundNode (groundNode)
    end
    
    -- Flames are static physics bodies, but they are moved by an action - So we need to tell the physics engine that the transforms did change.
    for _, flameNode in pairs(self.flameNodes) do
        flameNode.physicsBody:resetTransform()
    end
end

function GameViewController:renderer_didSimulatePhysicsAtTime (renderer, time)
    -- If the character did hit a wall, its position may need to be adjusted
    local character = self.pandaCharacter
    if character.replacementPosition then
        character.node.position = character.replacementPosition
        -- character.isWalking = false
    end
end

-----------------------------------------------------------------------
-- Setup methods
-----------------------------------------------------------------------

function GameViewController:setupCameras(scene --[[@type objc.SCNScene]], gameStateData)
    
    local rootNode =  scene.rootNode
    
    --[[  We create 2 nodes to manipulate the camera:
          The first node "cameraYHandle" is at the center of the world (0, ALTITUDE, 0) and will only rotate on the Y axis
          The second node "cameraXHandle" is a child of the first one and will ony rotate on the X axis
          The camera node is a child of the "cameraXHandle" at a specific distance (DISTANCE).
          So rotating cameraYHandle and cameraXHandle will update the camera position and the camera will always look at the center of the scene.
       ]]
    
    local pov = self.gameView.pointOfView
    pov.eulerAngles = SCNVector3(0.0, 0.0, 0.0)
    pov.position    = SCNVector3(0.0, 0.0, cameraDistance)
    
    local cameraXHandle = SCNNode:new()
    cameraXHandle.rotation = SCNVector4(1.0, 0.0, 0.0, gameStateData and gameStateData.cameraXAngle or cameraDefaultAngleX)
    cameraXHandle:addChildNode (pov)
    self.cameraXHandle = cameraXHandle
    
    if self.cameraYHandle then
        -- make sure we don't have more that one camera handle in the scene
        self.cameraYHandle:removeFromParentNode()
    end
    
    local cameraYHandle = SCNNode:new()
    cameraYHandle.position = SCNVector3(0.0, cameraAltitude, 0.0)
    cameraYHandle.rotation = SCNVector4(0.0, 1.0, 0.0, gameStateData and gameStateData.cameraYAngle or cameraDefaultAngleY)
    cameraYHandle:addChildNode (cameraXHandle)
    self.cameraYHandle = cameraYHandle
    
    rootNode:addChildNode(cameraYHandle)
    
    -- Automatic camera positions for identified ground nodes
    self.automaticCameraPositions = { [rootNode:childNodeWithName_recursively("bloc04_collisionMesh_02", true)] = CGPoint(-0.188683, 4.719608),
                                      [rootNode:childNodeWithName_recursively("bloc03_collisionMesh", true)] = CGPoint(-0.435909, 6.297167),
                                      [rootNode:childNodeWithName_recursively("bloc07_collisionMesh", true)] = CGPoint(-0.333663, 7.868592),
                                      [rootNode:childNodeWithName_recursively("bloc08_collisionMesh", true)] = CGPoint(-0.575011, 8.739003),
                                      [rootNode:childNodeWithName_recursively("bloc06_collisionMesh", true)] = CGPoint(-1.095519, 9.425292),
                                      [rootNode:childNodeWithName_recursively("bloc05_collisionMesh_02", true)] = function (characterNode)
                                                                                                                      if characterNode.position.x < 2.5 then
                                                                                                                          return CGPoint(-0.098175, 3.926991)
                                                                                                                      else
                                                                                                                          return CGPoint(-0.072051, 8.202264)
                                                                                                                      end
                                                                                                                  end,
                                      [rootNode:childNodeWithName_recursively("bloc05_collisionMesh_01", true)] = CGPoint(-0.072051, 8.202264),
                                    }
    
    local isGameStarting = (gameStateData == nil) or self.lockCamera or
                           ((abs(gameStateData.cameraXAngle - cameraDefaultAngleX) < 0.0001) and (abs(gameStateData.cameraYAngle -cameraDefaultAngleY) < 0.0001))
    
    if isGameStarting then
        
        -- Animate camera on launch and prevent the user from manipulating the camera until the end of the animation.
        
        SCNTransaction:begin()
        SCNTransaction:setAnimationDuration (0.25)
        SCNTransaction:setCompletionBlock (function() 
                                               self.lockCamera = false 
                                           end)
        
        self.lockCamera = true
        
        -- Create 2 additive animations that converge to 0
        -- That way at the end of the animation, the camera will be at its default position.
        local cameraYAnimation = objc.CABasicAnimation:animationWithKeyPath("rotation.w")
        cameraYAnimation.fromValue = math.pi * 2 - cameraYHandle.rotation.w
        cameraYAnimation.toValue = 0.0
        cameraYAnimation.additive = true
        cameraYAnimation.beginTime = CACurrentMediaTime() + 3.0
        cameraYAnimation.fillMode = CaMediaTiming.FillModeBoth
        cameraYAnimation.duration = 5.0
        cameraYAnimation.timingFunction = objc.CAMediaTimingFunction:functionWithName(CaMediaTimingFunction.EaseInEaseOut)
        cameraYHandle:addAnimation_forKey (cameraYAnimation, nil)
        
        local cameraXAnimation = cameraYAnimation:copy()
        cameraXAnimation.fromValue = - math.pi / 2 + cameraXHandle.rotation.w
        cameraXHandle:addAnimation_forKey (cameraXAnimation, nil)
        
        SCNTransaction:commit()
    end
end


function GameViewController:setupSounds (scene --[[@type objc.SCNScene]], gameStateData)
    
    local function ambientAudioSourceWithName_volume (soundFileName, volume)
        local audioSource = SCNAudioSource:audioSourceNamed("sounds/" .. soundFileName)
        audioSource.volume = volume
        audioSource.positional = false
        audioSource.shouldStream = true
        audioSource.loops = true
        -- audioSource:load()
        return audioSource
    end
    
    local function audioSourceWithName_volume (soundFileName, volume, looping)
        local audioSource = SCNAudioSource:audioSourceNamed("sounds/" .. soundFileName)
        audioSource.volume = volume
        audioSource.positional = true
        audioSource.shouldStream = false
        audioSource.loops = false
        audioSource:load()
        return audioSource
    end
    
    local rootNode = self.gameView.scene.rootNode
    
    rootNode:removeAllAudioPlayers()
    rootNode:addAudioPlayer (SCNAudioPLayer:newWithSource (ambientAudioSourceWithName_volume ("music.m4a", 0.25)))
    rootNode:addAudioPlayer (SCNAudioPLayer:newWithSource (ambientAudioSourceWithName_volume ("wind.m4a", 0.25)))
    
    self.collectPearlSound = audioSourceWithName_volume ("collect1.mp3", 0.5)
    self.collectFlowerSound =  audioSourceWithName_volume ("collect2.mp3", 1.0)
end

-----------------------------------------------------------------------
-- Load the class extension that handles collisions and treasures
-----------------------------------------------------------------------

require "GameViewController-Collisions"

-----------------------------------------------------------------------
-- return the class defined by this module
-----------------------------------------------------------------------
return GameViewController