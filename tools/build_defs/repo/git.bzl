# Copyright 2015 The Bazel Authors. All rights reserved.
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
"""Rules for cloning external git repositories."""

load(":utils.bzl", "patch", "update_attrs", "workspace_and_buildfile")


def _if_debug(cond, st, what="Action"):
    "Print if 'cond'."
    if cond:
        print("{} returned {}\n{}\n----\n{}".format(what, st.return_code, st.stdout, st.stderr))

def _setup_cache(ctx, git_cache):
    # Set-up git_cache git repository.
    bash_exe = ctx.os.environ["BAZEL_SH"] if "BAZEL_SH" in ctx.os.environ else "bash"
    st = ctx.execute([bash_exe, "-c", """set -ex
  mkdir -p {git_cache}
  git -C {git_cache} init --bare || :
  """.format(git_cache=git_cache)], environment = ctx.os.environ)
    _if_debug(cond=ctx.attr.verbose, st=st, what='Init')
    if st.return_code:
        fail("Error ... {}:\n{}\n---\n{}".format(ctx.name, st.stdout, st.stderr))

def _get_repository_from_cache(ctx, directory, ref, git_cache):
    bash_exe = ctx.os.environ["BAZEL_SH"] if "BAZEL_SH" in ctx.os.environ else "bash"
    exec_result = ctx.execute([bash_exe, "-c", """
  cd {working_dir}
  set -ex
      rm -rf '{directory}' '{dir_link}'
      git -C {git_cache} worktree prune
      git -C {git_cache} worktree add '{directory}' {ref}
  """.format(
        working_dir = ctx.path(".").dirname,
        dir_link = ctx.path("."),
        directory = directory,
        ref = ref,
        git_cache = git_cache,
    )], environment = ctx.os.environ)
    _if_debug(cond=ctx.attr.verbose, st=exec_result, what='Checkout')

    return exec_result

def _populate_cache(ctx, git_cache, remote_name, ref, shallow):
    # 'remote add x' must be done only if x does not exist
    bash_exe = ctx.os.environ["BAZEL_SH"] if "BAZEL_SH" in ctx.os.environ else "bash"
    st = ctx.execute([bash_exe, "-c", """set -ex
  git -C {git_cache} remote add '{remote_name}' '{remote}' || \
                      git -C {git_cache} remote set-url '{remote_name}' '{remote}'
  git -C {git_cache} fetch '{shallow}' '{remote_name}' {ref} || \
                      git -C {git_cache} fetch '{remote_name}' {ref} || \
                      git -C {git_cache} '{shallow}' fetch '{remote_name}' || \
                      git -C {git_cache} fetch '{remote_name}'
  """.format(
      git_cache=git_cache,
      remote_name=remote_name,
      remote=ctx.attr.remote,
      ref=ref,
      shallow=shallow)], environment = ctx.os.environ)
    _if_debug(cond=ctx.attr.verbose, st=st, what='Fetching')

    if st.return_code:
        fail("Error fetching {}:\n{}\n----\n{}".format(ctx.name, st.stdout, st.stderr))

def _clone_or_update(ctx):
    if ((not ctx.attr.tag and not ctx.attr.commit and not ctx.attr.branch) or
        (ctx.attr.tag and ctx.attr.commit) or
        (ctx.attr.tag and ctx.attr.branch) or
        (ctx.attr.commit and ctx.attr.branch)):
        fail("Exactly one of commit, tag, or branch must be provided")
    remote_name = "remote_" + str(hash(ctx.attr.remote))
    shallow = ""
    if ctx.attr.commit:
        ref = ctx.attr.commit
    elif ctx.attr.tag:
        ref = "tags/" + ctx.attr.tag
        shallow = "--depth=1"
    else:
        ref = ctx.attr.branch
        shallow = "--depth=1"
    directory = str(ctx.path("."))
    if ctx.attr.strip_prefix:
        directory = directory + "-tmp"
    if ctx.attr.shallow_since:
        if ctx.attr.tag:
            fail("shallow_since not allowed if a tag is specified; --depth=1 will be used for tags")
        if ctx.attr.branch:
            fail("shallow_since not allowed if a branch is specified; --depth=1 will be used for branches")
        shallow = "--shallow-since=%s" % ctx.attr.shallow_since

    ctx.report_progress("Cloning %s of %s" % (ref, ctx.attr.remote))
    if (ctx.attr.verbose):
        print("git.bzl: Cloning or updating %s repository %s using strip_prefix of [%s]" %
              (
                  " (%s)" % shallow if shallow else "",
                  ctx.name,
                  ctx.attr.strip_prefix if ctx.attr.strip_prefix else "None",
              ))
    bash_exe = ctx.os.environ["BAZEL_SH"] if "BAZEL_SH" in ctx.os.environ else "bash"
    git_cache = ctx.os.environ.get("BAZEL_GIT_REPOSITORY_CACHE")

    if git_cache:
        _setup_cache(ctx, git_cache)
        st = _get_repository_from_cache(ctx, directory, ref, git_cache)

        if st.return_code:
            _populate_cache(ctx, git_cache, remote_name, ref, shallow)
            st = _get_repository_from_cache(ctx, directory, ref, git_cache)

            if st.return_code:
                fail("""Error checking out worktree %s. Maybe your git version is too old?. Using Git
                repository caching requires at least Git 2.5.0. Her is the error we got :\n%s""" %
                (ctx.name, st.stderr))
    else:
        st = ctx.execute([bash_exe, "-c", """
    cd {working_dir}
    set -ex
    ( cd {working_dir} &&
        if ! ( cd '{dir_link}' && [[ "$(git rev-parse --git-dir)" == '.git' ]] ) >/dev/null 2>&1; then
        rm -rf '{directory}' '{dir_link}'
        git clone '{shallow}' '{remote}' '{directory}' || git clone '{remote}' '{directory}'
        fi
        git -C '{directory}' reset --hard {ref} || \
        ((git -C '{directory}' fetch '{shallow}' origin {ref}:{ref} || \
        git -C '{directory}' fetch origin {ref}:{ref}) && git -C '{directory}' reset --hard {ref})
        git -C '{directory}' clean -xdf )
    """.format(
            working_dir = ctx.path(".").dirname,
            dir_link = ctx.path("."),
            directory = directory,
            remote = ctx.attr.remote,
            ref = ref,
            shallow = shallow,
        )], environment = ctx.os.environ)

        if st.return_code:
            fail("Error cloning %s:\n%s" % (ctx.name, st.stderr))


    if ctx.attr.strip_prefix:
        dest_link = "{}/{}".format(directory, ctx.attr.strip_prefix)
        if not ctx.path(dest_link).exists:
            fail("strip_prefix at {} does not exist in repo".format(ctx.attr.strip_prefix))

        ctx.symlink(dest_link, ctx.path("."))
    if ctx.attr.init_submodules:
        ctx.report_progress("Updating submodules")
        st = ctx.execute([bash_exe, "-c", """
set -ex
(   git -C '{directory}' submodule update --init --checkout --force )
  """.format(
            directory = ctx.path("."),
        )], environment = ctx.os.environ)

        if st.return_code:
            fail("error updating submodules %s:\n%s" % (ctx.name, st.stderr))

    ctx.report_progress("Recording actual commit")

    # After the fact, determine the actual commit and its date
    actual_commit = ctx.execute([
        bash_exe,
        "-c",
        "(git -C '{directory}' log -n 1 --pretty='format:%H')".format(
            directory = ctx.path("."),
        ),
    ]).stdout
    shallow_date = ctx.execute([
        bash_exe,
        "-c",
        "(git -C '{directory}' log -n 1 --pretty='format:%cd' --date=raw)".format(
            directory = ctx.path("."),
        ),
    ]).stdout
    return {"commit": actual_commit, "shallow_since": shallow_date}

def _remove_dot_git(ctx):
    # Remove the .git directory, if present
    bash_exe = ctx.os.environ["BAZEL_SH"] if "BAZEL_SH" in ctx.os.environ else "bash"
    ctx.execute([
        bash_exe,
        "-c",
        "rm -rf '{directory}'".format(directory = ctx.path(".git")),
    ])

def _update_git_attrs(orig, keys, override):
    result = update_attrs(orig, keys, override)

    # if we found the actual commit, remove all other means of specifying it,
    # like tag or branch.
    if "commit" in result:
        result.pop("tag", None)
        result.pop("branch", None)
    return result

_common_attrs = {
    "remote": attr.string(
        mandatory = True,
        doc = "The URI of the remote Git repository",
    ),
    "commit": attr.string(
        default = "",
        doc =
            "specific commit to be checked out." +
            " Precisely one of branch, tag, or commit must be specified.",
    ),
    "shallow_since": attr.string(
        default = "",
        doc =
            "an optional date, not after the specified commit; the " +
            "argument is not allowed if a tag is specified (which allows " +
            "cloning with depth 1). Setting such a date close to the " +
            "specified commit allows for a more shallow clone of the " +
            "repository, saving bandwidth " +
            "and wall-clock time.",
    ),
    "tag": attr.string(
        default = "",
        doc =
            "tag in the remote repository to checked out." +
            " Precisely one of branch, tag, or commit must be specified.",
    ),
    "branch": attr.string(
        default = "",
        doc =
            "branch in the remote repository to checked out." +
            " Precisely one of branch, tag, or commit must be specified.",
    ),
    "init_submodules": attr.bool(
        default = False,
        doc = "Whether to clone submodules in the repository.",
    ),
    "verbose": attr.bool(default = False),
    "strip_prefix": attr.string(
        default = "",
        doc = "A directory prefix to strip from the extracted files.",
    ),
    "patches": attr.label_list(
        default = [],
        doc =
            "A list of files that are to be applied as patches afer " +
            "extracting the archive.",
    ),
    "patch_tool": attr.string(
        default = "patch",
        doc = "The patch(1) utility to use.",
    ),
    "patch_args": attr.string_list(
        default = ["-p0"],
        doc = "The arguments given to the patch tool",
    ),
    "patch_cmds": attr.string_list(
        default = [],
        doc = "Sequence of commands to be applied after patches are applied.",
    ),
}

_new_git_repository_attrs = dict(_common_attrs.items() + {
    "build_file": attr.label(
        allow_single_file = True,
        doc =
            "The file to use as the BUILD file for this repository." +
            "This attribute is an absolute label (use '@//' for the main " +
            "repo). The file does not need to be named BUILD, but can " +
            "be (something like BUILD.new-repo-name may work well for " +
            "distinguishing it from the repository's actual BUILD files. " +
            "Either build_file or build_file_content must be specified.",
    ),
    "build_file_content": attr.string(
        doc =
            "The content for the BUILD file for this repository. " +
            "Either build_file or build_file_content must be specified.",
    ),
    "workspace_file": attr.label(
        doc =
            "The file to use as the `WORKSPACE` file for this repository. " +
            "Either `workspace_file` or `workspace_file_content` can be " +
            "specified, or neither, but not both.",
    ),
    "workspace_file_content": attr.string(
        doc =
            "The content for the WORKSPACE file for this repository. " +
            "Either `workspace_file` or `workspace_file_content` can be " +
            "specified, or neither, but not both.",
    ),
}.items())

def _new_git_repository_implementation(ctx):
    if ((not ctx.attr.build_file and not ctx.attr.build_file_content) or
        (ctx.attr.build_file and ctx.attr.build_file_content)):
        fail("Exactly one of build_file and build_file_content must be provided.")
    update = _clone_or_update(ctx)
    workspace_and_buildfile(ctx)
    patch(ctx)
    _remove_dot_git(ctx)
    return _update_git_attrs(ctx.attr, _new_git_repository_attrs.keys(), update)

def _git_repository_implementation(ctx):
    update = _clone_or_update(ctx)
    patch(ctx)
    _remove_dot_git(ctx)
    return _update_git_attrs(ctx.attr, _common_attrs.keys(), update)

new_git_repository = repository_rule(
    implementation = _new_git_repository_implementation,
    attrs = _new_git_repository_attrs,
    doc = """Clone an external git repository.

Clones a Git repository, checks out the specified tag, or commit, and
makes its targets available for binding. Also determine the id of the
commit actually checked out and its date, and return a dict with parameters
that provide a reproducible version of this rule (which a tag not necessarily
is).
""",
)

git_repository = repository_rule(
    implementation = _git_repository_implementation,
    attrs = _common_attrs,
    doc = """Clone an external git repository.

Clones a Git repository, checks out the specified tag, or commit, and
makes its targets available for binding. Also determine the id of the
commit actually checked out and its date, and return a dict with parameters
that provide a reproducible version of this rule (which a tag not necessarily
is).
""",
)
