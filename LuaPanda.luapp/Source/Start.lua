-- This is the Lua module loaded from AppDelegate in the Xcode project

-- Start monitoring changes in storyboard "MainStoryboard"
local StoryboardMonitor = require 'StoryboardMonitor'
local mainStoryboardMonitor = StoryboardMonitor:named 'MainStoryboard'

-- Declare the Controller classes updated by this mainStoryboardMonitor
mainStoryboardMonitor:updateControllersOfClasses { objc.GameViewController }

-- Load class-specific Lua modules in the project
require "GameViewController"
