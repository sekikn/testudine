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

add_plugin checkstyle

CHECKSTYLE_TIMER=0

# if it ends in an explicit .sh, then this is shell code.
# if it doesn't have an extension, we assume it is shell code too
function checkstyle_filefilter
{
  local filename=$1

  if [[ ${filename} =~ \.java$ ]]; then
    add_test checkstyle
  fi
}

function checkstyle_mvnrunner
{
  local repostatus=$1
  local tmp=${PATCH_DIR}/$$.${RANDOM}
  local j
  local i=0
  local fn
  local savestart=${TIMER}
  local savestop
  local output
  local logfile
  local repo
  local modulesuffix

  mvn_modules_reset

  if [[ ${repostatus} == branch ]]; then
    repo=${PATCH_BRANCH}
  else
    repo="the patch"
  fi

  #shellcheck disable=SC2153
  until [[ $i -eq ${#MODULE[@]} ]]; do
    start_clock
    fn=$(module_file_fragment "${MODULE[${i}]}")
    modulesuffix=$(basename "${MODULE[${i}]}")
    output="${PATCH_DIR}/${repostatus}-checkstyle-${fn}.txt"
    logfile="${PATCH_DIR}/maven-${repostatus}-checkstyle-${fn}.txt"
    pushd "${BASEDIR}/${MODULE[${i}]}" >/dev/null
    #shellcheck disable=SC2086

    "${MVN}" "${MAVEN_ARGS[@]}" clean test \
       checkstyle:checkstyle \
      -Dcheckstyle.consoleOutput=true \
      ${MODULEEXTRAPARAM[${i}]} -Ptest-patch \
      "-D${PROJECT_NAME}PatchProcess" 2>&1 \
        | tee "${logfile}" \
        | ${GREP} ^/ \
        | ${SED} -e "s,${BASEDIR},.,g" \
            > "${tmp}"
    if [[ $? == 0 ]] ; then
      mvn_module_status ${i} +1 "${logfile}" "${modulesuffix} in ${repo} passed checkstyle"
    else
      mvn_module_status ${i} -1 "${logfile}" "${modulesuffix} in ${repo} failed checkstyle"
      ((result = result + 1))
    fi
    savestop=$(stop_clock)
    #shellcheck disable=SC2034
    MODULE_STATUS_TIMER[${i}]=${savestop}

    for j in ${CHANGED_FILES}; do
      ${GREP} "${j}" "${tmp}" >> "${output}"
    done

    rm "${tmp}" 2>/dev/null
    # shellcheck disable=SC2086
    popd >/dev/null
    ((i=i+1))
  done

  TIMER=${savestart}

  if [[ ${result} -gt 0 ]]; then
    return 1
  fi
  return 0
}

function checkstyle_preapply
{
  local result

  big_console_header "${PATCH_BRANCH} checkstyle"

  start_clock

  verify_needed_test checkstyle
  if [[ $? == 0 ]]; then
    echo "Patch does not need checkstyle testing."
    return 0
  fi

  personality branch checkstyle
  checkstyle_mvnrunner branch
  result=$?
  mvn_modules_message branch checkstyle

  # keep track of how much as elapsed for us already
  CHECKSTYLE_TIMER=$(stop_clock)
  if [[ ${result} != 0 ]]; then
    return 1
  fi
  return 0
}

function checkstyle_calcdiffs
{
  local orig=$1
  local new=$2
  local diffout=$3
  local tmp=${PATCH_DIR}/cs.$$.${RANDOM}
  local count=0
  local j

  # first, pull out just the errors
  # shellcheck disable=SC2016
  ${AWK} -F: '{print $NF}' "${orig}" >> "${tmp}.branch"

  # shellcheck disable=SC2016
  ${AWK} -F: '{print $NF}' "${new}" >> "${tmp}.patch"

  # compare the errors, generating a string of line
  # numbers.  Sorry portability: GNU diff makes this too easy
  ${DIFF} --unchanged-line-format="" \
     --old-line-format="" \
     --new-line-format="%dn " \
     "${tmp}.branch" \
     "${tmp}.patch" > "${tmp}.lined"

  # now, pull out those lines of the raw output
  # shellcheck disable=SC2013
  for j in $(cat "${tmp}.lined"); do
    # shellcheck disable=SC2086
    head -${j} "${new}" | tail -1 >> "${diffout}"
  done

  if [[ -f "${diffout}" ]]; then
    # shellcheck disable=SC2016
    count=$(wc -l "${diffout}" | ${AWK} '{print $1}' )
  fi
  rm "${tmp}.branch" "${tmp}.patch" "${tmp}.lined" 2>/dev/null
  echo "${count}"
}

function checkstyle_postapply
{
  local result
  local module
  local numprepatch=0
  local numpostpatch=0
  local diffpostpatch=0

  big_console_header "Patch checkstyle plugin"

  start_clock

  verify_needed_test checkstyle
  if [[ $? == 0 ]]; then
    echo "Patch does not need checkstyle testing."
    return 0
  fi

  personality patch checkstyle
  checkstyle_mvnrunner patch
  result=$?


  # add our previous elapsed to our new timer
  # by setting the clock back
  offset_clock "${CHECKSTYLE_TIMER}"

  until [[ $i -eq ${#MODULE[@]} ]]; do
    if [[ ${MODULE_STATUS[${i}]} == -1 ]]; then
      ((result=result+1))
      ((i=i+1))
      continue
    fi
    module=${MODULE[$i]}
    fn=$(module_file_fragment "${module}")

    if [[ ! -f "${PATCH_DIR}/branch-checkstyle-${fn}.txt" ]]; then
      touch "${PATCH_DIR}/branch-checkstyle-${fn}.txt"
    fi

    #shellcheck disable=SC2016
    diffpostpatch=$(checkstyle_calcdiffs \
      "${PATCH_DIR}/branch-checkstyle-${fn}.txt" \
      "${PATCH_DIR}/patch-checkstyle-${fn}.txt" \
      "${PATCH_DIR}/diff-checkstyle-${fn}.txt" )

    if [[ ${diffpostpatch} -gt 0 ]] ; then
      ((result = result + 1))

      # shellcheck disable=SC2016
      numprepatch=$(wc -l "${PATCH_DIR}/branch-checkstyle-${fn}.txt" | ${AWK} '{print $1}')
      # shellcheck disable=SC2016
      numpostpatch=$(wc -l "${PATCH_DIR}/patch-checkstyle-${fn}.txt" | ${AWK} '{print $1}')

      mvn_module_status ${i} -1 "diff-checkstyle-${fn}.txt" "Patch generated "\
        "${diffpostpatch} new checkstyle issues in "\
        "${module} (total was ${numprepatch}, now ${numpostpatch})."
    fi
    ((i=i+1))
  done

  mvn_modules_message patch checkstyle

  if [[ ${result} != 0 ]]; then
    return 1
  fi
  return 0
}