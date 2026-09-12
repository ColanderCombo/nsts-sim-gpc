# One ctest per test file.  The tree mirrors src/, and a test is named for
# its path in it -- `gpc/iop_state`, `lru/mdm`, `meds/render` -- so
# `ctest -R '^lru/'` runs one area.
#
# Each test bundles the sources it needs with esbuild, so the only build
# dependency is npm and, for the two that read the shared-memory ring, the
# addons.  A file whose name begins with `_` is a helper, not a test.
#
# NSTS_BASE_PORT keeps concurrent tests off each other's busses; a test
# without one draws a base from its pid.

file(GLOB_RECURSE _tests CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/*.cjs")

foreach(_t ${_tests})
    file(RELATIVE_PATH _rel "${CMAKE_CURRENT_SOURCE_DIR}" "${_t}")
    get_filename_component(_leaf "${_rel}" NAME)
    if(_leaf MATCHES "^_")
        continue()
    endif()
    # gpc/floatIBM compares against a reference generator built elsewhere
    # and names it as an argument; it has nothing to run against here.
    if(_rel STREQUAL "gpc/floatIBM.cjs")
        continue()
    endif()
    string(REGEX REPLACE "\\.cjs$" "" _name "${_rel}")
    add_test(NAME "${_name}"
             COMMAND "${NODE_EXECUTABLE}" "${_t}"
             WORKING_DIRECTORY "${NSTS_SRC_ROOT}")
    set_tests_properties("${_name}" PROPERTIES
        ENVIRONMENT "NSTS_NATIVE=${NSTS_NATIVE_DIR}"
        TIMEOUT 600)
endforeach()
