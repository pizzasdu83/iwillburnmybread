THEOS_PACKAGE_SCHEME = rootless

ARCHS = arm64
TARGET = iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = YouTubeMusic

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BetterLyricsYTM

BetterLyricsYTM_FILES = Tweak.x
BetterLyricsYTM_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
BetterLyricsYTM_FRAMEWORKS = UIKit Foundation QuartzCore MediaPlayer

include $(THEOS_MAKE_PATH)/tweak.mk
