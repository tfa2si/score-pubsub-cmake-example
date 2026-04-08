cmake_minimum_required(VERSION 3.16)
project(minimal_score_pubsub LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ---------------------------------------------------------------------------
# Find pre-installed score::mw::com (via install_sysroot.sh)
# Set CMAKE_PREFIX_PATH to the sysroot, e.g.:
#   cmake -DCMAKE_PREFIX_PATH=/path/to/sysroot ..
# ---------------------------------------------------------------------------
find_package(MwCom REQUIRED)

# ---------------------------------------------------------------------------
# Shared datatype library
# ---------------------------------------------------------------------------
add_library(datatype STATIC datatype.cpp datatype.h)
target_include_directories(datatype PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
)
target_link_libraries(datatype PUBLIC score::mw::com)

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
