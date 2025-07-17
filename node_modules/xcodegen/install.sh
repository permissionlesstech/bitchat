#!/bin/bash
#
# name:
#   install.sh
#
# description:
#   Install XcodeGen to /usr/local
#
#     - /usr/local/bin/xcodegen
#     - /usr/local/share/xcodegen/SettingPresets
#
# parameters:
#   - 1: install location

PREFIX=${PREFIX:-${1:-/usr/local}}
BASE_DIR=$(cd `dirname $0`; pwd)

cp -r $BASE_DIR/share "${PREFIX}"
## Linked by npm
#cp -r $BASE_DIR/bin "${PREFIX}"
