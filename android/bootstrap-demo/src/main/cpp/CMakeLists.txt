cmake_minimum_required(VERSION 3.22.1)

project(kelivo_bootstrap_demo)

add_library(kelivo_bootstrap_demo SHARED bootstrap_demo.c)

find_library(log-lib log)

target_link_libraries(kelivo_bootstrap_demo ${log-lib})
