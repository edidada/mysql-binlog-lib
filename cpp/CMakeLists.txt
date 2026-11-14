cmake_minimum_required(VERSION 3.10)
project(mysqlbinlog-cpp LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
add_compile_options(-Wall -Wextra)

add_library(mbparserpp STATIC src/mysqlbinlog.cpp)
target_include_directories(mbparserpp PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)

add_executable(mysqlbinlog-cpp examples/main.cpp)
target_link_libraries(mysqlbinlog-cpp PRIVATE mbparserpp)

enable_testing()
add_executable(test_parser tests/test_parser.cpp)
target_link_libraries(test_parser PRIVATE mbparserpp)
add_test(NAME test_parser COMMAND test_parser)
