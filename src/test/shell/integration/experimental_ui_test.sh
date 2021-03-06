#!/bin/bash
#
# Copyright 2016 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# An end-to-end test that Bazel's experimental UI produces reasonable output.

# Load the test setup defined in the parent directory
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${CURRENT_DIR}/../integration_test_setup.sh" \
  || { echo "integration_test_setup.sh not found!" >&2; exit 1; }

#### SETUP #############################################################

set -e

add_to_bazelrc "build --genrule_strategy=local"
add_to_bazelrc "test --test_strategy=standalone"

function set_up() {
  mkdir -p pkg
  touch remote_file
  cat > pkg/true.sh <<EOF
#!/bin/sh
exit 0
EOF
  chmod 755 pkg/true.sh
  cat > pkg/slow.sh <<EOF
#!/bin/sh
sleep 3
exit 0
EOF
  chmod 755 pkg/slow.sh
  cat > pkg/false.sh <<EOF
#!/bin/sh
exit 1
EOF
  chmod 755 pkg/false.sh
  cat > pkg/output.sh <<EOF
#!/bin/sh
`which echo` -n foo
sleep 1
`which echo` -n bar
exit 0
EOF
  chmod 755 pkg/output.sh
  cat > pkg/do_output.sh <<EOF
#!/bin/sh
echo Beginning \$1
for _ in \`seq 1 10240\`
do echo '1234567890'
done
echo Ending \$1
EOF
  chmod 755 pkg/do_output.sh
  cat > pkg/BUILD <<EOF
sh_test(
  name = "true",
  srcs = ["true.sh"],
)
sh_test(
  name = "slow",
  srcs = ["slow.sh"],
)
sh_test(
  name = "false",
  srcs = ["false.sh"],
)
sh_test(
  name = "output",
  srcs = ["output.sh"],
)
genrule(
  name = "gentext",
  outs = ["gentext.txt"],
  cmd = "echo here be dragons > \"\$@\""
)
genrule(
  name = "withOutputA",
  outs = ["a"],
  tools = [":do_output.sh"],
  cmd = "\$(location :do_output.sh) A && touch \$@",
)
genrule(
  name = "withOutputB",
  outs = ["b"],
  tools = [":do_output.sh"],
  cmd = "\$(location :do_output.sh) B && touch \$@",
)
sh_library(
  name = "outputlib",
  data = [":withOutputA", ":withOutputB"],
)
sh_test(
  name = "truedependingonoutput",
  srcs = ["true.sh"],
  deps = [":outputlib"],
)
EOF
}

#### TESTS #############################################################

function test_basic_progress() {
  bazel test --experimental_ui --curses=yes --color=yes pkg:true 2>$TEST_log \
    || fail "${PRODUCT_NAME} test failed"
  # some progress indicator is shown
  expect_log '\[[0-9,]* / [0-9,]*\]'
  # curses are used to delete at least one line
  expect_log $'\x1b\[1A\x1b\[K'
  # As precisely one target is specified, it should be reported during
  # analysis phase.
  expect_log 'Analy.*pkg:true'
}

function test_noshow_progress() {
  bazel test --experimental_ui --noshow_progress --curses=yes --color=yes \
    pkg:true 2>$TEST_log || fail "${PRODUCT_NAME} test failed"
  # Info messages should still go through
  expect_log 'Elapsed time'
  # no progress indicator is shown
  expect_not_log '\[[0-9,]* / [0-9,]*\]'
}

function test_basic_progress_no_curses() {
  bazel test --experimental_ui --curses=no --color=yes pkg:true 2>$TEST_log \
    || fail "${PRODUCT_NAME} test failed"
  # some progress indicator is shown
  expect_log '\[[0-9,]* / [0-9,]*\]'
  # cursor is not moved up
  expect_not_log $'\x1b\[1A'
  # no line is deleted
  expect_not_log $'\x1b\[K'
  # but some green color is used
  expect_log $'\x1b\[32m'
}

function test_no_curses_no_linebreak() {
  bazel test --experimental_ui --curses=no --color=yes --terminal_columns=9 \
    pkg:true 2>$TEST_log || fail "${PRODUCT_NAME} test failed"
  # expect a long-ish status line
  expect_log '\[[0-9,]* / [0-9,]*\]......'
}

function test_pass() {
  bazel test --experimental_ui --curses=yes --color=yes pkg:true >$TEST_log \
    || fail "${PRODUCT_NAME} test failed"
  # PASS is written in green on the same line as the test target
  expect_log 'pkg:true.*'$'\x1b\[32m''.*PASS'
}

function test_fail() {
  bazel test --experimental_ui --curses=yes --color=yes pkg:false >$TEST_log \
    && fail "expected failure"
  # FAIL is written in red bold on the same line as the test target
  expect_log 'pkg:false.*'$'\x1b\[31m\x1b\[1m''.*FAIL'
}

function test_timestamp() {
  bazel test --experimental_ui --show_timestamps pkg:true 2>$TEST_log \
    || fail "${PRODUCT_NAME} test failed"
  # expect something that looks like HH:mm:ss
  expect_log '[0-2][0-9]:[0-5][0-9]:[0-6][0-9]'
}

function test_info_spacing() {
  # Verify that the output of "bazel info" is suitable for backtick escapes,
  # in particular free carriage-return characters.
  BAZEL_INFO_OUTPUT=XXX`bazel info --experimental_ui workspace`XXX
  echo "$BAZEL_INFO_OUTPUT" | grep -q 'XXX[^'$'\r'']*XXX' \
    || fail "${PRODUCT_NAME} info output spaced as $BAZEL_INFO_OUTPUT"
}

function test_query_spacing() {
  # Verify that the output of "bazel query" is suitable for consumption by
  # other tools, i.e., contains only result lines, separated only by newlines.
  BAZEL_QUERY_OUTPUT=`bazel query --experimental_ui 'deps(//pkg:true)'`
  echo "$BAZEL_QUERY_OUTPUT" | grep -q -v '^[@/]' \
   && fail "bazel query output is >$BAZEL_QUERY_OUTPUT<"
  echo "$BAZEL_QUERY_OUTPUT" | grep -q $'\r' \
   && fail "bazel query output is >$BAZEL_QUERY_OUTPUT<"
  true
}

function test_clean_nobuild {
  bazel clean --experimental_ui 2>$TEST_log \
   || fail "bazel shutdown failed"
  expect_not_log "actions running"
  expect_not_log "Building"
}

function test_clean_color_nobuild {
  bazel clean --experimental_ui --color=yes 2>$TEST_log \
   || fail "bazel shutdown failed"
  expect_not_log "actions running"
  expect_not_log "Building"
}

function test_help_nobuild {
  bazel help --experimental_ui 2>$TEST_log \
   || fail "bazel help failed"
  expect_not_log "actions running"
  expect_not_log "Building"
}

function test_help_color_nobuild {
  bazel help --experimental_ui --color=yes 2>$TEST_log \
   || fail "bazel help failed"
  expect_not_log "actions running"
  expect_not_log "Building"
}

function test_version_nobuild {
  bazel version --experimental_ui --curses=yes 2>$TEST_log \
   || fail "bazel version failed"
  expect_not_log "action"
  expect_not_log "Building"
}

function test_version_nobuild_announce_rc {
  bazel version --experimental_ui --curses=yes --announce_rc 2>$TEST_log \
   || fail "bazel version failed"
  expect_not_log "action"
  expect_not_log "Building"
}

function test_subcommand {
  bazel clean || fail "${PRODUCT_NAME} clean failed"
  bazel build --experimental_ui -s pkg:gentext 2>$TEST_log \
    || fail "bazel build failed"
  expect_log "here be dragons"
}

function test_subcommand_notdefault {
  bazel clean || fail "${PRODUCT_NAME} clean failed"
  bazel build --experimental_ui pkg:gentext 2>$TEST_log \
    || fail "bazel build failed"
  expect_not_log "dragons"
}

function test_loading_progress {
  bazel clean || fail "${PRODUCT_NAME} clean failed"
  bazel test --experimental_ui pkg:true 2>$TEST_log \
    || fail "${PRODUCT_NAME} test failed"
  # some progress indicator is shown during loading
  expect_log 'Loading.*[0-9,]* packages'
}

function test_failure_scrollback_buffer_curses {
  bazel clean || fail "${PRODUCT_NAME} clean failed"
  bazel test --experimental_ui --curses=yes --color=yes \
    --nocache_test_results pkg:false pkg:slow 2>$TEST_log \
    && fail "expected failure"
  # Some line starts with FAIL in red bold.
  expect_log '^'$'\(.*\x1b\[K\)*\x1b\[31m\x1b\[1mFAIL:'
}

function test_terminal_title {
  bazel test --experimental_ui --curses=yes \
    --progress_in_terminal_title pkg:true \
    2>$TEST_log || fail "${PRODUCT_NAME} test failed"
  # The terminal title is changed
  expect_log $'\x1b\]0;.*\x07'
}

function test_failure_scrollback_buffer {
  bazel clean || fail "${PRODUCT_NAME} clean failed"
  bazel test --experimental_ui --curses=no --color=yes \
    --nocache_test_results pkg:false pkg:slow 2>$TEST_log \
    && fail "expected failure"
  # Some line starts with FAIL in red bold.
  expect_log '^'$'\x1b\[31m\x1b\[1mFAIL:'
}

function test_streamed {
  bazel test --experimental_ui --curses=yes --color=yes \
    --nocache_test_results --test_output=streamed pkg:output >$TEST_log \
    || fail "expected success"
  expect_log 'foobar'
}

function test_output_limit {
    # Verify that output limting works
    bazel clean --expunge
    bazel version
    # The two actions produce about 100k of output each. As we set an output
    # limit to 50k total, we expect it to be truncated reasonably so that we
    # can see the end of the output of both actions, while still staying in
    # the limit.
    # However, that limit only applies to the output produces by the bazel
    # server; any startup message generated by the client is on top of that.
    # So we add another 1k output for what the client has to tell.
    bazel build --experimental_ui --curses=yes --color=yes \
          --experimental_ui_limit_console_output=51200 \
          pkg:withOutputA pkg:withOutputB >$TEST_log 2>&1 \
    || fail "expected success"
    expect_log 'Ending A'
    expect_log 'Ending B'
    output_length=`cat $TEST_log | wc -c`
    [ "${output_length}" -le 52224 ] \
        || fail "Output too large, is ${output_length}"
}

function test_status_despite_output_limit {
    # Verify that even if we limit the output very strictly, we
    # still find the test summary.
    bazel clean --expunge
    bazel version
    bazel test --experimental_ui --curses=yes --color=yes \
          --experimental_ui_limit_console_output=500 \
          pkg:truedependingonoutput >$TEST_log 2>&1 \
    || fail "expected success"
    expect_log "//pkg:truedependingonoutput.*PASSED"

    # Also sanity check that the limit was applied, again, allowing
    # 2k for any startup messages etc generated by the client.
    output_length=`cat $TEST_log | wc -c`
    [ "${output_length}" -le 2724 ] \
        || fail "Output too large, is ${output_length}"
}

run_suite "Integration tests for ${PRODUCT_NAME}'s experimental UI"
