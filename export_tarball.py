#!/usr/bin/env python3
# Copyright (c) 2012 The Chromium Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
"""
This tool creates a tarball with all the sources, but without .git directories.
It can also remove files which are not strictly required for build, so that
the resulting tarball can be reasonably small (last time it was ~110 MB).
Example usage:
export_tarball.py /foo/bar
The above will create file /foo/bar.tar.xz.
"""
import optparse
import os
import stat
import subprocess
import sys
import tarfile
nonessential_dirs = (
    'build/linux/debian_bullseye_amd64-sysroot',
    'build/linux/debian_bullseye_i386-sysroot',
    'third_party/blink/tools',
    'third_party/blink/web_tests',
    'third_party/hunspell_dictionaries',
    'third_party/hunspell/tests',
    'third_party/instrumented_libs',
    'third_party/jdk/current',
    'third_party/jdk/extras',
    'third_party/liblouis/src/tests/braille-specs',
    'third_party/llvm-build',
    'third_party/xdg-utils/tests',
    'v8/test',
)
ESSENTIAL_FILES = (
    'chrome/test/data/webui/i18n_process_css_test.html',
    'chrome/test/data/webui/mojo/foobar.mojom',
    # TODO(rockot): Remove this once web_ui_test.mojom is no longer in the
    # chrome/test directory (https://crbug.com/926270).
    'chrome/test/data/webui/web_ui_test.mojom',
    # Allows the orchestrator_all target to work with gn gen
    'v8/test/torque/test-torque.tq',
)
ESSENTIAL_GIT_DIRS = (
    # The .git subdirs in the Rust checkout need to exist to build rustc.
    'third_party/rust-src/',)
TEST_DIRS = (
    'chrome/test/data',
    'content/test/data',
    'courgette/testdata',
    'extensions/test/data',
    'media/test/data',
    'native_client/src/trusted/service_runtime/testdata',
    'third_party/breakpad/breakpad/src/processor/testdata',
    'third_party/catapult/tracing/test_data',
)
# Workaround lack of the exclude parameter in add method in python-2.4.
# TODO(phajdan.jr): remove the workaround when it's not needed on the bot.
class MyTarFile(tarfile.TarFile):
  def set_remove_nonessential_files(self, remove):
    # pylint: disable=attribute-defined-outside-init
    self.__remove_nonessential_files = remove
  def set_verbose(self, verbose):
    # pylint: disable=attribute-defined-outside-init
    self.__verbose = verbose
  def set_src_dir(self, src_dir):
    # pylint: disable=attribute-defined-outside-init
    self.__src_dir = src_dir
  def set_mtime(self, mtime):
    # pylint: disable=attribute-defined-outside-init
    self.__mtime = mtime
  def __report_skipped(self, name):
    if self.__verbose:
      print('D\t%s' % name)
  def __report_added(self, name):
    if self.__verbose:
      print('A\t%s' % name)
  def __filter(self, tar_info):
    tar_info.mtime = self.__mtime
    tar_info.mode |= stat.S_IWUSR
    tar_info.uid = 0
    tar_info.gid = 0
    tar_info.uname = '0'
    tar_info.gname = '0'
    return tar_info
  # pylint: disable=redefined-builtin
  def add(self, name, arcname=None, recursive=True, *, filter=None):
    if os.path.islink(name) and not os.path.exists(name):
      # Beware of symlinks whose target is nonessential
      self.__report_skipped(name)
      return
    rel_name = os.path.relpath(name, self.__src_dir)
    file_path, file_name = os.path.split(name)
    if file_name == '__pycache__' or file_name.endswith('.pyc'):
      self.__report_skipped(name)
      return
    if file_name in ('.svn', 'out'):
      # Since m132 devtools-frontend requires files in node_modules/<module>/out
      # to prevent this happening again we can exclude based on the path
      # rather than explicitly allowlisting
      if 'node_modules' not in file_path:
        self.__report_skipped(name)
        return
    if file_name == '.git':
      if not any(
          rel_name.startswith(essential) for essential in ESSENTIAL_GIT_DIRS):
        self.__report_skipped(name)
        return
    if self.__remove_nonessential_files:
      # WebKit change logs take quite a lot of space. This saves ~10 MB
      # in a bzip2-compressed tarball.
      if 'ChangeLog' in name:
        self.__report_skipped(name)
        return
      # Preserve GYP/GN files, and other potentially critical files, so that
      # build/gyp_chromium / gn gen can work.
      #
      # Preserve `*.pydeps` files too. `gn gen` reads them to generate build
      # targets, even if those targets themselves are not built
      # (crbug.com/1362021).
      keep_file = ('.gyp' in file_name or '.gn' in file_name or
                   '.isolate' in file_name or '.grd' in file_name or
                   file_name.endswith('.pydeps') or rel_name in ESSENTIAL_FILES)
      # Remove contents of non-essential directories.
      if not keep_file:
        for nonessential_dir in (set(nonessential_dirs) | set(TEST_DIRS)):
          if rel_name.startswith(nonessential_dir) and os.path.isfile(name):
            self.__report_skipped(name)
            return
    self.__report_added(name)
    tarfile.TarFile.add(self, name, arcname=arcname, recursive=recursive, filter=self.__filter)
def main(argv):
  parser = optparse.OptionParser()
  parser.add_option("--basename")
  parser.add_option("--remove-nonessential-files",
                    dest="remove_nonessential_files",
                    action="store_true", default=False)
  parser.add_option("--test-data", action="store_true")
  # TODO(phajdan.jr): Remove --xz option when it's not needed for compatibility.
  parser.add_option("--xz", action="store_true")
  parser.add_option("--verbose", action="store_true", default=False)
  parser.add_option("--src-dir")
  parser.add_option("--version")
  options, args = parser.parse_args(argv)
  if len(args) != 1:
    print('You must provide only one argument: output file name')
    print('(without .tar.xz extension).')
    return 1
  if not options.version:
    print('A version number must be provided via the --version option.')
    return 1
  if not os.path.exists(options.src_dir):
    print('Cannot find the src directory ' + options.src_dir)
    return 1
  output_fullname = args[0] + '.tar.xz'
  output_basename = options.basename or os.path.basename(args[0])
  tarball = open(output_fullname, 'w')
  xz = subprocess.Popen(
      ['xz', '-T', '0', '-9', '-'],
      stdin=subprocess.PIPE,
      stdout=tarball)
  archive = MyTarFile.open(None, 'w|', xz.stdin)
  archive.set_remove_nonessential_files(options.remove_nonessential_files)
  archive.set_verbose(options.verbose)
  archive.set_src_dir(options.src_dir)
  with open(os.path.join(options.src_dir, 'build/util/LASTCHANGE.committime'), 'r') as f:
    timestamp = int(f.read())
    archive.set_mtime(timestamp)
  try:
    if options.test_data:
      for directory in TEST_DIRS:
        test_dir = os.path.join(options.src_dir, directory)
        if not os.path.isdir(test_dir):
          # A directory may not exist depending on the milestone we're building
          # a tarball for.
          print('"%s" not present; skipping.' % test_dir)
          continue
        archive.add(test_dir,
                    arcname=os.path.join(output_basename, directory))
    else:
      archive.add(options.src_dir, arcname=output_basename)
  finally:
    archive.close()
  xz.stdin.close()
  if xz.wait() != 0:
    print('xz -9 failed!')
    return 1
  tarball.flush()
  tarball.close()
  return 0
if __name__ == "__main__":
  sys.exit(main(sys.argv[1:]))
