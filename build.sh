#!/usr/bin/env bash

# Copyright © 2018 Joel Baranick <jbaranick@gmail.com>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


BUILD_DIR="$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)"
BINARY_DIR="$BUILD_DIR/.bin"
VERSION=$(cat $BUILD_DIR/.version)

function verbose() { echo -e "$*"; }
function error() { echo -e "ERROR: $*" 1>&2; }
function fatal() { echo -e "ERROR: $*" 1>&2; exit 1; }
function pushd () { command pushd "$@" > /dev/null; }
function popd () { command popd > /dev/null; }

function trap_add() {
  localtrap_add_cmd=$1; shift || fatal "${FUNCNAME} usage error"
  for trap_add_name in "$@"; do
    trap -- "$(
      extract_trap_cmd() { printf '%s\n' "$3"; }
      eval "extract_trap_cmd $(trap -p "${trap_add_name}")"
      printf '%s\n' "${trap_add_cmd}"
    )" "${trap_add_name}" || fatal "unable to add to trap ${trap_add_name}"
  done
}
declare -f -t trap_add

function get_platform() {
  unameOut="$(uname -s)"
  case "${unameOut}" in
    Linux*)
      echo "linux"
    ;;
    Darwin*)
      echo "darwin"
    ;;
    *)
      echo "Unsupported machine type :${unameOut}"
      exit 1
    ;;
  esac
}

PLATFORM=$(get_platform)
DEP=$BINARY_DIR/dep-$PLATFORM-amd64
GOMETALINTER=$BINARY_DIR/gometalinter
BINARY_DEPENDENCIES="$DEP,https://github.com/golang/dep/releases/download/v0.4.1/dep-$PLATFORM-amd64;$GOMETALINTER,https://github.com/alecthomas/gometalinter/releases/download/v2.0.4/gometalinter-2.0.4-$PLATFORM-amd64.tar.gz"

function download_binary() {
  local url
  local "$@"
  local tmpdir=`mktemp -d`
  trap_add "rm -rf $tmpdir" EXIT
  pushd $tmpdir
  curl -L -s -O $url
  for i in *.tar.gz; do
    [ "$i" = "*.tar.gz" ] && continue
    tar xzvf "$i" -C $tmpdir --strip-components 1 && rm -r "$i"
  done
  chmod +x $tmpdir/*
  popd
  mkdir -p $BINARY_DIR
  cp $tmpdir/* $BINARY_DIR/
}

function download_binaries() {
  for i in ${BINARY_DEPENDENCIES//;/ }; do
    binary=$(echo "$i" | awk -F',' '{print $1}')
    url=$(echo "$i" | awk -F',' '{print $2}')
    if [ ! -f "$binary" ]; then
      verbose "   --> $binary"
      download_binary url=$url || fatal "failed to download binary '$binary' from $url: $?"
    fi
  done
}

function run() {
  verbose "Fetching binaries..."
  download_binaries

  verbose "Updating dependencies..."
  $DEP ensure || fatal "dep ensure failed : $?"

  local gofiles=$(find . -path ./vendor -prune -o -print | grep '\.go$')

  verbose "Formatting source..."
  if [[ ${#gofiles[@]} -gt 0 ]]; then
    while read -r gofile; do
        gofmt -s -w $PWD/$gofile
    done <<< "$gofiles"
  fi

  verbose "Linting source..."
  $GOMETALINTER --min-confidence=.85 --disable=gotype --fast --exclude=vendor --vendor || fatal "gometalinter failed: $?"

  verbose "Checking licenses..."
  licRes=$(
  for file in $(find . -type f -iname '*.go' ! -path './vendor/*'); do
    head -n3 "${file}" | grep -Eq "(Copyright|generated|GENERATED)" || error "  Missing license in: ${file}"
  done;)
  if [ -n "${licRes}" ]; then
  	fatal "license header checking failed:\n${licRes}"
  fi

  verbose "Building binaries..."
  local revision=`git rev-parse HEAD`
  local branch=`git rev-parse --abbrev-ref HEAD`
  local host=`hostname`
  local buildDate=`date -u +"%Y-%m-%dT%H:%M:%SZ"`
  if [ ! -x "$(command -v gox)" ]; then
    echo "Getting gox..."
    go get github.com/mitchellh/gox || fatal "go get 'github.com/mitchellh/gox' failed: $?"
  fi
  gox -ldflags "-X github.com/kadaan/consulate/version.Version=$VERSION -X github.com/kadaan/consulate/version.Revision=$revision -X github.com/kadaan/consulate/version.Branch=$branch -X github.com/kadaan/consulate/version.BuildUser=$USER@$host -X github.com/kadaan/consulate/version.BuildDate=$buildDate" -output="dist/{{.Dir}}_{{.OS}}_{{.Arch}}"  || fatal "gox failed: $?"
}

run "$@"
