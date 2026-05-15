TARGET := iphone:clang:latest:16.0
INSTALL_TARGET_PROCESSES = SpringBoard ProxySwitcher

THEOS_PACKAGE_SCHEME ?= rootless
PACKAGE_BUILDNAME ?=
export CLANG_MODULE_CACHE_PATH ?= $(CURDIR)/.theos/module-cache
# Keep version stable for the same source version; do not auto-increment build numbers.
PACKAGE_VERSION = $(THEOS_PACKAGE_BASE_VERSION)$(VERSION.EXTRAVERSION)
PROXYSWITCHER_APP_ONLY ?= 0
ifeq ($(PROXYSWITCHER_APP_ONLY),1)
ARCHS = arm64
else
ARCHS = arm64 arm64e
endif

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = ProxySwitcher
ProxySwitcher_FILES = App/main.m App/PSAppDelegate.m App/PSRootViewController.m Shared/PSProxyManager.m
ProxySwitcher_FRAMEWORKS = UIKit SystemConfiguration NetworkExtension
ProxySwitcher_CFLAGS = -fobjc-arc -IShared -DPROXYSWITCHER_APP_CLIENT=1
ProxySwitcher_BUNDLE_ID = codes.var.tweak.proxyswitcher
ifeq ($(PROXYSWITCHER_APP_ONLY),1)
ProxySwitcher_CFLAGS += -DPROXYSWITCHER_APP_ONLY=1
ProxySwitcher_CODESIGN_FLAGS = -Cadhoc -SEntitlements/nonjailbreak-app.plist
else
ProxySwitcher_CODESIGN_FLAGS = -SEntitlements/jailbreak.plist
endif
ProxySwitcher_RESOURCE_FILES = App/Info.plist App/AppIcon60x60@2x.png App/AppIcon60x60@3x.png
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
ProxySwitcher_LIBRARIES = roothide
endif

include $(THEOS_MAKE_PATH)/application.mk

APPEX_NAME = ProxySwitcherTunnel
ProxySwitcherTunnel_BUNDLE_NAME = ProxySwitcherTunnel
ProxySwitcherTunnel_FILES = Tunnel/PacketTunnelProvider.m
ProxySwitcherTunnel_FRAMEWORKS = Foundation NetworkExtension
ProxySwitcherTunnel_EXTRA_FRAMEWORKS = SystemConfiguration
ProxySwitcherTunnel_INSTALL_PATH = /Applications/ProxySwitcher.app/PlugIns
ProxySwitcherTunnel_CFLAGS = -fobjc-arc -ITunnel
ProxySwitcherTunnel_OBJ_FILES = Tunnel/libproxyswitcher_tun2http.a
ifeq ($(PROXYSWITCHER_APP_ONLY),1)
ProxySwitcherTunnel_CODESIGN_FLAGS = -Cadhoc -SEntitlements/nonjailbreak-tunnel.plist
else
ProxySwitcherTunnel_CODESIGN_FLAGS = -SEntitlements/jailbreak.plist
endif
ProxySwitcherTunnel_RESOURCE_FILES = Tunnel/Info.plist

include $(THEOS_MAKE_PATH)/appex.mk

before-all::
	$(ECHO_NOTHING)./scripts/prepare-tun2http-ios.sh$(ECHO_END)

ifeq ($(PROXYSWITCHER_APP_ONLY),0)
BUNDLE_NAME = ProxySwitcherCC
ProxySwitcherCC_BUNDLE_EXTENSION = bundle
ProxySwitcherCC_FILES = ControlCenter/PSCCModule.m ControlCenter/PSCCMenuViewController.m Shared/PSProxyManager.m
ProxySwitcherCC_FRAMEWORKS = UIKit SystemConfiguration NetworkExtension
ProxySwitcherCC_INSTALL_PATH = /Library/ControlCenter/Bundles
ProxySwitcherCC_CFLAGS = -fobjc-arc -IShared -IControlCenter -DPROXYSWITCHER_APP_CLIENT=1
ProxySwitcherCC_LDFLAGS = -undefined dynamic_lookup
ProxySwitcherCC_CODESIGN_FLAGS = -SEntitlements/jailbreak.plist
ProxySwitcherCC_RESOURCE_FILES = ControlCenter/Info.plist ControlCenter/ProxySwitcherCCGlyph.png ControlCenter/ProxySwitcherCCGlyph@2x.png ControlCenter/ProxySwitcherCCGlyph@3x.png
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
ProxySwitcherCC_LIBRARIES = roothide
endif

include $(THEOS_MAKE_PATH)/bundle.mk

TOOL_NAME = proxyswitcherctl
proxyswitcherctl_FILES = Helper/main.m Shared/PSProxyManager.m
proxyswitcherctl_FRAMEWORKS = Foundation SystemConfiguration NetworkExtension
proxyswitcherctl_CFLAGS = -fobjc-arc -IShared -DPROXYSWITCHER_HELPER=1 -DPROXYSWITCHER_APP_CLIENT=1
proxyswitcherctl_CODESIGN_FLAGS = -SEntitlements/jailbreak.plist
proxyswitcherctl_INSTALL_PATH = /usr/bin
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
proxyswitcherctl_LIBRARIES = roothide
endif

include $(THEOS_MAKE_PATH)/tool.mk
endif

after-install::
	install.exec "sbreload"

before-package::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/DEBIAN"$(ECHO_END)
ifeq ($(PROXYSWITCHER_APP_ONLY),0)
	$(ECHO_NOTHING)cp "layout/DEBIAN/postinst" "$(THEOS_STAGING_DIR)/DEBIAN/postinst"$(ECHO_END)
	$(ECHO_NOTHING)chmod 0755 "$(THEOS_STAGING_DIR)/DEBIAN/postinst"$(ECHO_END)
endif

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

.PHONY: package-nonjailbreak
package-nonjailbreak:
	$(MAKE) clean
	$(MAKE) all THEOS_PACKAGE_SCHEME=rootless PROXYSWITCHER_APP_ONLY=1 APPLICATION_NAME=ProxySwitcher APPEX_NAME=ProxySwitcherTunnel
	$(ECHO_NOTHING)mkdir -p packages$(ECHO_END)
	$(ECHO_NOTHING)rm -rf "$(THEOS_OBJ_DIR)/ipa"$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p "$(THEOS_OBJ_DIR)/ipa/Payload"$(ECHO_END)
	$(ECHO_NOTHING)cp -R "$(THEOS_OBJ_DIR)/$(APPLICATION_NAME).app" "$(THEOS_OBJ_DIR)/ipa/Payload/"$(ECHO_END)
	$(ECHO_NOTHING)rm -rf "$(THEOS_OBJ_DIR)/ipa/Payload/$(APPLICATION_NAME).app/PlugIns/ProxySwitcherTunnel.appex"$(ECHO_END)
	$(ECHO_NOTHING)if [ -d "$(THEOS_OBJ_DIR)/ProxySwitcherTunnel.appex" ]; then \
		mkdir -p "$(THEOS_OBJ_DIR)/ipa/Payload/$(APPLICATION_NAME).app/PlugIns"; \
		cp -R "$(THEOS_OBJ_DIR)/ProxySwitcherTunnel.appex" "$(THEOS_OBJ_DIR)/ipa/Payload/$(APPLICATION_NAME).app/PlugIns/"; \
	elif [ -d "$(THEOS_OBJ_DIR)/debug/ProxySwitcherTunnel.appex" ]; then \
		mkdir -p "$(THEOS_OBJ_DIR)/ipa/Payload/$(APPLICATION_NAME).app/PlugIns"; \
		cp -R "$(THEOS_OBJ_DIR)/debug/ProxySwitcherTunnel.appex" "$(THEOS_OBJ_DIR)/ipa/Payload/$(APPLICATION_NAME).app/PlugIns/"; \
	fi$(ECHO_END)
	$(ECHO_NOTHING)rm -f "$(CURDIR)/packages/$(APPLICATION_NAME)_$(PACKAGE_VERSION)_nonjailbreak.ipa"$(ECHO_END)
	$(ECHO_NOTHING)cd "$(THEOS_OBJ_DIR)/ipa" && zip -qry "$(CURDIR)/packages/$(APPLICATION_NAME)_$(PACKAGE_VERSION)_nonjailbreak.ipa" Payload$(ECHO_END)

.PHONY: package-app-only-rootless
package-app-only-rootless: package-nonjailbreak

install-rootful:
	$(MAKE) all install THEOS_PACKAGE_SCHEME=rootful

install-rootless:
	$(MAKE) all install THEOS_PACKAGE_SCHEME=rootless

install-roothide:
	$(MAKE) all install THEOS_PACKAGE_SCHEME=roothide THEOS_PACKAGE_INSTALL_PREFIX=
