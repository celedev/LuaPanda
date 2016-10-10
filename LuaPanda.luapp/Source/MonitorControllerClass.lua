--[[ This module returns 3 values:
       1- a "monitor dynamic updates" function for View Controller classes,
       2- a "monitor dynamic updates" function for Window Controller classes
       3- the StoryboardMonitor class

     Both "monitor dynamic updates" function take two parameters:
       - The Controller Class for which updates shall be monitored (subclass of NSViewController / NSWindowCOntroller)
       - The name of a storyboard resource to monitor (optional; omit or pass nil if the storyboard is monitored by a parent View Controller or Window Controller)
  ]]

--[[ The ViewController dynamic updates implementation uses a few optional methods that can be implemented to configure the View Controller update cycle:
     - configureView(): configures the View Controller's view; called when the view is loaded (i.e. by method viewDidLoad()) or when the view 
                        controller code is updated. Note that your own View Controller class extentions shall not redefine the viewDidLoad() method
     - refreshView(): refresh the View Controller's view when the View Controller code is updated; should at least call self:configureView() 
                      and may take actions to redisplay the view after the update.
     - viewControllerStateData() -> table or function: returns the state data of the the current View Controller to cloneViewController. 
                                  Called before replacing self by an up-to-date View Controller in case of storyboard update
     - storyboardIdentifier: (string) the storyboard identifier of the current View Controller, used for cloning of the View Controller when the soryboard changes
                             Note that a private UIViewController instance method exists with the same name, so you can decide to use it
                             or you can redefine your own 'storyboardIdentifier' field in Lua, at the class or instance level.
]]

local NSNotFound = require "Foundation.NSObjCRuntime".NSNotFound

-----------------------------------------------------------------------
-- Create a dedicated class for monitorings storyboard updates
-----------------------------------------------------------------------
local StoryboardMonitor = class.createClass ("StoryboardMonitor")

function StoryboardMonitor.class:monitorStoryboardWithName (storyboardName)
    
    -- returns the storyboard-update message identifier for this storyboard and the current value of the storyboard if known
    local storyboardUpdatedMessageId = "Storyboard-" .. storyboardName .. "-Updated"
    
    -- Lazy creation of the monitoredStoryboards table
    self.monitoredStoryboards = self.monitoredStoryboards or {}
    
    if self.monitoredStoryboards [storyboardName] == nil then
        -- Not already monitoring this storyboard
        self:getResource(storyboardName, 'storyboardc',
                         function (self, storyboard)
                             self.monitoredStoryboards [storyboardName] = storyboard
                             message.post (storyboardUpdatedMessageId, storyboard)
                         end)
    end
    
    return storyboardUpdatedMessageId, self.monitoredStoryboards [storyboardName]
end

function StoryboardMonitor.class:currentStoryboardWithName (storyboardName)
    return self.monitoredStoryboards and self.monitoredStoryboards [storyboardName]
end

-----------------------------------------------------------------------
-- This function encapsulates the creation of a View Controller class extension that takes care of monitoring updates
-----------------------------------------------------------------------

local function monitorUpdatesInViewControllerClass (ViewControllerClass --[[@type objc.NSViewController]], monitoredStoryboardName)
    
    local ViewController = class.extendClass (ViewControllerClass, 'UpdatesMonitoring')
    
    -----------------------------------------------------------------------
    -- Overriding NSViewController standard methods
    -----------------------------------------------------------------------
    
    function ViewController:viewDidLoad()
        self[objc]:viewDidLoad()
        
        self:markLuaSetupDone()
        
        -- Apply the saved view controller state, if set
        if type(self.applyViewControllerStateData) == 'function' then
            self:applyViewControllerStateData ()
        end
        
        self:configureForUpdates()
    end
    
    -----------------------------------------------------------------------
    -- Monitoring updates and configuring pre-existing instances for Lua
    -----------------------------------------------------------------------
    
    function ViewController:doLuaSetup()
        -- Setup the View Controller and start monitoring updates if viewDidLoad has already been called
        if self.isViewLoaded then
            self:configureForUpdates()
        end
        
        -- Propagate the Lua setup to parent and sibling View Controllers,
        local parentViewController = self.parentViewController
        if parentViewController ~= nil then
            
            if type(parentViewController) == 'instance' then
                parentViewController:doLuaSetupIfNeeded()
            end
            
            for siblingViewController in parentViewController.childViewControllers do
                if (siblingViewController ~= self) and (type(siblingViewController) == 'instance') then
                    siblingViewController:doLuaSetupIfNeeded()
                end
            end
        end
        
        -- Propagate the Lua setup to child View Controllers
        for ChildViewController in self.childViewControllers do
            if type(ChildViewController) == 'instance' then
                ChildViewController:doLuaSetupIfNeeded()
            end
        end
    end
    
    -------------------------------------------------------------------------------------------
    function ViewController:configureForUpdates()
        
        local isValidViewController = true
        
        if monitoredStoryboardName ~= nil then
            isValidViewController = self:subscribeToStoryboardUpdates()
        end
        
        if  isValidViewController then
            
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
    -- Managing View Controller state propagation
    -------------------------------------------------------------------------------------------
    
    function ViewController:getViewControllerStateData()
        
        local controllerStateData
        if type(self.viewControllerStateData) == 'function' then 
            controllerStateData = self:viewControllerStateData()
        end
        
        -- get state data from child View Controllers
        local childStateData
        for childViewController in self.childViewControllers do
            if (type(childViewController) == 'instance') and (childViewController.storyboardIdentifier ~= nil) and (type(childViewController.getViewControllerStateData) == 'function') then
                local childStoryboardId = childViewController.storyboardIdentifier
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
        
        -- set child state data to existing child controllers
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
            
            self:setStateDataOnChildViewController (segue.destinationController)
            
            -- call super
            self[ViewController.superclass]:prepareForSegue_sender(segue, sender)
        end
    end
    
    -------------------------------------------------------------------------------------------
    -- set a default storyboard identifier at the class level
    if ViewController.storyboardIdentifier == nil then
        ViewController.storyboardIdentifier = ViewController.classname
    end
    
    -------------------------------------------------------------------------------------------
    -- Getting updates of storyboard named 'monitoredStoryboardName'
    -------------------------------------------------------------------------------------------
    if monitoredStoryboardName then
        
        -- Define methods related to storyboard updates only if a storyboard name is defined!
        
        local storyboardUpdatedMessage
        
        -------------------------------------------------------------------------------------------
        function ViewController:subscribeToStoryboardUpdates()
            -- Subscribe to the storyboard updates messages or replace the View Controller
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
            local storyboard = StoryboardMonitor:currentStoryboardWithName (monitoredStoryboardName)
            return (storyboard == nil) or ((self.storyboard == storyboard))
        end
        
        -------------------------------------------------------------------------------------------
        function ViewController:replaceInViewControllerHierarchyWithViewController (replacingViewController, replaceDoneHandler)
            
            local isReplaced = false
            
            if type(self.replaceWithViewController) == 'function' then
                -- A custom View Controller replacement method is defined for this View Controller: use it
                isReplaced = self:replaceWithViewController (replacingViewController)
                
            else
                -- Default replacing strategies depending on the kind of parent View Controller
                
                local parentViewController = self.parentViewController
                
                if parentViewController == nil then
                    -- check if this View Controller is the content View Controller of a window in this application
                    for window --[[@type objc.NSWindow]] in objc.NSApplication.sharedApplication.windows do
                        if window.contentViewController == self then
                            if self:isViewLoaded() then
                                -- preserve the window size by setting the replacing controller's view frame
                                replacingViewController.view.frame = self.view.frame
                            end
                            -- Replace self with updatedViewController as the window content View Controller
                            window.contentViewController = replacingViewController
                            isReplaced = true
                            break -- exit the for loop
                        end
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
        function ViewController:replaceForCurrentStoryboard()
            
            local isReplaced = false
            local storyboard = StoryboardMonitor:currentStoryboardWithName (monitoredStoryboardName)
            
            if storyboard and (self.storyboard ~= storyboard) then
                
                -- Instanciate a replacement ViewController using the current storyboard
                local replacementViewController = storyboard:instantiateControllerWithIdentifier (self.storyboardIdentifier or self.classname)
                if replacementViewController then
                    
                    -- Copy controller state data to the replacement View Controller
                    local controllerStateData = self:getViewControllerStateData()
                    if controllerStateData ~= nil then
                        replacementViewController:setViewControllerStateData (controllerStateData)
                    end
                    
                    -- Replace self with replacementViewController in the View Controller hierarchy
                    
                    local function replaceDoneHandler ()
                        -- Make replacementViewController subscribe to storyboard updates without waiting until viewDidLoad is called
                        replacementViewController:addMessageHandler(storyboardUpdatedMessage, 'replaceForCurrentStoryboard')
                        -- Stop monitoring updates in self
                        self:stopMonitoringUpdates()
                    end
                        
                    isReplaced = self:replaceInViewControllerHierarchyWithViewController (replacementViewController, replaceDoneHandler)
                end
            end
            
            return isReplaced
        end
        
        -------------------------------------------------------------------------------------------
        -- Subscribe to storyboard updates and get the corresponding notification mesage
        storyboardUpdatedMessage = StoryboardMonitor:monitorStoryboardWithName (monitoredStoryboardName)
    end
    
    -- Declare the class extension as complete
    class.endExtendClass(ViewController);    
end

-----------------------------------------------------------------------
-- This function encapsulates the creation of a Window Controller class extension that takes care of monitoring updates
-----------------------------------------------------------------------

local function monitorUpdatesInWindowControllerClass (WindowControllerClass --[[@type objc.NSWindowController]], monitoredStoryboardName, windowControllerStoryboardId)
    
    local WindowController = class.extendClass (WindowControllerClass, 'UpdatesMonitoring')
    
    -----------------------------------------------------------------------
    -- Overriding UIViewController standard methods
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
        -- Setup the View Controller and start monitoring updates if viewDidLoad has already been called
        if self.isWindowLoaded then
            self:configureForUpdates()
        end
        
        -- Propagate the Lua setup to the content View Controller?
        if type(self.contentViewController) == 'instance' then
            self.contentViewController:doLuaSetupIfNeeded()
        end
    end
    
    -------------------------------------------------------------------------------------------
    function WindowController:configureForUpdates()
        
        local isValidViewController = true
        
        if monitoredStoryboardName ~= nil then
            isValidViewController = self:subscribeToStoryboardUpdates()
        end
        
        if  isValidViewController then
            
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
    if monitoredStoryboardName then
        
        -- Define methods related to storyboard updates only if a storyboard name is defined!
        
        local storyboardUpdatedMessage
        
        -------------------------------------------------------------------------------------------
        function WindowController:subscribeToStoryboardUpdates()
            
            -- Do an initial update for the current storyboard and subscribe for storyboard update messages
            self:updateForCurrentStoryboard()
            self:addMessageHandler(storyboardUpdatedMessage, 'updateForCurrentStoryboard')
            
            return true -- subscription always succeeds for Window controllers
        end
        
        -------------------------------------------------------------------------------------------
        function WindowController:updateForCurrentStoryboard()
            
            local storyboard = StoryboardMonitor:currentStoryboardWithName (monitoredStoryboardName)
            
            if storyboard and (self.contentViewController.storyboard ~= storyboard) then
                
                local currentContentController = self.contentViewController
                
                -- Instanciate a replacement ViewController using the current storyboard
                local replacementContentController = storyboard:instantiateControllerWithIdentifier (currentContentController.storyboardIdentifier)
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
                    -- and stop monitoring updates in currentContentController
                    currentContentController:stopMonitoringUpdates()
                end
            end
        end
        
        -------------------------------------------------------------------------------------------
        -- Subscribe to storyboard updates and get the corresponding notification mesage
        storyboardUpdatedMessage = StoryboardMonitor:monitorStoryboardWithName (monitoredStoryboardName)
    end
    
    -- Declare the class extension as complete
    class.endExtendClass(WindowController);    
end

return monitorUpdatesInViewControllerClass, monitorUpdatesInWindowControllerClass, StoryboardMonitor
