# NodeBundles.cmake -- the esbuild and Electron targets
#
# Every bundle is written into ${NSTS_DIST}.  The bundler reads the source
# root and the output directory from the environment (cmake/esbuild/bundle.js),
# so nothing is relative to a working directory.
#
# Electron is built by electron-esbuild, which resolves every path against
# its working directory.  It runs in the build tree with a configured
# electron-esbuild.config.yaml naming absolute sources, and --no-clean
# because its clean removes <cwd>/dist -- the output of this build.

find_program(NODE_EXECUTABLE node REQUIRED)
find_program(NPM_EXECUTABLE npm REQUIRED)

set(NSTS_BUNDLER "${NSTS_SRC_ROOT}/cmake/esbuild/bundle.js")
set(NSTS_NODE_ENV
    "NSTS_SRC_ROOT=${NSTS_SRC_ROOT}"
    "NSTS_DIST=${NSTS_DIST}")

#-----------------------------------------------------------------------------
# npm dependencies
#-----------------------------------------------------------------------------
set(NPM_STAMP "${CMAKE_BINARY_DIR}/npm.stamp")
add_custom_command(
    OUTPUT "${NPM_STAMP}"
    COMMAND "${NPM_EXECUTABLE}" install
    COMMAND ${CMAKE_COMMAND} -E touch "${NPM_STAMP}"
    WORKING_DIRECTORY "${NSTS_SRC_ROOT}"
    DEPENDS "${NSTS_SRC_ROOT}/package.json"
    COMMENT "Installing npm dependencies"
    VERBATIM
)
add_custom_target(npm-deps DEPENDS "${NPM_STAMP}")

#-----------------------------------------------------------------------------
# What a bundle is made of.  A glob is enough: esbuild decides what it
# actually reads, and a stale bundle costs one rebuild.
#-----------------------------------------------------------------------------
file(GLOB_RECURSE NSTS_SOURCES CONFIGURE_DEPENDS
    "${NSTS_SRC_ROOT}/tools/deu/*.coffee"
    "${NSTS_SRC_ROOT}/src/*.coffee"
    "${NSTS_SRC_ROOT}/src/*.civet"
    "${NSTS_SRC_ROOT}/src/*.ts"
    "${NSTS_SRC_ROOT}/src/*.tsx"
    "${NSTS_SRC_ROOT}/src/*.js"
    "${NSTS_SRC_ROOT}/src/*.json"
    "${NSTS_SRC_ROOT}/src/*.pegjs"
    "${NSTS_SRC_ROOT}/src/*.asm"
)
list(APPEND NSTS_SOURCES "${NSTS_BUNDLER}" "${NSTS_SRC_ROOT}/tsconfig.json")

# data/ carries the vector fonts a bundle embeds (tsconfig maps `data/*`).
file(GLOB_RECURSE NSTS_DATA CONFIGURE_DEPENDS "${NSTS_SRC_ROOT}/data/*.svg")
list(APPEND NSTS_SOURCES ${NSTS_DATA})

# nsts_bundle(<name>) -- dist/<name>.js, target <name>-bundle
function(nsts_bundle NAME)
    add_custom_command(
        OUTPUT "${NSTS_DIST}/${NAME}.js"
        COMMAND ${CMAKE_COMMAND} -E env ${NSTS_NODE_ENV}
                "${NODE_EXECUTABLE}" "${NSTS_BUNDLER}" "${NAME}"
        DEPENDS "${NPM_STAMP}" ${NSTS_SOURCES}
        COMMENT "Bundling ${NAME}"
        VERBATIM
    )
    add_custom_target(${NAME}-bundle DEPENDS "${NSTS_DIST}/${NAME}.js")
endfunction()

set(NSTS_BUNDLES gpc gpcmd idp ratsnest lru
                 adc adta ddu imu mdm mmu mtu nsp pcmmu
                 dfbDump dpsDispToFcb fcwCal)
foreach(_b ${NSTS_BUNDLES})
    nsts_bundle(${_b})
endforeach()

add_custom_target(bundles COMMENT "Every node bundle")
foreach(_b ${NSTS_BUNDLES})
    add_dependencies(bundles ${_b}-bundle)
endforeach()

#-----------------------------------------------------------------------------
# Electron main and renderer
#-----------------------------------------------------------------------------
configure_file(
    "${NSTS_SRC_ROOT}/cmake/templates/electron-esbuild.config.yaml.in"
    "${CMAKE_BINARY_DIR}/electron-esbuild.config.yaml"
    @ONLY
)

set(ELECTRON_STAMP "${CMAKE_BINARY_DIR}/electron.stamp")
add_custom_command(
    OUTPUT "${ELECTRON_STAMP}"
    COMMAND ${CMAKE_COMMAND} -E env ${NSTS_NODE_ENV}
            "${NSTS_SRC_ROOT}/node_modules/.bin/electron-esbuild" build --no-clean
    COMMAND ${CMAKE_COMMAND} -E touch "${ELECTRON_STAMP}"
    WORKING_DIRECTORY "${CMAKE_BINARY_DIR}"
    DEPENDS "${NPM_STAMP}" "${CMAKE_BINARY_DIR}/electron-esbuild.config.yaml"
            "${NSTS_SRC_ROOT}/cmake/esbuild/main.config.ts"
            "${NSTS_SRC_ROOT}/cmake/esbuild/renderer.config.ts"
            "${NSTS_SRC_ROOT}/src/simRunner/renderer/index.html"
            ${NSTS_SOURCES}
    COMMENT "Building the Electron main and renderer bundles"
    VERBATIM
)
add_custom_target(electron DEPENDS "${ELECTRON_STAMP}")

# `gpc gui` and `meds` are Electron windows that talk to units on the
# busses, so their wrappers build those units too.
add_custom_target(gpc-gui COMMENT "The GUI debugger and the units it needs")
add_dependencies(gpc-gui electron gpc-bundle mmu-bundle gpcmd-bundle)

add_custom_target(meds COMMENT "The MDU displays and the units they need")
add_dependencies(meds electron
    gpc-bundle gpcmd-bundle idp-bundle
    mmu-bundle mdm-bundle mtu-bundle nsp-bundle pcmmu-bundle
    adc-bundle ddu-bundle)

#-----------------------------------------------------------------------------
# electron-builder packages
#
# The app is built from the source tree, because that is where package.json
# and node_modules are; the bundles come in from the build tree as a file
# set.  Output lands in ${CMAKE_BINARY_DIR}/release-<name>.
#-----------------------------------------------------------------------------
function(nsts_package NAME APPID PRODUCT EXECUTABLE)
    set(NSTS_PKG_NAME       "${NAME}")
    set(NSTS_PKG_APPID      "${APPID}")
    set(NSTS_PKG_PRODUCT    "${PRODUCT}")
    set(NSTS_PKG_EXECUTABLE "${EXECUTABLE}")
    configure_file(
        "${NSTS_SRC_ROOT}/cmake/templates/electron-builder.yml.in"
        "${CMAKE_BINARY_DIR}/electron-builder-${NAME}.yml"
        @ONLY
    )
    add_custom_target(${NAME}-pkg
        COMMAND "${NSTS_SRC_ROOT}/node_modules/.bin/electron-builder"
                --config "${CMAKE_BINARY_DIR}/electron-builder-${NAME}.yml"
        WORKING_DIRECTORY "${NSTS_SRC_ROOT}"
        COMMENT "Packaging ${PRODUCT}"
        VERBATIM
    )
    add_dependencies(${NAME}-pkg ${ARGN})
endfunction()

nsts_package(gpc  com.nsts.gpc  GPC  gpc  gpc-gui)
nsts_package(meds com.nsts.meds MEDS meds meds)
