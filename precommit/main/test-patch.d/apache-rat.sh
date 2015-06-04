
add_plugin asflicense

function asflicense_filefilter
{
  local filename=$1

  add_test asflicense
}

## @description  Verify all files have an Apache License
## @audience     private
## @stability    evolving
## @replaceable  no
## @return       0 on success
## @return       1 on failure
function asflicense_postapply
{
  local numpatch

  big_console_header "Determining number of patched ASF License errors"

  start_clock

  personality_modules patch asflicense
  modules_workers patch asflicense apache-rat:check

  if [[ $? != 0 ]]; then
    add_vote_table -1 asflicense "apache-rat:check failed"
    return 1
  fi

  #shellcheck disable=SC2038
  find "${BASEDIR}" -name rat.txt | xargs cat > "${PATCH_DIR}/patch-asflicense.txt"

  if [[ -f "${PATCH_DIR}/patch-asflicense.txt" ]] ; then
    numpatch=$("${GREP}" -c '\!?????' "${PATCH_DIR}/patch-asflicense.txt")
    echo ""
    echo ""
    echo "There appear to be ${numpatch} ASF License warnings after applying the patch."
    if [[ -n ${numpatch}
       && ${numpatch} -gt 0 ]] ; then
      add_vote_table -1 asflicense "Patch generated ${numpatch} ASF License warnings."

      echo "Lines that start with ????? in the ASF License "\
          "report indicate files that do not have an Apache license header:" \
            > "${PATCH_DIR}/patch-asflicense-problems.txt"

      ${GREP} '\!?????' "${PATCH_DIR}/patch-asflicense.txt" \
      >>  "${PATCH_DIR}/patch-asflicense-problems.txt"

      add_footer_table asflicense "@@BASE@@/patch-asflicense-problems.txt"

      return 1
    fi
  fi
  add_vote_table 1 asflicense "Patch does not generate ASF License warnings."
  return 0
}
