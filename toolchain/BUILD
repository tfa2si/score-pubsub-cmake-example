
filegroup(
    name = "empty",
    srcs = [],
)

load(":cc_toolchain_config.bzl", "arm64_linux_gcc_toolchain_config")

cc_toolchain(
    name = "arm64_linux_gcc_toolchain",
    toolchain_identifier = "aarch64-linux-gnu-toolchain",
    toolchain_config = ":arm64_linux_gcc_toolchain_config",
    all_files = ":empty",
    ar_files = ":empty",
    as_files = ":empty",
    compiler_files = ":empty",
    dwp_files = ":empty",
    linker_files = ":empty",
    strip_files = ":empty",
    objcopy_files = ":empty",
    supports_param_files = 1,
)

arm64_linux_gcc_toolchain_config(
    name = "arm64_linux_gcc_toolchain_config",
)

toolchain(
    name = "arm64_linux_gcc_toolchain_entry",
    toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
    toolchain = ":arm64_linux_gcc_toolchain",
    exec_compatible_with = [],
    target_compatible_with = ["@platforms//cpu:aarch64"],
)
