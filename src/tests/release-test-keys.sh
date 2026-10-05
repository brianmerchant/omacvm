# Throwaway release keys for tests (sourced; never the real keys): T must be
# a temporary folder, R the checkout. Sets OMACVM_RELEASE_TEST_KEYS (the main
# and the spare test key, as src/lib ships two) and OMACVM_SETTINGS_DIR (kept
# documents land in T, not in ~/Library). sign_doc FILE [KEY]: FILE.sig with
# test-key, or KEY (spare-key, stranger-key).
swiftc -O -o "$T/sign" "$R/src/release/sign.swift" 2>/dev/null || { echo "FAIL swiftc src/release/sign.swift"; exit 1; }
for k in test-key spare-key stranger-key; do "$T/sign" keygen "$T/$k" > "$T/$k.pub"; done
OMACVM_RELEASE_TEST_KEYS="$(cat "$T/test-key.pub") $(cat "$T/spare-key.pub")"
OMACVM_SETTINGS_DIR=$T/settings
export OMACVM_RELEASE_TEST_KEYS OMACVM_SETTINGS_DIR
sign_doc() { "$T/sign" sign "$T/${2:-test-key}" "$1" > "$1.sig"; }
