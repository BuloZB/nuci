# This file contains configuration of the build. It may be generated by some
# script in the future.

# The RELATIVE variable is for the wrapper makefiles.
O := $(RELATIVE).
S := $(RELATIVE).
ASCIIDOC := asciidoc
AR := ar
LUAC := luac
MAX_LOG_LEVEL := LOG_DEBUG_VERBOSE
PAGE_SIZE := $(shell getconf PAGE_SIZE)
LUA_COMPILE := yes

ifeq ($(LUA_COMPILE),yes)
PLUGIN_PATH := $(abspath $(S))
else
PLUGIN_PATH := $(abspath $(S)/src)
endif

include $(S)/Makefile.dir

check:
	cd $(S) && make
	cd $(S) && valgrind -v ./bin/test_runner ./tests/editconfig_test.lua
	cd $(S) && ./tests/lua-test-all
	cd $(S) && valgrind -v ./bin/test_runner ./tests/stress2_xml.lua
	cd $(S) && valgrind -v ./bin/test_runner ./tests/stress_xml.lua
	cd $(S) && ./tests/full-test-all

.PHONY: check
