#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# vim:ts=4:et
# This file is part of solidity.
#
# solidity is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# solidity is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with solidity.  If not, see <http://www.gnu.org/licenses/>
#
# (c) solidity contributors.
# ------------------------------------------------------------------------------
# Bash script to test the import/exports.
# ast import/export tests:
#   - first exporting a .sol file to JSON, then loading it into the compiler
#     and exporting it again. The second JSON should be identical to the first.

set -euo pipefail

READLINK=readlink
if [[ "$OSTYPE" == "darwin"* ]]; then
    READLINK=greadlink
fi
REPO_ROOT=$(${READLINK} -f "$(dirname "$0")"/..)
SOLIDITY_BUILD_DIR=${SOLIDITY_BUILD_DIR:-${REPO_ROOT}/build}
SOLC="${SOLIDITY_BUILD_DIR}/solc/solc"
SPLITSOURCES="${REPO_ROOT}/scripts/splitSources.py"

# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"

function print_usage
{
    fail "Usage: ${0} ast|evm-assembly [--exit-on-error]."
}

function print_used_commands
{
    local test_directory="$1"
    local export_command="$2"
    local import_command="$3"
    printError "You can find the files used for this test here: ${test_directory}"
    printError "Used commands for test:"
    printError "# export"
    echo "$ ${export_command}" >&2
    printError "# import"
    echo "$ ${import_command}" >&2
}

function print_stderr_stdout
{
    local error_message="$1"
    local stderr_file="$2"
    local stdout_file="$3"
    printError "$error_message"
    printError ""
    printError "stderr:"
    cat "$stderr_file" >&2
    printError ""
    printError "stdout:"
    cat "$stdout_file" >&2
}

IMPORT_TEST_TYPE=
EXIT_ON_ERROR=0
for PARAM in "$@"
do
    case "$PARAM" in
        ast) IMPORT_TEST_TYPE="ast" ;;
        evm-assembly) IMPORT_TEST_TYPE="evm-assembly" ;;
        --exit-on-error) EXIT_ON_ERROR=1 ;;
        *) print_usage ;;
    esac
done

SYNTAXTESTS_DIR="${REPO_ROOT}/test/libsolidity/syntaxTests"
ASTJSONTESTS_DIR="${REPO_ROOT}/test/libsolidity/ASTJSON"
SEMANTICTESTS_DIR="${REPO_ROOT}/test/libsolidity/semanticTests"

FAILED=0
UNCOMPILABLE=0
TESTED=0

function ast_import_export_equivalence
{
    local sol_file="$1"
    local input_files=( "${@:2}" )

    local export_command=("$SOLC" --combined-json ast --pretty-json --json-indent 4 "${input_files[@]}")
    local import_command=("$SOLC" --import-ast --combined-json ast --pretty-json --json-indent 4 expected.json)

    # export ast - save ast json as expected result (silently)
    if ! "${export_command[@]}" > expected.json 2> stderr_export.txt
    then
        print_stderr_stdout "ERROR: AST reimport failed (export) for input file ${sol_file}." ./stderr_export.txt ./expected.json
        print_used_commands "$(pwd)" "${export_command[*]} > expected.json" "${import_command[*]}"
        return 1
    fi

    # (re)import ast - and export it again as obtained result (silently)
    if ! "${import_command[@]}" > obtained.json 2> stderr_import.txt
    then
        print_stderr_stdout "ERROR: AST reimport failed (import) for input file ${sol_file}." ./stderr_import.txt ./obtained.json
        print_used_commands "$(pwd)" "${export_command[*]} > expected.json" "${import_command[*]}"
        return 1
    fi

    # compare expected and obtained ast's
    if diff_files expected.json obtained.json
    then
        echo -n "✅"
    else
        printError "❌ ERROR: AST reimport failed for ${sol_file}"
        if [[ $EXIT_ON_ERROR == 1 ]]
        then
            print_used_commands "$(pwd)" "${export_command[*]}" "${import_command[*]}"
            return 1
        fi
        FAILED=$((FAILED + 1))
    fi
    TESTED=$((TESTED + 1))
}

function evmjson_import_export_equivalence
{
    local sol_file="$1"
    local input_files=( "${@:2}" )
    local outputs=( "asm" "bin" "bin-runtime" "opcodes" "srcmap" "srcmap-runtime" )
    local export_command=("$SOLC" --combined-json "$(IFS=, ; echo "${outputs[*]}")" --pretty-json --json-indent 4 "${input_files[@]}")
    local success=1
    if ! "${export_command[@]}" > expected.json 2> expected.error
    then
        success=0
        printError "❌ ERROR: (export) EVM Assembly JSON reimport failed for ${sol_file}"
        if [[ $EXIT_ON_ERROR == 1 ]]
        then
            print_used_commands "$(pwd)" "${export_command[*]}" ""
            return 1
        fi
    fi

    # Note that we have some test files, that only consists of free functions.
    # Those files doesn't define any contracts, so the resulting json does not define any
    # keys. In this case `jq` returns an error like `jq: error: null (null) has no keys`
    # to not get spammed by these errors, errors are redirected to /dev/null.
    for contract in $(jq '.contracts | keys | .[]' expected.json 2> /dev/null)
    do
        for output in "${outputs[@]}"
        do
            jq --raw-output ".contracts.${contract}.\"${output}\"" expected.json > "expected.${output}.json"
        done

        assembly=$(cat expected.asm.json)
        [[ $assembly != "" && $assembly != "null" ]] || continue

        local import_command=("${SOLC}" --combined-json "bin,bin-runtime,opcodes,asm,srcmap,srcmap-runtime" --pretty-json --json-indent 4 --import-asm-json expected.asm.json)
        if ! "${import_command[@]}" > obtained.json 2> obtained.error
        then
            success=0
            printError "❌ ERROR: (import) EVM Assembly JSON reimport failed for ${sol_file}"
            if [[ $EXIT_ON_ERROR == 1 ]]
            then
                print_used_commands "$(pwd)" "${export_command[*]}" "${import_command[*]}"
                return 1
            fi
        fi

        for output in "${outputs[@]}"
        do
            for obtained_contract in $(jq '.contracts | keys | .[]' obtained.json  2> /dev/null)
            do
                jq --raw-output ".contracts.${obtained_contract}.\"${output}\"" obtained.json > "obtained.${output}.json"
                # compare expected and obtained evm assembly json
                if ! diff_files "expected.${output}.json" "obtained.${output}.json"
                then
                    success=0
                    printError "❌ ERROR: (${output}) EVM Assembly JSON reimport failed for ${sol_file}"
                    if [[ $EXIT_ON_ERROR == 1 ]]
                    then
                        print_used_commands "$(pwd)" "${export_command[*]}" "${import_command[*]}"
                        return 1
                    fi
                fi
            done
        done

        # direct export via --asm-json, if imported with --import-asm-json.
        if ! "${SOLC}" --asm-json --import-asm-json expected.asm.json --pretty-json --json-indent 4 | tail -n+4 > obtained_direct_import_export.json 2> obtained_direct_import_export.error
        then
            success=0
            printError "❌ ERROR: (direct) EVM Assembly JSON reimport failed for ${sol_file}"
            if [[ $EXIT_ON_ERROR == 1 ]]
            then
                print_used_commands "$(pwd)" "${SOLC} --asm-json --import-asm-json expected.asm.json --pretty-json --json-indent 4 | tail -n+4" ""
                return 1
            fi
        fi

        # reformat json files using jq.
        jq . expected.asm.json > expected.asm.json.pretty
        jq . obtained_direct_import_export.json > obtained_direct_import_export.json.pretty

        # compare expected and obtained evm assembly.
        if ! diff_files expected.asm.json.pretty obtained_direct_import_export.json.pretty
        then
            success=0
            printError "❌ ERROR: EVM Assembly JSON reimport failed for ${sol_file}"
            if [[ $EXIT_ON_ERROR == 1 ]]
            then
                print_used_commands "$(pwd)" "${export_command[*]}" "${import_command[*]}"
                return 1
            fi
        fi
    done

    if (( success == 1 ))
    then
        TESTED=$((TESTED + 1))
    else
        FAILED=$((FAILED + 1))
    fi
}

# function tests whether exporting and importing again is equivalent.
# Results are recorded by adding to FAILED or UNCOMPILABLE.
# Also, in case of a mismatch a diff is printed
# Expected parameters:
# $1 name of the file to be exported and imported
# $2 any files needed to do so that might be in parent directories
function test_import_export_equivalence {
    local sol_file="$1"
    local input_files=( "${@:2}" )
    local OUTPUT
    local SOLC_RC

    set +e
    OUTPUT=$("$SOLC" --bin "${input_files[@]}" 2>&1)
    SOLC_RC=$?
    set -e

    # if input files where compilable with success
    if (( SOLC_RC == 0 ))
    then
        case "$IMPORT_TEST_TYPE" in
            ast) ast_import_export_equivalence "${sol_file}" "${input_files[@]}" ;;
            evm-assembly) evmjson_import_export_equivalence "${sol_file}" "${input_files[@]}" ;;
            *) fail "Unknown import test type '${IMPORT_TEST_TYPE}'. Aborting." ;;
        esac
    else
        UNCOMPILABLE=$((UNCOMPILABLE + 1))
        # solc will return exit code 2, if it was terminated by an uncaught exception.
        if (( SOLC_RC == 2 ))
        then
          # Ignore all UnimplementedFeatureError exceptions.
          if [[ "$OUTPUT" != *"UnimplementedFeatureError"* ]]
          then
            printError "\n\nERROR: Uncaught Exception while executing '$SOLC --bin ${input_files[*]}':\n${OUTPUT}\n"
            exit 1
          fi
        fi
    fi
}

WORKINGDIR=$PWD

command_available "$SOLC" --version
command_available jq --version

case "$IMPORT_TEST_TYPE" in
    ast) TEST_DIRS=("${SYNTAXTESTS_DIR}" "${ASTJSONTESTS_DIR}") ;;
    evm-assembly) TEST_DIRS=("${SEMANTICTESTS_DIR}") ;;
    *)  print_usage ;;
esac

# boost_filesystem_bug specifically tests a local fix for a boost::filesystem
# bug. Since the test involves a malformed path, there is no point in running
# tests on it. See https://github.com/boostorg/filesystem/issues/176
IMPORT_TEST_FILES=$(find "${TEST_DIRS[@]}" -name "*.sol" -and -not -name "boost_filesystem_bug.sol")

NSOURCES="$(echo "${IMPORT_TEST_FILES}" | wc -l)"
echo "Looking at ${NSOURCES} .sol files..."

for solfile in $IMPORT_TEST_FILES
do
    echo -n "·"
    # create a temporary sub-directory
    FILETMP=$(mktemp -d)
    cd "$FILETMP"

    set +e
    OUTPUT=$("$SPLITSOURCES" "$solfile")
    SPLITSOURCES_RC=$?
    set -e

    if (( SPLITSOURCES_RC == 0 ))
    then
        IFS=' ' read -ra OUTPUT_ARRAY <<< "$OUTPUT"
        test_import_export_equivalence "$solfile" "${OUTPUT_ARRAY[@]}"
    elif (( SPLITSOURCES_RC == 1 ))
    then
        test_import_export_equivalence "$solfile" "$solfile"
    elif (( SPLITSOURCES_RC == 2 ))
    then
        # The script will exit with return code 2, if an UnicodeDecodeError occurred.
        # This is the case if e.g. some tests are using invalid utf-8 sequences. We will ignore
        # these errors, but print the actual output of the script.
        printError "\n\n${OUTPUT}\n\n"
        test_import_export_equivalence "$solfile" "$solfile"
    else
        # All other return codes will be treated as critical errors. The script will exit.
        printError "\n\nGot unexpected return code ${SPLITSOURCES_RC} from '${SPLITSOURCES} ${solfile}'. Aborting."
        printError "\n\n${OUTPUT}\n\n"

        cd "$WORKINGDIR"
        # Delete temporary files
        rm -rf "$FILETMP"

        exit 1
    fi

    cd "$WORKINGDIR"
    # Delete temporary files
    rm -rf "$FILETMP"
done

echo

if (( FAILED == 0 ))
then
    echo "SUCCESS: ${TESTED} tests passed, ${FAILED} failed, ${UNCOMPILABLE} could not be compiled (${NSOURCES} sources total)."
else
    fail "FAILURE: Out of ${NSOURCES} sources, ${FAILED} failed, (${UNCOMPILABLE} could not be compiled)."
fi
