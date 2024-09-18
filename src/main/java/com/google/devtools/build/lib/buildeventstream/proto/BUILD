load("@rules_java//java:defs.bzl", "java_proto_library")
load("//tools/build_rules:utilities.bzl", "java_library_srcs")

package(default_visibility = ["//src:__subpackages__"])

filegroup(
    name = "srcs",
    srcs = glob(["**"]),
    visibility = ["//src/main/java/com/google/devtools/build/lib:__pkg__"],
)

java_library_srcs(
    name = "dist_jars",
    deps = [":build_event_stream_java_proto"],
)

java_proto_library(
    name = "build_event_stream_java_proto",
    # The Bazel IntelliJ plugin uses this.
    visibility = ["//visibility:public"],
    deps = ["@build_event_stream//src/main/protobuf:build_event_stream_proto"],
)
