-include Makefile.local
THEOS_DEVICE_PORT ?= 22
THEOS_DEVICE_USER ?= root

ifeq ($(SIMULATOR),1)
TARGET := simulator:clang::14.0
ARCHS = arm64
else
TARGET := iphone:clang:16.5:15.0
ARCHS = arm64e arm64
INSTALL_TARGET_PROCESSES = SpringBoard
endif

THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Oneko

Oneko_FILES = Oneko.m resources.m EdgeMap.m Tweak.xm
Oneko_CFLAGS = -include macros.h -Wno-deprecated-declarations
Tweak.xm_CFLAGS = -fobjc-arc
resources.m_CFLAGS = -fobjc-arc
EdgeMap.m_CFLAGS = -fobjc-arc -O2
Oneko_FRAMEWORKS = IOSurface

include $(THEOS_MAKE_PATH)/tweak.mk

before-all:: resources.m

resources.m: bundle.sh $(wildcard Resources/*.gif)
	./bundle.sh Resources/*.gif
