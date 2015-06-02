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

cd "${BASEDIR}"

if [[ -n ${JAVA_HOME}
  && ! -d ${JAVA_HOME} ]]; then
  echo "JAVA_HOME: ${JAVA_HOME} does not exist. Dockermode: switching to another." 1>&2
  JAVA_HOME=""
fi

if [[ -z ${JAVA_HOME} ]]; then
  JAVA_HOME=$(find /usr/lib/jvm/ -name "java-*" -type d | tail -1)
  export JAVA_HOME
fi

# Avoid out of memory errors in builds
MAVEN_OPTS="-Xms256m -Xmx1g"
export MAVEN_OPTS

# strip out any --docker or --docker= params
TESTPATCHMODE=${TESTPATCHMODE/--docker }

if [[ ${TESTPATCHMODE} =~ reexec ]]; then
  tpbin="${PATCH_DIR}/precommit-test/test-patch.sh"
else
  tpbin="${BASEDIR}/precommit/test-patch.sh"
fi

"${tpbin}" \
   --dockermode ${TESTPATCHMODE} \
   --basedir="${BASEDIR}" \
   --patch-dir="${PATCH_DIR}" \
   --java-home="${JAVA_HOME}" \
   --jira-cmd=/opt/jiracli/jira-cli-2.2.0/jira.sh
