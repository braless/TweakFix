export ARCHS = arm64 arm64e
export TARGET = iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Tweakfix
Tweakfix_FILES = Tweak.xm
Tweakfix_CFLAGS = -fobjc-arc -Wno-arc-performSelector-leaks -Wno-arc-retain-cycles
Tweakfix_FRAMEWORKS = UIKit AVFoundation Security

include $(THEOS_MAKE_PATH)/tweak.mk
