CROSS_CXX ?= x86_64-w64-mingw32-g++
WINDRES ?= x86_64-w64-mingw32-windres
MAKENSIS ?= makensis
HOST_CXX ?= g++
PYTHON ?= python3
STRIP ?= x86_64-w64-mingw32-strip
FLAGS = -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -municode -mwindows -static -static-libgcc -static-libstdc++ -D_WIN32_WINNT=0x0A00 -DWINVER=0x0A00 -DUNICODE -D_UNICODE
LIBS = -lcomctl32 -lcomdlg32 -ldwmapi -lwtsapi32 -lwinmm -lgdiplus -lshell32 -lole32 -luuid -ladvapi32 -luxtheme -lwinhttp -lversion
.PHONY: all test package gui-test clean
all: test release/EyeBreakReminder.exe
release:
	mkdir -p release
release/resources.o: src/resources.rc src/app.manifest $(wildcard assets/*.ico assets/*.wav) | release
	$(WINDRES) src/resources.rc -O coff -o $@
release/EyeBreakReminder.exe: src/app.cpp src/core.hpp src/theme.hpp src/update_checker.hpp src/windows_services.hpp release/resources.o
	$(CROSS_CXX) $(FLAGS) src/app.cpp release/resources.o -o $@ $(LIBS) -Wl,--dynamicbase,--nxcompat,--high-entropy-va
	$(STRIP) $@
build/gui-test:
	mkdir -p $@
build/gui-test/EyeBreakReminder.exe: src/app.cpp src/core.hpp src/theme.hpp src/update_checker.hpp src/windows_services.hpp release/resources.o | build/gui-test
	$(CROSS_CXX) $(FLAGS) -DEYEBREAK_TEST_BUILD src/app.cpp release/resources.o -o $@ $(LIBS) -Wl,--dynamicbase,--nxcompat,--high-entropy-va
	$(STRIP) $@
gui-test: build/gui-test/EyeBreakReminder.exe
tests/core-tests: tests/core_tests.cpp src/core.hpp
	$(HOST_CXX) -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror $< -o $@
test: tests/core-tests
	./tests/core-tests
release/EyeBreakReminder-Setup-x64.exe: release/EyeBreakReminder.exe installer/setup.nsi README.md docs/PRIVACY.md docs/VERIFICATION.md
	$(MAKENSIS) -NOCD installer/setup.nsi
package: all release/EyeBreakReminder-Setup-x64.exe
	$(PYTHON) scripts/package.py
	$(PYTHON) scripts/verify.py
clean:
	rm -f release/*.exe release/*.o release/*.zip release/EyeBreakReminder-SHA256.txt tests/core-tests
