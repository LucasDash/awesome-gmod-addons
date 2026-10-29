if not SERVER then return end

MotionMatching = MotionMatching or {}
MotionMatching.API_VERSION = 1
MotionMatching.VERSION = "0.1.0"
MotionMatching.Matcher = include("motion_matching/matcher.lua")
