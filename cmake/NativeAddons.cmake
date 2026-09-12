# NativeAddons.cmake -- the two Node-API addons
#
# Built into ${CMAKE_BINARY_DIR}/native.  A bundle in ${NSTS_DIST} finds
# them there as __dirname/../native (com/busshm.coffee, native/rtpolicy.js);
# without them --sched has no effect and every bus is UDP.

set(NSTS_NATIVE_DIR "${CMAKE_BINARY_DIR}/native")
set(NSTS_NATIVE_SRC "${NSTS_SRC_ROOT}/src/native")

foreach(_mod machrt shmring)
    add_custom_command(
        OUTPUT "${NSTS_NATIVE_DIR}/${_mod}.node"
        COMMAND "${NSTS_SRC_ROOT}/cmake/native-build.sh"
                "${NSTS_NATIVE_SRC}" "${NSTS_NATIVE_DIR}" ${_mod}
        DEPENDS "${NSTS_NATIVE_SRC}/${_mod}.c"
                "${NSTS_SRC_ROOT}/cmake/native-build.sh"
        COMMENT "Building the ${_mod} addon"
        VERBATIM
    )
    list(APPEND _native_outputs "${NSTS_NATIVE_DIR}/${_mod}.node")
endforeach()

add_custom_target(native DEPENDS ${_native_outputs})
