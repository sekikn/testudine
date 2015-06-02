##!/usr/bin/env bash
## Licensed to the Apache Software Foundation (ASF) under one or more
## contributor license agreements.  See the NOTICE file distributed with
## this work for additional information regarding copyright ownership.
## The ASF licenses this file to You under the Apache License, Version 2.0
## (the "License"); you may not use this file except in compliance with
## the License.  You may obtain a copy of the License at
##
##     http://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
#
#HADOOP_MODULES=""
#
#function hadoop_module_manipulation
#{
#  local need_common=0
#  local module
#  local hdfs_modules
#  local ordered_modules
#  local tools_modules
#  local passed_modules=${CHANGED_MODULES}
#
#  testudine_debug "hmm: starting list: ${passed_modules}"
#
#  # if one of our modules is ., then shortcut:
#  # ignore the rest and just set it to everything.
#  if [[ ${CHANGED_MODULES} == ' . ' ]]; then
#    HADOOP_MODULES='.'
#    return
#  fi
#
#  # ${CHANGED_MODULES} is already sorted and uniq'd.
#  # let's remove child modules if we're going to
#  # touch their parent
#  for module in ${CHANGED_MODULES}; do
#    testudine_debug "Stripping ${module}"
#    # shellcheck disable=SC2086
#    passed_modules=$(echo ${passed_modules} | tr ' ' '\n' | ${GREP} -v ${module}/ )
#  done
#
#  for module in ${passed_modules}; do
#    testudine_debug "Personality ordering ${module}"
#    if [[ ${module} == hadoop-hdfs-project* ]]; then
#      hdfs_modules="${hdfs_modules} ${module}"
#      need_common=1
#    elif [[ ${module} == hadoop-common-project/hadoop-common
#      || ${module} == hadoop-common-project ]]; then
#      ordered_modules="${ordered_modules} ${module}"
#      building_common=1
#    elif [[ ${module} == hadoop-tools* ]]; then
#      tools_modules="${tools_modules} ${module}"
#    else
#      ordered_modules="${ordered_modules} ${module}"
#    fi
#  done
#
#  ordered_modules="${ordered_modules} ${hdfs_modules} ${tools_modules}"
#
#  if [[ ${need_common} -eq 1
#      && ${building_common} -eq 0 ]]; then
#      ordered_modules="hadoop-common-project/hadoop-common ${ordered_modules}"
#  fi
#
#  testudine_debug "hmm: ${ordered_modules}"
#  HADOOP_MODULES=${ordered_modules}
#}
#
#function hadoop_javac_ordering
#{
#  local special=$1
#  local ordered_modules
#  local module
#
#  hadoop_module_manipulation
#
#  # Based upon HADOOP-11937
#  #
#  # Some notes:
#  #
#  # - getting fuse to compile on anything but Linux
#  #   is always tricky.
#  # - Darwin assumes homebrew is in use.
#  # - HADOOP-12027 required for bzip2 on OS X.
#  # - bzip2 is broken in lots of places.
#  #   e.g, HADOOP-12027 for OS X. so no -Drequire.bzip2
#  #
#
#  for module in ${HADOOP_MODULES}; do
#      case ${module} in
#        # (special case: all of them...)
#        \.)
#          case ${OSTYPE} in
#            Linux)
#              # shellcheck disable=SC2086
#              personality_enqueue_module ${module} ${special} \
#                -Pnative \
#                -Drequire.snappy -Drequire.openssl -Drequire.fuse \
#                -Drequire.test.libhadoop
#            ;;
#            Darwin)
#              JANSSON_INCLUDE_DIR=/usr/local/opt/jansson/include
#              JANSSON_LIBRARY=/usr/local/opt/jansson/lib
#              export JANSSON_LIBRARY JANSSON_INCLUDE_DIR
#              # shellcheck disable=SC2086
#              personality_enqueue_module ${module} ${special} \
#              -Pnative -Drequire.snappy  \
#              -Drequire.openssl \
#                -Dopenssl.prefix=/usr/local/opt/openssl/ \
#                -Dopenssl.include=/usr/local/opt/openssl/include \
#                -Dopenssl.lib=/usr/local/opt/openssl/lib \
#              -Drequire.libwebhdfs -Drequire.test.libhadoop
#            ;;
#            *)
#              # shellcheck disable=SC2086
#              personality_enqueue_module ${module} ${special} \
#                -Pnative \
#                -Drequire.snappy -Drequire.openssl \
#                -Drequire.libwebhdfs -Drequire.test.libhadoop
#            ;;
#          esac
#        ;;
#        hadoop-common-project|hadoop-common-project/hadoop-common)
#          case ${OSTYPE} in
#            Linux)
#              # shellcheck disable=SC2086
#              personality_enqueue_module ${module} ${special} \
#                -Pnative -Drequire.snappy \
#                -Drequire.openssl -Drequire.test.libhadoop
#            ;;
#            Darwin)
#              # shellcheck disable=SC2086
#              personality_enqueue_module ${module} ${special} \
#                -Pnative -Drequire.snappy  \
#                -Drequire.openssl \
#                  -Dopenssl.prefix=/usr/local/opt/openssl/ \
#                  -Dopenssl.include=/usr/local/opt/openssl/include \
#                  -Dopenssl.lib=/usr/local/opt/openssl/lib \
#                -Drequire.test.libhadoop
#            ;;
#            *)
#              # shellcheck disable=SC2086
#              personality_enqueue_module ${module} ${special} \
#                -Pnative -Drequire.snappy \
#                -Drequire.openssl -Drequire.libwebhdfs \
#                -Drequire.test.libhadoop
#            ;;
#          esac
#        ;;
#        hadoop-hdfs-project|hadoop-hdfs-project/hadoop-hdfs)
#        case ${OSTYPE} in
#          Linux)
#            # shellcheck disable=SC2086
#            personality_enqueue_module ${module} ${special} \
#              -Pnative -Drequire.fuse \
#              -Drequire.test.libhadoop
#            ;;
#            Darwin)
#              JANSSON_INCLUDE_DIR=/usr/local/opt/jansson/include
#              JANSSON_LIBRARY=/usr/local/opt/jansson/lib
#              export JANSSON_LIBRARY JANSSON_INCLUDE_DIR
#              # shellcheck disable=SC2086
#              personality_enqueue_module ${module} ${special} \
#                -Pnative -Drequire.libwebhdfs \
#                -Drequire.test.libhadoop
#            ;;
#            *)
#              # shellcheck disable=SC2086
#              personality_enqueue_module ${module} ${special} \
#                -Pnative -Drequire.libwebhdfs \
#                -Drequire.test.libhadoop
#            ;;
#          esac
#        ;;
#        hadoop-yarn-project|hadoop-yarn-project/hadoop-yarn|hadoop-yarn-project/hadoop-yarn/hadoop-yarn-server|hadoop-yarn-project/hadoop-yarn/hadoop-yarn-server/hadoop-yarn-server-nodemanager)
#          # shellcheck disable=SC2086
#          personality_enqueue_module ${module} ${special} \
#            -Pnative -Drequire.test.libhadoop
#        ;;
#        hadoop-mapreduce-project|hadoop-mapreduce-project/hadoop-mapreduce-client|hadoop-mapreduce-project/hadoop-mapreduce-client/hadoop-mapreduce-client-nativetask)
#          # shellcheck disable=SC2086
#          personality_enqueue_module ${module} ${special} \
#            -Pnative -Drequire.test.libhadoop
#        ;;
#        hadoop-tools|hadoop-tools/hadoop-pipes)
#          # shellcheck disable=SC2086
#          personality_enqueue_module ${module} ${special} \
#            -Pnative -Drequire.test.libhadoop
#        ;;
#        *)
#          # shellcheck disable=SC2086
#          personality_enqueue_module ${module} ${special}
#        ;;
#      esac
#  done
#}
#
#function personality_modules
#{
#  local repostatus=$1
#  local testtype=$2
#  local extra=""
#  local fn
#  local i
#
#  testudine_debug "Personality: ${repostatus} ${testtype}"
#
#  clear_personality_queue
#
#  case ${testtype} in
#    javac)
#      if [[ ${BUILD_NATIVE} == true ]]; then
#        hadoop_javac_ordering -DskipTests
#        return
#      fi
#      extra="-DskipTests"
#      ;;
#    javadoc)
#      if [[ ${repostatus} == patch ]]; then
#        echo "javadoc pre-reqs:"
#        for i in  hadoop-project \
#          hadoop-common-project/hadoop-annotations; do
#            fn=$(module_file_fragment "${i}")
#            pushd "${BASEDIR}/${i}" >/dev/null
#            echo "cd ${i}"
#            echo_and_redirect "${PATCH_DIR}/maven-${fn}-install.txt" \
#              "${MVN}" "${MAVEN_ARGS[@]}" install
#            popd >/dev/null
#        done
#      fi
#      extra="-Pdocs -DskipTests"
#    ;;
#    mvninstall)
#      extra="-DskipTests"
#      # mvn install breaks in lots of modules for a variety of reasons
#      # if you do them per-module.  So just force it to be all of them.
#      # personality_enqueue_module . "-DskipTests"
#      return
#      ;;
#    releaseaudit)
#      # this is very fast and provides the full path if we do it from
#      # the root of the source
#      personality_enqueue_module .
#      return
#    ;;
#    unit)
#      if [[ ${TEST_PARALLEL} == "true" ]] ; then
#        extra="-Pparallel-tests"
#        if [[ -z ${TEST_THREADS:-} ]]; then
#          extra="${extra} -DtestsThreadCount=${TEST_THREADS}"
#        fi
#      fi
#      if [[ ${BUILD_NATIVE} == true ]]; then
#        # shellcheck disable=SC2086
#        hadoop_javac_ordering ${extra}
#        return
#      fi
#    ;;
#    *)
#      extra="-DskipTests"
#    ;;
#  esac
#
#  hadoop_module_manipulation
#  for module in ${HADOOP_MODULES}; do
#    # shellcheck disable=SC2086
#    personality_enqueue_module ${module} ${extra}
#  done
#}
#
#function personality_file_tests
#{
#  local filename=$1
#
#  if [[ ${filename} =~ src/main/webapp ]]; then
#    testudine_debug "tests/webapp: ${filename}"
#  elif [[ ${filename} =~ \.sh
#       || ${filename} =~ \.cmd
#       ]]; then
#    testudine_debug "tests/shell: ${filename}"
#  elif [[ ${filename} =~ \.md$
#       || ${filename} =~ \.md\.vm$
#       || ${filename} =~ src/site
#       || ${filename} =~ src/main/docs
#       ]]; then
#    testudine_debug "tests/site: ${filename}"
#    add_test site
#  elif [[ ${filename} =~ \.c$
#       || ${filename} =~ \.cc$
#       || ${filename} =~ \.h$
#       || ${filename} =~ \.hh$
#       || ${filename} =~ \.proto$
#       || ${filename} =~ src/test
#       || ${filename} =~ \.cmake$
#       || ${filename} =~ CMakeLists.txt
#       ]]; then
#    testudine_debug "tests/units: ${filename}"
#    add_test javac
#    add_test mvninstall
#    add_test unit
#  elif [[ ${filename} =~ pom.xml$
#       || ${filename} =~ \.java$
#       || ${filename} =~ src/main
#       ]]; then
#    if [[ ${filename} =~ src/main/bin
#       || ${filename} =~ src/main/sbin ]]; then
#      testudine_debug "tests/shell: ${filename}"
#    else
#      testudine_debug "tests/javadoc+units: ${filename}"
#      add_test javac
#      add_test javadoc
#      add_test mvninstall
#      add_test unit
#    fi
#  fi
#
#  if [[ ${filename} =~ \.java$ ]]; then
#    add_test findbugs
#  fi
#}