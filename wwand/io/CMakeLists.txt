cmake_minimum_required(VERSION 3.13)

project(ucode-mod-wwand-io C)

set(CMAKE_C_STANDARD 11)

add_compile_options(-Wall -Wextra -Wno-unused-parameter)

find_path(UCODE_INCLUDE_DIR ucode/module.h)
find_library(UCODE_LIBRARY NAMES ucode)

add_library(wwand_io MODULE src/wwand-io.c)

set_target_properties(wwand_io PROPERTIES OUTPUT_NAME wwand_io PREFIX "")
target_include_directories(wwand_io PRIVATE ${UCODE_INCLUDE_DIR})
target_link_options(wwand_io PRIVATE -Wl,--no-undefined)
target_link_libraries(wwand_io ${UCODE_LIBRARY})

install(TARGETS wwand_io LIBRARY DESTINATION lib/ucode)
