#!/bin/bash
# Invoked only by the hosted test wrapper. Best-effort evidence must not mask test status.
set -u
cd "$(dirname "$0")/.."
mode="${1:?sample or collect}"
case "$mode" in
  sample)
    while :; do
      {
        printf '\n=== %s ===\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        df -h . /tmp
        vm_stat
        sysctl vm.swapusage
        # Include the test host and its driver, plus the largest resident processes.
        ps -axo pid,ppid,rss,vsz,stat,comm | sort -k3,3nr | head -n 35
        ps -axo pid,ppid,rss,vsz,stat,command | grep -E '[x]ctest|[s]wift-testing|[s]wift test|[s]wift-test' || true
      } >> build/ci/test-resources.txt 2>&1
      sleep 5
    done
    ;;
  collect)
    {
      echo '=== Swift test evidence ==='
      echo "Test command status: ${2:-unknown}"
      echo '=== Final resource sample ==='
      df -h . /tmp
      vm_stat
      sysctl vm.swapusage
      echo '=== Resource samples ==='
      cat build/ci/test-resources.txt 2>/dev/null || true
      echo '=== build/ci files ==='
      find build/ci -type f -exec ls -lh {} \; 2>/dev/null || true
      echo '=== Other build/ci file contents (up to 200 KB each) ==='
      find build/ci -type f ! -name 'test-evidence.txt' ! -name 'test-resources.txt' ! -name 'tests.txt' -print | while IFS= read -r item; do
        printf '\n--- %s ---\n' "$item"
        head -c 200000 "$item" || true
        echo
      done
      echo '=== Test result bundles and XML ==='
      find .build build -type d -name '*.xcresult' -print -prune -o -type f \( -name '*.xunit' -o -name '*.xml' \) -print 2>/dev/null || true
      find .build build -type f \( -name '*.xunit' -o -name '*.xml' \) -print 2>/dev/null | while IFS= read -r result; do
        printf '\n--- %s ---\n' "$result"
        cat "$result" || true
      done
      find .build build -type d -name '*.xcresult' -print -prune 2>/dev/null | while IFS= read -r result; do
        printf '\n--- xcresult summary: %s ---\n' "$result"
        xcrun xcresulttool get test-results summary --path "$result" 2>&1 || true
      done
      echo '=== Tail of Swift test log ==='
      tail -n 100 build/ci/tests.txt 2>/dev/null || true
      echo '=== New DiagnosticReports since test start ==='
      for dir in "$HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports; do
        if [[ -d "$dir" ]]; then
          find "$dir" -type f -newer build/ci/test-start -print | while IFS= read -r report; do
            printf '\n--- %s ---\n' "$report"
            cat "$report" || true
          done
        fi
      done
      echo '=== End evidence ==='
    } > build/ci/test-evidence.txt 2>&1
    cat build/ci/test-evidence.txt
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      {
        echo '### Swift test failure evidence'
        echo 'The full Swift test output and evidence are in the job log. Resource samples and diagnostic reports follow (limited to 800 KB).'
        echo '<details><summary>Evidence</summary>'
        echo
        echo '```text'
        head -c 350000 build/ci/test-evidence.txt
        echo
        echo '--- End of evidence (middle omitted if large) ---'
        tail -c 450000 build/ci/test-evidence.txt
        echo
        echo '```'
        echo '</details>'
      } >> "$GITHUB_STEP_SUMMARY"
    fi
    ;;
  *) exit 2 ;;
esac
