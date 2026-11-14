cmake_minimum_required(VERSION 3.10)
project(mysqlbinlog-c LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
add_compile_options(-Wall -Wextra)

add_library(mbparser STATIC src/mysqlbinlog.c)
target_include_directories(mbparser PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)

add_executable(mysqlbinlog-c examples/main.c)
target_link_libraries(mysqlbinlog-c PRIVATE mbparser)

enable_testing()
add_executable(test_parser tests/test_parser.c)
target_link_libraries(test_parser PRIVATE mbparser)
add_test(NAME test_parser COMMAND test_parser)
