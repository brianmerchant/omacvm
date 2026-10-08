# The LaunchAgent labels of OmacVM's Mac helpers (sourced; no other effects).
# launchd has one GUI session per user, whatever HOME says. So the production
# labels (org.omacvm.bridge, org.omacvm.gestures, org.omacvm.clip-in,
# ch.gillesgoetsch.omanotch) belong to the user's own HOME only. The test
# identity (OMACVM_TEST_IDENTITY=1) and any other HOME (a test run with
# HOME=<folder>) get org.omacvm.test.NAME: a test never replaces the user's own
# helpers (2026-10-08: a test run with its own HOME loaded its clipboard helper
# as org.omacvm.clip-in into the user's session). Test: src/tests/test-labels.sh
#   omacvm_label bridge|gestures|clip-in|omanotch
#   omacvm_test_home: true for the test identity or another HOME

omacvm_test_home() {
  [[ ${OMACVM_TEST_IDENTITY:-} == 1 ]] && return 0
  local own
  own=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
  [[ -n $own ]] || return 1   # not known: the user's own (as before)
  [[ $(cd "$HOME" 2>/dev/null && pwd -P) != "$(cd "$own" 2>/dev/null && pwd -P)" ]]
}

omacvm_label() {
  if omacvm_test_home; then echo "org.omacvm.test.$1"; return; fi
  case $1 in
    omanotch) echo ch.gillesgoetsch.omanotch ;;
    *) echo "org.omacvm.$1" ;;
  esac
}
