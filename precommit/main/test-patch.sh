#!/usr/bin/env bash
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

### BUILD_URL is set by Hudson if it is run by patch process

this="${BASH_SOURCE-$0}"
BINDIR=$(cd -P -- "$(dirname -- "${this}")" >/dev/null && pwd -P)
CWD=$(pwd)
USER_PARAMS=("$@")
GLOBALTIMER=$(date +"%s")

## @description  Setup the default global variables
## @audience     public
## @stability    stable
## @replaceable  no
function setup_defaults
{
  if [[ -z "${MAVEN_HOME:-}" ]]; then
    MVN=mvn
  else
    MVN=${MAVEN_HOME}/bin/mvn
  fi
  # This parameter needs to be kept as an array
  MAVEN_ARGS=()

  PROJECT_NAME=testudine
  DOCKERFILE="${BINDIR}/test-patch-docker/Dockerfile-startstub"
  HOW_TO_CONTRIBUTE="https://dierobotsdie.github.io/testudine/test-patch-names.html"
  JENKINS=false
  BASEDIR=$(pwd)
  RELOCATE_PATCH_DIR=false

  USER_PLUGIN_DIR=""
  LOAD_SYSTEM_PLUGINS=true

  DOCKERSUPPORT=false
  FINDBUGS_HOME=${FINDBUGS_HOME:-}
  FINDBUGS_WARNINGS_FAIL_PRECHECK=false
  ECLIPSE_HOME=${ECLIPSE_HOME:-}
  BUILD_NATIVE=${BUILD_NATIVE:-true}
  PATCH_BRANCH=""
  PATCH_BRANCH_DEFAULT="trunk"

  #shellcheck disable=SC2034
  CHANGED_MODULES=""
  USER_MODULE_LIST=""
  OFFLINE=false
  CHANGED_FILES=""
  REEXECED=false
  RESETREPO=false
  ISSUE=""
  ISSUE_RE='^(HADOOP|YARN|MAPREDUCE|HDFS)-[0-9]+$'
  TIMER=$(date +"%s")
  PATCHURL=""
  OSTYPE=$(uname -s)

  # Solaris needs POSIX, not SVID
  case ${OSTYPE} in
    SunOS)
      PS=${PS:-ps}
      AWK=${AWK:-/usr/xpg4/bin/awk}
      SED=${SED:-/usr/xpg4/bin/sed}
      WGET=${WGET:-wget}
      GIT=${GIT:-git}
      EGREP=${EGREP:-/usr/xpg4/bin/egrep}
      GREP=${GREP:-/usr/xpg4/bin/grep}
      PATCH=${PATCH:-patch}
      DIFF=${DIFF:-/usr/gnu/bin/diff}
      JIRACLI=${JIRA:-jira}
      FILE=${FILE:-file}
    ;;
    *)
      PS=${PS:-ps}
      AWK=${AWK:-awk}
      SED=${SED:-sed}
      WGET=${WGET:-wget}
      GIT=${GIT:-git}
      EGREP=${EGREP:-egrep}
      GREP=${GREP:-grep}
      PATCH=${PATCH:-patch}
      DIFF=${DIFF:-diff}
      JIRACLI=${JIRA:-jira}
      FILE=${FILE:-file}
    ;;
  esac

  declare -a JIRA_COMMENT_TABLE
  declare -a JIRA_FOOTER_TABLE
  declare -a JIRA_HEADER
  declare -a JIRA_TEST_TABLE

  JFC=0
  JTC=0
  JTT=0
  RESULT=0
}

## @description  Print a message to stderr
## @audience     public
## @stability    stable
## @replaceable  no
## @param        string
function testudine_error
{
  echo "$*" 1>&2
}

## @description  Print a message to stderr if --debug is turned on
## @audience     public
## @stability    stable
## @replaceable  no
## @param        string
function testudine_debug
{
  if [[ -n "${HADOOP_SHELL_SCRIPT_DEBUG}" ]]; then
    echo "[$(date) DEBUG]: $*" 1>&2
  fi
}

## @description  Convert the given module name to a file fragment
## @audience     public
## @stability    stable
## @replaceable  no
## @param        module
function module_file_fragment
{
  local mod=$1
  if [[ ${mod} == . ]]; then
    echo root
  else
    echo "$1" | tr '/' '_' | tr '\\' '_'
  fi
}

## @description  Convert time in seconds to m + s
## @audience     public
## @stability    stable
## @replaceable  no
## @param        seconds
function clock_display
{
  local -r elapsed=$1

  if [[ ${elapsed} -lt 0 ]]; then
    echo "N/A"
  else
    printf  "%3sm %02ss" $((elapsed/60)) $((elapsed%60))
  fi
}

## @description  Activate the local timer
## @audience     public
## @stability    stable
## @replaceable  no
function start_clock
{
  testudine_debug "Start clock"
  TIMER=$(date +"%s")
}

## @description  Print the elapsed time in seconds since the start of the local timer
## @audience     public
## @stability    stable
## @replaceable  no
function stop_clock
{
  local -r stoptime=$(date +"%s")
  local -r elapsed=$((stoptime-TIMER))
  testudine_debug "Stop clock"

  echo ${elapsed}
}

## @description  Print the elapsed time in seconds since the start of the global timer
## @audience     private
## @stability    stable
## @replaceable  no
function stop_global_clock
{
  local -r stoptime=$(date +"%s")
  local -r elapsed=$((stoptime-GLOBALTIMER))
  testudine_debug "Stop global clock"

  echo ${elapsed}
}

## @description  Add time to the local timer
## @audience     public
## @stability    stable
## @replaceable  no
## @param        seconds
function offset_clock
{
  ((TIMER=TIMER-$1))
}

## @description  Add to the header of the display
## @audience     public
## @stability    stable
## @replaceable  no
## @param        string
function add_jira_header
{
  JIRA_HEADER[${JHC}]="| $* |"
  JHC=$(( JHC+1 ))
}

## @description  Add to the output table. If the first parameter is a number
## @description  that is the vote for that column and calculates the elapsed time
## @description  based upon the last start_clock().  If it the string null, then it is
## @description  a special entry that signifies extra
## @description  content for the final column.  The second parameter is the reporting
## @description  subsystem (or test) that is providing the vote.  The second parameter
## @description  is always required.  The third parameter is any extra verbage that goes
## @description  with that subsystem.
## @audience     public
## @stability    stable
## @replaceable  no
## @param        +1/0/-1/null
## @param        subsystem
## @param        string
## @return       Elapsed time display
function add_jira_table
{
  local value=$1
  local subsystem=$2
  shift 2

  local color
  local calctime
  local -r elapsed=$(stop_clock)

  testudine_debug "add_jira_table ${value} ${subsystem} ${*}"

  calctime=$(clock_display "${elapsed}")

  case ${value} in
    1|+1)
      value="+1"
      color="green"
    ;;
    -1)
      color="red"
    ;;
    0)
      color="blue"
    ;;
    null)
    ;;
  esac

  if [[ -z ${color} ]]; then
    JIRA_COMMENT_TABLE[${JTC}]="|  | ${subsystem} | | ${*:-} |"
    JTC=$(( JTC+1 ))
  else
    JIRA_COMMENT_TABLE[${JTC}]="| {color:${color}}${value}{color} | ${subsystem} | ${calctime} | $* |"
    JTC=$(( JTC+1 ))
  fi
}

## @description  Put the opening environment information at the bottom
## @description  of the footer table
## @stability     stable
## @audience     private
## @replaceable  yes
function open_jira_footer
{
  # shellcheck disable=SC2016
  local -r javaversion=$("${JAVA_HOME}/bin/java" -version 2>&1 | head -1 | ${AWK} '{print $NF}' | tr -d \")
  local -r unamea=$(uname -a)

  add_jira_footer "Java" "${javaversion}"
  add_jira_footer "uname" "${unamea}"

  if [[ -n ${PERSONALITY} ]]; then
    add_jira_footer "Personality" ${PERSONALITY}
  fi
}

## @description  Put docker stats in various tables
## @stability     stable
## @audience     private
## @replaceable  yes
function finish_docker_stats
{
  if [[ ${DOCKERMODE} == true ]]; then
    # DOCKER_VERSION is set by our creator.
    add_jira_footer "Docker" "${DOCKER_VERSION}"
  fi
}

## @description  Put the final elapsed time at the bottom of the table.
## @audience     private
## @stability    stable
## @replaceable  no
function close_jira_table
{

  local -r elapsed=$(stop_global_clock)
  local calctime

  calctime=$(clock_display "${elapsed}")

  echo ""
  echo "Total Elapsed time: ${calctime}"
  echo ""

  JIRA_COMMENT_TABLE[${JTC}]="| | | ${calctime} | |"
  JTC=$(( JTC+1 ))
}

## @description  Add to the footer of the display. @@BASE@@ will get replaced with the
## @description  correct location for the local filesystem in dev mode or the URL for
## @description  Jenkins mode.
## @audience     public
## @stability    stable
## @replaceable  no
## @param        subsystem
## @param        string
function add_jira_footer
{
  local subsystem=$1
  shift 1

  JIRA_FOOTER_TABLE[${JFC}]="| ${subsystem} | $* |"
  JFC=$(( JFC+1 ))
}

## @description  Special table just for unit test failures
## @audience     public
## @stability    stable
## @replaceable  no
## @param        failurereason
## @param        testlist
function add_jira_test_table
{
  local failure=$1
  shift 1

  JIRA_TEST_TABLE[${JTT}]="| ${failure} | $* |"
  JTT=$(( JTT+1 ))
}

## @description  Large display for the user console
## @audience     public
## @stability    stable
## @replaceable  no
## @param        string
## @return       large chunk of text
function big_console_header
{
  local text="$*"
  local spacing=$(( (75+${#text}) /2 ))
  printf "\n\n"
  echo "============================================================================"
  echo "============================================================================"
  printf "%*s\n"  ${spacing} "${text}"
  echo "============================================================================"
  echo "============================================================================"
  printf "\n\n"
}

## @description  Remove {color} tags from a string
## @audience     public
## @stability    stable
## @replaceable  no
## @param        string
## @return       string
function colorstripper
{
  local string=$1
  shift 1

  local green=""
  local white=""
  local red=""
  local blue=""

  echo "${string}" | \
  ${SED} -e "s,{color:red},${red},g" \
         -e "s,{color:green},${green},g" \
         -e "s,{color:blue},${blue},g" \
         -e "s,{color},${white},g"
}

## @description  Find the largest size of a column of an array
## @audience     private
## @stability    evolving
## @replaceable  no
## @return       size
function findlargest
{
  local column=$1
  shift
  local a=("$@")
  local sizeofa=${#a[@]}
  local i=0

  until [[ ${i} -gt ${sizeofa} ]]; do
    # shellcheck disable=SC2086
    string=$( echo ${a[$i]} | cut -f$((column + 1)) -d\| )
    if [[ ${#string} -gt $maxlen ]]; then
      maxlen=${#string}
    fi
    i=$((i+1))
  done
  echo "${maxlen}"
}

## @description  Verify that ${JAVA_HOME} is defined
## @audience     public
## @stability    stable
## @replaceable  no
## @return       1 - no JAVA_HOME
## @return       0 - JAVA_HOME defined
function find_java_home
{
  start_clock
  if [[ -z ${JAVA_HOME:-} ]]; then
    case ${OSTYPE} in
      Darwin)
        if [[ -z "${JAVA_HOME}" ]]; then
          if [[ -x /usr/libexec/java_home ]]; then
            JAVA_HOME="$(/usr/libexec/java_home)"
            export JAVA_HOME
          else
            export JAVA_HOME=/Library/Java/Home
          fi
        fi
      ;;
      *)
      ;;
    esac
  fi

  if [[ -z ${JAVA_HOME:-} ]]; then
    echo "JAVA_HOME is not defined."
    add_jira_table -1 pre-patch "JAVA_HOME is not defined."
    return 1
  fi
  return 0
}

## @description Write the contents of a file to jenkins
## @params filename
## @stability stable
## @audience public
## @returns ${JIRACLI} exit code
function write_to_jira
{
  local -r commentfile=${1}
  shift

  local retval=0

  if [[ ${OFFLINE} == false
     && ${JENKINS} == true
     && -n ${JIRA_PASSWD} ]]; then

    # shellcheck disable=SC2086
    ${JIRACLI} --comment "$(cat ${commentfile})" \
               -s https://issues.apache.org/jira \
               -a addcomment -u ${JIRA_USER} \
               -p "${JIRA_PASSWD}" \
               --issue "${ISSUE}"
    retval=$?
    ${JIRACLI} -s https://issues.apache.org/jira \
               -a logout -u ${JIRA_USER} \
               -p "${JIRA_PASSWD}"
  fi
  return ${retval}
}

## @description Verify that the patch directory is still in working order
## @description since bad actors on some systems wipe it out. If not,
## @description recreate it and then exit
## @audience    private
## @stability   evolving
## @replaceable yes
## @returns     may exit on failure
function verify_patchdir_still_exists
{
  local -r commentfile=/tmp/testpatch.$$.${RANDOM}
  local extra=""

  if [[ ! -d ${PATCH_DIR} ]]; then
    rm "${commentfile}" 2>/dev/null

    echo "(!) The patch artifact directory has been removed! " > "${commentfile}"
    echo "This is a fatal error for test-patch.sh.  Aborting. " >> "${commentfile}"
    echo
    cat ${commentfile}
    echo
    if [[ ${JENKINS} == true ]]; then
      if [[ -n ${NODE_NAME} ]]; then
        extra=" (node ${NODE_NAME})"
      fi
      echo "Jenkins${extra} information at ${BUILD_URL} may provide some hints. " >> "${commentfile}"

      write_to_jira ${commentfile}
    fi

    rm "${commentfile}"
    cleanup_and_exit ${RESULT}
  fi
}

## @description generate a list of all files and line numbers that
## @description that were added/changed in the source repo
## @audience    private
## @stability   stable
## @params      filename
## @replaceable no
function compute_gitdiff
{
  local outfile=$1
  local file
  local line
  local startline
  local counter
  local numlines
  local actual

  pushd "${BASEDIR}" >/dev/null
  ${GIT} add --all --intent-to-add
  while read line; do
    if [[ ${line} =~ ^\+\+\+ ]]; then
      file="./"$(echo "${line}" | cut -f2- -d/)
      continue
    elif [[ ${line} =~ ^@@ ]]; then
      startline=$(echo "${line}" | cut -f3 -d' ' | cut -f1 -d, | tr -d + )
      numlines=$(echo "${line}" | cut -f3 -d' ' | cut -s -f2 -d, )
      # if this is empty, then just this line
      # if it is 0, then no lines were added and this part of the patch
      # is strictly a delete
      if [[ ${numlines} == 0 ]]; then
        continue
      elif [[ -z ${numlines} ]]; then
        numlines=1
      fi
      counter=0
      until [[ ${counter} -gt ${numlines} ]]; do
          ((actual=counter+startline))
          echo "${file}:${actual}:" >> "${outfile}"
          ((counter=counter+1))
      done
    fi
  done < <("${GIT}" diff --unified=0 --no-color)
  popd >/dev/null
}

## @description  Print the command to be executing to the screen. Then
## @description  run the command, sending stdout and stderr to the given filename
## @description  This will also ensure that any directories in ${BASEDIR} have
## @description  the exec bit set as a pre-exec step.
## @audience     public
## @stability    stable
## @param        filename
## @param        command
## @param        [..]
## @replaceable  no
## @returns      $?
function echo_and_redirect
{
  local logfile=$1
  shift

  verify_patchdir_still_exists

  find "${BASEDIR}" -type d -exec chmod +x {} \;
  # to the screen
  echo "${*} > ${logfile} 2>&1"
  # to the log
  echo "${*}" > "${logfile}"
  # the actual command
  "${@}" >> "${logfile}" 2>&1
}

## @description is PATCH_DIR relative to BASEDIR?
## @audience    public
## @stability   stable
## @replaceable yes
## @returns     1 - no, PATCH_DIR
## @returns     0 - yes, PATCH_DIR - BASEDIR
function relative_patchdir
{
  local p=${PATCH_DIR#${BASEDIR}}

  if [[ ${#p} -eq ${#PATCH_DIR} ]]; then
    echo "${p}"
    return 1
  fi
  p=${p#/}
  echo "${p}"
  return 0
}

## @description  shortcut for docker
## @audience     private
## @stability    evolving
## @replaceable  no
function docker_launch
{
  local patchdir

  if [[ ${DOCKERSUPPORT} == false ]]; then
    return
  fi

  big_console_header "Switching to Docker"

  start_clock

  cd "${CWD}"
  mkdir -p "${PATCH_DIR}/precommit-test"
  cp -pr "${BINDIR}"/* "${PATCH_DIR}/precommit-test"
  cat ${DOCKERFILE} \
      "${BINDIR}/test-patch-docker/Dockerfile-endstub" \
      > "${PATCH_DIR}/precommit-test/test-patch-docker/Dockerfile"

  client=$(docker version | grep 'Client version' | cut -f2 -d: | tr -d ' ')
  server=$(docker version | grep 'Server version' | cut -f2 -d: | tr -d ' ')

  dockerversion="C=${client}/S=${server}"

  TESTPATCHMODE="${USER_PARAMS[*]}"
  if [[ -n "${BUILD_URL}" ]]; then
    TESTPATCHMODE="--build-url=${BUILD_URL} ${TESTPATCHMODE}"
  fi
  TESTPATCHMODE="--tpglobaltimer=${GLOBALTIMER} ${TESTPATCHMODE}"
  TESTPATCHMODE="--tpdockertimer=${TIMER} ${TESTPATCHMODE}"

  export TESTPATCHMODE
  patchdir=$(relative_patchdir)
  export STARTBINDIR=${BINDIR}
  export PROJECT_NAME
  cd "${BASEDIR}"
  exec bash "${PATCH_DIR}/precommit-test/test-patch-docker/test-patch-docker.sh" \
     --dockerversion="${dockerversion}" \
     --java-home="${JAVA_HOME}" \
     --patch-dir="${patchdir}" \
     --project="${PROJECT_NAME}"
}

## @description  Print the usage information
## @audience     public
## @stability    stable
## @replaceable  no
function testudine_usage
{
  local -r up=$(echo ${PROJECT_NAME} | tr '[:lower:]' '[:upper:]')

  echo "Usage: test-patch.sh [options] patch-file | issue-number | http"
  echo
  echo "Where:"
  echo "  patch-file is a local patch file containing the changes to test"
  echo "  issue-number is a 'Patch Available' JIRA defect number (e.g. '${up}-9902') to test"
  echo "  http is an HTTP address to download the patch file"
  echo
  echo "Options:"
  echo "--basedir=<dir>        The directory to apply the patch to (default current directory)"
  echo "--branch=<ref>         Forcibly set the branch"
  echo "--branch-default=<ref> If the branch isn't forced and we don't detect one in the patch name, use this branch (default 'trunk')"
  echo "--build-native=<bool>  If true, then build native components (default 'true')"
  echo "--contrib-guide=<url>  URL to point new users towards project conventions. (default Hadoop's wiki)"
  echo "--debug                If set, then output some extra stuff to stderr"
  echo "--dirty-workspace      Allow the local git workspace to have uncommitted changes"
  echo "--docker               Spawn a docker container"
  echo "--dockerfile=<file>    Dockerfile fragment to use as the base"
  echo "--findbugs-home=<path> Findbugs home directory (default FINDBUGS_HOME environment variable)"
  echo "--findbugs-strict-precheck If there are Findbugs warnings during precheck, fail"
  echo "--issue-re=<expr>      Bash regular expression to use when trying to find a jira ref in the patch name (default '^(HADOOP|YARN|MAPREDUCE|HDFS)-[0-9]+$')"
  echo "--java-home=<path>     Set JAVA_HOME (In Docker mode, this should be local to the image)"
  echo "--modulelist=<list>    Specify additional modules to test (comma delimited)"
  echo "--offline              Avoid connecting to the Internet"
  echo "--patch-dir=<dir>      The directory for working and output files (default '/tmp/${PROJECT_NAME}-test-patch/pid')"
  echo "--personality=<file>   The personality file to load"
  echo "--plugins=<dir>        A directory of user provided plugins. see test-patch.d for examples (default empty)"
  echo "--project=<name>       The short name for project currently using test-patch (default 'testudine')"
  echo "--resetrepo            Forcibly clean the repo"
  echo "--run-tests            Run all relevant tests below the base directory"
  echo "--skip-system-plugins  Do not load plugins from ${BINDIR}/test-patch.d"
  echo "--testlist=<list>      Specify which subsystem tests to use (comma delimited)"
  echo "--test-parallel=<bool> Run multiple tests in parallel (default false in developer mode, true in Jenkins mode)"
  echo "--test-threads=<int>   Number of tests to run in parallel (default defined in ${PROJECT_NAME} build)"

  echo "Shell binary overrides:"
  echo "--awk-cmd=<cmd>        The 'awk' command to use (default 'awk')"
  echo "--diff-cmd=<cmd>       The GNU-compatible 'diff' command to use (default 'diff')"
  echo "--file-cmd=<cmd>       The 'file' command to use (default 'file')"
  echo "--git-cmd=<cmd>        The 'git' command to use (default 'git')"
  echo "--grep-cmd=<cmd>       The 'grep' command to use (default 'grep')"
  echo "--mvn-cmd=<cmd>        The 'mvn' command to use (default \${MAVEN_HOME}/bin/mvn, or 'mvn')"
  echo "--patch-cmd=<cmd>      The 'patch' command to use (default 'patch')"
  echo "--ps-cmd=<cmd>         The 'ps' command to use (default 'ps')"
  echo "--sed-cmd=<cmd>        The 'sed' command to use (default 'sed')"

  echo
  echo "Jenkins-only options:"
  echo "--jenkins              Run by Jenkins (runs tests and posts results to JIRA)"
  echo "--build-url            Set the build location web page"
  echo "--eclipse-home=<path>  Eclipse home directory (default ECLIPSE_HOME environment variable)"
  echo "--jira-cmd=<cmd>       The 'jira' command to use (default 'jira')"
  echo "--jira-password=<pw>   The password for the 'jira' command"
  echo "--jira-user=<user>     The user for the 'jira' command"
  echo "--mv-patch-dir         Move the patch-dir into the basedir during cleanup."
  echo "--wget-cmd=<cmd>       The 'wget' command to use (default 'wget')"
}

## @description  Interpret the command line parameters
## @audience     private
## @stability    stable
## @replaceable  no
## @params       $@
## @return       May exit on failure
function parse_args
{
  local i
  local j

  for i in "$@"; do
    case ${i} in
      --awk-cmd=*)
        AWK=${i#*=}
      ;;
      --basedir=*)
        BASEDIR=${i#*=}
      ;;
      --branch=*)
        PATCH_BRANCH=${i#*=}
      ;;
      --branch-default=*)
        PATCH_BRANCH_DEFAULT=${i#*=}
      ;;
      --build-native=*)
        BUILD_NATIVE=${i#*=}
      ;;
      --build-url=*)
        BUILD_URL=${i#*=}
      ;;
      --contrib-guide=*)
        HOW_TO_CONTRIBUTE=${i#*=}
      ;;
      --debug)
        HADOOP_SHELL_SCRIPT_DEBUG=true
      ;;
      --diff-cmd=*)
        DIFF=${i#*=}
      ;;
      --dirty-workspace)
        DIRTY_WORKSPACE=true
      ;;
      --docker)
        DOCKERSUPPORT=true
      ;;
      --dockerfile=*)
        DOCKERFILE=${i#*=}
      ;;
      --dockermode)
        DOCKERMODE=true
      ;;
      --eclipse-home=*)
        ECLIPSE_HOME=${i#*=}
      ;;
      --file-cmd=*)
        FILE=${i#*=}
      ;;
      --findbugs-home=*)
        FINDBUGS_HOME=${i#*=}
      ;;
      --findbugs-strict-precheck)
        FINDBUGS_WARNINGS_FAIL_PRECHECK=true
      ;;
      --git-cmd=*)
        GIT=${i#*=}
      ;;
      --grep-cmd=*)
        GREP=${i#*=}
      ;;
      --help|-help|-h|help|--h|--\?|-\?|\?)
        testudine_usage
        exit 0
      ;;
      --issue-re=*)
        ISSUE_RE=${i#*=}
      ;;
      --java-home=*)
        JAVA_HOME=${i#*=}
      ;;
      --jenkins)
        JENKINS=true
        TEST_PARALLEL=${TEST_PARALLEL:-true}
      ;;
      --jira-cmd=*)
        JIRACLI=${i#*=}
      ;;
      --jira-password=*)
        JIRA_PASSWD=${i#*=}
      ;;
      --jira-user=*)
        JIRA_USER=${i#*=}
      ;;
      --modulelist=*)
        USER_MODULE_LIST=${i#*=}
        USER_MODULE_LIST=${USER_MODULE_LIST//,/ }
        testudine_debug "Manually forcing modules ${USER_MODULE_LIST}"
      ;;
      --mvn-cmd=*)
        MVN=${i#*=}
      ;;
      --mv-patch-dir)
        RELOCATE_PATCH_DIR=true;
      ;;
      --offline)
        OFFLINE=true
      ;;
      --patch-cmd=*)
        PATCH=${i#*=}
      ;;
      --patch-dir=*)
        USER_PATCH_DIR=${i#*=}
      ;;
      --personality=*)
        PERSONALITY=${i#*=}
      ;;
      --plugins=*)
        USER_PLUGIN_DIR=${i#*=}
      ;;
      --project=*)
        PROJECT_NAME=${i#*=}
      ;;
      --ps-cmd=*)
        PS=${i#*=}
      ;;
      --reexec)
        REEXECED=true
      ;;
      --resetrepo)
        RESETREPO=true
      ;;
      --run-tests)
        RUN_TESTS=true
      ;;
      --skip-system-plugins)
        LOAD_SYSTEM_PLUGINS=false
      ;;
      --testlist=*)
        testlist=${i#*=}
        testlist=${testlist//,/ }
        for j in ${testlist}; do
          testudine_debug "Manually adding patch test subsystem ${j}"
          add_test "${j}"
        done
      ;;
      --test-parallel=*)
        TEST_PARALLEL=${i#*=}
      ;;
      --test-threads=*)
        # shellcheck disable=SC2034
        TEST_THREADS=${i#*=}
      ;;
      --tpglobaltimer=*)
        GLOBALTIMER=${i#*=}
      ;;
      --tpdockertimer=*)
        DOCKERLAUNCHTIMER=${i#*=}
      ;;
      --tpreexectimer=*)
        REEXECLAUNCHTIMER=${i#*=}
      ;;
      --wget-cmd=*)
        WGET=${i#*=}
      ;;
      --*)
        ## PATCH_OR_ISSUE can't be a --.  So this is probably
        ## a plugin thing.
        continue
      ;;
      *)
        PATCH_OR_ISSUE=${i}
      ;;
    esac
  done

  if [[ ${REEXECED} == true ]]; then
    if [[ -n ${REEXECLAUNCHTIMER} ]]; then
      TIMER=${REEXECLAUNCHTIMER};
    else
      start_clock
    fi
    add_jira_table 0 reexec "precommit patch detected."
  fi

  # if we requested offline, pass that to mvn
  if [[ ${OFFLINE} == "true" ]]; then
    MAVEN_ARGS=(${MAVEN_ARGS[@]} --offline)
  fi

  if [[ -z "${PATCH_OR_ISSUE}" ]]; then
    testudine_usage
    exit 1
  fi

  if [[ ${DOCKERMODE} == true ]]; then
    if [[ -n ${DOCKERLAUNCHTIMER} ]]; then
      TIMER=${DOCKERLAUNCHTIMER};
    else
      start_clock
    fi
    add_jira_table 0 docker "docker mode"
  fi

  # we need absolute dir for ${BASEDIR}
  cd "${CWD}"
  BASEDIR=$(cd -P -- "${BASEDIR}" >/dev/null && pwd -P)

  if [[ -n ${USER_PATCH_DIR} ]]; then
    PATCH_DIR="${USER_PATCH_DIR}"
  else
    PATCH_DIR=/tmp/${PROJECT_NAME}-test-patch/$$
  fi

  cd "${CWD}"
  if [[ ! -d ${PATCH_DIR} ]]; then
    mkdir -p "${PATCH_DIR}"
    if [[ $? == 0 ]] ; then
      echo "${PATCH_DIR} has been created"
    else
      echo "Unable to create ${PATCH_DIR}"
      cleanup_and_exit 1
    fi
  fi

  # we need absolute dir for PATCH_DIR
  PATCH_DIR=$(cd -P -- "${PATCH_DIR}" >/dev/null && pwd -P)

  if [[ ${BUILD_NATIVE} == "true" ]]; then
    NATIVE_PROFILE=-Pnative
  fi

  if [[ ${JENKINS} == "true" ]]; then
    echo "Running in Jenkins mode"
    ISSUE=${PATCH_OR_ISSUE}
    RESETREPO=true
    # shellcheck disable=SC2034
    ECLIPSE_PROPERTY="-Declipse.home=${ECLIPSE_HOME}"
  else
    if [[ ${RESETREPO} == "true" ]] ; then
      echo "Running in destructive (--resetrepo) developer mode"
    else
      echo "Running in developer mode"
    fi
    JENKINS=false
  fi

  GITDIFFLINES=${PATCH_DIR}/gitdifflines.txt
}

## @description  Locate the pom.xml file for a given directory
## @audience     private
## @stability    stable
## @replaceable  no
## @return       directory containing the pom.xml
function find_pom_dir
{
  local dir

  dir=$(dirname "$1")

  testudine_debug "Find pom dir for: ${dir}"

  while builtin true; do
    if [[ -f "${dir}/pom.xml" ]];then
      echo "${dir}"
      testudine_debug "Found: ${dir}"
      return
    else
      dir=$(dirname "${dir}")
    fi
  done
}

## @description  List of files that ${PATCH_DIR}/patch modifies
## @audience     private
## @stability    stable
## @replaceable  no
## @return       None; sets ${CHANGED_FILES}
function find_changed_files
{
  # get a list of all of the files that have been changed,
  # except for /dev/null (which would be present for new files).
  # Additionally, remove any a/ b/ patterns at the front
  # of the patch filenames and any revision info at the end
  # shellcheck disable=SC2016
  CHANGED_FILES=$(${GREP} -E '^(\+\+\+|---) ' "${PATCH_DIR}/patch" \
    | ${SED} \
      -e 's,^....,,' \
      -e 's,^[ab]/,,' \
    | ${GREP} -v /dev/null \
    | ${AWK} '{print $1}' \
    | sort -u)
}

## @description  Find the modules of the maven build that ${PATCH_DIR}/patch modifies
## @audience     private
## @stability    stable
## @replaceable  no
## @return       None; sets ${CHANGED_MODULES} and ${CHANGED_UNFILTERED_MODULES}
function find_changed_modules
{
  # Come up with a list of changed files into ${TMP}
  local pomdirs
  local module
  local pommods

  # Now find all the modules that were changed
  for file in ${CHANGED_FILES}; do
    #shellcheck disable=SC2086
    pomdirs="${pomdirs} $(find_pom_dir ${file})"
  done

  #shellcheck disable=SC2086,SC2034
  CHANGED_UNFILTERED_MODULES=$(echo ${pomdirs} ${USER_MODULE_LIST} | tr ' ' '\n' | sort -u)

  # Filter out modules without code
  for module in ${pomdirs}; do
    ${GREP} "<packaging>pom</packaging>" "${module}/pom.xml" > /dev/null
    if [[ "$?" != 0 ]]; then
      pommods="${pommods} ${module}"
    fi
  done

  #shellcheck disable=SC2086,SC2034
  CHANGED_MODULES=$(echo ${pommods} ${USER_MODULE_LIST} | tr ' ' '\n' | sort -u)
}

## @description  git checkout the appropriate branch to test.  Additionally, this calls
## @description  'determine_issue' and 'determine_branch' based upon the context provided
## @description  in ${PATCH_DIR} and in git after checkout.
## @audience     private
## @stability    stable
## @replaceable  no
## @return       0 on success.  May exit on failure.
function git_checkout
{
  local currentbranch
  local exemptdir

  big_console_header "Confirming git environment"

  cd "${BASEDIR}"
  if [[ ! -d .git ]]; then
    testudine_error "ERROR: ${BASEDIR} is not a git repo."
    cleanup_and_exit 1
  fi

  if [[ ${RESETREPO} == "true" ]] ; then
    ${GIT} reset --hard
    if [[ $? != 0 ]]; then
      testudine_error "ERROR: git reset is failing"
      cleanup_and_exit 1
    fi

    # if PATCH_DIR is in BASEDIR, then we don't want
    # git wiping it out.
    exemptdir=$(relative_patchdir)
    if [[ $? == 1 ]]; then
      ${GIT} clean -xdf
    else
      # we do, however, want it emptied of all _files_.
      # we need to leave _directories_ in case we are in
      # re-exec mode (which places a directory full of stuff in it)
      testudine_debug "Exempting ${exemptdir} from clean"
      rm "${PATCH_DIR}/*" 2>/dev/null
      ${GIT} clean -xdf -e "${exemptdir}"
    fi
    if [[ $? != 0 ]]; then
      testudine_error "ERROR: git clean is failing"
      cleanup_and_exit 1
    fi

    ${GIT} checkout --force "${PATCH_BRANCH_DEFAULT}"
    if [[ $? != 0 ]]; then
      testudine_error "ERROR: git checkout --force ${PATCH_BRANCH_DEFAULT} is failing"
      cleanup_and_exit 1
    fi

    determine_branch
    if [[ ${PATCH_BRANCH} =~ ^git ]]; then
      PATCH_BRANCH=$(echo "${PATCH_BRANCH}" | cut -dt -f2)
    fi

    # we need to explicitly fetch in case the
    # git ref hasn't been brought in tree yet
    if [[ ${OFFLINE} == false ]]; then
      ${GIT} pull --rebase
      if [[ $? != 0 ]]; then
        testudine_error "ERROR: git pull is failing"
        cleanup_and_exit 1
      fi
    fi
    # forcibly checkout this branch or git ref
    ${GIT} checkout --force "${PATCH_BRANCH}"
    if [[ $? != 0 ]]; then
      testudine_error "ERROR: git checkout ${PATCH_BRANCH} is failing"
      cleanup_and_exit 1
    fi

    # if we've selected a feature branch that has new changes
    # since our last build, we'll need to rebase to see those changes.
    if [[ ${OFFLINE} == false ]]; then
      ${GIT} pull --rebase
      if [[ $? != 0 ]]; then
        testudine_error "ERROR: git pull is failing"
        cleanup_and_exit 1
      fi
    fi

  else

    status=$(${GIT} status --porcelain)
    if [[ "${status}" != "" && -z ${DIRTY_WORKSPACE} ]] ; then
      testudine_error "ERROR: --dirty-workspace option not provided."
      testudine_error "ERROR: can't run in a workspace that contains the following modifications"
      testudine_error "${status}"
      cleanup_and_exit 1
    fi

    determine_branch
    if [[ ${PATCH_BRANCH} =~ ^git ]]; then
      PATCH_BRANCH=$(echo "${PATCH_BRANCH}" | cut -dt -f2)
    fi

    currentbranch=$(${GIT} rev-parse --abbrev-ref HEAD)
    if [[ "${currentbranch}" != "${PATCH_BRANCH}" ]];then
      echo "WARNING: Current git branch is ${currentbranch} but patch is built for ${PATCH_BRANCH}."
      echo "WARNING: Continuing anyway..."
      PATCH_BRANCH=${currentbranch}
    fi
  fi

  determine_issue

  GIT_REVISION=$(${GIT} rev-parse --verify --short HEAD)
  # shellcheck disable=SC2034
  VERSION=${GIT_REVISION}_${ISSUE}_PATCH-${patchNum}

  if [[ "${ISSUE}" == 'Unknown' ]]; then
    echo "Testing patch on ${PATCH_BRANCH}."
  else
    echo "Testing ${ISSUE} patch on ${PATCH_BRANCH}."
  fi

  add_jira_footer "git revision" "${PATCH_BRANCH} / ${GIT_REVISION}"

  if [[ ! -f ${BASEDIR}/pom.xml ]]; then
    testudine_error "ERROR: This verison of test-patch.sh only supports Maven-based builds. Aborting."
    add_jira_table -1 pre-patch "Unsupported build system."
    output_to_jira 1
    cleanup_and_exit 1
  fi
  return 0
}

## @description  Confirm the given branch is a member of the list of space
## @description  delimited branches or a git ref
## @audience     private
## @stability    evolving
## @replaceable  no
## @param        branch
## @param        branchlist
## @return       0 on success
## @return       1 on failure
function verify_valid_branch
{
  local branches=$1
  local check=$2
  local i

  # shortcut some common
  # non-resolvable names
  if [[ -z ${check} ]]; then
    return 1
  fi

  if [[ ${check} == patch ]]; then
    return 1
  fi

  if [[ ${check} =~ ^git ]]; then
    ref=$(echo "${check}" | cut -f2 -dt)
    count=$(echo "${ref}" | wc -c | tr -d ' ')

    if [[ ${count} == 8 || ${count} == 41 ]]; then
      return 0
    fi
    return 1
  fi

  for i in ${branches}; do
    if [[ "${i}" == "${check}" ]]; then
      return 0
    fi
  done
  return 1
}

## @description  Try to guess the branch being tested using a variety of heuristics
## @audience     private
## @stability    evolving
## @replaceable  no
## @return       0 on success, with PATCH_BRANCH updated appropriately
## @return       1 on failure, with PATCH_BRANCH updated to PATCH_BRANCH_DEFAULT
function determine_branch
{
  local allbranches
  local patchnamechunk

  testudine_debug "Determine branch"

  # something has already set this, so move on
  if [[ -n ${PATCH_BRANCH} ]]; then
    return
  fi

  pushd "${BASEDIR}" > /dev/null

  # developer mode, existing checkout, whatever
  if [[ "${DIRTY_WORKSPACE}" == true ]];then
    PATCH_BRANCH=$(${GIT} rev-parse --abbrev-ref HEAD)
    echo "dirty workspace mode; applying against existing branch"
    return
  fi

  allbranches=$(${GIT} branch -r | tr -d ' ' | ${SED} -e s,origin/,,g)

  for j in "${PATCHURL}" "${PATCH_OR_ISSUE}"; do
    testudine_debug "Determine branch: starting with ${j}"
    # shellcheck disable=SC2016
    patchnamechunk=$(echo "${j}" | ${AWK} -F/ '{print $NF}')

    # ISSUE.branch.##.patch
    testudine_debug "Determine branch: ISSUE.branch.##.patch"
    PATCH_BRANCH=$(echo "${patchnamechunk}" | cut -f2 -d. )
    verify_valid_branch "${allbranches}" "${PATCH_BRANCH}"
    if [[ $? == 0 ]]; then
      return
    fi

    # ISSUE-branch-##.patch
    testudine_debug "Determine branch: ISSUE-branch-##.patch"
    PATCH_BRANCH=$(echo "${patchnamechunk}" | cut -f3- -d- | cut -f1,2 -d-)
    verify_valid_branch "${allbranches}" "${PATCH_BRANCH}"
    if [[ $? == 0 ]]; then
      return
    fi

    # ISSUE-##.patch.branch
    testudine_debug "Determine branch: ISSUE-##.patch.branch"
    # shellcheck disable=SC2016
    PATCH_BRANCH=$(echo "${patchnamechunk}" | ${AWK} -F. '{print $NF}')
    verify_valid_branch "${allbranches}" "${PATCH_BRANCH}"
    if [[ $? == 0 ]]; then
      return
    fi

    # ISSUE-branch.##.patch
    testudine_debug "Determine branch: ISSUE-branch.##.patch"
    # shellcheck disable=SC2016
    PATCH_BRANCH=$(echo "${patchnamechunk}" | cut -f3- -d- | ${AWK} -F. '{print $(NF-2)}' 2>/dev/null)
    verify_valid_branch "${allbranches}" "${PATCH_BRANCH}"
    if [[ $? == 0 ]]; then
      return
    fi
  done

  PATCH_BRANCH="${PATCH_BRANCH_DEFAULT}"

  popd >/dev/null
}

## @description  Try to guess the issue being tested using a variety of heuristics
## @audience     private
## @stability    evolving
## @replaceable  no
## @return       0 on success, with ISSUE updated appropriately
## @return       1 on failure, with ISSUE updated to "Unknown"
function determine_issue
{
  local patchnamechunk
  local maybeissue

  testudine_debug "Determine issue"

  # we can shortcut jenkins
  if [[ ${JENKINS} == true ]]; then
    ISSUE=${PATCH_OR_ISSUE}
    return 0
  fi

  # shellcheck disable=SC2016
  patchnamechunk=$(echo "${PATCH_OR_ISSUE}" | ${AWK} -F/ '{print $NF}')

  maybeissue=$(echo "${patchnamechunk}" | cut -f1,2 -d-)

  if [[ ${maybeissue} =~ ${ISSUE_RE} ]]; then
    ISSUE=${maybeissue}
    return 0
  fi

  ISSUE="Unknown"
  return 1
}

## @description  Add the given test type
## @audience     public
## @stability    stable
## @replaceable  yes
## @param        test
function add_test
{
  local testname=$1

  testudine_debug "Testing against ${testname}"

  if [[ -z ${NEEDED_TESTS} ]]; then
    testudine_debug "Setting tests to ${testname}"
    NEEDED_TESTS=${testname}
  elif [[ ! ${NEEDED_TESTS} =~ ${testname} ]] ; then
    testudine_debug "Adding ${testname}"
    NEEDED_TESTS="${NEEDED_TESTS} ${testname}"
  fi
}

## @description  Verify if a given test was requested
## @audience     public
## @stability    stable
## @replaceable  yes
## @param        test
## @return       1 = yes
## @return       0 = no
function verify_needed_test
{
  local i=$1

  if [[ ${NEEDED_TESTS} =~ $i ]]; then
    return 1
  fi
  return 0
}

## @description  Use some heuristics to determine which long running
## @description  tests to run
## @audience     private
## @stability    stable
## @replaceable  no
function determine_needed_tests
{
  local i

  for i in ${CHANGED_FILES}; do

    personality_file_tests ${i}

    for plugin in ${PLUGINS}; do
      if declare -f ${plugin}_filefilter >/dev/null 2>&1; then
        "${plugin}_filefilter" "${i}"
      fi
    done
  done

  add_jira_footer "Optional Tests" "${NEEDED_TESTS}"
}

## @description  Given ${PATCH_ISSUE}, determine what type of patch file is in use, and do the
## @description  necessary work to place it into ${PATCH_DIR}/patch.
## @audience     private
## @stability    evolving
## @replaceable  no
## @return       0 on success
## @return       1 on failure, may exit
function locate_patch
{
  local notSureIfPatch=false
  testudine_debug "locate patch"

  if [[ -f ${PATCH_OR_ISSUE} ]]; then
    PATCH_FILE="${PATCH_OR_ISSUE}"
  else
    if [[ ${PATCH_OR_ISSUE} =~ ^http ]]; then
      echo "Patch is being downloaded at $(date) from"
      PATCHURL="${PATCH_OR_ISSUE}"
    else
      ${WGET} -q -O "${PATCH_DIR}/jira" "http://issues.apache.org/jira/browse/${PATCH_OR_ISSUE}"

      if [[ $? != 0 ]];then
        testudine_error "ERROR: Unable to determine what ${PATCH_OR_ISSUE} may reference."
        cleanup_and_exit 1
      fi

      if [[ $(${GREP} -c 'Patch Available' "${PATCH_DIR}/jira") == 0 ]] ; then
        if [[ ${JENKINS} == true ]]; then
          testudine_error "ERROR: ${PATCH_OR_ISSUE} is not \"Patch Available\"."
          cleanup_and_exit 1
        else
          testudine_error "WARNING: ${PATCH_OR_ISSUE} is not \"Patch Available\"."
        fi
      fi

      relativePatchURL=$(${GREP} -o '"/jira/secure/attachment/[0-9]*/[^"]*' "${PATCH_DIR}/jira" | ${GREP} -v -e 'htm[l]*$' | sort | tail -1 | ${GREP} -o '/jira/secure/attachment/[0-9]*/[^"]*')
      PATCHURL="http://issues.apache.org${relativePatchURL}"
      if [[ ! ${PATCHURL} =~ \.patch$ ]]; then
        notSureIfPatch=true
      fi
      patchNum=$(echo "${PATCHURL}" | ${GREP} -o '[0-9]*/' | ${GREP} -o '[0-9]*')
      echo "${ISSUE} patch is being downloaded at $(date) from"
    fi
    echo "${PATCHURL}"
    add_jira_footer "Patch URL" "${PATCHURL}"
    ${WGET} -q -O "${PATCH_DIR}/patch" "${PATCHURL}"
    if [[ $? != 0 ]];then
      testudine_error "ERROR: ${PATCH_OR_ISSUE} could not be downloaded."
      cleanup_and_exit 1
    fi
    PATCH_FILE="${PATCH_DIR}/patch"
  fi

  if [[ ! -f "${PATCH_DIR}/patch" ]]; then
    cp "${PATCH_FILE}" "${PATCH_DIR}/patch"
    if [[ $? == 0 ]] ; then
      echo "Patch file ${PATCH_FILE} copied to ${PATCH_DIR}"
    else
      testudine_error "ERROR: Could not copy ${PATCH_FILE} to ${PATCH_DIR}"
      cleanup_and_exit 1
    fi
  fi
  if [[ ${notSureIfPatch} == "true" ]]; then
    guess_patch_file "${PATCH_DIR}/patch"
    if [[ $? != 0 ]]; then
      testudine_error "ERROR: ${PATCHURL} is not a patch file."
      cleanup_and_exit 1
    else
      testudine_debug "The patch ${PATCHURL} was not named properly, but it looks like a patch file. proceeding, but issue/branch matching might go awry."
      add_jira_table 0 patch "The patch file was not named according to ${PROJECT_NAME}'s naming conventions. Please see ${HOW_TO_CONTRIBUTE} for instructions."
    fi
  fi
}

## @description Given a possible patch file, guess if it's a patch file without using smart-apply-patch
## @audience private
## @stability evolving
## @param path to patch file to test
## @return 0 we think it's a patch file
## @return 1 we think it's not a patch file
function guess_patch_file
{
  local patch=$1
  local fileOutput

  testudine_debug "Trying to guess is ${patch} is a patch file."
  fileOutput=$("${FILE}" "${patch}")
  if [[ $fileOutput =~ \ diff\  ]]; then
    testudine_debug "file magic says it's a diff."
    return 0
  fi
  fileOutput=$(head -n 1 "${patch}" | "${EGREP}" "^(From [a-z0-9]* Mon Sep 17 00:00:00 2001)|(diff .*)|(Index: .*)$")
  if [[ $? == 0 ]]; then
    testudine_debug "first line looks like a patch file."
    return 0
  fi
  return 1
}

## @description  Given ${PATCH_DIR}/patch, verify the patch is good using ${BINDIR}/smart-apply-patch.sh
## @description  in dryrun mode.
## @audience     private
## @stability    evolving
## @replaceable  no
## @return       0 on success
## @return       1 on failure
function verify_patch_file
{
  # Before building, check to make sure that the patch is valid
  export PATCH

  "${BINDIR}/smart-apply-patch.sh" "${PATCH_DIR}/patch" dryrun
  if [[ $? != 0 ]] ; then
    echo "PATCH APPLICATION FAILED"
    add_jira_table -1 patch "The patch command could not apply the patch during dryrun."
    return 1
  else
    return 0
  fi
}

## @description  Given ${PATCH_DIR}/patch, apply the patch using ${BINDIR}/smart-apply-patch.sh
## @audience     private
## @stability    evolving
## @replaceable  no
## @return       0 on success
## @return       exit on failure
function apply_patch_file
{
  big_console_header "Applying patch"

  export PATCH
  "${BINDIR}/smart-apply-patch.sh" "${PATCH_DIR}/patch"
  if [[ $? != 0 ]] ; then
    echo "PATCH APPLICATION FAILED"
    ((RESULT = RESULT + 1))
    add_jira_table -1 patch "The patch command could not apply the patch."
    output_to_console 1
    output_to_jira 1
    cleanup_and_exit 1
  fi
  return 0
}

## @description  If this patches actually patches test-patch.sh, then
## @description  run with the patched version for the test.
## @audience     private
## @stability    evolving
## @replaceable  no
## @return       none; otherwise relaunches
function check_reexec
{
  local commentfile=${PATCH_DIR}/tp.${RANDOM}

  if [[ ${REEXECED} == true ]]; then
    big_console_header "Re-exec mode detected. Continuing."
    return
  fi

  if [[ ! ${CHANGED_FILES} =~ precommit/test-patch
      || ${CHANGED_FILES} =~ precommit/smart-apply ]] ; then
    return
  fi

  big_console_header "precommit patch detected"

  if [[ ${RESETREPO} == false ]]; then
    ((RESULT = RESULT + 1))
    testudine_debug "can't destructively change the working directory. run with '--resetrepo' please. :("
    add_jira_table -1 precommit "Couldn't test precommit changes because we aren't configured to destructively change the working directory."
    return
  fi

  printf "\n\nRe-executing against patched versions to test.\n\n"

  apply_patch_file

  if [[ ${JENKINS} == true ]]; then

    rm "${commentfile}" 2>/dev/null

    echo "(!) A patch to test-patch or smart-apply-patch has been detected. " > "${commentfile}"
    echo "Re-executing against the patched versions to perform further tests. " >> "${commentfile}"
    echo "The console is at ${BUILD_URL}console in case of problems." >> "${commentfile}"

    write_to_jira "${commentfile}"
    rm "${commentfile}"
  fi

  cd "${CWD}"
  mkdir -p "${PATCH_DIR}/precommit-test"
  cp -pr "${BASEDIR}"/precommit/test-patch* "${PATCH_DIR}/precommit-test"
  cp -pr "${BASEDIR}"/precommit/smart-apply* "${PATCH_DIR}/precommit-test"

  big_console_header "exec'ing test-patch.sh now..."

  exec "${PATCH_DIR}/precommit-test/test-patch.sh" \
    --reexec \
    --branch="${PATCH_BRANCH}" \
    --patch-dir="${PATCH_DIR}" \
    --tpglobaltimer="${GLOBALTIMER}" \
    --tpreexectimer="${TIMER}" \
      "${USER_PARAMS[@]}"
}

## @description  Reset the test results
## @audience     public
## @stability    evolving
## @replaceable  no
function mvn_modules_reset
{
  MODULE_STATUS=()
  MODULE_STATUS_TIMER=()
  MODULE_STATUS_MSG=()
  MODULE_STATUS_LOG=()
}

## @description  Utility to print standard module errors
## @audience     public
## @stability    evolving
## @replaceable  no
## @param        repostatus
## @param        testtype
## @param        mvncmdline
function mvn_modules_message
{
  local repostatus=$1
  local testtype=$2
  shift 2
  local i=0
  local repo

  if [[ ${repostatus} == branch ]]; then
    repo=${PATCH_BRANCH}
  else
    repo="the patch"
  fi

  oldtimer=${TIMER}
  until [[ ${i} -eq ${#MODULE[@]} ]]; do
    start_clock
    echo ""
    echo "${MODULE_STATUS_MSG[${i}]}"
    echo ""
    offset_clock "${MODULE_STATUS_TIMER[${i}]}"
    add_jira_table "${MODULE_STATUS[${i}]}" "${testtype}" "${MODULE_STATUS_MSG[${i}]}"
    if [[ ${MODULE_STATUS[${i}]} == -1
      && -n "${MODULE_STATUS_LOG[${i}]}" ]]; then
      add_jira_footer "${testtype}" "@@BASE@@/${MODULE_STATUS_LOG[${i}]}"
    fi
    ((i=i+1))
  done
  TIMER=${oldtimer}
}

## @description  Add a test result
## @audience     public
## @stability    evolving
## @replaceable  no
## @param        module
## @param        runtime
function mvn_module_status
{
  local index=$1
  local value=$2
  local log=$3
  shift 3

  MODULE_STATUS[${index}]="${value}"
  MODULE_STATUS_LOG[${index}]="${log}"
  MODULE_STATUS_MSG[${index}]="${*}"
}

## @description  run the maven tests for the queued modules
## @audience     public
## @stability    evolving
## @replaceable  no
## @param        repostatus
## @param        testtype
## @param        mvncmdline
function mvn_modules_worker
{
  local repostatus=$1
  local testtype=$2
  shift 2
  local i=0
  local fn
  local savestart=${TIMER}
  local savestop
  local repo
  local modulesuffix

  if [[ ${repostatus} == branch ]]; then
    repo=${PATCH_BRANCH}
  else
    repo="the patch"
  fi

  mvn_modules_reset

  until [[ ${i}  -eq ${#MODULE[@]} ]]; do
    start_clock
    fn=$(module_file_fragment "${MODULE[${i}]}")
    modulesuffix=$(basename "${MODULE[${i}]}")
    pushd "${BASEDIR}/${MODULE[${i}]}" >/dev/null

    if [[ $? != 0 ]]; then
      echo "${BASEDIR}/${MODULE[${i}]} no longer exists. Skipping:"
      echo "${MVN}" "${MAVEN_ARGS[@]}" "${@}" "${MODULEEXTRAPARAM[${i}]}" -Ptest-patch "-D${PROJECT_NAME}PatchProcess"
      ((i=i+1))
      continue
    fi

    #shellcheck disable=SC2086
    echo_and_redirect "${PATCH_DIR}/${repostatus}-${testtype}-${fn}.txt" \
       ${MVN} "${MAVEN_ARGS[@]}" "${@}" ${MODULEEXTRAPARAM[${i}]} -Ptest-patch "-D${PROJECT_NAME}PatchProcess"
    if [[ $? == 0 ]] ; then
      mvn_module_status ${i} +1 "${repostatus}-${testtype}-${fn}.txt" "${modulesuffix} in ${repo} passed."
    else
      mvn_module_status \
        ${i} \
        -1 \
        "${repostatus}-${testtype}-${fn}.txt" \
        "${modulesuffix} in ${repo} failed."
      ((result = result + 1))
    fi
    savestop=$(stop_clock)
    MODULE_STATUS_TIMER[${i}]=${savestop}
    # shellcheck disable=SC2086
    echo "Elapsed: $(clock_display ${savestop})"
    popd >/dev/null
    ((i=i+1))
  done

  TIMER=${savestart}

  if [[ ${result} -gt 0 ]]; then
    return 1
  fi
  return 0
}

## @description  Reset the queue for tests
## @audience     public
## @stability    evolving
## @replaceable  no
function clear_personality_queue
{
  testudine_debug "Personality: clear queue"
  MODCOUNT=0
}

## @description  Build the queue for tests
## @audience     public
## @stability    evolving
## @replaceable  no
## @param        module
## @param        profiles/flags/etc
function personality_enqueue_module
{
  testudine_debug "Personality: enqueue $*"
  local module=$1
  shift

  MODULE[${MODCOUNT}]=${module}
  MODULEEXTRAPARAM[${MODCOUNT}]=${*}
  ((MODCOUNT=MODCOUNT+1))
}

## @description  Confirm compilation pre-patch
## @audience     private
## @stability    stable
## @replaceable  no
## @return       0 on success
## @return       1 on failure
function precheck_javac
{
  local result=0

  big_console_header "Pre-patch ${PATCH_BRANCH} Java compilation verification"

  verify_needed_test javac
  if [[ $? == 0 ]]; then
     echo "Patch does not appear to need javac tests."
     return 0
  fi

  personality_modules branch javac
  mvn_modules_worker branch javac clean test
  result=$?
  mvn_modules_message branch javac
  if [[ ${result} != 0 ]]; then
    return 1
  fi
  return 0
}

## @description  Confirm Javadoc pre-patch
## @audience     private
## @stability    stable
## @replaceable  no
## @return       0 on success
## @return       1 on failure
function precheck_javadoc
{
  local result

  big_console_header "Pre-patch ${PATCH_BRANCH} Javadoc compilation verification"

  verify_needed_test javadoc
  if [[ $? == 0 ]]; then
     echo "Patch does not appear to need javadoc tests."
     return 0
  fi

  personality_modules branch javadoc
  mvn_modules_worker branch javadoc clean javadoc:javadoc
  result=$?
  mvn_modules_message branch javadoc
  if [[ ${result} != 0 ]]; then
    return 1
  fi
  return 0
}

## @description  Confirm site pre-patch
## @audience     private
## @stability    stable
## @replaceable  no
## @return       0 on success
## @return       1 on failure
function precheck_site
{
  local result=0

  big_console_header "Pre-patch ${PATCH_BRANCH} site verification"

  verify_needed_test site
  if [[ $? == 0 ]];then
    echo "Patch does not appear to need site tests."
    return 0
  fi

  personality_modules branch site
  mvn_modules_worker branch site clean site site:stage
  result=$?
  mvn_modules_message branch site
  if [[ ${result} != 0 ]]; then
    return 1
  fi
  return 0
}

## @description  Confirm the source environment pre-patch
## @audience     private
## @stability    stable
## @replaceable  no
## @return       0 on success
## @return       1 on failure
function precheck_without_patch
{
  local result=0

  precheck_javac

  if [[ $? -gt 0 ]]; then
    ((result = result +1 ))
  fi

  precheck_mvninstall

  if [[ $? -gt 0 ]]; then
    ((result = result +1 ))
  fi

  precheck_javadoc

  if [[ $? -gt 0 ]]; then
    ((result = result +1 ))
  fi

  precheck_site

  if [[ $? -gt 0 ]]; then
    ((result = result +1 ))
  fi

  precheck_findbugs

  if [[ $? != 0 ]] ; then
    ((result = result +1 ))
  fi

  if [[ ${result} -gt 0 ]]; then
    return 1
  fi

  return 0
}

## @description  Check the current directory for @author tags
## @audience     private
## @stability    evolving
## @replaceable  no
## @return       0 on success
## @return       1 on failure
function check_author
{
  local authorTags

  big_console_header "Checking there are no @author tags in the patch."

  if [[ ${CHANGED_FILES} =~ precommit/test-patch ]]; then
    echo "Skipping @author checks as test-patch has been patched."
    add_jira_table 0 @author "Skipping @author checks as test-patch has been patched."
    return 0
  fi

  start_clock

  authorTags=$("${GREP}" -c -i '^[^-].*@author' "${PATCH_DIR}/patch")
  echo "There appear to be ${authorTags} @author tags in the patch."
  if [[ ${authorTags} != 0 ]] ; then
    add_jira_table -1 @author \
      "The patch appears to contain ${authorTags} @author tags which the" \
      " community has agreed to not allow in code contributions."
    return 1
  fi
  add_jira_table +1 @author "The patch does not contain any @author tags."
  return 0
}

## @description  Check the patch file for changed/new tests
## @audience     private
## @stability    evolving
## @replaceable  no
## @return       0 on success
## @return       1 on failure
function check_modified_unittests
{
  local testReferences=0
  local i

  big_console_header "Checking there are new or changed tests in the patch."

  verify_needed_test unit

  if [[ $? == 0 ]]; then
    echo "Patch does not appear to need new or modified tests."
    return 0
  fi

  start_clock

  for i in ${CHANGED_FILES}; do
    if [[ ${i} =~ /test/ ]]; then
      ((testReferences=testReferences + 1))
    fi
  done

  echo "There appear to be ${testReferences} test file(s) referenced in the patch."
  if [[ ${testReferences} == 0 ]] ; then
    add_jira_table -1 "tests included" \
      "The patch doesn't appear to include any new or modified tests. " \
      "Please justify why no new tests are needed for this patch." \
      "Also please list what manual steps were performed to verify this patch."
    return 1
  fi
  add_jira_table +1 "tests included" \
    "The patch appears to include ${testReferences} new or modified test files."
  return 0
}

## @description  Helper for check_patch_javac
## @audience     private
## @stability    evolving
## @replaceable  no
## @return       0 on success
## @return       1 on failure
function count_javac_warns
{
  local warningfile=$1
  #shellcheck disable=SC2016,SC2046
  return $(${AWK} 'BEGIN {total = 0} {total += 1} END {print total}' "${warningfile}")
}

## @description  Count and compare the number of javac warnings pre- and post- patch
## @audience     private
## @stability    evolving
## @replaceable  no
## @return       0 on success
## @return       1 on failure
function check_patch_javac
{
  local numbranch
  local numpatch
  local i=0
  local result=0
  local fn
  local oldtimer

  big_console_header "Determining number of patched javac errors"

  verify_needed_test javac

  if [[ $? == 0 ]]; then
    echo "Patch does not appear to need javac tests."
    return 0
  fi

  personality_modules patch javac
  mvn_modules_worker patch javac clean test

  until [[ ${i} -eq ${#MODULE[@]} ]]; do
    if [[ ${MODULE_STATUS[${i}]} == -1 ]]; then
      ((result=result+1))
      ((i=i+1))
      continue
    fi

    fn=$(module_file_fragment "${MODULE[${i}]}")

    # if it was a new module, this won't exist.
    if [[ -f "${PATCH_DIR}/branch-javac-${fn}.txt" ]]; then
      ${GREP} '\[WARNING\]' "${PATCH_DIR}/branch-javac-${fn}.txt" \
        > "${PATCH_DIR}/branch-javac-${fn}-warning.txt"
    else
      touch "${PATCH_DIR}/branch-javac-${fn}.txt" \
        "${PATCH_DIR}/branch-javac-${fn}-warning.txt"
    fi

    ${GREP} '\[WARNING\]' "${PATCH_DIR}/patch-javac-${fn}.txt" \
      > "${PATCH_DIR}/patch-javac-${fn}-warning.txt"

    fn=$(module_file_fragment "${MODULE[${i}]}")
    count_javac_warns "${PATCH_DIR}/branch-javac-${fn}-warning.txt"
    numbranch=$?
    count_javac_warns "${PATCH_DIR}/patch-javac-${fn}-warning.txt"
    numpatch=$?

    if [[ -n ${numbranch}
        && -n ${numpatch}
        && ${numpatch} -gt ${numbranch} ]]; then

      ${DIFF} -u "${PATCH_DIR}/branch-javac-${fn}-warning.txt" \
        "${PATCH_DIR}/patch-javac-${fn}-warning.txt" \
        > "${PATCH_DIR}/javac-${fn}-diff.txt"

      mvn_module_status ${i} -1 "javac-${fn}-diff.txt" \
        "Patched ${MODULE[${i}]} generated "\
        "$((numpatch-numbranch)) additional warning messages." \


      ((result=result+1))
    fi
    ((i=i+1))
  done

  mvn_modules_message patch javac
  if [[ ${result} -gt 0 ]]; then
    return 1
  fi
  return 0
}

## @description  Helper for check_patch_javadoc
## @audience     private
## @stability    evolving
## @replaceable  no
## @return       0 on success
## @return       1 on failure
function count_javadoc_warns
{
  local warningfile=$1

  #shellcheck disable=SC2016,SC2046
  return $(${EGREP} "^[0-9]+ warnings$" "${warningfile}" | ${AWK} '{sum+=$1} END {print sum}')
}

## @description  Count and compare the number of JavaDoc warnings pre- and post- patch
## @audience     private
## @stability    evolving
## @replaceable  no
## @return       0 on success
## @return       1 on failure
function check_patch_javadoc
{
  local numbranch
  local numpatch
  local i=0
  local result=0
  local fn

  big_console_header "Determining number of patched javadoc warnings"

  verify_needed_test javadoc
    if [[ $? == 0 ]]; then
    echo "Patch does not appear to need javadoc tests."
    return 0
  fi

  personality_modules patch javadoc
  mvn_modules_worker patch javadoc clean javadoc:javadoc

  until [[ ${i} -eq ${#MODULE[@]} ]]; do
    if [[ ${MODULE_STATUS[${i}]} == -1 ]]; then
      ((result=result+1))
      ((i=i+1))
      continue
    fi

    fn=$(module_file_fragment "${MODULE[${i}]}")
    count_javadoc_warns "${PATCH_DIR}/branch-javadoc-${fn}.txt"
    numbranch=$?
    count_javadoc_warns "${PATCH_DIR}/patch-javadoc-${fn}.txt"
    numpatch=$?

    if [[ -n ${numbranch}
        && -n ${numpatch}
        && ${numpatch} -gt ${numbranch} ]] ; then

      if [[ -f "${PATCH_DIR}/branch-javadoc-${fn}.txt" ]]; then
        ${GREP} -i warning "${PATCH_DIR}/branch-javadoc-${fn}.txt" \
          > "${PATCH_DIR}/branch-javadoc-${fn}-filtered.txt"
      else
        touch "${PATCH_DIR}/branch-javadoc-${fn}.txt" \
          "${PATCH_DIR}/branch-javadoc-${fn}-filtered.txt"
      fi

      ${GREP} -i warning "${PATCH_DIR}/patch-javadoc-${fn}.txt" \
        > "${PATCH_DIR}/patch-javadoc-${fn}-filtered.txt"

      ${DIFF} -u "${PATCH_DIR}/branch-javadoc-${fn}-filtered.txt" \
        "${PATCH_DIR}/patch-javadoc-${fn}-filtered.txt" \
        > "${PATCH_DIR}/javadoc-${fn}-diff.txt"
      rm -f "${PATCH_DIR}/branch-javadoc-${fn}-filtered.txt" \
         "${PATCH_DIR}/patch-javadoc-${fn}-filtered.txt"

      mvn_module_status ${i} -1  "javadoc-${fn}-diff.txt" \
        "Patched ${MODULE[${i}]} generated "\
        "$((numpatch-numbranch)) additional warning messages." \


      ((result=result+1))
    fi
    ((i=i+1))
  done

  mvn_modules_message patch javac
  if [[ ${result} -gt 0 ]]; then
    return 1
  fi
  return 0
}

## @description  Make sure site still compiles
## @audience     private
## @stability    evolving
## @replaceable  no
## @return       0 on success
## @return       1 on failure
function check_site
{
  local result

  big_console_header "Determining number of patched site errors"

  verify_needed_test patch site
  if [[ $? == 0 ]]; then
    echo "Patch does not appear to need site tests."
    return 0
  fi

  personality_modules patch site
  mvn_modules_worker patch site clean site site:stage -Dmaven.javadoc.skip=true
  result=$?
  mvn_modules_message patch site
  if [[ ${result} != 0 ]]; then
    return 1
  fi
  return 0
}

## @description  Verify mvn install works
## @audience     private
## @stability    evolving
## @replaceable  no
## @return       0 on success
## @return       1 on failure
function precheck_mvninstall
{
  local result

  big_console_header "Verifying mvn install works"

  verify_needed_test javadoc
  retval=$?

  verify_needed_test javac
  ((retval = retval + $? ))
  if [[ ${retval} == 0 ]]; then
    echo "This patch does not appear to need mvn install checks."
    return 0
  fi

  personality_modules branch mvninstall
  mvn_modules_worker branch mvninstall install -Dmaven.javadoc.skip=true
  result=$?
  mvn_modules_message branch mvninstall
  if [[ ${result} != 0 ]]; then
    return 1
  fi
  return 0
}

## @description  Verify mvn install works
## @audience     private
## @stability    evolving
## @replaceable  no
## @return       0 on success
## @return       1 on failure
function check_mvninstall
{
  local result

  big_console_header "Verifying mvn install still works"

  verify_needed_test javadoc
  retval=$?

  verify_needed_test javac
  ((retval = retval + $? ))
  if [[ ${retval} == 0 ]]; then
    echo "This patch does not appear to need mvn install checks."
    return 0
  fi

  personality_modules patch mvninstall
  mvn_modules_worker patch mvninstall install -Dmaven.javadoc.skip=true
  result=$?
  mvn_modules_message patch mvninstall
  if [[ ${result} != 0 ]]; then
    return 1
  fi
  return 0
}

## @description  are the needed bits for findbugs present?
## @audience     private
## @stability    evolving
## @replaceable  no
## @return       0 findbugs will work for our use
## @return       1 findbugs is missing some component
function findbugs_is_installed
{
  if [[ ! -e "${FINDBUGS_HOME}/bin/findbugs" ]]; then
    printf "\n\n%s is not executable.\n\n" "${FINDBUGS_HOME}/bin/findbugs"
    add_jira_table -1 findbugs "Findbugs is not installed."
    return 1
  fi
  return 0
}

## @description  Run the maven findbugs plugin and record found issues in a bug database
## @audience     private
## @stability    evolving
## @replaceable  no
## @return       0 on success
## @return       1 on failure
function findbugs_mvnrunner
{
  local name=$1
  local module
  local result=0
  local fn
  local warnings_file
  local i
  local savestop

  personality_modules "${name}" findbugs
  mvn_modules_worker "${name}" findbugs clean test findbugs:findbugs

  until [[ ${i} -eq ${#MODULE[@]} ]]; do
    if [[ ${MODULE_STATUS[${i}]} == -1 ]]; then
      ((result=result+1))
      ((i=i+1))
      continue
    fi
    start_clock
    offset_clock "${MODULE_STATUS_TIMER[${i}]}"
    module="${MODULE[${i}]}"
    file="${module}/target/findbugsXml.xml"

    fn=$(module_file_fragment "${module}")

    if [[ -z ${FINDBUGS_VERSION} ]]; then
      #shellcheck disable=SC2016
      FINDBUGS_VERSION=$(${AWK} 'match($0, /findbugs-maven-plugin:[^:]*:findbugs/) { print substr($0, RSTART + 22, RLENGTH - 31); exit }' \
           "${PATCH_DIR}/${name}-findbugs-${fn}.txt")
      add_jira_footer findbugs "v${FINDBUGS_VERSION}"
    fi

    warnings_file="${PATCH_DIR}/${name}-findbugs-${fn}-warnings"

    cp -p "${file}" "${warnings_file}.xml"

    if [[ ${name} == branch ]]; then
      "${FINDBUGS_HOME}/bin/setBugDatabaseInfo" -name "${PATCH_BRANCH}" \
          "${warnings_file}.xml" "${warnings_file}.xml"
    else
      "${FINDBUGS_HOME}/bin/setBugDatabaseInfo" -name patch \
          "${warnings_file}.xml" "${warnings_file}.xml"
    fi
    if [[ $? != 0 ]]; then
      savestop=$(stop_clock)
      MODULE_STATUS_TIMER[${i}]=${savestop}
      mvn_module_status ${i} -1 "" "${name}/${module} cannot run setBugDatabaseInfo from findbugs"
      ((retval = retval + 1))
      ((i=i+1))
      continue
    fi

    "${FINDBUGS_HOME}/bin/convertXmlToText" -html \
      "${warnings_file}.xml" \
      "${warnings_file}.html"
    if [[ $? != 0 ]]; then
      savestop=$(stop_clock)
      MODULE_STATUS_TIMER[${i}]=${savestop}
      mvn_module_status ${i} -1 "" "${name}/${module} cannot run convertXmlToText from findbugs"
      ((result = result + 1))
    fi

    ((i=i+1))
  done
  return ${result}
}

## @description  Track pre-existing findbugs warnings
## @audience     private
## @stability    evolving
## @replaceable  no
## @return       0 on success
## @return       1 on failure
function precheck_findbugs
{
  local fn
  local module
  local i
  local warnings_file
  local module_findbugs_warnings
  local results=0

  big_console_header "Pre-patch findbugs detection"

  verify_needed_test findbugs

  if [[ $? == 0 ]]; then
    echo "Patch does not appear to need findbugs tests."
    return 0
  fi

  findbugs_is_installed
  if [[ $? != 0 ]]; then
    return 1
  fi

  findbugs_mvnrunner branch
  results=$?

  if [[ "${FINDBUGS_WARNINGS_FAIL_PRECHECK}" == "true" ]]; then
    until [[ $i -eq ${#MODULE[@]} ]]; do
      if [[ ${MODULE_STATUS[${i}]} == -1 ]]; then
        ((result=result+1))
        ((i=i+1))
        continue
      fi
      module=${MODULE[${i}]}
      start_clock
      offset_clock "${MODULE_STATUS_TIMER[${i}]}"
      fn=$(module_file_fragment "${module}")
      warnings_file="${PATCH_DIR}/branch-findbugs-${fn}-warnings"
      # shellcheck disable=SC2016
      module_findbugs_warnings=$("${FINDBUGS_HOME}/bin/filterBugs" -first \
          "${PATCH_BRANCH}" \
          "${warnings_file}.xml" \
          "${warnings_file}.xml" \
          | ${AWK} '{print $1}')

      if [[ ${module_findbugs_warnings} -gt 0 ]] ; then
        mvn_module_status ${i} -1 "branch-findbugs-${fn}.html" "${module} in ${PATCH_BRANCH} cannot run convertXmlToText from findbugs"
        ((results=results+1))
      fi
      savestop=$(stop_clock)
      MODULE_STATUS_TIMER[${i}]=${savestop}
      ((i=i+1))
    done
    mvn_modules_message branch findbugs
  fi

  if [[ ${results} != 0 ]]; then
    return 1
  fi
  return 0
}

## @description  Verify patch does not trigger any findbugs warnings
## @audience     private
## @stability    evolving
## @replaceable  no
## @return       0 on success
## @return       1 on failure
function check_findbugs
{
  local module
  local oldtimer
  local fn
  local combined_xml
  local branchxml
  local patchxml
  local newbugsbase
  local new_findbugs_warnings
  local line
  local firstpart
  local secondpart
  local i
  local results=0
  local savestop

  big_console_header "Patch findbugs detection"

  verify_needed_test findbugs

  if [[ $? == 0 ]]; then
    echo "Patch does not appear to need findbugs tests."
    return 0
  fi

  findbugs_is_installed
  if [[ $? != 0 ]]; then
    return 1
  fi

  findbugs_mvnrunner patch

  until [[ $i -eq ${#MODULE[@]} ]]; do
    if [[ ${MODULE_STATUS[${i}]} == -1 ]]; then
      ((result=result+1))
      ((i=i+1))
      continue
    fi
    start_clock
    offset_clock "${MODULE_STATUS_TIMER[${i}]}"
    module="${MODULE[${i}]}"
    pushd "${module}" >/dev/null
    fn=$(module_file_fragment "${module}")

    combined_xml="${PATCH_DIR}/combined-findbugs-${fn}.xml"
    branchxml="${PATCH_DIR}/branch-findbugs-${fn}-warnings.xml"
    patchxml="${PATCH_DIR}/patch-findbugs-${fn}-warnings.xml"

    if [[ ! -f "${branchxml}" ]]; then
      branchxml=${patchxml}
    fi

    newbugsbase="${PATCH_DIR}/new-findbugs-${fn}"

    "${FINDBUGS_HOME}/bin/computeBugHistory" -useAnalysisTimes -withMessages \
            -output "${combined_xml}" \
            "${branchxml}" \
            "${patchxml}"
    if [[ $? != 0 ]]; then
      popd >/dev/null
      mvn_module_status ${i} -1 "" "${module} cannot run computeBugHistory from findbugs"
      ((result=result+1))
      savestop=$(stop_clock)
      MODULE_STATUS_TIMER[${i}]=${savestop}
      ((i=i+1))
      continue
    fi

    #shellcheck disable=SC2016
    new_findbugs_warnings=$("${FINDBUGS_HOME}/bin/filterBugs" -first patch \
        "${combined_xml}" "${newbugsbase}.xml" | ${AWK} '{print $1}')
    if [[ $? != 0 ]]; then
      popd >/dev/null
      mvn_module_status ${i} -1 "" "${module} cannot run filterBugs (#1) from findbugs"
      ((result=result+1))
      savestop=$(stop_clock)
      MODULE_STATUS_TIMER[${i}]=${savestop}
      ((i=i+1))
      continue
    fi

    #shellcheck disable=SC2016
    new_findbugs_fixed_warnings=$("${FINDBUGS_HOME}/bin/filterBugs" -fixed patch \
        "${combined_xml}" "${newbugsbase}.xml" | ${AWK} '{print $1}')
    if [[ $? != 0 ]]; then
      popd >/dev/null
      mvn_module_status ${i} -1 "" "${module} cannot run filterBugs (#2) from findbugs"
      ((result=result+1))
      savestop=$(stop_clock)
      MODULE_STATUS_TIMER[${i}]=${savestop}
      ((i=i+1))
      continue
    fi

    echo "Found ${new_findbugs_warnings} new Findbugs warnings and ${new_findbugs_fixed_warnings} newly fixed warnings."
    findbugs_warnings=$((findbugs_warnings+new_findbugs_warnings))
    findbugs_fixed_warnings=$((findbugs_fixed_warnings+new_findbugs_fixed_warnings))

    "${FINDBUGS_HOME}/bin/convertXmlToText" -html "${newbugsbase}.xml" \
        "${newbugsbase}.html"
    if [[ $? != 0 ]]; then
      popd >/dev/null
      mvn_module_status ${i} -1 "" "${module} cannot run convertXmlToText from findbugs"
      ((result=result+1))
      savestop=$(stop_clock)
      MODULE_STATUS_TIMER[${i}]=${savestop}
      ((i=i+1))
      continue
    fi

    if [[ ${new_findbugs_warnings} -gt 0 ]] ; then
      populate_test_table FindBugs "module:${module}"
      while read line; do
        firstpart=$(echo "${line}" | cut -f2 -d:)
        secondpart=$(echo "${line}" | cut -f9- -d' ')
        add_jira_test_table "" "${firstpart}:${secondpart}"
      done < <("${FINDBUGS_HOME}/bin/convertXmlToText" "${newbugsbase}.xml")

      mvn_module_status ${i} -1 "${newbugsbase}.html" "${module} introduced "\
        "${new_findbugs_warnings} new FindBugs issues."
      ((result=result+1))
    fi
    savestop=$(stop_clock)
    MODULE_STATUS_TIMER[${i}]=${savestop}
    popd >/dev/null
    ((i=i+1))
  done

  mvn_modules_message patch findbugs
  if [[ ${result} != 0 ]]; then
    return 1
  fi
  return 0
}

## @description  Make sure Maven's eclipse generation works.
## @audience     private
## @stability    evolving
## @replaceable  no
## @return       0 on success
## @return       1 on failure
function check_mvn_eclipse
{
  big_console_header "Verifying mvn eclipse:eclipse still works"

  verify_needed_test javac
  if [[ $? == 0 ]]; then
    echo "Patch does not touch any java files. Skipping mvn eclipse:eclipse"
    return 0
  fi

  personality_modules patch eclipse
  mvn_modules_worker patch eclipse eclipse:eclipse
  result=$?
  mvn_modules_message patch eclipse
  if [[ ${result} != 0 ]]; then
    return 1
  fi
  return 0
}

## @description  Utility to push many tests into the failure list
## @audience     private
## @stability    evolving
## @replaceable  no
## @param        testdesc
## @param        testlist
function populate_test_table
{
  local reason=$1
  shift
  local first=""
  local i

  for i in "$@"; do
    if [[ -z "${first}" ]]; then
      add_jira_test_table "${reason}" "${i}"
      first="${reason}"
    else
      add_jira_test_table " " "${i}"
    fi
  done
}

## @description  Run and verify the output of the appropriate unit tests
## @audience     private
## @stability    evolving
## @replaceable  no
## @return       0 on success
## @return       1 on failure
function check_unittests
{

  local failed_tests=""
  local failed_test_builds=""
  local test_timeouts=""
  local test_logfile
  local test_build_result
  local module_test_timeouts=""
  local result
  local oldtimer

  big_console_header "Running unit tests"

  verify_needed_test unit

  if [[ $? == 0 ]]; then
    echo "Existing unit tests do not test patched files. Skipping."
    return 0

  fi

  personality_modules patch unit
  mvn_modules_worker patch unit clean install -fae
  if [[ $? == 0 ]]; then
    add_jira_table +1 unit "Patch unit tests appear healthy."
    return 0
  fi

  mvn_modules_message patch unit "" "unit tests are broken."

  until [[ $i -eq ${#MODULE[@]} ]]; do
    module=${MODULE[${i}]}
    fn=$(module_file_fragment "${module}")
    test_logfile="${PATCH_DIR}/patch-unit-${fn}.txt"

    # shellcheck disable=2016
    module_test_timeouts=$(${AWK} '/^Running / { array[$NF] = 1 } /^Tests run: .* in / { delete array[$NF] } END { for (x in array) { print x } }' "${test_logfile}")
    if [[ -n "${module_test_timeouts}" ]] ; then
      test_timeouts="${test_timeouts} ${module_test_timeouts}"
      result=1
    fi

    pushd "${MODULE[${i}]}" >/dev/null
    #shellcheck disable=SC2026,SC2038,SC2016
    module_failed_tests=$(find . -name 'TEST*.xml'\
      | xargs "${GREP}" -l -E "<failure|<error"\
      | ${AWK} -F/ '{sub("TEST-org.apache.",""); sub(".xml",""); print $NF}')

    popd >/dev/null

    if [[ -n "${module_failed_tests}" ]] ; then
      failed_tests="${failed_tests} ${module_failed_tests}"
      result=1
    fi
    if [[ ${test_build_result} != 0 && -z "${module_failed_tests}" && -z "${module_test_timeouts}" ]] ; then
      failed_test_builds="${failed_test_builds} ${module}"
      result=1
    fi

    ((i=i+1))
  done

  if [[ -n "${failed_tests}" ]] ; then
    # shellcheck disable=SC2086
    populate_test_table "Failed unit tests" ${failed_tests}
  fi
  if [[ -n "${test_timeouts}" ]] ; then
    # shellcheck disable=SC2086
    populate_test_table "Timed out tests" ${test_timeouts}
  fi
  if [[ -n "${failed_test_builds}" ]] ; then
    # shellcheck disable=SC2086
    populate_test_table "Failed build" ${failed_test_builds}
  fi

  if [[ ${JENKINS} == true ]]; then
    add_jira_footer "Test Results" "${BUILD_URL}testReport/"
  fi

  return 1
}

## @description  Print out the finished details on the console
## @audience     private
## @stability    evolving
## @replaceable  no
## @param        runresult
## @return       0 on success
## @return       1 on failure
function output_to_console
{
  local result=$1
  shift
  local i
  local ourstring
  local vote
  local subs
  local ela
  local comment
  local commentfile1="${PATCH_DIR}/comment.1"
  local commentfile2="${PATCH_DIR}/comment.2"
  local normaltop
  local line
  local seccoladj=0
  local spcfx=${PATCH_DIR}/spcl.txt

  if [[ ${result} == 0 ]]; then
    if [[ ${JENKINS} == false ]]; then
      {
        printf "IF9fX19fX19fX18gCjwgU3VjY2VzcyEgPgogLS0tLS0tLS0tLSAKIFwgICAg";
        printf "IC9cICBfX18gIC9cCiAgXCAgIC8vIFwvICAgXC8gXFwKICAgICAoKCAgICBP";
        printf "IE8gICAgKSkKICAgICAgXFwgLyAgICAgXCAvLwogICAgICAgXC8gIHwgfCAg";
        printf "XC8gCiAgICAgICAgfCAgfCB8ICB8ICAKICAgICAgICB8ICB8IHwgIHwgIAog";
        printf "ICAgICAgIHwgICBvICAgfCAgCiAgICAgICAgfCB8ICAgfCB8ICAKICAgICAg";
        printf "ICB8bXwgICB8bXwgIAo"
      } > "${spcfx}"
    fi
    printf "\n\n+1 overall\n\n"
  else
    if [[ ${JENKINS} == false ]]; then
      {
        printf "IF9fX19fICAgICBfIF8gICAgICAgICAgICAgICAgXyAKfCAgX19ffF8gXyhf";
        printf "KSB8XyAgIF8gXyBfXyBfX198IHwKfCB8XyAvIF9gIHwgfCB8IHwgfCB8ICdf";
        printf "Xy8gXyBcIHwKfCAgX3wgKF98IHwgfCB8IHxffCB8IHwgfCAgX18vX3wKfF98";
        printf "ICBcX18sX3xffF98XF9fLF98X3wgIFxfX18oXykKICAgICAgICAgICAgICAg";
        printf "ICAgICAgICAgICAgICAgICAK"
      } > "${spcfx}"
    fi
    printf "\n\n-1 overall\n\n"
  fi

  if [[ -f ${spcfx} ]]; then
    if which base64 >/dev/null 2>&1; then
      base64 --decode "${spcfx}" 2>/dev/null
    elif which openssl >/dev/null 2>&1; then
      openssl enc -A -d -base64 -in "${spcfx}" 2>/dev/null
    fi
    echo
    echo
    rm "${spcfx}"
  fi

  seccoladj=$(findlargest 2 "${JIRA_COMMENT_TABLE[@]}")
  if [[ ${seccoladj} -lt 10 ]]; then
    seccoladj=10
  fi

  seccoladj=$((seccoladj + 2 ))
  i=0
  until [[ $i -eq ${#JIRA_HEADER[@]} ]]; do
    printf "%s\n" "${JIRA_HEADER[${i}]}"
    ((i=i+1))
  done

  printf "| %s | %*s |  %s   | %s\n" "Vote" ${seccoladj} Subsystem Runtime "Comment"
  echo "============================================================================"
  i=0
  until [[ $i -eq ${#JIRA_COMMENT_TABLE[@]} ]]; do
    ourstring=$(echo "${JIRA_COMMENT_TABLE[${i}]}" | tr -s ' ')
    vote=$(echo "${ourstring}" | cut -f2 -d\|)
    vote=$(colorstripper "${vote}")
    subs=$(echo "${ourstring}"  | cut -f3 -d\|)
    ela=$(echo "${ourstring}" | cut -f4 -d\|)
    comment=$(echo "${ourstring}"  | cut -f5 -d\|)

    echo "${comment}" | fold -s -w $((78-seccoladj-22)) > "${commentfile1}"
    normaltop=$(head -1 "${commentfile1}")
    ${SED} -e '1d' "${commentfile1}"  > "${commentfile2}"

    printf "| %4s | %*s | %-10s |%-s\n" "${vote}" ${seccoladj} \
      "${subs}" "${ela}" "${normaltop}"
    while read line; do
      printf "|      | %*s |            | %-s\n" ${seccoladj} " " "${line}"
    done < "${commentfile2}"

    ((i=i+1))
    rm "${commentfile2}" "${commentfile1}" 2>/dev/null
  done

  if [[ ${#JIRA_TEST_TABLE[@]} -gt 0 ]]; then
    seccoladj=$(findlargest 1 "${JIRA_TEST_TABLE[@]}")
    printf "\n\n%*s | Tests\n" "${seccoladj}" "Reason"
    i=0
    until [[ $i -eq ${#JIRA_TEST_TABLE[@]} ]]; do
      ourstring=$(echo "${JIRA_TEST_TABLE[${i}]}" | tr -s ' ')
      vote=$(echo "${ourstring}" | cut -f2 -d\|)
      subs=$(echo "${ourstring}"  | cut -f3 -d\|)
      printf "%*s | %s\n" "${seccoladj}" "${vote}" "${subs}"
      ((i=i+1))
    done
  fi

  printf "\n\n|| Subsystem || Report/Notes ||\n"
  echo "============================================================================"
  i=0

  until [[ $i -eq ${#JIRA_FOOTER_TABLE[@]} ]]; do
    comment=$(echo "${JIRA_FOOTER_TABLE[${i}]}" |
              ${SED} -e "s,@@BASE@@,${PATCH_DIR},g")
    printf "%s\n" "${comment}"
    ((i=i+1))
  done
}

## @description  Print out the finished details to the JIRA issue
## @audience     private
## @stability    evolving
## @replaceable  no
## @param        runresult
function output_to_jira
{
  local result=$1
  local i
  local commentfile=${PATCH_DIR}/commentfile
  local comment

  rm "${commentfile}" 2>/dev/null

  if [[ ${JENKINS} != "true" ]] ; then
    return 0
  fi

  big_console_header "Adding comment to JIRA"

  add_jira_footer "Console output" "${BUILD_URL}console"

  if [[ ${result} == 0 ]]; then
    add_jira_header "(/) *{color:green}+1 overall{color}*"
  else
    add_jira_header "(x) *{color:red}-1 overall{color}*"
  fi

  { echo "\\\\" ; echo "\\\\"; } >>  "${commentfile}"

  i=0
  until [[ $i -eq ${#JIRA_HEADER[@]} ]]; do
    printf "%s\n" "${JIRA_HEADER[${i}]}" >> "${commentfile}"
    ((i=i+1))
  done

  { echo "\\\\" ; echo "\\\\"; } >>  "${commentfile}"

  echo "|| Vote || Subsystem || Runtime || Comment ||" >> "${commentfile}"

  i=0
  until [[ $i -eq ${#JIRA_COMMENT_TABLE[@]} ]]; do
    printf "%s\n" "${JIRA_COMMENT_TABLE[${i}]}" >> "${commentfile}"
    ((i=i+1))
  done

  if [[ ${#JIRA_TEST_TABLE[@]} -gt 0 ]]; then
    { echo "\\\\" ; echo "\\\\"; } >>  "${commentfile}"

    echo "|| Reason || Tests ||" >>  "${commentfile}"
    i=0
    until [[ $i -eq ${#JIRA_TEST_TABLE[@]} ]]; do
      printf "%s\n" "${JIRA_TEST_TABLE[${i}]}" >> "${commentfile}"
      ((i=i+1))
    done
  fi

  { echo "\\\\" ; echo "\\\\"; } >>  "${commentfile}"

  echo "|| Subsystem || Report/Notes ||" >> "${commentfile}"
  i=0
  until [[ $i -eq ${#JIRA_FOOTER_TABLE[@]} ]]; do
    comment=$(echo "${JIRA_FOOTER_TABLE[${i}]}" |
              ${SED} -e "s,@@BASE@@,${BUILD_URL}artifact/patchprocess,g")
    printf "%s\n" "${comment}" >> "${commentfile}"
    ((i=i+1))
  done

  printf "\n\nThis message was automatically generated.\n\n" >> "${commentfile}"

  write_to_jira "${commentfile}"
}

## @description  Clean the filesystem as appropriate and then exit
## @audience     private
## @stability    evolving
## @replaceable  no
## @param        runresult
function cleanup_and_exit
{
  local result=$1

  if [[ ${JENKINS} == "true" && ${RELOCATE_PATCH_DIR} == "true" && \
      -e ${PATCH_DIR} && -d ${PATCH_DIR} ]] ; then
    # if PATCH_DIR is already inside BASEDIR, then
    # there is no need to move it since we assume that
    # Jenkins or whatever already knows where it is at
    # since it told us to put it there!
    relative_patchdir >/dev/null
    if [[ $? == 1 ]]; then
      testudine_debug "mv ${PATCH_DIR} ${BASEDIR}"
      mv "${PATCH_DIR}" "${BASEDIR}"
    fi
  fi
  big_console_header "Finished build."

  # shellcheck disable=SC2086
  exit ${result}
}

## @description  Driver to execute _postcheckout routines
## @audience     private
## @stability    evolving
## @replaceable  no
function postcheckout
{
  local routine
  local plugin

  for routine in find_java_home verify_patch_file
  do
    verify_patchdir_still_exists

    testudine_debug "Running ${routine}"
    ${routine}

    (( RESULT = RESULT + $? ))
    if [[ ${RESULT} != 0 ]] ; then
      output_to_console 1
      output_to_jira 1
      cleanup_and_exit 1
    fi
  done

  for plugin in ${PLUGINS}; do
    verify_patchdir_still_exists

    if declare -f ${plugin}_postcheckout >/dev/null 2>&1; then

      testudine_debug "Running ${plugin}_postcheckout"
      #shellcheck disable=SC2086
      ${plugin}_postcheckout

      (( RESULT = RESULT + $? ))
      if [[ ${RESULT} != 0 ]] ; then
        output_to_console 1
        output_to_jira 1
        cleanup_and_exit 1
      fi
    fi
  done
}

## @description  Driver to execute _preapply routines
## @audience     private
## @stability    evolving
## @replaceable  no
function preapply
{
  local routine
  local plugin

  for routine in precheck_without_patch check_author \
                 check_modified_unittests
  do
    verify_patchdir_still_exists

    testudine_debug "Running ${routine}"
    ${routine}

    (( RESULT = RESULT + $? ))
  done

  for plugin in ${PLUGINS}; do
    verify_patchdir_still_exists

    if declare -f ${plugin}_preapply >/dev/null 2>&1; then

      testudine_debug "Running ${plugin}_preapply"
      #shellcheck disable=SC2086
      ${plugin}_preapply

      (( RESULT = RESULT + $? ))
    fi
  done
}

## @description  Driver to execute _postapply routines
## @audience     private
## @stability    evolving
## @replaceable  no
function postapply
{
  local routine
  local plugin
  local retval

  compute_gitdiff "${GITDIFFLINES}"

  check_patch_javac
  retval=$?
  if [[ ${retval} -gt 1 ]] ; then
    output_to_console 1
    output_to_jira 1
    cleanup_and_exit 1
  fi

  ((RESULT = RESULT + retval))

  for routine in check_patch_javadoc check_site
  do
    verify_patchdir_still_exists
    testudine_debug "Running ${routine}"
    $routine

    (( RESULT = RESULT + $? ))

  done

  for plugin in ${PLUGINS}; do
    verify_patchdir_still_exists
    if declare -f ${plugin}_postapply >/dev/null 2>&1; then
      testudine_debug "Running ${plugin}_postapply"
      #shellcheck disable=SC2086
      ${plugin}_postapply
      (( RESULT = RESULT + $? ))
    fi
  done
}

## @description  Driver to execute _postinstall routines
## @audience     private
## @stability    evolving
## @replaceable  no
function postinstall
{
  local routine
  local plugin

  for routine in check_mvn_eclipse check_findbugs
  do
    verify_patchdir_still_exists
    testudine_debug "Running ${routine}"
    ${routine}
    (( RESULT = RESULT + $? ))
  done

  for plugin in ${PLUGINS}; do
    verify_patchdir_still_exists
    if declare -f ${plugin}_postinstall >/dev/null 2>&1; then
      testudine_debug "Running ${plugin}_postinstall"
      #shellcheck disable=SC2086
      ${plugin}_postinstall
      (( RESULT = RESULT + $? ))
    fi
  done

}

## @description  Driver to execute _tests routines
## @audience     private
## @stability    evolving
## @replaceable  no
function runtests
{
  local plugin

  ### Run tests for Jenkins or if explictly asked for by a developer
  if [[ ${JENKINS} == "true" || ${RUN_TESTS} == "true" ]] ; then

    verify_patchdir_still_exists
    check_unittests

    (( RESULT = RESULT + $? ))
  fi

  for plugin in ${PLUGINS}; do
    verify_patchdir_still_exists
    if declare -f ${plugin}_tests >/dev/null 2>&1; then
      testudine_debug "Running ${plugin}_tests"
      #shellcheck disable=SC2086
      ${plugin}_tests
      (( RESULT = RESULT + $? ))
    fi
  done
}

## @description  Import content from test-patch.d and optionally
## @description  from user provided plugin directory
## @audience     private
## @stability    evolving
## @replaceable  no
function importplugins
{
  local i
  local files=()

  if [[ ${LOAD_SYSTEM_PLUGINS} == "true" ]]; then
    if [[ -d "${BINDIR}/test-patch.d" ]]; then
      files=(${BINDIR}/test-patch.d/*.sh)
    fi
  fi

  if [[ -n "${USER_PLUGIN_DIR}" && -d "${USER_PLUGIN_DIR}" ]]; then
    testudine_debug "Loading user provided plugins from ${USER_PLUGIN_DIR}"
    files=("${files[@]}" ${USER_PLUGIN_DIR}/*.sh)
  fi

  for i in "${files[@]}"; do
    testudine_debug "Importing ${i}"
    . "${i}"
  done

  if [[ -z ${PERSONALITY}
      && -f "${BINDIR}/personality/${PROJECT_NAME}.sh" ]]; then
    PERSONALITY="${BINDIR}/personality/${PROJECT_NAME}.sh"
  fi

  if [[ -n ${PERSONALITY} ]]; then
    testudine_debug "Importing ${PERSONALITY}"
    . "${PERSONALITY}"
  fi
}

## @description  Let plugins also get a copy of the arguments
## @audience     private
## @stability    evolving
## @replaceable  no
function parse_args_plugins
{
  for plugin in ${PLUGINS}; do
    if declare -f ${plugin}_parse_args >/dev/null 2>&1; then
      testudine_debug "Running ${plugin}_parse_args"
      #shellcheck disable=SC2086
      ${plugin}_parse_args "$@"
      (( RESULT = RESULT + $? ))
    fi
  done
}

## @description  Register test-patch.d plugins
## @audience     public
## @stability    stable
## @replaceable  no
function add_plugin
{
  PLUGINS="${PLUGINS} $1"
}

###############################################################################
###############################################################################
###############################################################################

big_console_header "Bootstrapping test harness"

setup_defaults

parse_args "$@"

importplugins

parse_args_plugins "$@"

open_jira_footer

finish_docker_stats

locate_patch

# from here on out, we'll be in ${BASEDIR} for cwd
# routines need to pushd/popd if they change.
git_checkout
RESULT=$?
if [[ ${JENKINS} == "true" ]] ; then
  if [[ ${RESULT} != 0 ]] ; then
    exit 100
  fi
fi

# if we are doing docker
if [[ ${DOCKERSUPPORT} == true ]]; then
   docker_launch
fi

find_changed_files

determine_needed_tests

check_reexec

postcheckout

find_changed_modules

preapply

apply_patch_file

# we find changed modules again
# in case the patch adds or removes a module
# this also means that test suites need to be
# aware that there might not be a 'before'
find_changed_modules

postapply

check_mvninstall

postinstall

runtests

close_jira_table

output_to_console ${RESULT}
output_to_jira ${RESULT}
cleanup_and_exit ${RESULT}
