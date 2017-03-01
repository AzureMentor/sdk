#!/bin/bash
set -e
# switch to the root directory of dev_compiler
cd $( dirname "${BASH_SOURCE[0]}" )/..

echo "*** Patching SDK"
{ # Try
  dart -c tool/patch_sdk.dart ../.. tool/input_sdk gen/patched_sdk \
      > tool/sdk_expected_errors.txt
} || { # Catch
  # Show errors if the sdk didn't compile.
  cat tool/sdk_expected_errors.txt
  exit 1
}

echo "*** Compiling SDK to JavaScript"
{ # Try
  # TODO(jmesserly): break out dart:html & friends into a module.
  dart -c tool/build_sdk.dart \
      --dart-sdk gen/patched_sdk \
      --dart-sdk-summary=build \
      --summary-out lib/sdk/ddc_sdk.sum \
      --modules=amd \
      -o lib/js/amd/dart_sdk.js \
      --modules=es6 \
      -o lib/js/es6/dart_sdk.js \
      --modules=common \
      -o lib/js/common/dart_sdk.js \
      --modules=legacy \
      -o lib/js/legacy/dart_sdk.js \
      "$@" > tool/sdk_expected_errors.txt
} || { # Catch
  # Show errors if the sdk didn't compile.
  cat tool/sdk_expected_errors.txt
  exit 1
}
