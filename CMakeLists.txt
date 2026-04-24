cmake_minimum_required(VERSION 3.16)
project(minimal_score_pubsub LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ---------------------------------------------------------------------------
# score::mw::com sysroot — set via cmake -DSCORE_MW_SYSROOT=/path/to/sysroot
# or via CMAKE_PREFIX_PATH for find_package compatibility.
#
# This approach uses explicit target_include_directories / target_link_libraries
# instead of find_package, so it can be dropped into Simulink-generated
# CMakeLists.txt files without modification.
#
# Example:
#   cmake -DSCORE_MW_SYSROOT=/path/to/score_mw_sysroot ..
# ---------------------------------------------------------------------------
if(NOT DEFINED SCORE_MW_SYSROOT)
    # Fall back to CMAKE_PREFIX_PATH if provided
    if(DEFINED CMAKE_PREFIX_PATH)
        set(SCORE_MW_SYSROOT "${CMAKE_PREFIX_PATH}")
    else()
        message(FATAL_ERROR "SCORE_MW_SYSROOT is not set. Pass -DSCORE_MW_SYSROOT=/path/to/score_mw_sysroot or -DCMAKE_PREFIX_PATH=/path/to/score_mw_sysroot")
    endif()
endif()

set(SCORE_MW_INCLUDE_DIR "${SCORE_MW_SYSROOT}/include")
set(SCORE_MW_LIB        "${SCORE_MW_SYSROOT}/lib/libmw_com.a")

if(NOT EXISTS "${SCORE_MW_LIB}")
    message(FATAL_ERROR "libmw_com.a not found at ${SCORE_MW_LIB}. Run setup_score_sysroot.sh first.")
endif()

# ---------------------------------------------------------------------------
# Shared datatype library
# ---------------------------------------------------------------------------
add_library(datatype STATIC datatype.cpp datatype.h)
target_include_directories(datatype PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
    ${SCORE_MW_INCLUDE_DIR}
)
target_link_libraries(datatype PUBLIC
    ${SCORE_MW_LIB}
    acl
)

# ---------------------------------------------------------------------------
# Publisher
# ---------------------------------------------------------------------------
add_executable(publisher publisher.cpp)
target_link_libraries(publisher PRIVATE datatype)

# ---------------------------------------------------------------------------
# Subscriber
# ---------------------------------------------------------------------------
add_executable(subscriber subscriber.cpp)
target_link_libraries(subscriber PRIVATE datatype)
