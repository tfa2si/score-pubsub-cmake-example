# *******************************************************************************
# Copyright (c) 2025 Contributors to the Eclipse Foundation
#
# See the NOTICE file(s) distributed with this work for additional
# information regarding copyright ownership.
#
# This program and the accompanying materials are made available under the
# terms of the Apache License Version 2.0 which is available at
# https://www.apache.org/licenses/LICENSE-2.0
#
# SPDX-License-Identifier: Apache-2.0
# *******************************************************************************

load("@rules_cc//cc:defs.bzl", "cc_binary", "cc_library")
load("@score_baselibs//score/language/safecpp:toolchain_features.bzl", "COMPILER_WARNING_FEATURES")

cc_library(
    name = "datatype",
    srcs = [
        "datatype.cpp",
    ],
    hdrs = [
        "datatype.h",
    ],
    features = COMPILER_WARNING_FEATURES,
    visibility = ["//visibility:private"],
    deps = [
        "//score/mw/com",
        "@score_baselibs//score/language/futurecpp",
    ],
)

cc_binary(
    name = "publisher",
    srcs = ["publisher.cpp"],
    data = ["etc/mw_com_config.json"],
    features = COMPILER_WARNING_FEATURES,
    visibility = ["//visibility:public"],
    deps = [
        ":datatype",
        "//score/mw/com",
    ],
)

cc_binary(
    name = "subscriber",
    srcs = ["subscriber.cpp"],
    data = ["etc/mw_com_config.json"],
    features = COMPILER_WARNING_FEATURES,
    visibility = ["//visibility:public"],
    deps = [
        ":datatype",
        "//score/mw/com",
    ],
)

exports_files([
    "etc/mw_com_config.json",
])
