cmake_minimum_required(VERSION 3.16)
project(multi_output_standard_cell LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(MOCKTURTLE_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(MOCKTURTLE_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(MOCKTURTLE_BUILD_EXPERIMENTS OFF CACHE BOOL "" FORCE)

add_subdirectory(third_party/mockturtle)

add_executable(mo_techmap src/mo_techmap.cpp)
target_link_libraries(mo_techmap PRIVATE mockturtle)
target_compile_options(mo_techmap PRIVATE -Wall -Wextra -Wpedantic)
