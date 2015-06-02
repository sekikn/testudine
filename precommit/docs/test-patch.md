<!---
  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License. See accompanying LICENSE file.
-->

test-patch
==========

* [Purpose](#Purpose)
* [Pre-requisites](#Pre-requisites)
* [Basic Usage](#Basic_Usage)
* [Advanced Features](#Advanced_Features)
* [Configuring for Other Projects](#Configuring_for_Other_Projects)

## Purpose

As part of Hadoop's commit process, all patches to the source base go through a precommit test that does some (usually) light checking to make sure the proposed change does not break unit tests and/or passes some other prerequisites.  This is meant as a preliminary check for committers so that the basic patch is in a known state.  This check, called test-patch, may also be used by individual developers to verify a patch prior to sending to the Hadoop QA systems.

Other projects have adopted a similar methodology after seeing great success in the Hadoop model.  Some have even gone as far as forking Hadoop's precommit code and modifying it to meet their project's needs.

This is a modification to Hadoop's version of test-patch so that we may bring together all of these forks under a common code base to help the community as a whole.


## Pre-requisites

test-patch has the following requirements:

* Maven-based project (and maven installed)
* git-based project (and git installed)
* bash v3.x or higher
* findbugs 3.x installed
* shellcheck installed
* GNU diff
* POSIX awk
* POSIX grep
* POSIX sed
* wget
* file command
* smart-apply-patch.sh

Optional:

* Apache JIRA-based issue tracking
* JIRA cli tools


The locations of these files are (mostly) assumed to be in the file path, but may be overridden via command line options.  For Solaris and Solaris-like operating systems, the default location for the POSIX binaries is in /usr/xpg4/bin.


## Basic Usage

This command will execute basic patch testing against a patch file stored in filename:

```bash
$ cd <your repo>
$ dev-support/test-patch.sh --dirty-workspace <filename>
```

The `--dirty-workspace` flag tells test-patch that the repository is not clean and it is ok to continue.  This version command does not run the unit tests.

To do that, we need to provide the --run-tests command:


```bash
$ cd <your repo>
$ dev-support/test-patch.sh --dirty-workspace --run-tests <filename>
```

This is the same command, but now runs the unit tests.

A typical configuration is to have two repositories.  One with the code you are working on and another, clean repository.  This means you can:

```bash
$ cd <workrepo>
$ git diff --no-prefix trunk > /tmp/patchfile
$ cd ../<testrepo>
$ <workrepo>/dev-support/test-patch.sh --basedir=<testrepo> --resetrepo /tmp/patchfile
```

We used two new options here.  --basedir sets the location of the repository to use for testing.  --resetrepo tells test patch that it can go into **destructive** mode.  Destructive mode will wipe out any changes made to that repository, so use it with care!

After the tests have run, there is a directory that contains all of the test-patch related artifacts.  This is generally referred to as the patchprocess directory.  By default, test-patch tries to make something off of /tmp to contain this content.  Using the `--patchdir` command, one can specify exactly which directory to use.  This is helpful for automated precommit testing so that the Jenkins or other automated workflow system knows where to look to gather up the output.

test-patch has many other features and command line options for the basic user.  Many of these are self-explanatory.  To see the list of options, run test-patch.sh without any options or with --help.


## Advanced Features

### Self-testing

If test-patch is placed in a directory off of dev-support, test-patch can sense that it or parts that is dependent upon is being patched.  It will copy the patched version of itself in the patch processing directory and re-execute itself.

### Plug-ins

test-patch allows one to add to its basic feature set via plug-ins.  There is a directory called test-patch.d off of the directory where test-patch.sh lives.  Inside this directory one may place some bash shell fragments that, if setup with proper functions, will allow for test-patch to call it as necessary.


Every plugin must have one line in order to be recognized:

```bash
add_plugin <pluginname>
```

This function call registers the `pluginname` so that test-patch knows that it exists.  This plug-in name also acts as the key to the custom functions that you can define. For example:

```bash
function pluginname_filefilter
```

This function gets called for every file that a patch may contain.  This allows the plug-in author to determine if this plug-in should be called, what files it might need to analyze, etc.

Similarly, there are other functions that may be defined during the test-patch run:

* pluginname_postcheckout
    - executed prior to the patch being applied but after the git repository is setup.  This is useful for any early error checking that might need to be done before any heavier work.

* pluginname_preapply
    - executed prior to the patch being applied.  This is useful for any "before"-type data collection for later comparisons

* pluginname_postapply
    - executed after the patch has been applied.  This is useful for any "after"-type data collection.


* pluginname_postinstall
    - executed after the mvn install test has been done.  If any tests require the Maven repository to be up-to-date with the contents of the patch, this is the place.

* pluginname_tests
    - executed after the unit tests have completed.

    HINT: It is recommend to make the pluginname relatively small, XX characters at the most.  Otherwise the ASCII output table may be skewed.


## Configuring for Other Projects

It is impossible for any general framework to be predictive about what types of special rules any given project may have, especially when it comes to ordering and Maven profiles.  In order to assist non-Hadoop projects, a project `personality` should be added that enacts these custom rules.

A personality consists of two functions. One that determines which test types to run and another that allows a project to dictate ordering rules, flags, and profiles on a per-module, per-test run.

There can be only **one** of each personality function defined.

### Test Determination

The `personality_file_tests` function determines which tests to turn on based upon the file name.  It is realtively simple.  For example, to turn on a full suite of tests for Java files:

```bash
function personality_file_tests
{
  local filename=$1

  if [[ ${filename} =~ \.java$ ]]; then
    add_test findbugs
    add_test javac
    add_test javadoc
    add_test mvninstall
    add_test unit
  fi

}
```

The `add_test` function is used to activate the standard tests.  Additional plug-ins (such as checkstyle), will get queried on their own.

### Module & Profile Determination

Once the tests are determined, it is now time to pick which modules should get used.  That's the job of the `personality_modules` function.

```bash
function personality_modules
{

    clear_personality_queue

...

    personality_enqueue_module <module> <flags>

}
```

It takes exactly two parameters `repostatus` and `testtype`.

The `repostatus` parameter tells the `personality` function exactly what state the repository is in.  It can only be in one of two states:  `branch` or `patch`.  `branch` means the patch has not been applied.  The `patch` state is after the patch has been applied.

The `testtype` state tells the personality exactly which test is about to be executed.

In order to communicate back to test-patch, there are two functions for the personality to use.

The first is `clear_personality_queue`. This removes the previous test's configuration so that a new module queue may be built.

The second is `personality_enqueue_module`.  This function takes two parameters.  The first parameter is the name of the module to add to this test's queue.  The second parameter is an option list of additional flags to pass to Maven when processing it. `personality_enqueue_module` may be called as many times as necessary for your project.

    NOTE: A module name of . signifies the root of the repository.

For example, let's say your project uses a special configuration to skip unit tests (-DskipTests).  Running unit tests during a javadoc build isn't very interesting. We can write a simple personality check to disable the unit tests:


```bash
function personality
{
    local repostatus=$1
    local testtype=$2

    if [[ ${testtype} == 'javadoc' ]]; then
        personality_enqueue_module . -DskipTests
        return
    fi
    ...

```

This function will tell test-patch that when the javadoc test is being run, do the documentation test at the base of the repository and make sure the -DskipTests flag is passed to Maven.

