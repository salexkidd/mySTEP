#!/usr/bin/make -f
#
ifeq (nil,null)   ## this is to allow for the following text without special comment character considerations
#
# This file is part of mySTEP
#
# Last Change: $Id$
#
# You should not edit this file as it affects all projects you will compile!
#
# Copyright, H. Nikolaus Schaller <hns@computer.org>, 2003-2013
# This document is licenced using LGPL
#
# Requires Xcode 3.2 or later
# and Apple X11 incl. X11 SDK
#
# To use this makefile in Xcode with Xtoolchain:
#
#  1. open the xcode project
#  2. select the intended target in the Targets group
#  3. select from the menu Build/New Build Phase/New Shell Script Build Phase
#  4. select the "Shell Script Files" phase in the target
#  5. open the information (i) or (Apple-I)
#  6. copy the following code into the "Script" area

########################### start cut here ############################

# variables inherited from Xcode environment (or version.def)
# PROJECT_NAME
# PRODUCT_NAME						# e.g. Foundation
# WRAPPER_EXTENSION					# e.g. framework
# EXECUTABLE_NAME
# BUILT_PRODUCTS_DIR
# TARGET_BUILD_DIR

# project settings for cross-compiler (that can't be derived from the Xcode project)
export SOURCES=*.m                  # all source codes (no cross-compilation if empty)
export LIBS=						# add any additional libraries like -ltiff etc. (space separated list)
export FRAMEWORKS=					# add any additional Frameworks (e.g. AddressBook) etc. (adds -I and -L)
export INSTALL_PATH=/Applications   # override INSTALL_PATH for MacOS X for the embedded device
#export ADD_MAC_LIBRARY=			# true to store a copy in /Library/Frameworks on the build host (needed for demo apps)

# global/compile settings
#export INSTALL=true                # true (or empty) will install locally to $ROOT/$INSTALL_PATH
#export SEND2ZAURUS=true			# true (or empty) will try to install on the embedded device at /$INSTALL_PATH (using ssh)
#export RUN=true                    # true (or empty) will finally try to run on the embedded device (using X11 on host)
#export RUN_OPTIONS=-NoNSBackingStoreBuffered
#export BUILD_FOR_DEPLOYMENT=		# true to generate optimized code and strip binaries
#export	PREINST=./preinst			# preinst file
#export	POSTRM=./postrm				# postrm file

# Debian packages
export DEPENDS="quantumstep-cocoa-framework"	# debian package dependencies (, separated list)
# export DEBIAN_PACKAGE_NAME="quantumstep"	# manually define package name
# export FILES=""					# list of other files to be added to the package (relative to $ROOT)
# export DATA=""					# directory of other files to be added to the package (relative to /)
# export DEBIAN_PREINST=./preinst	# preinst file if needed
# export DEBIAN_POSTRM=./postrm		# postrm file if needed

# start make script
QuantumSTEP=/usr/share/QuantumSTEP /usr/bin/make -f $QuantumSTEP/System/Sources/Frameworks/mySTEP.make $ACTION

########################### end to cut here ###########################

#  7. change the SOURCES= line to include all required source files (e.g. main.m other/*.m)
#  8. change the LIBS= line to add any non-standard libraries (e.g. -lsqlite3)
#  9. Build the project (either in deployment or development mode)
#
endif

ROOT=$(QuantumSTEP)

include $(ROOT)/System/Sources/Frameworks/Version.def

.PHONY:	clean build build_architecture

ARCHITECTURES=arm-linux-gnueabi

ifeq ($(ARCHITECTURES),)
ifeq ($(BUILD_FOR_DEPLOYMENT),true)
# set all architectures for which we know a compiler (should also check that we have a libobjc.so for this architecture!)
# and that other libraries and include directories are available...
# should exclude i386-apple-darwin
ARCHITECTURES=$(shell cd $(ROOT)/System/Library/Frameworks/System.framework/Versions/Current/gcc && echo *-*-*)
endif
endif

ifeq ($(ARCHITECTURES),)	# try to read from ZMacSync
ARCHITECTURES:=$(shell defaults read de.dsitri.ZMacSync SelectedArchitecture 2>/dev/null)
endif

ifeq ($(ARCHITECTURES),)	# still not defined
ARCHITECTURES=i486-debianetch-linux-gnu
endif

# configure Embedded System if undefined

ifeq ($(EMBEDDED_ROOT),)
EMBEDDED_ROOT:=/usr/share/QuantumSTEP
endif

IP_ADDR:=$(shell defaults read de.dsitri.ZMacSync SelectedHost 2>/dev/null)

ifeq ($(IP_ADDR),)	# set a default
IP_ADDR:=192.168.129.201
endif

# FIXME: zaurusconnect (rename to zrsh) should simply know how to access the currently selected device

DOWNLOAD := $(QuantumSTEP)/System/Sources/System/Tools/ZMacSync/ZMacSync/build/Development/ZMacSync.app/Contents/MacOS/zaurusconnect -l 

ROOT:=$(QuantumSTEP)

# tools
# use platform specific cross-compiler
ifeq ($(ARCHITECTURE),arm-iPhone-darwin)
TOOLCHAIN=/Developer/Platforms/iPhoneOS.platform/Developer/usr
CC := $(TOOLCHAIN)/bin/arm-apple-darwin9-gcc-4.0.1
else
TOOLCHAIN := $(ROOT)/System/Library/Frameworks/System.framework/Versions/Current/gcc/$(ARCHITECTURE)
CC := $(TOOLCHAIN)/$(ARCHITECTURE)/bin/gcc
# CC := clang -march=armv7-a -mfloat-abi=soft -ccc-host-triple $(ARCHITECTURE) -integrated-as --sysroot $(ROOT) -I$(ROOT)/include
LD := $(TOOLCHAIN)/$(ARCHITECTURE)/bin/gcc -v -L$(TOOLCHAIN)/$(ARCHITECTURE)/lib -Wl,-rpath-link,$(TOOLCHAIN)/$(ARCHITECTURE)/lib

endif
LS := $(TOOLCHAIN)/bin/$(ARCHITECTURE)-ld
AS := $(TOOLCHAIN)/bin/$(ARCHITECTURE)-as
NM := $(TOOLCHAIN)/bin/$(ARCHITECTURE)-nm
STRIP := $(TOOLCHAIN)/bin/$(ARCHITECTURE)-strip
# TAR := tar

# disable special MacOS X stuff for tar
TAR := COPY_EXTENDED_ATTRIBUTES_DISABLED=true COPYFILE_DISABLE=true /usr/bin/gnutar
# TAR := $(TOOLS)/gnutar-1.13.25	# use older tar that does not know about ._ resource files
# TAR := $(ROOT)/this/bin/gnutar

# Xcode aggregate target
ifeq ($(PRODUCT_NAME),All)
PRODUCT_NAME=$(PROJECT_NAME)
endif
# if we call the makefile not within Xcode
ifeq ($(BUILT_PRODUCTS_DIR),)
BUILT_PRODUCTS_DIR=/tmp/$(PRODUCT_NAME)/
endif
ifeq ($(TARGET_BUILD_DIR),)
TARGET_BUILD_DIR=/tmp/$(PRODUCT_NAME)/
endif

## FIXME: handle meta packages without WRAPPER_EXTENSION; PRODUCT_NAME = "All" ?
## i.e. target type Aggregate

# define CONTENTS subdirectory as expected by the Foundation library

ifeq ($(WRAPPER_EXTENSION),)	# command line tool
	CONTENTS=.
	NAME_EXT=$(PRODUCT_NAME)
	PKG=$(BUILT_PRODUCTS_DIR)/$(ARCHITECTURE)/bin
	EXEC=$(PKG)
	BINARY=$(EXEC)/$(NAME_EXT)
	# architecture specific version (only if it does not yet have the prefix
ifneq (,$(findstring ///System/Library/Frameworks/System.framework/Versions/$(ARCHITECTURE),//$(INSTALL_PATH)))
	INSTALL_PATH := /System/Library/Frameworks/System.framework/Versions/$(ARCHITECTURE)$(INSTALL_PATH)
endif
else
ifeq ($(WRAPPER_EXTENSION),framework)	# framework
	CONTENTS=Versions/Current
	NAME_EXT=$(PRODUCT_NAME).$(WRAPPER_EXTENSION)
	PKG=$(BUILT_PRODUCTS_DIR)
	EXEC=$(PKG)/$(NAME_EXT)/$(CONTENTS)/$(ARCHITECTURE)
	BINARY=$(EXEC)/lib$(EXECUTABLE_NAME).so
	HEADERS=$(EXEC)/Headers/$(PRODUCT_NAME)
	CFLAGS := -I$(EXEC)/Headers/ $(CFLAGS)
	LDFLAGS := -shared -Wl,-soname,$(PRODUCT_NAME) $(LDFLAGS)
else
	CONTENTS=Contents
	NAME_EXT=$(PRODUCT_NAME).$(WRAPPER_EXTENSION)
	PKG=$(BUILT_PRODUCTS_DIR)
	EXEC=$(PKG)/$(NAME_EXT)/$(CONTENTS)/$(ARCHITECTURE)
	BINARY=$(EXEC)/$(EXECUTABLE_NAME)
ifeq ($(WRAPPER_EXTENSION),app)
	CFLAGS := -DFAKE_MAIN $(CFLAGS)	# application
else
	LDFLAGS := -shared -Wl,-soname,$(NAME_EXT) $(LDFLAGS)	# any other bundle
endif
endif
endif

ifeq ($(DEBIAN_ARCHITECTURES),)
DEBIAN_ARCHITECTURES=armel i386 mipsel
endif

build:
### check if meta package
### copy/install $DATA and $FILES
### use ARCHITECTURE=all
### build_deb (only)
### architecture all-packages are part of machine specific Packages.gz (!)
### there is not necessarily a special binary-all directory but we can do that

### FIXME: directly use the DEBIAN_ARCH names for everything

ifneq ($(DEBIAN_ARCHITECTURES),)
	# make for architectures $(DEBIAN_ARCHITECTURES)
	for DEBIAN_ARCH in $(DEBIAN_ARCHITECTURES); do \
		case "$$DEBIAN_ARCH" in \
			armel ) export ARCHITECTURE=arm-linux-gnueabi;; \
			armelhf ) export ARCHITECTURE=arm-linux-gnueabihf;; \
			i386 ) export ARCHITECTURE=i486-linux-gnu;; \
			mipsel ) export ARCHITECTURE=mipsel-linux-gnu;; \
			? ) export ARCHITECTURE=unknown-debian-linux-gnu;; \
		esac; \
		echo "*** building for $$DEBIAN_ARCH using xtc $$ARCHITECTURE ***"; \
		export DEBIAN_ARCH="$$DEBIAN_ARCH"; \
		make -f $(QuantumSTEP)/System/Sources/Frameworks/mySTEP.make build_deb; \
		done
endif
ifneq ($(ARCHITECTURES),)
	# make for architectures $(ARCHITECTURES)
	for ARCH in $(ARCHITECTURES); do \
		if [ "$$ARCH" = "i386-apple-darwin" ] ; then continue; fi; \
		echo "*** building for $$ARCH ***"; \
		export ARCHITECTURE="$$ARCH"; \
		export ARCHITECTURES="$$ARCHITECTURES"; \
		make -f $(QuantumSTEP)/System/Sources/Frameworks/mySTEP.make build_architecture; \
		done
endif

__dummy__:
	# dummy target to allow for comments while setting more make variables
	
	# override if (stripped) package is build using xcodebuild

ifeq ($(BUILD_FOR_DEPLOYMENT),true)
# ifneq ($(BUILD_STYLE),Development)
	# optimize for speed
OPTIMIZE := 2
	# should also remove headers and symbols
#	STRIP_Framework := true
	# remove MacOS X code
#	STRIP_MacOS := true
	# install in our file system so that we can build the package
INSTALL := true
	# don't send to the device
SEND2ZAURUS := false
	# and don't run
RUN := false
endif

	# default to optimize depending on BUILD_STYLE
ifeq ($(OPTIMIZE),)
ifeq ($(BUILD_STYLE),Development)
OPTIMIZE := s
else
OPTIMIZE := $(GCC_OPTIMIZATION_LEVEL)
endif
endif

# workaround for bug in arm-linux-gnueabi toolchain
ifeq ($(ARCHITECTURE),arm-linux-gnueabi)
OPTIMIZE := 3
# we could try -mfloat-abi=hardfp
# see https://wiki.linaro.org/Linaro-arm-hardfloat
CFLAGS += -fno-section-anchors -ftree-vectorize -mfpu=neon -mfloat-abi=softfp
endif

## FIXME: we need different prefix paths on compile host and embedded!
HOST_INSTALL_PATH := $(QuantumSTEP)/$(INSTALL_PATH)
## prefix by $ROOT unless starting with //
ifneq ($(findstring //,$(INSTALL_PATH)),//)
TARGET_INSTALL_PATH := $(EMBEDDED_ROOT)/$(INSTALL_PATH)
else
TARGET_INSTALL_PATH := $(INSTALL_PATH)
endif

# check if embedded device responds
ifneq ($(SEND2ZAURUS),false) # check if we can reach the device
ifneq "$(shell ping -qc 1 $(IP_ADDR) | fgrep '1 packets received' >/dev/null && echo yes)" "yes"
SEND2ZAURUS := false
RUN := false
endif
endif

# could better check ifeq ($(PRODUCT_TYPE),com.apple.product-type.framework)

# system includes&libraries and locate all standard frameworks

#		-I$(ROOT)/System/Library/Frameworks/System.framework/Versions/$(ARCHITECTURE)/usr/include/X11 \
# 		-I$(ROOT)/System/Library/Frameworks/System.framework/Versions/$(ARCHITECTURE)/usr/include \

INCLUDES := $(INCLUDES) \
		-I$(ROOT)/System/Library/Frameworks/System.framework/Versions/$(ARCHITECTURE)/usr/include/freetype2 \
		-I$(shell sh -c 'echo $(ROOT)/System/Library/*Frameworks/*.framework/Versions/Current/$(ARCHITECTURE)/Headers | sed "s/ / -I/g"') \
		-I$(shell sh -c 'echo $(ROOT)/Developer/Library/*Frameworks/*.framework/Versions/Current/$(ARCHITECTURE)/Headers | sed "s/ / -I/g"') \
		-I$(shell sh -c 'echo $(ROOT)/Library/*Frameworks/*.framework/Versions/Current/$(ARCHITECTURE)/Headers | sed "s/ / -I/g"')

# set up appropriate CFLAGS for $(ARCHITECTURE)

# -Wall
WARNINGS =  -Wno-shadow -Wpointer-arith -Wno-import

DEFINES = -DARCHITECTURE=@\"$(ARCHITECTURE)\" \
		-D__mySTEP__ \
		-DHAVE_MMAP

# add -v to debug include search path issues

CFLAGS := $(CFLAGS) \
		-g -O$(OPTIMIZE) -fPIC -rdynamic \
		$(WARNINGS) \
		$(DEFINES) \
		$(INCLUDES) \
		$(OTHER_CFLAGS)

ifeq ($(PROFILING),YES)
CFLAGS := -pg $(CFLAGS)
endif

# ifeq ($(GCC_WARN_ABOUT_MISSING_PROTOTYPES),YES)
# CFLAGS :=  -Wxyz $(CFLAGS)
# endif

# should be solved differently
ifneq ($(ARCHITECTURE),arm-zaurus-linux-gnu)
OBJCFLAGS := $(CFLAGS) -fconstant-string-class=NSConstantString -D_NSConstantStringClassName=NSConstantString
endif

# expand patterns in SOURCES
XSOURCES := $(wildcard $(SOURCES))

# get the objects from all sources we need to compile and link
OBJCSRCS   := $(filter %.m %.mm,$(XSOURCES))
CSRCS   := $(filter %.c %.cpp %x++,$(XSOURCES))
SRCOBJECTS := $(OBJCSRCS) $(CSRCS)
OBJECTS := $(SRCOBJECTS:%.m=$(TARGET_BUILD_DIR)/$(ARCHITECTURE)/+%.o)
OBJECTS := $(OBJECTS:%.mm=$(TARGET_BUILD_DIR)/$(ARCHITECTURE)/+%.o)
OBJECTS := $(OBJECTS:%.c=$(TARGET_BUILD_DIR)/$(ARCHITECTURE)/+%.o)
OBJECTS := $(OBJECTS:%.c++=$(TARGET_BUILD_DIR)/$(ARCHITECTURE)/+%.o)
OBJECTS := $(OBJECTS:%.cpp=$(TARGET_BUILD_DIR)/$(ARCHITECTURE)/+%.o)

RESOURCES := $(filter-out $(SRCOBJECTS),$(XSOURCES))	# all remaining (re)sources
SUBPROJECTS:= $(filter %.qcodrproj,$(RESOURCES))	# subprojects
# build them in a loop - if not globaly disabled
HEADERSRC := $(filter %.h,$(RESOURCES))	# header files
IMAGES := $(filter %.png %.jpg %.icns %.gif %.tiff,$(RESOURCES))	# image/icon files

ifeq ($(PRODUCT_NAME),Foundation)
FMWKS := $(addprefix -l,$(FRAMEWORKS))
else
ifeq ($(PRODUCT_NAME),AppKit)
FMWKS := $(addprefix -l,Foundation $(FRAMEWORKS))
else
ifneq ($(strip $(OBJCSRCS)),)	# any objective C source
FMWKS := $(addprefix -l,Foundation AppKit $(FRAMEWORKS))
endif
endif
endif

#		-L$(TOOLCHAIN)/lib \

LIBRARIES := \
		-L$(ROOT)/usr/lib \
		-Wl,-rpath-link,$(ROOT)/usr/lib \
		-L$(ROOT)/System/Library/Frameworks/System.framework/Versions/$(ARCHITECTURE)/usr/lib \
		-Wl,-rpath-link,$(ROOT)/System/Library/Frameworks/System.framework/Versions/$(ARCHITECTURE)/usr/lib \
		-L$(shell sh -c 'echo $(ROOT)/System/Library/*Frameworks/*.framework/Versions/Current/$(ARCHITECTURE) | sed "s/ / -L/g"') \
		-Wl,-rpath-link,$(shell sh -c 'echo $(ROOT)/System/Library/*Frameworks/*.framework/Versions/Current/$(ARCHITECTURE) | sed "s/ / -Wl,-rpath-link,/g"') \
		-L$(shell sh -c 'echo $(ROOT)/Developer/Library/*Frameworks/*.framework/Versions/Current/$(ARCHITECTURE) | sed "s/ / -L/g"') \
		-Wl,-rpath-link,$(shell sh -c 'echo $(ROOT)/Developer/Library/*Frameworks/*.framework/Versions/Current/$(ARCHITECTURE) | sed "s/ / -Wl,-rpath-link,/g"') \
		-L$(shell sh -c 'echo $(ROOT)/Library/*Frameworks/*.framework/Versions/Current/$(ARCHITECTURE) | sed "s/ / -L/g"') \
		-Wl,-rpath-link,$(shell sh -c 'echo $(ROOT)/Library/*Frameworks/*.framework/Versions/Current/$(ARCHITECTURE) | sed "s/ / -Wl,-rpath-link,/g"') \
		$(FMWKS) \
		$(LIBS)

.SUFFIXES : .o .c .m

# adding /+ to the file path looks strange but is to avoid problems with ../neighbour/source.m
# if someone knows how to easily substitute ../ by ++/ or .../ in TARGET_BUILD_DIR we could avoid some other minor problems
# FIXME: please use $(subst ...)

$(TARGET_BUILD_DIR)/$(ARCHITECTURE)/+%.o: %.m
	@- mkdir -p $(TARGET_BUILD_DIR)/$(ARCHITECTURE)/+$(*D)
	# compile $< -> $*.o
	$(CC) -c $(OBJCFLAGS) -E $< -o $(TARGET_BUILD_DIR)/$(ARCHITECTURE)/+$*.i	# store preprocessor result for debugging
	$(CC) -c $(OBJCFLAGS) -S $< -o $(TARGET_BUILD_DIR)/$(ARCHITECTURE)/+$*.S	# store assembler source for debugging
	$(CC) -c $(OBJCFLAGS) $< -o $(TARGET_BUILD_DIR)/$(ARCHITECTURE)/+$*.o

$(TARGET_BUILD_DIR)/$(ARCHITECTURE)/+%.o: %.c
	@- mkdir -p $(TARGET_BUILD_DIR)/$(ARCHITECTURE)/+$(*D)
	# compile $< -> $*.o
	$(CC) -c $(CFLAGS) $< -o $(TARGET_BUILD_DIR)/$(ARCHITECTURE)/+$*.o

#
# makefile targets
#

build_architecture: make_bundle make_exec make_binary make_php install_local install_tool install_remote launch_remote
	# $(BINARY) for $(ARCHITECTURE) built.
	date

make_bundle:

make_exec: "$(EXEC)"

ifneq ($(SRCOBJECTS),)
make_binary: "$(BINARY)"
	ls -l "$(BINARY)"
else
make_binary:
	# no sources - no binary
endif

make_php:
	for PHP in *.php Sources/*.php; do \
		if [ -r "$$PHP" ]; then mkdir -p "$(PKG)/$(NAME_EXT)/$(CONTENTS)/php" && cp "$$PHP" "$(PKG)/$(NAME_EXT)/$(CONTENTS)/php/"; fi; \
		done


#
# Debian package builder
# see http://www.debian.org/doc/debian-policy/ch-controlfields.html
#

# add default dependency

# FIXME: eigentlich sollte zu jedem mit mystep-/quantumstep- beginnenden Eintrag von "DEPENDS" ein >= $(VERSION) zugefuegt werden
# damit auch abhaengige Pakete einen Versions-Upgrade bekommen

ifeq ($(DEBIAN_PACKAGE_NAME),)
ifeq ($(WRAPPER_EXTENSION),)
DEBIAN_PACKAGE_NAME = $(shell echo "QuantumSTEP-$(PRODUCT_NAME)" | tr "[:upper:]" "[:lower:]")
else
DEBIAN_PACKAGE_NAME = $(shell echo "QuantumSTEP-$(PRODUCT_NAME)-$(WRAPPER_EXTENSION)" | tr "[:upper:]" "[:lower:]")
endif
endif

ifeq ($(DEBIAN_DESCRIPTION),)
DEBIAN_DESCRIPTION = "this is part of mySTEP/QuantumSTEP"
endif
ifeq ($(DEPENDS),)
DEPENDS := "quantumstep-cocoa-framework"
endif
ifeq ($(DEBIAN_SECTION),)
DEBIAN_SECTION = "x11"
endif
ifeq ($(DEBIAN_PRIORITY),)
DEBIAN_PRIORITY = "optional"
endif
ifeq ($(DEBIAN_VERSION),)
DEBIAN_VERSION := 0.$(shell date '+%Y%m%d%H%M%S' )
endif

DEBDIST="$(QuantumSTEP)/System/Installation/Debian/dists/staging/main"

# FIXME: allow to disable -dev and -dbg if we are marked "private"
build_deb: make_bundle make_exec make_binary install_tool \
	"$(DEBDIST)/binary-$(DEBIAN_ARCH)/$(DEBIAN_PACKAGE_NAME)_$(DEBIAN_VERSION)_$(DEBIAN_ARCH).deb" \
	"$(DEBDIST)/binary-$(DEBIAN_ARCH)/$(DEBIAN_PACKAGE_NAME)-dev_$(DEBIAN_VERSION)_$(DEBIAN_ARCH).deb" 

# FIXME: use different /tmp/data subdirectories for each running make
# NOTE: don't include /tmp here to protect against issues after typos

UNIQUE := mySTEP-$(shell date '+%Y%m%d%H%M%S')
TMP_DATA := $(UNIQUE)/data
TMP_CONTROL := $(UNIQUE)/control
TMP_DEBIAN_BINARY := $(UNIQUE)/debian-binary

"$(DEBDIST)/binary-$(DEBIAN_ARCH)/$(DEBIAN_PACKAGE_NAME)_$(DEBIAN_VERSION)_$(DEBIAN_ARCH).deb":
	# make debian package $(DEBIAN_PACKAGE_NAME)_$(DEBIAN_VERSION)_$(DEBIAN_ARCH).deb
	mkdir -p "$(DEBDIST)/binary-$(DEBIAN_ARCH)" "$(DEBDIST)/archive"
	- rm -rf "/tmp/$(TMP_DATA)"
	- mkdir -p "/tmp/$(TMP_DATA)/$(TARGET_INSTALL_PATH)"
ifneq ($(OBJECTS),)
	tar czf - --exclude .DS_Store --exclude .svn --exclude MacOS --exclude Headers -C "$(PKG)" $(NAME_EXT) | (mkdir -p "/tmp/$(TMP_DATA)/$(TARGET_INSTALL_PATH)" && cd "/tmp/$(TMP_DATA)/$(TARGET_INSTALL_PATH)" && tar xvzf -)
endif
ifneq ($(FILES),)
	tar czf - --exclude .DS_Store --exclude .svn --exclude MacOS --exclude Headers -C "$(PWD)" $(FILES) | (mkdir -p "/tmp/$(TMP_DATA)/$(TARGET_INSTALL_PATH)" && cd "/tmp/$(TMP_DATA)/$(TARGET_INSTALL_PATH)" && tar xvzf -)
endif
ifneq ($(DATA),)
	tar czf - --exclude .DS_Store --exclude .svn --exclude MacOS --exclude Headers -C "$(PWD)" $(DATA) | (cd "/tmp/$(TMP_DATA)/" && tar xvzf -)
endif
	# strip all executables down to the minimum
	find "/tmp/$(TMP_DATA)" "(" -name '*-*-linux-gnu*' ! -name $(ARCHITECTURE) ")" -prune -print -exec rm -rf {} ";"
	find "/tmp/$(TMP_DATA)" -name '*php' -prune -print -exec rm -rf {} ";"
ifeq ($(WRAPPER_EXTENSION),framework)
	# strip MacOS X binary for frameworks
	rm -rf "/tmp/$(TMP_DATA)/$(TARGET_INSTALL_PATH)/$(NAME_EXT)/$(CONTENTS)/$(PRODUCT_NAME)"
	rm -rf "/tmp/$(TMP_DATA)/$(TARGET_INSTALL_PATH)/$(NAME_EXT)/$(PRODUCT_NAME)"
endif
	find "/tmp/$(TMP_DATA)" -type f -perm +a+x -exec $(STRIP) {} \;
	mkdir -p "/tmp/$(TMP_DATA)/$(EMBEDDED_ROOT)/Library/Receipts" && echo $(DEBIAN_VERSION) >"/tmp/$(TMP_DATA)/$(EMBEDDED_ROOT)/Library/Receipts/$(DEBIAN_PACKAGE_NAME)_@_$(DEBIAN_ARCH).deb"
	$(TAR) czf "/tmp/$(TMP_DATA).tar.gz" --owner 0 --group 0 -C "/tmp/$(TMP_DATA)" .
	ls -l "/tmp/$(TMP_DATA).tar.gz"
	echo "2.0" >"/tmp/$(TMP_DEBIAN_BINARY)"
	( echo "Package: $(DEBIAN_PACKAGE_NAME)"; \
	  echo "Section: $(DEBIAN_SECTION)"; \
	  echo "Priority: $(DEBIAN_PRIORITY)"; \
	  [ "$(DEBIAN_REPLACES)" ] && echo "Replaces: $(DEBIAN_REPLACES)"; \
	  echo "Version: $(DEBIAN_VERSION)"; \
	  echo "Architecture: $(DEBIAN_ARCH)"; \
	  echo "Maintainer: info@goldelico.com"; \
	  echo "Homepage: http://www.quantum-step.com"; \
	  echo "Installed-Size: `du -kHs /tmp/$(TMP_DATA) | cut -f1`"; \
	  [ "$(DEPENDS)" ] && echo "Depends: $(DEPENDS)"; \
	  echo "Description: $(DEBIAN_DESCRIPTION)"; \
	) >"/tmp/$(TMP_CONTROL)"
	$(TAR) czf /tmp/$(TMP_CONTROL).tar.gz $(DEBIAN_CONTROL) --owner 0 --group 0 -C /tmp/$(UNIQUE) ./control
	- mv -f "$(DEBDIST)/binary-$(DEBIAN_ARCH)/$(DEBIAN_PACKAGE_NAME)_"*"_$(DEBIAN_ARCH).deb" "$(DEBDIST)/archive" 2>/dev/null
	- rm -rf $@
	ar -r -cSv $@ /tmp/$(TMP_DEBIAN_BINARY) /tmp/$(TMP_CONTROL).tar.gz /tmp/$(TMP_DATA).tar.gz
	ls -l $@

"$(DEBDIST)/binary-$(DEBIAN_ARCH)/$(DEBIAN_PACKAGE_NAME)-dev_$(DEBIAN_VERSION)_$(DEBIAN_ARCH).deb":
	# FIXME: make also dependent on location (i.e. public */Frameworks/ only)
ifeq ($(WRAPPER_EXTENSION),framework)
	# make debian development package
	mkdir -p "$(DEBDIST)/binary-$(DEBIAN_ARCH)" "$(DEBDIST)/archive"
	- rm -rf /tmp/$(TMP_DATA)
	- mkdir -p "/tmp/$(TMP_DATA)/$(TARGET_INSTALL_PATH)"
	# don't exclude Headers
	tar czf - --exclude .DS_Store --exclude .svn --exclude MacOS -C "$(PKG)" $(NAME_EXT) | (mkdir -p "/tmp/$(TMP_DATA)/$(TARGET_INSTALL_PATH)" && cd "/tmp/$(TMP_DATA)/$(TARGET_INSTALL_PATH)" && tar xvzf -)
	# strip all executables down so that they can be linked
	find /tmp/$(TMP_DATA) -name '*-*-linux-gnu*' ! -name $(ARCHITECTURE) -exec rm -rf {} ";" -prune
	rm -rf /tmp/$(TMP_DATA)/$(TARGET_INSTALL_PATH)/$(NAME_EXT)/$(CONTENTS)/$(PRODUCT_NAME)
	rm -rf /tmp/$(TMP_DATA)/$(TARGET_INSTALL_PATH)/$(NAME_EXT)/$(PRODUCT_NAME)
	find /tmp/$(TMP_DATA) -type f -perm +a+x -exec $(STRIP) {} \;
	mkdir -p /tmp/$(TMP_DATA)/$(EMBEDDED_ROOT)/Library/Receipts && echo $(DEBIAN_VERSION) >/tmp/$(TMP_DATA)/$(EMBEDDED_ROOT)/Library/Receipts/$(DEBIAN_PACKAGE_NAME)-dev_@_$(DEBIAN_ARCH).deb
	$(TAR) czf /tmp/$(TMP_DATA).tar.gz --owner 0 --group 0 -C /tmp/$(TMP_DATA) .
	ls -l /tmp/$(TMP_DATA).tar.gz
	echo "2.0" >"/tmp/$(TMP_DEBIAN_BINARY)"
	( echo "Package: $(DEBIAN_PACKAGE_NAME)-dev"; \
	  echo "Section: $(DEBIAN_SECTION)"; \
	  echo "Priority: extra"; \
	  echo "Version: $(DEBIAN_VERSION)"; \
	  echo "Replaces: $(DEBIAN_PACKAGE_NAME)"; \
	  echo "Architecture: $(DEBIAN_ARCH)"; \
	  echo "Maintainer: info@goldelico.com"; \
	  echo "Homepage: http://www.quantum-step.com"; \
	  echo "Installed-Size: `du -kHs /tmp/$(TMP_DATA) | cut -f1`"; \
	  [ "$(DEPENDS)" ] && echo "Depends: $(DEPENDS)"; \
	  echo "Description: $(DEBIAN_DESCRIPTION)"; \
	) >"/tmp/$(TMP_CONTROL)"
	$(TAR) czf /tmp/$(TMP_CONTROL).tar.gz $(DEBIAN_CONTROL) --owner 0 --group 0 -C /tmp/$(UNIQUE) ./control
	- rm -rf $@
	- mv -f "$(DEBDIST)/binary-$(DEBIAN_ARCH)/$(DEBIAN_PACKAGE_NAME)-dev_"*"_$(DEBIAN_ARCH).deb" "$(DEBDIST)/archive" 2>/dev/null
	ar -r -cSv $@ /tmp/$(TMP_DEBIAN_BINARY) /tmp/$(TMP_CONTROL).tar.gz /tmp/$(TMP_DATA).tar.gz
	ls -l $@
else
	# no development version
endif

install_local:
ifeq ($(ADD_MAC_LIBRARY),true)
	# install locally in /Library/Frameworks
	- $(TAR) czf - --exclude .svn -C "$(PKG)" "$(NAME_EXT)" | (cd '/Library/Frameworks' && (pwd; rm -rf "$(NAME_EXT)" ; $(TAR) xpzvf -))
else
	# don't install local
endif
	
install_tool:
ifneq ($(OBJECTS),)
ifneq ($(INSTALL),false)
	$(TAR) czf - --exclude .svn -C "$(PKG)" "$(NAME_EXT)" | (mkdir -p '$(HOST_INSTALL_PATH)' && cd '$(HOST_INSTALL_PATH)' && (pwd; rm -rf "$(NAME_EXT)" ; $(TAR) xpzvf -))
	# installed on localhost at $(HOST_INSTALL_PATH)
else
	# don't install tool
endif
endif

install_remote:
ifneq ($(OBJECTS),)
ifneq ($(SEND2ZAURUS),false)
	ls -l "$(BINARY)"
	- $(TAR) czf - --exclude .svn --exclude MacOS --owner 500 --group 1 -C "$(PKG)" "$(NAME_EXT)" | $(DOWNLOAD) "cd; mkdir -p '$(TARGET_INSTALL_PATH)' && cd '$(TARGET_INSTALL_PATH)' && gunzip | tar xpvf -"
	# installed on $(IP_ADDR) at $(TARGET_INSTALL_PATH)
else
	# don't install on $(IP_ADDR)
endif
endif

launch_remote:
ifneq ($(OBJECTS),)
ifneq ($(SEND2ZAURUS),false)
ifneq ($(RUN),false)
ifeq ($(WRAPPER_EXTENSION),app)
	# try to launch $(RUN) Application
	: defaults write com.apple.x11 nolisten_tcp false; \
	defaults write org.x.X11 nolisten_tcp 0; \
	rm -rf /tmp/.X0-lock /tmp/.X11-unix; open -a X11; sleep 5; \
	export DISPLAY=localhost:0.0; [ -x /usr/X11R6/bin/xhost ] && /usr/X11R6/bin/xhost +$(IP_ADDR) && \
	$(DOWNLOAD) \
		"cd; set; export QuantumSTEP=$(EMBEDDED_ROOT); export PATH=\$$PATH:$(EMBEDDED_ROOT)/usr/bin; export LOGNAME=$(LOGNAME); export NSLog=yes; export HOST=\$$(expr \"\$$SSH_CONNECTION\" : '\\(.*\\) .* .* .*'); export DISPLAY=\$$HOST:0.0; set; export EXECUTABLE_PATH=Contents/$(ARCHITECTURE); cd '$(TARGET_INSTALL_PATH)' && run '$(PRODUCT_NAME)' $(RUN_OPTIONS)" || echo failed to run;
endif		
endif
endif
endif

clean:
	# ignored

# generic bundle rule

### add rules or code to copy the Info.plist and Resources if not done by Xcode
### so that this makefile can be used independently of Xcode to create full bundles

# FIXME: use dependencies to link only if any object file has changed

"$(BINARY)":: $(OBJECTS)
	# link $(SRCOBJECTS) -> $(OBJECTS) -> $(BINARY)
	@mkdir -p "$(EXEC)"
	$(LD) $(LDFLAGS) -o "$(BINARY)" $(OBJECTS) $(LIBRARIES)
	# compiled.

# link headers of framework

headers:
ifeq ($(WRAPPER_EXTENSION),framework)
ifneq ($(strip $(HEADERSRC)),)
	# included header files $(HEADERSRC)
	- (mkdir -p "$(PKG)/$(NAME_EXT)/$(CONTENTS)/Headers" && cp $(HEADERSRC) "$(PKG)/$(NAME_EXT)/$(CONTENTS)/Headers" )	# copy headers
endif
	- (mkdir -p "$(EXEC)/Headers" && ln -sf ../../Headers "$(HEADERS)")	# link to headers to find <Framework/File.h>
endif

"$(EXEC)":: headers
	# make directory for Linux executable
	# SUBPROJECTS: $(SUBPROJECTS)
	# SRCOBJECTS: $(SRCOBJECTS)
	# OBJCSRCS: $(OBJCSRCS)
	# HEADERS: $(HEADERSRC)
	# RESOURCES: $(RESOURCES)
	# OBJECTS: $(OBJECTS)
	mkdir -p "$(EXEC)"
ifeq ($(WRAPPER_EXTENSION),framework)
	# link shared library for frameworks
	- rm -f $(PKG)/$(NAME_EXT)/$(CONTENTS)/$(ARCHITECTURE)/$(EXECUTABLE_NAME)
	- ln -sf lib$(EXECUTABLE_NAME).so $(PKG)/$(NAME_EXT)/$(CONTENTS)/$(ARCHITECTURE)/$(EXECUTABLE_NAME)	# create libXXX.so entry for ldconfig
endif

# EOF