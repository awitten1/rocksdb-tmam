cmake_minimum_required(VERSION 3.20)
project(rocksdb_tmam CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "" FORCE)
endif()

# Frame pointers keep perf call stacks usable for TMAM drill-down.
add_compile_options(-fno-omit-frame-pointer -Wall -Wextra)

# Point find_package at the local install produced by scripts/install_rocksdb.sh.
set(_local_prefix "${CMAKE_SOURCE_DIR}/local/rocksdb")
list(PREPEND CMAKE_PREFIX_PATH "${_local_prefix}")

find_package(RocksDB CONFIG REQUIRED)

# Static install needs the usual transitive deps.
find_package(Threads REQUIRED)

add_executable(bench src/bench.cpp)
target_link_libraries(bench PRIVATE RocksDB::rocksdb Threads::Threads ${CMAKE_DL_LIBS})

message(STATUS "RocksDB found; bench will link against the local install at ${_local_prefix}")
