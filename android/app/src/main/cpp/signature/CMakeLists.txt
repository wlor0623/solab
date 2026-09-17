# SoLab 签名兼容注入原生库（原包模式，arm64）。
# 仅编译 arm64-v8a，与项目 abiFilters 保持一致。

cmake_minimum_required(VERSION 3.4.1)

set(CMAKE_C_FLAGS "-Wall -Wextra -fvisibility=hidden")

add_library(
        solab_signature
        SHARED
        mt_jni.c
        xhook.c
        xh_core.c
        xh_elf.c
        xh_log.c
        xh_util.c
        xh_version.c)

find_library(log-lib log)

target_link_libraries(solab_signature ${log-lib})

# 16KB page size 对齐（Android 15+ 16KB 设备强制要求，4KB 设备兼容）。
# 未对齐的 so 在 16KB 设备上会被 linker 拒载 → native hook 静默降级 →
# 整包校验拿到重签名的 base.apk → App 自杀闪退。
set_target_properties(solab_signature PROPERTIES LINK_FLAGS "-Wl,-z,max-page-size=16384")
