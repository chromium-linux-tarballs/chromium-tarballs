#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# This script is used to package the Chromium browser sources into a tarball for a given version.

source logging.sh

set -e

# This function clones the depot_tools repository from the Chromium project
# and adds the depot_tools directory to the system PATH.
#
# Usage:
#   get_depot_tools
#
# The function performs the following steps:
# 1. Clones the depot_tools repository from the Chromium project's Git repository.
# 2. Adds the cloned depot_tools directory to the system PATH environment variable.
get_depot_tools() {
	clog "Getting depot_tools"
	if [[ -d "depot_tools" ]]; then
		clog "depot_tools already exists, pulling latest changes"
		pushd depot_tools &> /dev/null || die "Failed to enter depot_tools directory"
		if [ "$(git symbolic-ref --short -q HEAD)" == "" ]; then
			clog "Currently in a detached HEAD state, checking out main branch"
			git checkout main || die "Failed to checkout main branch in depot_tools repository"
		fi
		git pull || die "Failed to pull latest changes in depot_tools repository"
		popd &> /dev/null || die "Failed to exit depot_tools directory"
	else
		clog "Cloning depot_tools repository"
		git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git || die "Failed to clone depot_tools repository"
	fi
	export PATH="$(pwd)/depot_tools:${PATH}"
}

# This script configures the gclient for Chromium development.
#
# Functions:
#
# configure_gclient(version)
#   - Configures gclient with the specified Chromium version.
#   - Arguments:
#     - version: The version of Chromium to configure gclient with.
#   - Behavior:
#     - If no version is specified, the function will terminate with an error message.
#     - Configures gclient to use the specified Chromium version from the repository.
#     - Appends the target operating system (Linux) to the .gclient configuration file.
configure_gclient() {
	if [ -z "$1" ]; then
		die "${FUNCNAME}: No version specified"
	fi
	clog "Configuring gclient with version ${1}"
	gclient config --name src "https://chromium.googlesource.com/chromium/src.git@${1}" ||
		die "Failed to configure gclient with version ${1}"
	echo "target_os = [ 'linux' ]" >> .gclient
}

# This function runs a series of hooks to update various build-related files.
# It performs the following actions:
# 1. Updates the LASTCHANGE file with the latest change information.
# 2. Updates the GPU lists version header with the latest revision ID.
# 3. Updates the Skia commit hash header with the latest commit hash from the Skia repository.
# 4. Updates the DAWN version with the latest revision from the Dawn repository.
# 5. Touches the i18n_process_css_test.html file to ensure that it exists. Tests fail if this file does not exist.
# 6. Updates the PGO profiles for the Linux target using the specified Google Storage URL base.

run_hooks() {
	clog "Running post-checkout hooks"
	src/build/util/lastchange.py -o src/build/util/LASTCHANGE
	src/build/util/lastchange.py -m GPU_LISTS_VERSION --revision-id-only --header src/gpu/config/gpu_lists_version.h
	src/build/util/lastchange.py -m SKIA_COMMIT_HASH -s src/third_party/skia --header src/skia/ext/skia_commit_hash.h
	src/build/util/lastchange.py -s src/third_party/dawn --revision src/gpu/webgpu/DAWN_VERSION
	touch src/chrome/test/data/webui/i18n_process_css_test.html
	src/tools/update_pgo_profiles.py '--target=linux' update '--gs-url-base=chromium-optimization-profiles/pgo_profiles' ||
		die "Failed to update PGO profiles"
	src/v8/tools/builtins-pgo/download_profiles.py --force --check-v8-revision --depot-tools depot_tools download ||
		die "Failed to download V8 PGO profiles"
}

# This function exports the tarballs for a given version of Chromium.
# We suffix the tarball with -linux so that it doesn't conflict with
# official tarballs, whenever they come out.
export_tarballs() {
	if [ -z "$1" ]; then
		die "${FUNCNAME}: No version specified"
	fi
	if [[ ! -d "out" ]]; then
		mkdir out || die "Failed to create out directory"
	fi
	clog "Exporting tarballs for version ${1}:"
	clog "Exporting test data tarball"
	./export_tarball.py --version --xz --test-data --remove-nonessential-files "chromium-${1}" --src-dir src/
	mv "chromium-${1}.tar.xz" "out/chromium-${1}-testdata.tar.xz" || die "Failed to move test data tarball"
	clog "Exporting main tarball"
	./export_tarball.py --version --xz --remove-nonessential-files chromium-"${1}" --src-dir src/
	mv "chromium-${1}.tar.xz" "out/chromium-${1}.tar.xz" || die "Failed to move tarball"
}

main() {
	if [ -z "${1}" ]; then
		die "No version specified"
	fi

	local version="$1"

	# Some Google Python scripts start with "#!/usr/bin/env python"
	python --version 2>&1 | grep -q '^Python 3\.' || die "Python 3 must be accessible in the PATH as \"python\""

	clog "Packaging Chromium version ${version}"

	get_depot_tools
	configure_gclient "$version"
	# We don't need the full history of the Chromium repository to generate a tarball, and we'll run a limited subset of manual hooks.
	clog "Syncing Chromium sources with no history"
	gclient sync --nohooks --no-history
	run_hooks
	export_tarballs "$version"
}

usage() {
	echo "Usage: $0 <version>"
	echo "Example: $0 91.0.4472.77"
	exit 1
}

if [ "$#" -ne 1 ]; then
	usage
fi

main "$@"
