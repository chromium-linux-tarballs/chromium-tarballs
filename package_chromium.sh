#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# This script is used to package the Chromium browser sources into a tarball for a given version.

source logging.sh

set -e
umask 022

# This function clones one of Google's Chromium-related tool repositories.
#
# Usage:
#   get_google_repo REPO_BASENAME
#
get_google_repo() {
	local repo="${1}"
	if [[ -d "${repo}" ]]; then
		clog "${repo} repository already exists, pulling latest changes"
		pushd "${repo}" &> /dev/null || die "Failed to enter ${repo} directory"
		if [ "$(git symbolic-ref --short -q HEAD)" == "" ]; then
			clog "Currently in a detached HEAD state, switching to main branch"
			git switch main || die "Failed to switch to main branch in ${repo} repository"
		fi
		git pull || die "Failed to pull latest changes in ${repo} repository"
		popd &> /dev/null || die "Failed to exit ${repo} directory"
	else
		clog "Cloning ${repo} repository"
		git clone -q --depth=1 "https://chromium.googlesource.com/chromium/tools/${repo}.git" ||
			die "Failed to clone ${repo} repository"
	fi
}

# This function configures the gclient for Chromium development.
#
# Usage:
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
	local version="${1}"
	if [ -z "${version}" ]; then
		die "${FUNCNAME}: No version specified"
	fi
	clog "Configuring gclient with version ${version}"
	gclient config --name src "https://chromium.googlesource.com/chromium/src.git@${version}" ||
		die "Failed to configure gclient with version ${version}"
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
# 7. Updates the V8 PGO profiles.
#
# These largely match what Google does in their process:
# https://chromium.googlesource.com/chromium/tools/build/+/refs/heads/main/recipes/recipes/publish_tarball.py
run_hooks() {
	clog "Running post-checkout hooks"

	src/build/util/lastchange.py -o src/build/util/LASTCHANGE

	src/build/util/lastchange.py \
		-m GPU_LISTS_VERSION \
		--revision-id-only \
		--header src/gpu/config/gpu_lists_version.h

	src/build/util/lastchange.py \
		-m SKIA_COMMIT_HASH \
		-s src/third_party/skia \
		--header src/skia/ext/skia_commit_hash.h

	src/build/util/lastchange.py \
		-m DAWN_COMMIT_HASH \
		-s src/third_party/dawn \
		--revision src/gpu/webgpu/DAWN_VERSION \
		--header src/gpu/webgpu/dawn_commit_hash.h

	touch src/chrome/test/data/webui/i18n_process_css_test.html

	src/tools/update_pgo_profiles.py \
		--target=linux \
		update \
		--gs-url-base=chromium-optimization-profiles/pgo_profiles ||
		die "Failed to update PGO profiles"

	src/v8/tools/builtins-pgo/download_profiles.py \
		--force \
		--check-v8-revision \
		--depot-tools depot_tools \
		download ||
		die "Failed to download V8 PGO profiles"

	if ! src/tools/clang/scripts/build.py \
		--without-android \
		--use-system-cmake \
		--skip-build \
		--without-fuchsia
	then
		cwarn "Failed to download LLVM components, excluding from tarball"
		rm -rf src/third_party/llvm
	fi

	if ! src/tools/rust/build_rust.py --sync-for-gnrt
	then
		cwarn "Failed to download Rust components, excluding from tarball"
		rm -rf src/third_party/rust-src
	fi

	cp -f build/recipes/recipe_modules/chromium/resources/clang-format src/buildtools/linux64/
}

get_gn_sources() {
	clog "Fetching GN sources"
	local temp_dir git_root tools_gn gn_commit basename
	temp_dir=$(mktemp -d)
	git_root="${temp_dir}/gn"
	tools_gn="src/tools/gn"
	# This is x86_64 only(?); we should add support for other architectures in the future
	gn_commit=$(src/buildtools/linux64/gn --version | perl -ne '/^\d+ \((\w+)\)$/ and print $1' | grep .)

	# Clone the GN repository
	git clone -q https://gn.googlesource.com/gn.git "${git_root}" || die "Failed to clone GN repository"
	git -C "${git_root}" config advice.detachedHead false
	git -C "${git_root}" checkout "${gn_commit}"

	# Generate last_commit_position.h
	python3 "${git_root}/build/gen.py" || die "Failed to generate last_commit_position.h"

	# Move GN sources to the tools/gn directory
	find "${git_root}" \
		-maxdepth 1 -mindepth 1 \
		-not -name ".git" \
		-not -name ".gitignore" \
		-not -name ".linux-sysroot" \
		-not -name "out" \
		-print \
	| while read -r f; do
		basename=$(basename "$f")
		rm -rf "$tools_gn/$basename"
		mv "$f" "$tools_gn/$basename" ||
			die "Failed to move $basename"
	done

	# Move last_commit_position.h
	mv \
		"${git_root}/out/last_commit_position.h" \
		"${tools_gn}/bootstrap/last_commit_position.h" ||
		die "Failed to move last_commit_position.h"

	# Clean up temporary directory
	rm -rf "$temp_dir" || die "Failed to remove temporary directory"
}

# This function should match the behavior of the export_lite_tarball()
# function in the publish_tarball.py script (excluding the export_tarball
# invocation, which we do later).
#
prune_lite_excluded_dirs() {
	local excluded_directories=$(grep -v '#' <<END
		android_webview
		build/linux/debian_bullseye_amd64-sysroot
		build/linux/debian_bullseye_i386-sysroot
		buildtools/reclient
		chrome/android
		chromecast
		ios
		native_client
		native_client_sdk
		third_party/android_platform
		third_party/angle/third_party/VK-GL-CTS
		third_party/apache-linux
		third_party/catapult/third_party/vinn/third_party/v8
		third_party/closure_compiler
		third_party/instrumented_libs
		third_party/llvm
		third_party/llvm-build
		third_party/llvm-build-tools
		third_party/node/linux
		third_party/rust-src
		third_party/rust-toolchain
		third_party/webgl
		third_party/blink/manual_tests
		# Note: perf_tests is also in TEST_DIRS
		third_party/blink/perf_tests
END
	)

	# Make destructive file operations on the copy of the checkout.
	clog "Making hard-linked copy of tree for non-destructive pruning"
	rm -rf src-lite
	cp -al src src-lite

	clog "Pruning directories excluded from lite tarball"
	for directory in ${excluded_directories}; do
		test -d "src-lite/${directory}" || continue
		find "src-lite/${directory}" \
			-type f,l \
			-regextype egrep \
			! -regex '.*\.(gn|gni|grd|grdp|isolate|pydeps)(\.[^ /]+)?' \
			! '(' '(' -iname '*COPYING*'   -o \
				  -iname '*Copyright*' -o \
				  -iname '*LICENSE*' \
			      ')' \
			      ! -iregex '.*\.(cc|cfg|cpp|h|java|js|json|m|patch|pl|py|rs|sh|sha1|stderr|ts|ya?ml)' \
			  ')' \
			-delete
	done

	# Empty directories take up space in the tarball.
	find src-lite -path 'src/.git/*' -o -type d -empty -delete
}

# This function exports the tarballs for a given version of Chromium.
# We suffix the tarball with -linux so that it doesn't conflict with
# official tarballs, whenever they come out.
export_tarballs() {
	local version="$1"
	if [ -z "${version}" ]; then
		die "${FUNCNAME}: No version specified"
	fi
	if [[ ! -d "out" ]]; then
		mkdir out || die "Failed to create out directory"
	fi
	clog "Exporting tarballs for version ${version}:"

	clog "Exporting test data tarball"
	build/recipes/recipe_modules/chromium/resources/export_tarball.py \
		--version \
		--xz \
		--test-data \
		"chromium-${version}" \
		--src-dir src/
	mv "chromium-${version}.tar.xz" "out/chromium-${version}-linux-testdata.tar.xz" ||
		die "Failed to move test data tarball"

	clog "Exporting main tarball"
	build/recipes/recipe_modules/chromium/resources/export_tarball.py \
		--version \
		--xz \
		--remove-nonessential-files \
		"chromium-${version}" \
		--src-dir src-lite/
	mv "chromium-${version}.tar.xz" "out/chromium-${version}-linux.tar.xz" ||
		die "Failed to move main tarball"

	clog "Generating hashes"
	pushd out &> /dev/null || die "Failed to enter out directory"
	local tarball
	for tarball in "chromium-${version}"-*.tar.xz; do
		../build/recipes/recipe_modules/chromium/resources/generate_hashes.py \
			"${tarball}" \
			"${tarball}.hashes"
		# Include the hashes in the log output
		cat "${tarball}.hashes"; echo
	done
	popd &> /dev/null || die "Failed to exit out directory"
}

main() {
	local version="${1}"
	if [ -z "${version}" ]; then
		die "No version specified"
	fi

	# Some Google Python scripts start with "#!/usr/bin/env python"
	python --version 2>&1 | grep -q '^Python 3\.' ||
		die "Python 3 must be accessible in the PATH as \"python\""

	clog "Packaging Chromium version ${version}"

	get_google_repo depot_tools
	get_google_repo build
	export PATH="${PWD}/depot_tools:${PATH}"

	clog "Checking for breaking changes"
	patch -p1 --dry-run < check.patch ||
		die "The publish_tarball script has changed, please update the prune_lite_excluded_dirs() function and check.patch accordingly"

	configure_gclient "${version}"
	# We don't need the full history of the Chromium repository to
	# generate a tarball, and we'll run a limited subset of manual hooks.
	clog "Syncing Chromium sources with no history"
	gclient sync --nohooks --no-history

	clog "Patching upstream scripts"
	patch -p1 --no-backup-if-mismatch < tweak-src.patch ||
		die "Failed to patch upstream source scripts"

	# This keeps down the size of the LLVM and Rust clone operations.
	export EXTRA_GIT_CLONE_ARGS="-q --shallow-since=2024-10-01"

	run_hooks
	get_gn_sources

	clog "Un-patching upstream source scripts"
	patch -p1 -R --no-backup-if-mismatch < tweak-src.patch ||
		die "Failed to un-patch upstream source scripts"

	prune_lite_excluded_dirs
	export_tarballs "${version}"
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
