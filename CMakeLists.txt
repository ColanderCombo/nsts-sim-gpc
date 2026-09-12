cmake_minimum_required(VERSION 3.20)

project(NSTS_SIM
        VERSION 1.0.0
        DESCRIPTION "AP-101 GPC and Shuttle avionics simulator"
        LANGUAGES NONE)

# Everything this build produces lives under the build tree: the node
# bundles in dist/, the addons in native/, the command wrappers in bin/.
set(NSTS_SRC_ROOT "${CMAKE_SOURCE_DIR}")
set(NSTS_DIST     "${CMAKE_BINARY_DIR}/dist")
set(NSTS_BINDIR   "${CMAKE_BINARY_DIR}/bin")

list(APPEND CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/cmake")

find_package(Python3 COMPONENTS Interpreter REQUIRED)

include(NodeBundles)
include(NativeAddons)
include(InstallWrappers)

#-----------------------------------------------------------------------------
# Build targets:
#   cmake --build build                  the bundles, Electron and the addons
#   cmake --build build --target gpc-bundle    one bundle
#   cmake --build build --target electron      main + renderer only
#   cmake --build build --target native        the two addons only
#   cmake --build build --target check         build, then run the tests
#-----------------------------------------------------------------------------
add_custom_target(world ALL COMMENT "The simulator")
add_dependencies(world bundles electron native)

set_property(DIRECTORY APPEND PROPERTY ADDITIONAL_CLEAN_FILES
    "${NSTS_DIST}"
    "${CMAKE_BINARY_DIR}/native"
    "${CMAKE_BINARY_DIR}/electron.stamp"
    "${CMAKE_BINARY_DIR}/npm.stamp"
)

#-----------------------------------------------------------------------------
# Tests (ctest)
#-----------------------------------------------------------------------------
enable_testing()
list(APPEND CMAKE_CTEST_ARGUMENTS "--output-on-failure")
add_subdirectory(test)

add_custom_target(check
    COMMAND ${CMAKE_CTEST_COMMAND} --output-on-failure
    DEPENDS world
    WORKING_DIRECTORY "${CMAKE_BINARY_DIR}"
    COMMENT "Building everything and running the tests"
)
