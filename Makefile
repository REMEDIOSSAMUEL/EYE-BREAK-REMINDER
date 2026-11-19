CROSS_CXX ?= x86_64-w64-mingw32-g++
WINDRES ?= x86_64-w64-mingw32-windres
MAKENSIS ?= makensis
HOST_CXX ?= g++
PYTHON ?= python3
STRIP ?= x86_64-w64-mingw32-strip
UPDATER_SMOKE_ARGS ?=
FLAGS = -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -municode -mwindows -static -static-libgcc -static-libstdc++ -D_WIN32_WINNT=0x0A00 -DWINVER=0x0A00 -DUNICODE -D_UNICODE
LIBS = -lcomctl32 -lcomdlg32 -ldwmapi -lwtsapi32 -lwinmm -lgdiplus -lshell32 -lole32 -loleaut32 -luuid -ladvapi32 -luxtheme -lwinhttp -lversion -lbcrypt
.PHONY: all test package gui-test updater-metadata-test package-source-policy-test updater-windows-test updater-test-artifacts github-updater-smoke clean
all: test release/EyeBreakReminder.exe
release:
	mkdir -p release
build:
	mkdir -p build
release/resources.o: src/resources.rc src/app.manifest $(wildcard assets/*.ico assets/*.wav) | release
	$(WINDRES) src/resources.rc -O coff -o $@
release/EyeBreakReminder.exe: src/app.cpp src/core.hpp src/theme.hpp src/update_checker.hpp src/update_client.hpp src/update_coordinator.hpp src/update_accessibility.hpp src/windows_services.hpp release/resources.o
	$(CROSS_CXX) $(FLAGS) src/app.cpp release/resources.o -o $@ $(LIBS) -Wl,--dynamicbase,--nxcompat,--high-entropy-va,--no-insert-timestamp
	$(STRIP) --preserve-dates $@
build/gui-test: | build
	mkdir -p $@
build/gui-test/EyeBreakReminder.exe: src/app.cpp src/core.hpp src/theme.hpp src/update_checker.hpp src/update_client.hpp src/update_coordinator.hpp src/update_accessibility.hpp src/windows_services.hpp release/resources.o | build/gui-test
	$(CROSS_CXX) $(FLAGS) -DEYEBREAK_TEST_BUILD src/app.cpp release/resources.o -o $@ $(LIBS) -Wl,--dynamicbase,--nxcompat,--high-entropy-va,--no-insert-timestamp
	$(STRIP) --preserve-dates $@
gui-test: build/gui-test/EyeBreakReminder.exe
build/github-updater-smoke.exe: tests/github_updater_smoke.cpp src/update_checker.hpp src/update_client.hpp | build
	$(HOST_CXX) -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror $< -o $@ -lwinhttp -lbcrypt
github-updater-smoke: build/github-updater-smoke.exe
	./build/github-updater-smoke.exe $(UPDATER_SMOKE_ARGS)
build/updater-windows-tests.exe: tests/updater_windows_tests.cpp src/update_checker.hpp src/update_client.hpp src/update_coordinator.hpp src/windows_services.hpp | build
	$(HOST_CXX) -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -static -static-libgcc -static-libstdc++ -D_WIN32_WINNT=0x0A00 -DWINVER=0x0A00 -DUNICODE -D_UNICODE $< -o $@ -lwinhttp -lbcrypt -lole32
build/updater-production-policy-test.exe: tests/updater_production_url_policy.cpp src/update_checker.hpp src/update_client.hpp | build
	$(HOST_CXX) -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -static -static-libgcc -static-libstdc++ -D_WIN32_WINNT=0x0A00 -DWINVER=0x0A00 -DUNICODE -D_UNICODE $< -o $@ -lwinhttp -lbcrypt
updater-windows-test: build/updater-windows-tests.exe build/updater-production-policy-test.exe
	./build/updater-windows-tests.exe
	./build/updater-production-policy-test.exe
build/updater-failing-installer-resources.o: tests/updater_failing_installer.rc | build
	$(WINDRES) $< -O coff -o $@
build/updater-failing-installer.exe: tests/updater_failing_installer.cpp build/updater-failing-installer-resources.o | build
	$(CROSS_CXX) -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -municode -mwindows -static -static-libgcc -static-libstdc++ $^ -o $@ -ladvapi32
updater-test-artifacts: build/updater-failing-installer.exe
tests/core-tests: tests/core_tests.cpp src/core.hpp
	$(HOST_CXX) -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror $< -o $@
test: tests/core-tests build/updater-metadata-tests package-source-policy-test
	./tests/core-tests
	./build/updater-metadata-tests
build/updater-metadata-tests: tests/updater_metadata_tests.cpp src/update_checker.hpp | build
	$(HOST_CXX) -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror $< -o $@
updater-metadata-test: build/updater-metadata-tests
	./build/updater-metadata-tests
package-source-policy-test:
	$(PYTHON) tests/package_source_policy_tests.py
release/EyeBreakReminder-Setup-x64.exe: release/EyeBreakReminder.exe installer/setup.nsi README.md docs/PRIVACY.md docs/VERIFICATION.md
	$(MAKENSIS) -NOCD installer/setup.nsi
package: all release/EyeBreakReminder-Setup-x64.exe
	$(PYTHON) scripts/package.py
	$(PYTHON) scripts/verify.py
clean:
	rm -f release/*.exe release/*.o release/*.zip release/EyeBreakReminder-SHA256.txt tests/core-tests
