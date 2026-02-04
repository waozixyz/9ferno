# CMakeLists.txt for TaijiOS Android app - Full build
# Compiles the complete TaijiOS emu layer with WM support

cmake_minimum_required(VERSION 3.22.1)
project("taijos-android")

# Set C standard
set(CMAKE_C_STANDARD 11)

# Define Android-specific macros
add_definitions(-DANDROID -D__ANDROID__ -DUSE_PTHREADS)

# Find paths to parent directories
# From app/src/main/cpp, go up 5 levels to reach TaijiOS root
set(TAIJIOS_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../../../../..)
set(EMU_PORT ${TAIJIOS_ROOT}/emu/port)
set(EMU_ANDROID ${TAIJIOS_ROOT}/emu/Android)
set(INCLUDE ${TAIJIOS_ROOT}/include)
set(LIB9 ${TAIJIOS_ROOT}/lib9)
set(LIBINTERP ${TAIJIOS_ROOT}/libinterp)
set(LIBDRAW ${TAIJIOS_ROOT}/libdraw)
set(LIBMEMDRAW ${TAIJIOS_ROOT}/libmemdraw)
set(LIBTK ${TAIJIOS_ROOT}/libtk)
set(LIBSEC ${TAIJIOS_ROOT}/libsec)

# Include directories - order matters!
include_directories(
	${CMAKE_CURRENT_SOURCE_DIR}
	${EMU_PORT}
	${INCLUDE}
	${LIB9}
	${LIBINTERP}
	${LIBDRAW}
	${LIBMEMDRAW}
	${LIBTK}
	${LIBSEC}
	${TAIJIOS_ROOT}/Android/arm64/include
)

# Source files - port files (shared with other platforms)
set(EMU_PORT_SOURCES
	${EMU_PORT}/alloc.c
	${EMU_PORT}/cache.c
	${EMU_PORT}/chan.c
	${EMU_PORT}/dev.c
	${EMU_PORT}/devcons.c
	${EMU_PORT}/devdraw.c
	${EMU_PORT}/devmnt.c
	${EMU_PORT}/devroot.c
	${EMU_PORT}/devpipe.c
	${EMU_PORT}/devprof.c
	${EMU_PORT}/devsrv.c
	${EMU_PORT}/devssl.c
	${EMU_PORT}/devtab.c
	${EMU_PORT}/error.c
	${EMU_PORT}/kproc-pthreads.c
	${EMU_PORT}/qio.c
	${EMU_PORT}/random.c
	${EMU_PORT}/parse.c
)

# lib9 source files (basic utilities)
set(LIB9_SOURCES
	${LIB9}/rune.c
	${LIB9}/runestrlen.c
	${LIB9}/runeseprint.c
	${LIB9}/runesnprint.c
	${LIB9}/runesmprint.c
	${LIB9}/runevseprint.c
	${LIB9}/runestrchr.c
	${LIB9}/runetype.c
	${LIB9}/utfrune.c
	${LIB9}/utfrrune.c
	${LIB9}/utfnlen.c
	${LIB9}/utflen.c
	${LIB9}/utfecpy.c
	${LIB9}/lock.c
	${LIB9}/print.c
	${LIB9}/snprint.c
	${LIB9}/sprint.c
	${LIB9}/fprint.c
	${LIB9}/fmtfd.c
	${LIB9}/fmtstr.c
	${LIB9}/fmtprint.c
	${LIB9}/fmtvprint.c
	${LIB9}/dofmt.c
	${LIB9}/dorfmt.c
	${LIB9}/errfmt.c
	# errstr-posix.c - use os.c implementation instead
	${LIB9}/rerrstr.c
	${LIB9}/mallocz.c
	${LIB9}/seek.c
	${LIB9}/readn.c
	${LIB9}/create.c
	${LIB9}/exits.c
	${LIB9}/dirstat-posix.c
	${LIB9}/nulldir.c
	${LIB9}/dirwstat.c
	${LIB9}/tokenize.c
	${LIB9}/cleanname.c
	${LIB9}/getfields.c
	${LIB9}/cistrncmp.c
	${LIB9}/cistrcmp.c
	${LIB9}/cistrstr.c
	${LIB9}/strecpy.c
	${LIB9}/strdup.c
	# qsort.c conflicts with system qsort
	${LIB9}/pow10.c
	${LIB9}/charstod.c
	${LIB9}/strtoll.c
	${LIB9}/strtoull.c
	${LIB9}/convD2M.c
	${LIB9}/convM2D.c
	${LIB9}/convM2S.c
	${LIB9}/convS2M.c
	${LIB9}/fcallfmt.c
	${LIB9}/sysfatal.c
	${LIB9}/getcallerpc-Linux-amd64.c
	${LIB9}/getwd-posix.c
	${LIB9}/getuser-posix.c
	${LIB9}/fmt.c
	${LIB9}/fltfmt.c
	${LIB9}/fmtrune.c
	# fmtquote.c needs doquote from elsewhere - exclude for now
	${LIB9}/seprint.c
	${LIB9}/vseprint.c
	${LIB9}/vsnprint.c
	${LIB9}/smprint.c
	${LIB9}/vsmprint.c
)

# Android-specific source files
set(EMU_ANDROID_SOURCES
	${EMU_ANDROID}/os.c
	# ${EMU_ANDROID}/android_main.c  # Requires android_native_app_glue - add later
	${EMU_ANDROID}/segflush-arm64.c
	${EMU_ANDROID}/asm-arm64.S
)

# libinterp source files (Dis VM)
file(GLOB_RECURSE LIBINTERP_SOURCES
	"${LIBINTERP}/*.c"
)
list(FILTER LIBINTERP_SOURCES EXCLUDE REGEX ".*win-x11.*")
list(FILTER LIBINTERP_SOURCES EXCLUDE REGEX ".*-darwin.*")
list(FILTER LIBINTERP_SOURCES EXCLUDE REGEX ".*dlm-.*")
list(FILTER LIBINTERP_SOURCES EXCLUDE REGEX ".*dlm\\.c")
list(FILTER LIBINTERP_SOURCES EXCLUDE REGEX ".*optab.c")
list(FILTER LIBINTERP_SOURCES EXCLUDE REGEX ".*prefab.c")
# Only keep ARM compiler for Android
list(FILTER LIBINTERP_SOURCES EXCLUDE REGEX ".*comp-386.*")
list(FILTER LIBINTERP_SOURCES EXCLUDE REGEX ".*comp-amd64.*")
list(FILTER LIBINTERP_SOURCES EXCLUDE REGEX ".*comp-mips.*")
list(FILTER LIBINTERP_SOURCES EXCLUDE REGEX ".*comp-power.*")
list(FILTER LIBINTERP_SOURCES EXCLUDE REGEX ".*comp-sparc.*")
list(FILTER LIBINTERP_SOURCES EXCLUDE REGEX ".*comp-spim.*")
list(FILTER LIBINTERP_SOURCES EXCLUDE REGEX ".*das-386.*")
list(FILTER LIBINTERP_SOURCES EXCLUDE REGEX ".*das-amd64.*")
list(FILTER LIBINTERP_SOURCES EXCLUDE REGEX ".*das-mips.*")
list(FILTER LIBINTERP_SOURCES EXCLUDE REGEX ".*das-power.*")
list(FILTER LIBINTERP_SOURCES EXCLUDE REGEX ".*das-sparc.*")
list(FILTER LIBINTERP_SOURCES EXCLUDE REGEX ".*das-spim.*")
list(FILTER LIBINTERP_SOURCES EXCLUDE REGEX ".*das-stub.*")
# Exclude test programs and files with duplicate symbols
list(FILTER LIBINTERP_SOURCES EXCLUDE REGEX ".*decgen\\.c")
list(FILTER LIBINTERP_SOURCES EXCLUDE REGEX ".*draw\\.c")

# libdraw source files
file(GLOB_RECURSE LIBDRAW_SOURCES
	"${LIBDRAW}/*.c"
)
list(FILTER LIBDRAW_SOURCES EXCLUDE REGEX ".*x11.*")
list(FILTER LIBDRAW_SOURCES EXCLUDE REGEX ".*winx.*")
list(FILTER LIBDRAW_SOURCES EXCLUDE REGEX ".*test\\.c")

# libmemdraw source files
file(GLOB_RECURSE LIBMEMDRAW_SOURCES
	"${LIBMEMDRAW}/*.c"
)
list(FILTER LIBMEMDRAW_SOURCES EXCLUDE REGEX ".*openmemsubfont.*")
list(FILTER LIBMEMDRAW_SOURCES EXCLUDE REGEX ".*drawtest.*")

# libtk source files
file(GLOB_RECURSE LIBTK_SOURCES
	"${LIBTK}/*.c"
)
list(FILTER LIBTK_SOURCES EXCLUDE REGEX ".*tkx11.*")
list(FILTER LIBTK_SOURCES EXCLUDE REGEX ".*x11.*")
list(FILTER LIBTK_SOURCES EXCLUDE REGEX ".*utils\\.c")

# libsec source files
file(GLOB_RECURSE LIBSEC_SOURCES
	"${LIBSEC}/*.c"
)
list(FILTER LIBSEC_SOURCES EXCLUDE REGEX ".*port/.*")
list(FILTER LIBSEC_SOURCES EXCLUDE REGEX ".*os\\.c")

# Exclude problematic source files from emu/port
list(FILTER EMU_PORT_SOURCES EXCLUDE REGEX ".*alloc.c")

# Combine all sources
set(TAIJIOS_SOURCES
	${EMU_PORT_SOURCES}
	${EMU_ANDROID_SOURCES}
	${LIB9_SOURCES}
	${LIBINTERP_SOURCES}
	${LIBDRAW_SOURCES}
	${LIBMEMDRAW_SOURCES}
	${LIBTK_SOURCES}
	${LIBSEC_SOURCES}
)

# Build the shared library
add_library(taijos SHARED ${TAIJIOS_SOURCES})

# Link libraries
target_link_libraries(taijos
	log
	android
	EGL
	GLESv2
	m
	z
	dl
	atomic
)

# Set output name
set_target_properties(taijos PROPERTIES
	OUTPUT_NAME "taijos"
)
