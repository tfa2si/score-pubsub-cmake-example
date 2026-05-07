
load(
    "@bazel_tools//tools/cpp:cc_toolchain_config_lib.bzl",
    "feature",
    "flag_group",
    "flag_set",
    "tool_path",
)

def _impl(ctx):
    tool_paths = [
        tool_path(name = "gcc", path = "/usr/bin/aarch64-linux-gnu-gcc"),
        tool_path(name = "g++", path = "/usr/bin/aarch64-linux-gnu-g++"),
        tool_path(name = "ld", path = "/usr/bin/aarch64-linux-gnu-ld"),
        tool_path(name = "ar", path = "/usr/bin/aarch64-linux-gnu-ar"),
        tool_path(name = "cpp", path = "/usr/bin/aarch64-linux-gnu-cpp"),
        tool_path(name = "gcov", path = "/usr/bin/aarch64-linux-gnu-gcov"),
        tool_path(name = "nm", path = "/usr/bin/aarch64-linux-gnu-nm"),
        tool_path(name = "objcopy", path = "/usr/bin/aarch64-linux-gnu-objcopy"),
        tool_path(name = "objdump", path = "/usr/bin/aarch64-linux-gnu-objdump"),
        tool_path(name = "strip", path = "/usr/bin/aarch64-linux-gnu-strip"),
        # --- THE WORKAROUND ---
        tool_path(name = "linker", path = "/usr/bin/aarch64-linux-gnu-g++"),
    ]

    with_sysroot_feature = feature(
        name = "with_sysroot",
        enabled = True,
        flag_sets = [
            flag_set(
                actions = [
                    "c-compile",
                    "c++-compile",
                    "c++-link",
                ],
                flag_groups = [
                    flag_group(flags = ["--sysroot=/usr/aarch64-linux-gnu"]),
                ],
            ),
        ],
    )

    link_libstdcpp_feature = feature(
        name = "link_libstdcpp",
        enabled = True,
        flag_sets = [
            flag_set(
                actions = ["c++-link-executable", "c++-link-dynamic-library", "c++-link-nodeps-dynamic-library"],
                flag_groups = [
                    flag_group(flags = ["-lstdc++", "-lm", "-lrt", "-latomic"]),
                ],
            ),
        ],
    )

    return cc_common.create_cc_toolchain_config_info(
        ctx = ctx,
        toolchain_identifier = "aarch64-linux-gnu-toolchain",
        host_system_name = "local",
        target_system_name = "local",
        target_cpu = "aarch64",
        target_libc = "glibc",
        compiler = "gcc",
        abi_version = "unknown",
        abi_libc_version = "unknown",
        tool_paths = tool_paths,
        features = [
            with_sysroot_feature,
            link_libstdcpp_feature,
        ],
        cxx_builtin_include_directories = [
            "/usr/aarch64-linux-gnu/include/c++/13",
            "/usr/aarch64-linux-gnu/include/aarch64-linux-gnu/c++/13",
            "/usr/lib/gcc-cross/aarch64-linux-gnu/13/include",
            # --- THE FINAL FIX: Explicitly add the main sysroot include path ---
            "/usr/aarch64-linux-gnu/include",
        ],
    )

arm64_linux_gcc_toolchain_config = rule(
    implementation = _impl,
    attrs = {},
    provides = [CcToolchainConfigInfo],
)
