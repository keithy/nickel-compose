#!/usr/bin/env bash

# Alternative to `make check`
# Script for running all the executable scripts in the folder
# Success/Failure is reported

cd "${BASH_SOURCE[0]%/*}"

echo "Working Directory:" $(pwd)
#echo "Which bash" $(which bash)

fails=0
total_pass=0
total_fail=0
for test in [^_]*.sh;
do
   if [[ -x "$test" ]]; then
       echo ">$test"
       out=$(./"$test")
       [[ $? != 0 ]] && fails=$((fails + 1))
       # Per-spec summary: capture N PASSED / N FAILED from the spec's
       # --SUMMARY block so we can report counts in both silent and
       # verbose modes (without dumping the whole test output).
       spec_pass=$(printf '%s\n' "$out" | grep -E '^[0-9]+ PASSED' | tail -1 | awk '{print $1}')
       spec_fail=$(printf '%s\n' "$out" | grep -E '^[0-9]+ FAILED' | tail -1 | awk '{print $1}')
       [[ -n "$spec_pass" ]] && total_pass=$((total_pass + spec_pass))
       [[ -n "$spec_fail" ]] && total_fail=$((total_fail + spec_fail))
       if [[ -n "$spec_pass" && -n "$spec_fail" ]]; then
         printf '  %d PASSED, %d FAILED\n' "$spec_pass" "$spec_fail"
       fi
       # In verbose mode, also dump the spec's full output (including
       # per-assertion detail).
       if [[ "$1" == "-v" ]]; then
         echo "$out"
       fi
   fi
done

[[ $fails == 0 ]] && echo "Pass" || echo "Fails: $fails"
echo "Total: $total_pass PASSED, $total_fail FAILED"

exit $fails
