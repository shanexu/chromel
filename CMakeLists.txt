cmake_minimum_required(VERSION 3.21)
project(emacs_chromel LANGUAGES C CXX OBJCXX)
if(NOT APPLE)
  message(FATAL_ERROR "This native backend currently supports macOS only")
endif()
# Keep our objects at the documented floor; without this the linker inherits the
# running host's version and warns when the CEF slices were built for an older one.
if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
  set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "Minimum macOS version" FORCE)
endif()
# An unset build type means no optimisation flags at all, which also disables
# -DNDEBUG and leaves CEF assertions live in release builds.
if(NOT CMAKE_CONFIGURATION_TYPES AND NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CEF_ROOT "" CACHE PATH "Extracted CEF minimal binary distribution")
set(EMACS_INCLUDE_DIR "" CACHE PATH "Directory containing emacs-module.h")
if(NOT EXISTS "${CEF_ROOT}/include/cef_app.h")
  message(FATAL_ERROR "Set CEF_ROOT or run scripts/build.sh")
endif()
if(NOT EXISTS "${EMACS_INCLUDE_DIR}/emacs-module.h")
  message(FATAL_ERROR "Set EMACS_INCLUDE_DIR to the installed Emacs include directory")
endif()
list(APPEND CMAKE_MODULE_PATH "${CEF_ROOT}/cmake")
find_package(CEF REQUIRED)
add_subdirectory("${CEF_LIBCEF_DLL_WRAPPER_PATH}" libcef_dll_wrapper)

add_library(chromel_core STATIC native/chromel_core.mm)
target_include_directories(chromel_core PUBLIC "${CEF_ROOT}" native)
target_compile_options(chromel_core PRIVATE -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers)
target_link_libraries(chromel_core PUBLIC libcef_dll_wrapper "-framework Cocoa")

add_library(chromel-module MODULE native/module.mm)
target_include_directories(chromel-module PRIVATE "${EMACS_INCLUDE_DIR}")
target_link_libraries(chromel-module PRIVATE chromel_core)
set_target_properties(chromel-module PROPERTIES PREFIX "" SUFFIX ".dylib")

add_executable(chromel-helper native/helper.cc)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/native/scroll.js")
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/native/scroll.js" CHROMEL_SCROLL_SOURCE)
configure_file(native/scripts.h.in generated/chromel_scripts.h @ONLY)
target_include_directories(chromel-helper PRIVATE "${CEF_ROOT}" "${CMAKE_CURRENT_BINARY_DIR}/generated")
target_link_libraries(chromel-helper PRIVATE libcef_dll_wrapper "-framework Cocoa")

add_executable(chromel-smoke native/smoke.mm)
target_compile_options(chromel-smoke PRIVATE -fobjc-arc)
target_link_libraries(chromel-smoke PRIVATE chromel_core)

# Explicit opt-in regression probe; never packaged in the runtime or module.
add_library(chromel-pump-probe MODULE EXCLUDE_FROM_ALL test/pump-probe.mm)
target_include_directories(chromel-pump-probe PRIVATE "${EMACS_INCLUDE_DIR}")
target_link_libraries(chromel-pump-probe PRIVATE "-framework Cocoa")
set_target_properties(chromel-pump-probe PROPERTIES PREFIX "" SUFFIX ".dylib")

# Native installation-dialog automation is isolated from the shipped module.
add_library(chromel-ui-probe MODULE EXCLUDE_FROM_ALL test/ui-probe.mm)
target_include_directories(chromel-ui-probe PRIVATE "${EMACS_INCLUDE_DIR}")
target_compile_options(chromel-ui-probe PRIVATE -fobjc-arc -Wall -Wextra)
target_link_libraries(chromel-ui-probe PRIVATE "-framework Cocoa")
set_target_properties(chromel-ui-probe PROPERTIES PREFIX "" SUFFIX ".dylib")

# Headless Cocoa wake-up regression: never orders a window or loads CEF.
add_executable(chromel-host-wakeup-test EXCLUDE_FROM_ALL test/host-wakeup.mm)
target_compile_options(chromel-host-wakeup-test PRIVATE -fobjc-arc -Wall -Wextra)
target_link_libraries(chromel-host-wakeup-test PRIVATE "-framework Cocoa")
