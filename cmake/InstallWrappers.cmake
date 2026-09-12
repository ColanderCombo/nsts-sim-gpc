# InstallWrappers.cmake -- the command wrappers in ${CMAKE_BINARY_DIR}/bin
#
# One per template in cmake/templates.  A wrapper builds its target and
# execs the bundle out of the build tree; NSTS_NO_BUILD=1 in the
# environment skips the build.

function(_nsts_wrapper NAME)
    configure_file(
        "${NSTS_SRC_ROOT}/cmake/templates/${NAME}.sh.in"
        "${NSTS_BINDIR}/${NAME}"
        @ONLY
    )
    file(CHMOD "${NSTS_BINDIR}/${NAME}"
         PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE
                     GROUP_READ GROUP_EXECUTE
                     WORLD_READ WORLD_EXECUTE)
endfunction()

foreach(_w gpc gpcmd idp meds ratsnest sim lru
           adc adta ddu imu mdm mmu mtu nsp pcmmu)
    _nsts_wrapper(${_w})
endforeach()
