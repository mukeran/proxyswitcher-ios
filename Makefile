ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:16.0
INSTALL_TARGET_PROCESSES = SpringBoard ProxySwitcher

THEOS_PACKAGE_SCHEME ?= rootless
PACKAGE_BUILDNAME ?=
export CLANG_MODULE_CACHE_PATH ?= $(CURDIR)/.theos/module-cache
# Keep version stable for the same source version; do not auto-increment build numbers.
PACKAGE_VERSION = $(THEOS_PACKAGE_BASE_VERSION)$(VERSION.EXTRAVERSION)

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = ProxySwitcher
ProxySwitcher_FILES = App/main.m App/PSAppDelegate.m App/PSRootViewController.m Shared/PSProxyManager.m
ProxySwitcher_FRAMEWORKS = UIKit SystemConfiguration
ProxySwitcher_CFLAGS = -fobjc-arc -IShared
ProxySwitcher_CODESIGN_FLAGS = -Sentitlements.plist
ProxySwitcher_RESOURCE_FILES = App/Info.plist App/AppIcon60x60@2x.png App/AppIcon60x60@3x.png
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
ProxySwitcher_LIBRARIES = roothide
endif

include $(THEOS_MAKE_PATH)/application.mk

BUNDLE_NAME = ProxySwitcherCC
ProxySwitcherCC_BUNDLE_EXTENSION = bundle
ProxySwitcherCC_FILES = ControlCenter/PSCCModule.m ControlCenter/PSCCMenuViewController.m Shared/PSProxyManager.m
ProxySwitcherCC_FRAMEWORKS = UIKit SystemConfiguration
ProxySwitcherCC_INSTALL_PATH = /Library/ControlCenter/Bundles
ProxySwitcherCC_CFLAGS = -fobjc-arc -IShared -IControlCenter
ProxySwitcherCC_LDFLAGS = -undefined dynamic_lookup
ProxySwitcherCC_CODESIGN_FLAGS = -Sentitlements.plist
ProxySwitcherCC_RESOURCE_FILES = ControlCenter/Info.plist ControlCenter/ProxySwitcherCCGlyph.png ControlCenter/ProxySwitcherCCGlyph@2x.png ControlCenter/ProxySwitcherCCGlyph@3x.png
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
ProxySwitcherCC_LIBRARIES = roothide
endif

include $(THEOS_MAKE_PATH)/bundle.mk

TOOL_NAME = proxyswitcherctl
proxyswitcherctl_FILES = Helper/main.m Shared/PSProxyManager.m
proxyswitcherctl_FRAMEWORKS = Foundation SystemConfiguration
proxyswitcherctl_CFLAGS = -fobjc-arc -IShared -DPROXYSWITCHER_HELPER=1
proxyswitcherctl_CODESIGN_FLAGS = -Sentitlements.plist
proxyswitcherctl_INSTALL_PATH = /usr/bin
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
proxyswitcherctl_LIBRARIES = roothide
endif

include $(THEOS_MAKE_PATH)/tool.mk

after-install::
	install.exec "sbreload"

before-package::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/DEBIAN"$(ECHO_END)
	$(ECHO_NOTHING)cp "layout/DEBIAN/postinst" "$(THEOS_STAGING_DIR)/DEBIAN/postinst"$(ECHO_END)
	$(ECHO_NOTHING)chmod 0755 "$(THEOS_STAGING_DIR)/DEBIAN/postinst"$(ECHO_END)

.PHONY: rename-package-rootless rename-package-roothide

define rename_package_with_scheme
	@pkg=$$(ls -t packages/*.deb 2>/dev/null | head -n 1); \
	if [ -n "$$pkg" ]; then \
		case "$$pkg" in \
			*_$(1)_iphoneos-*.deb) ;; \
			*) \
				new=$$(printf '%s\n' "$$pkg" | sed 's/_iphoneos-/_$(1)_iphoneos-/'); \
				if [ "$$pkg" != "$$new" ]; then \
					mv "$$pkg" "$$new"; \
					echo "Renamed package: $$new"; \
				fi; \
				;; \
		esac; \
	fi
endef

rename-package-rootless:
	$(call rename_package_with_scheme,rootless)

rename-package-roothide:
	$(call rename_package_with_scheme,roothide)

.PHONY: package-rootful package-rootless package-roothide install-rootful install-rootless install-roothide

package-rootful:
	$(MAKE) all package THEOS_PACKAGE_SCHEME=rootful

package-rootless:
	$(MAKE) all package THEOS_PACKAGE_SCHEME=rootless
	$(MAKE) rename-package-rootless

package-roothide:
	$(MAKE) all package THEOS_PACKAGE_SCHEME=roothide THEOS_PACKAGE_INSTALL_PREFIX=
	$(MAKE) rename-package-roothide

install-rootful:
	$(MAKE) all install THEOS_PACKAGE_SCHEME=rootful

install-rootless:
	$(MAKE) all install THEOS_PACKAGE_SCHEME=rootless

install-roothide:
	$(MAKE) all install THEOS_PACKAGE_SCHEME=roothide THEOS_PACKAGE_INSTALL_PREFIX=
