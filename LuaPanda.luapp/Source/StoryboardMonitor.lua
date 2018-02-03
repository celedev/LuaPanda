--[[

Module StoryboardMonitor
------------------------

This module contains the reference implementation of dynamic storyboard updates for macOS.

It returns a `StoryboardMonitor` class, that provides methods for dynamically updating ViewControllers when their referencing
storyboard changes.

You create a StoryboardMonitor instance by calling class method `StoryboardMonitor:named(storyboard_resource_path)`:

    local local StoryboardMonitor = require 'StoryboardMonitor'
    local mainStoryboardMonitor = StoryboardMonitor:named 'MainStoryboard'

Then you declare which ViewControllers or WindowController shall be dynamically updated. You can decide to dynamically update
 all Controllers of a given class, or only specific ViewControllers referenced by their storyboard-identifiers:

    -- This will dynamically update all instances of classes DocumentViewController and MyWindowController
    mainStoryboardMonitor:updateControllersOfClasses { objc.DocumentViewController, objc.MyWindowController } 
    
    -- This will only update ViewController with identifier "MyViewControllerId"
    mainStoryboardMonitor:updateViewControllersWithIds { "MyViewControllerId" }

    -- This will dynamically update all WindowControllers of class MyWindowController
    mainStoryboardMonitor:updateWindowControllersOfClass (MyWindowController)
    

You can also associate a ViewController class, with a set of  state properties that shall be preseved when the storyboard is 
updated. This is convenient when you use live storyboard update with a ViewController already implemented in Swift or Objective-C, 
since you don't have to add a Lua module for this ViewController class in your project:

    -- This will dynamically update all ViewControllers of class SessionController, and preserve the value of 
    -- SessionController's properties named 'userInfo' and 'session' when the storyboard is updated
    mainStoryboardMonitor:updateViewControllersOfClassWithStateProperties (objc.SessionController, { 'userInfo', 'session' } )

You can customize the behavior of a dynamically updated ViewController class by implementing the following optional ViewController methods
in a Lua class extension of the ViewController class:

     - configureView(): configures the view controller's view; called when the view is loaded (i.e. in viewDidLoad()) or when the 
                        view controller code is updated. 
                        IMPORTANT! You shall never directly override method `viewDidLoad()` in Lua when a StoryboardMonitor is associated 
                                   to its class.

     - refreshView(): refresh the view controller's view when the view controller's code is updated; should at least call self:configureView() 
                      and may take actions to ensure that the controller's view is correcly redisplayed after the update.

     - viewControllerStateData(): returns internal state information for the current View Controller, used to clone it into a new View 
                                  Controller when the storyboard changes.
        
                       View Controller State data can be returned either:
                       - as a list of property names:
                             return { 'modelProperty1', 'modelProperty2' }
                       - as a key-value table of property names and associated values;
                             return { modelProperty1 = self.modelProperty1, modelProperty2 = modelProperty2}
                       - as a function with a single parameter: the replacing view controller:
                             
                             local modelProperty1 = self.modelProperty1 -- avoid capturing self in the returned function
                             local scrollOffset = self.scrollView.contentOffset -- preserve the display state 
                             return function (viewController)
                                        viewController.modelProperty1 = modelProperty1
                                        viewController.scrollView.contentOffset = scrollOffset
                                    end

     - storyboardIdentifier: (string) the storyboard identifier of the current view controller, used for cloning of the view controller 
                             when the soryboard changes. If this property is not defined, the current class name is used as the 
                             storyboard identifier.
                             
]]


local NSNotFound = require "Foundation.NSObjCRuntime".NotFound

-----------------------------------------------------------------------
-- Create a dedicated class for monitorings storyboard updates
-----------------------------------------------------------------------
local StoryboardMonitor = class.createClass ("StoryboardMonitor")

function StoryboardMonitor:initWithStoryboardNamed (storyboardName)
    
    self.storyboardName = storyboardName
    self.updatedMessageId = "Storyboard-" .. storyboardName .. "-Updated"
    self.updatedControllerClasses = {}
    self.updatedControllerIds = {}
    
    -- Start monitoring storyboard updates
    self:getResource(storyboardName, 'storyboardc',
                     function (self, storyboard)
                         self.currentStoryboardVersion = storyboard --[[@type objc.NSStoryboard]] 
                         message.post (self.updatedMessageId, self, storyboard)
                     end)
    
    -- Add to the list of active storyboard monitors
    if self.class.activeMonitors == nil then
        self.class.activeMonitors = { }
    end
    self.class.activeMonitors [storyboardName] = self
    
end

function StoryboardMonitor.class:named (storyboardName)
    local storyboardMonitor
    
    if self.activeMonitors ~= nil then
        storyboardMonitor = self.activeMonitors [storyboardName]
    end
    
    if storyboardMonitor == nil then
        storyboardMonitor = self:newWithStoryboardNamed (storyboardName)
    end
    
    return storyboardMonitor
end

local addUpdatesMonitoringToViewControllerClassIfNeeded -- Forward declaration of a function used as upvalue by the method below 
local addUpdatesMonitoringToWindowControllerClassIfNeeded -- Forward declaration of a function used as upvalue by the method below 

function StoryboardMonitor:updateViewControllersWithIds (viewControllerIds)
    
    for _, viewControllerId in ipairs(viewControllerIds) do
        
        -- Get the class of the corresponding ViewController in the storyboard
        local viewControllerWIthId = self.currentStoryboardVersion:instantiateControllerWithIdentifier (viewControllerId)
        if viewControllerWIthId ~= nil then
            -- This is a valid storyboard Id
            
            -- Add it to the list of updated ViewController Ids
            self.updatedControllerIds [viewControllerId] = true
            
            -- Configure the ViewConrtroller class to monitor storyboard updates if not already done
            local ViewControllerClass = viewControllerWIthId.class
            addUpdatesMonitoringToViewControllerClassIfNeeded (ViewControllerClass, self)
        else
            print (string.format ("[StoryboardMonitor:updateViewControllersWithIds] error: cannot find a view controller with id \"%s\" in storyboard \"%s\"", viewControllerId, self.storyboardName))
        end
    end
end

function StoryboardMonitor:updateViewControllersOfClassWithStateProperties (ViewControllerClass, statePropertyNames)
    
    self.updatedControllerClasses [ViewControllerClass] = true
    
    -- Configure the ViewController class to monitor storyboard updates if not already done
    addUpdatesMonitoringToViewControllerClassIfNeeded (ViewControllerClass, self)
    
    if type(statePropertyNames) == 'table' then
        -- Store the state property names as a class field (copy the provided table)
        local viewControllerStateProperties = {}
        for propertyIndex, propertyName in ipairs(statePropertyNames) do
            viewControllerStateProperties [propertyIndex] = propertyName
        end
        ViewControllerClass._viewControllerStateProperties = viewControllerStateProperties
    end
end

function StoryboardMonitor:updateViewControllersOfClass (ViewControllerClass)

    self:updateViewControllersOfClassWithStateProperties(ViewControllerClass, nil) 
end

function StoryboardMonitor:updateViewControllersOfClasses (viewControllerClasses)
    
    for _, ViewControllerClass in ipairs(viewControllerClasses) do
        self:updateViewControllersOfClass(ViewControllerClass)
    end
end

function StoryboardMonitor:updateWindowControllersOfClass (windowControllerClass)
    
    self.updatedControllerClasses [windowControllerClass] = true
    
    -- Configure the ViewController class to monitor storyboard updates if not already done
    addUpdatesMonitoringToWindowControllerClassIfNeeded (windowControllerClass, self)
end

function StoryboardMonitor:updateControllersOfClasses (controllerClasses)
    
    for _, controllerClass in ipairs(controllerClasses) do
        
        if controllerClass:isSubclassOf(objc.NSViewController) then
            self:updateViewControllersOfClass(controllerClass)
            
        elseif controllerClass:isSubclassOf(objc.NSWindowController) then
            self:updateWindowControllersOfClass(controllerClass)
            
        end
    end
end 

-----------------------------------------------------------------------
-- This function encapsulates the creation of a class extension that takes care of monitoring updates
-----------------------------------------------------------------------
local function addUpdatesMonitoringExtensionToViewControllerClass (ViewControllerClass --[[@type objc.NSAccessibilityCustomActionViewController]], storyboardMonitor)
    
    local ViewController = class.extendClass (ViewControllerClass, 'StoryboardMonitor')
    
    -----------------------------------------------------------------------
    -- Overriding NSViewController standard methods
    -----------------------------------------------------------------------
    
    function ViewController:viewDidLoad()
        
        self:markLuaSetupDone()
        
        -- Apply an eventual view controller state
        if type(self.applyViewControllerStateData) == 'function' then
            self:applyViewControllerStateData ()
        end
        
        self[ViewController][objc]:viewDidLoad()
        
        self:configureForUpdates()
    end
    
    -----------------------------------------------------------------------
    -- Monitoring updates and configuring pre-existing instances for Lua
    -----------------------------------------------------------------------
    
    function ViewController:doLuaSetup()
        
        -- 1. Propagate the Lua setup to Lua-enabled child view controllers 
        --    (so that child controllers can be recreated from the current storyboard version and taken into account by this view controller's setup)
        for childViewController in self.childViewControllers do
            if type(childViewController) == 'instance' then
                childViewController:doLuaSetupIfNeeded()
            end
        end
        
        -- 2. Configure this view controller and start monitoring updates if viewDidLoad has already been called
        if self.isViewLoaded then
            self:configureForUpdates()
        end
        
        -- 3. Propagate the Lua setup to parent and sibling view controllers,
        local parentViewController = self.parentViewController
        if parentViewController ~= nil then
            
            if type(parentViewController) == 'instance' then
                parentViewController:doLuaSetupIfNeeded()
            end
            
            -- propagate to sibling controllers (in case the parent view controller is not a Lua-Objc object)
            for siblingViewController in parentViewController.childViewControllers do
                if (siblingViewController ~= self) and (type(siblingViewController) == 'instance') then
                    siblingViewController:doLuaSetupIfNeeded()
                end
            end
        end
        
    end
    
    -------------------------------------------------------------------------------------------
    function ViewController:configureForUpdates()
        
        local isValidViewController = true
        
        if storyboardMonitor ~= nil then
            isValidViewController = self:subscribeToStoryboardUpdates()
        end
        
        if  isValidViewController and self.isViewLoaded then
            
            -- optional method refreshView
            if type(self.refreshView) == 'function' then 
                self:addMessageHandler(self.class, "refreshView") -- When the code of the current class is updated, call refreshView
            end
            
            -- optional method configureView
            if type(self.configureView) == 'function' then 
                self:configureView() 
            end
        end
    end
    
    -------------------------------------------------------------------------------------------
    function ViewController:stopMonitoringUpdates()
        -- Remove all message handlers for self
        self:removeMessageHandler ()
    end
    
    -------------------------------------------------------------------------------------------
    -- Managing view controller state propagation
    -------------------------------------------------------------------------------------------
    
    function ViewController:getViewControllerStateData()
        
        -- If state data exist for this controller and has not been applied yet, use it; otherwise ask the View Controller for its state data
        local controllerStateData = self._viewControllerStateData
        if controllerStateData == nil then 
            
            if type(self.viewControllerStateData) == 'function' then 
                -- ViewController has an instance method viewControllerStateData: call it
                controllerStateData = self:viewControllerStateData()
        
                if type(controllerStateData) == 'table' then
                    -- consider int-indexed entries in the table as property names and save the current property values in the state
                    for stateIndex, propertyName in ipairs(controllerStateData) do
                        if type(propertyName) == 'string' then
                            controllerStateData [propertyName] = self [propertyName]
                            controllerStateData [stateIndex] = nil
                        end
                    end
                end
            
            elseif type(ViewController._viewControllerStateProperties) == 'table' then
                -- The list of state properties is defined at the class level: get the corresponding property values from the current instance
                controllerStateData = {}
                for _, propertyName in ipairs(ViewController._viewControllerStateProperties) do
                    controllerStateData [propertyName] = self [propertyName]
                end
            end
            
        end
        
        -- get state data from child view controllers
        local childStateData
        for childViewController in self.childViewControllers do
            local childStoryboardId = childViewController.storyboardIdentifier
            if (childStoryboardId ~= nil) and (type(childViewController) == 'instance') and (type(childViewController.getViewControllerStateData) == 'function') then
                childStateData = childStateData or {} -- create the childStateData table if needed
                childStateData [childStoryboardId] = childViewController:getViewControllerStateData()
            end
        end
        
        return (controllerStateData or childStateData) and { data = controllerStateData, childData = childStateData } 
               or nil
    end
    
    -------------------------------------------------------------------------------------------
    function ViewController:setViewControllerStateData (stateData)
        
        -- set the state data for this controller
        local controllerStateData = stateData.data
        if controllerStateData then
            self._viewControllerStateData = controllerStateData
            
            if self.isViewLoaded then
                self:applyViewControllerStateData()
            end
        end
        
        -- set child state data in existing child controllers
        do
            local childStateData = stateData.childData
            if childStateData ~= nil then
                
                for childViewController in self.childViewControllers do
                    if (type(childViewController) == 'instance') and (childViewController.storyboardIdentifier ~= nil) then
                        local childStoryboardId = childViewController.storyboardIdentifier
                        local childControllerStateData = childStateData [childStoryboardId]
                        if childControllerStateData ~= nil then
                            if type(childViewController.setViewControllerStateData) == 'function' then
                                childViewController:setViewControllerStateData (childControllerStateData)
                            end
                            
                            -- clear the state data for this child controller
                            childStateData [childStoryboardId] = nil
                        end
                    end
                end
                
                -- keep pending child state data in a field 
                if not table.isempty(childStateData) then
                    self._childControllersStateData = childStateData
                end
            end
        end      
    end
    
    -------------------------------------------------------------------------------------------
    function ViewController:applyViewControllerStateData ()
        
        -- apply the state data for this controller
        local controllerStateData = self._viewControllerStateData
        
        if controllerStateData then
            if type(controllerStateData) == 'table' then
                -- set all state data (key, value) pairs on self
                for key, value in pairs(controllerStateData) do
                    self [key] = value
                end
                
            elseif type(controllerStateData) == 'function' then
                -- call the state data function as a method of self
                controllerStateData(self)
            end
            
            self._viewControllerStateData = nil
        end
    end
    
    -------------------------------------------------------------------------------------------
    function ViewController:setStateDataOnChildViewController (childViewController)
        
        if (type(childViewController) == 'instance') and (type(childViewController.setViewControllerStateData) == 'function') then
            if self._childControllersStateData ~= nil then
                local destinationChildStateData = self._childControllersStateData [childViewController.storyboardIdentifier]
                if destinationChildStateData ~= nil then
                    childViewController:setViewControllerStateData (destinationChildStateData)
                    -- clear the state data for this child controller
                    self._childControllersStateData [childViewController.storyboardIdentifier] = nil
                    if table.isempty(self._childControllersStateData) then
                        self._childControllersStateData = nil
                    end
                end
            end
        end
    end
    
    -------------------------------------------------------------------------------------------
    if not ViewController:implementsLuaMethod ("prepareForSegue_sender") then
        
        function ViewController:prepareForSegue_sender (segue --[[@type objc.NSStoryboardSegue]], sender --[[@type objcid]])  --[[@return nil]] 
            
            self:setStateDataOnChildViewController (segue.destinationViewController)
            
            -- call the native `prepareForSegue` method
            self[ViewController][objc]:prepareForSegue_sender(segue, sender)
        end
    end
    
    -------------------------------------------------------------------------------------------
    -- set a default storyboard identifier at the class level
    if ViewController.storyboardIdentifier == nil then
        ViewController.storyboardIdentifier = ViewController.classname
    end
    
    -------------------------------------------------------------------------------------------
    -- Getting storyboard updates
    -------------------------------------------------------------------------------------------
    if storyboardMonitor then
        
        -- Define methods related to storyboard updates only if a storyboard monitor is defined!
        
        local storyboardUpdatedMessage = storyboardMonitor.updatedMessageId
        
        -------------------------------------------------------------------------------------------
        function ViewController:subscribeToStoryboardUpdates()
            -- Subscribe to the storyboard updates messages or replace the view controller
            local isControllerReplaced = false
            
            if not self:isForCurrentStoryboard() then
                isControllerReplaced = self:replaceForCurrentStoryboard()
            end
            
            if not isControllerReplaced then
                self:addMessageHandler(storyboardUpdatedMessage, 'replaceForCurrentStoryboard')
            end
            
            return (not isControllerReplaced)
        end
        
        -------------------------------------------------------------------------------------------
        function ViewController:isForCurrentStoryboard()
            local currentStoryboard = storyboardMonitor.currentStoryboardVersion
            return (currentStoryboard == nil) or ((self.storyboard == currentStoryboard))
        end
        
        -------------------------------------------------------------------------------------------
        function ViewController:replaceInParentViewController (replacingViewController, replaceDoneHandler)
            
            local isReplaced = false
            
            if type(self.replaceWithViewController) == 'function' then
                -- A custom view controller replacement method is defined for this view controller: use it
                isReplaced = self:replaceWithViewController (replacingViewController)
                
            else
                -- Default replacing strategies depending on the kind of parent view controller
                
                local parentViewController = self.parentViewController
                
                if parentViewController == nil then
                    -- check if this view controller is a root view controller
                    local parentWindow
                    for applicationWindow --[[@type objc.NSWindow]] in objc.NSApplication.sharedApplication.windows do
                        if applicationWindow.contentViewController == self then
                            parentWindow = applicationWindow
                            break
                        end
                    end
                    
                    if parentWindow then
                        if self:isViewLoaded() then
                            -- preserve the window size by setting the replacing controller's view frame
                            replacingViewController.view.frame = self.view.frame
                        end
                        -- Replace self with updatedViewController as the window content View Controller
                        parentWindow.contentViewController = replacingViewController
                        isReplaced = true
                        
                    elseif self.presentingViewController ~= nil then
                        -- if self is a presented view controller; replace it in its presenting controller
                        local presentingViewController = self.presentingViewController
                        presentingViewController:dismissViewController (self)
                        presentingViewController:presentViewController_animator(replacingViewController, nil)
                        isReplaced = true
                    end
                    
                else
                    -- Use the generic NSViewController container API
                    local indexInParentViewController = parentViewController.childViewControllers:indexOfObject(self)
                    
                    if indexInParentViewController ~= NSNotFound then
                        parentViewController:removeChildViewControllerAtIndex(indexInParentViewController)
                        parentViewController:insertChildViewController_atIndex(replacingViewController, indexInParentViewController)
                        isReplaced = true
                    end
                end
            end
            
            if isReplaced then
                -- Call the replace-done handler
                replaceDoneHandler ()
            end
            
            return isReplaced
        end
        
        -------------------------------------------------------------------------------------------
        function ViewController:replaceChildViewControllers (replacingViewController)
            
            -- if the current view controller has child controllers, add these to the replacing ViewController 
            if self.childViewControllers.count > 0 then
                
                -- do specific processing for each supported container controller type
                
                print "ViewController:replaceChildViewControllers is not implemented yet!"
            end
        end
        
        -------------------------------------------------------------------------------------------
        function ViewController:replaceForCurrentStoryboard()
            
            local isReplaced = false
            
            local currentStoryboardId = self.storyboardIdentifier
            
            if currentStoryboardId ~= nil then
                
                if storyboardMonitor.updatedControllerClasses [self.class] == true
                   or storyboardMonitor.updatedControllerIds [currentStoryboardId] == true then
                    
                    -- This ViewController or its class has been registered for automatic update
                    
                    local currentStoryboard = storyboardMonitor.currentStoryboardVersion
                    
                    if currentStoryboard and (self.storyboard ~= currentStoryboard) then
                        
                        -- Instanciate a replacement ViewController using the current storyboard
                        local replacementViewController = currentStoryboard:instantiateControllerWithIdentifier (currentStoryboardId)
                        if replacementViewController then
                            
                            -- Copy controller state data to the replacement view controller
                            local controllerStateData = self:getViewControllerStateData()
                            if controllerStateData ~= nil then
                                replacementViewController:setViewControllerStateData (controllerStateData)
                            end
                            
                            -- Replace self with replacementViewController in the view controller hierarchy
                            
                            local function replaceDoneHandler ()
                                -- Stop monitoring updates in the replaced ViewController (self)
                                self:stopMonitoringUpdates()
                                -- Stop monitoring resources in the replaced ViewController 
                                self:stopMonitoringResource()
                                -- Unsubscribe the replaced ViewController from NSNotifications (to avoid unwanted side effects before the replaced ViewController is GC-ed)
                                objc.NSNotificationCenter.defaultCenter:removeObserver(self)
                                
                                self:replaceChildViewControllers (replacementViewController)
                                --self:replacePresentedViewController (replacementViewController, currentStoryboard)
                                
                                -- Make replacementViewController subscribe to storyboard updates without waiting until viewDidLoad is called
                                replacementViewController:addMessageHandler(storyboardUpdatedMessage, 'replaceForCurrentStoryboard')
                                
                            end
                            
                            isReplaced = self:replaceInParentViewController (replacementViewController, replaceDoneHandler)
                        end
                    end
                end
                
            else
                print (string.format("Warning: can not update ViewController %s in storyboard %s because its storyboardId is not set.", 
                                     tostring (self), storyboardMonitor.storyboardName))
            end
            
            return isReplaced
        end
 
    end
    
    -- Declare the class extension as complete
    class.endExtendClass(ViewController);  
    
end

function addUpdatesMonitoringToViewControllerClassIfNeeded (ViewControllerClass --[[@type objc.NSViewController]], storyboardMonitor)
    
    if not ViewControllerClass:hasClassExtension('StoryboardMonitor') then
        addUpdatesMonitoringExtensionToViewControllerClass (ViewControllerClass, storyboardMonitor)
    end
end

-----------------------------------------------------------------------
-- This function encapsulates the creation of a Window Controller class extension that takes care of monitoring updates
-----------------------------------------------------------------------

local function addUpdatesMonitoringExtensionToWindowControllerClass (WindowControllerClass --[[@type objc.NSWindowController]], 
                                                                     storyboardMonitor)
    
    local WindowController = class.extendClass (WindowControllerClass, 'StoryboardMonitor')
    
    -----------------------------------------------------------------------
    -- Overriding NSWindowController standard methods
    -----------------------------------------------------------------------
    
    function WindowController:windowDidLoad()
        self[objc]:windowDidLoad()
        
        self:markLuaSetupDone()
        self:configureForUpdates()
    end
    
    -----------------------------------------------------------------------
    -- Monitoring updates and configuring pre-existing instances for Lua
    -----------------------------------------------------------------------
    
    function WindowController:doLuaSetup()
        
        -- 1. Propagate the Lua setup to the content View Controller
        if type(self.contentViewController) == 'instance' then
            self.contentViewController:doLuaSetupIfNeeded()
        end

        -- 2. Setup the View Controller and start monitoring updates if viewDidLoad has already been called
        if self.isWindowLoaded then
            self:configureForUpdates()
        end
    end
    
    -------------------------------------------------------------------------------------------
    function WindowController:configureForUpdates()
        
        local isValidController = true
        
        if storyboardMonitor ~= nil then
            isValidController = self:subscribeToStoryboardUpdates()
        end
        
        if  isValidController then
            
            -- optional method refreshView
            if type(self.refreshView) == 'function' then 
                self:addMessageHandler(self.class, "refreshView") -- When the code of the current class is updated, call refreshView
            end
            
            -- optional method configureView
            if type(self.configureView) == 'function' then 
                self:configureView() 
            end
        end
    end
    
    -------------------------------------------------------------------------------------------
    function WindowController:stopMonitoringUpdates()
        -- Remove all message handlers for self
        self:removeMessageHandler ()
    end
    
    -------------------------------------------------------------------------------------------
    -- Getting updates of storyboard named 'monitoredStoryboardName'
    -------------------------------------------------------------------------------------------
    if storyboardMonitor then
        
        -- Define methods related to storyboard updates only if a storyboard monitor is defined!
        
        -------------------------------------------------------------------------------------------
        function WindowController:subscribeToStoryboardUpdates()
            
            -- Do an initial update for the current storyboard and subscribe for storyboard update messages
            self:updateForCurrentStoryboard()
            self:addMessageHandler(storyboardMonitor.updatedMessageId, 'updateForCurrentStoryboard')
            
            return true -- subscription always succeeds for window controllers
        end
        
        -------------------------------------------------------------------------------------------
        function WindowController:updateForCurrentStoryboard()
            
            local currentStoryboard = storyboardMonitor.currentStoryboardVersion
            
            if currentStoryboard and (self.contentViewController.storyboard ~= currentStoryboard) then
                
                local currentContentController = self.contentViewController
                
                -- Instanciate a replacement ViewController using the current storyboard
                local replacementContentController = currentStoryboard:instantiateControllerWithIdentifier (currentContentController.storyboardIdentifier)
                if replacementContentController then
                    
                    -- Copy controller state data to the replacement View Controller
                    local controllerStateData = currentContentController:getViewControllerStateData()
                    if controllerStateData ~= nil then
                        replacementContentController:setViewControllerStateData (controllerStateData)
                    end
                    
                    -- preserve the window size by setting the replacing controller's view frame
                    replacementContentController.view.frame = currentContentController.view.frame
                    
                    -- Replace the Content View Controller
                    self.contentViewController = replacementContentController
                    
                    -- stop monitoring updates in the replaced ContentController
                    currentContentController:stopMonitoringUpdates()
                    -- Stop monitoring resources in the replaced ContentController 
                    currentContentController:stopMonitoringResource()
                    -- Unsubscribe the replaced ContentController from NSNotifications (to avoid unwanted side effects before the replaced ViewController is GC-ed)
                    objc.NSNotificationCenter.defaultCenter:removeObserver(currentContentController)
                    
                end
            end
        end
    end
    
    -- Declare the class extension as complete
    class.endExtendClass(WindowController);    
end

function addUpdatesMonitoringToWindowControllerClassIfNeeded (WindowControllerClass --[[@type objc.NSWindowController]], 
                                                              storyboardMonitor)
    
    if not WindowControllerClass:hasClassExtension('StoryboardMonitor') then
        addUpdatesMonitoringExtensionToWindowControllerClass (WindowControllerClass, storyboardMonitor)
    end
end


-- Return the StoryboardMonitorClass and the addUpdatesMonitoring function as results of the module

return StoryboardMonitor, addUpdatesMonitoringToViewControllerClassIfNeeded
