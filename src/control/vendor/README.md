# Textual for the control centre

The VM's control centre (`omacvm`) runs on these wheels, not on pacman's
`python-textual`: a VM whose package list is older than the mirrors cannot
get that package (every file a 404), and OmacVM never updates the package
list alone. `../omacvm_cc/vendor.py` checks them against `SHA256SUMS` and
unpacks them once into the desktop user's `~/.cache/omacvm/python/`.

All of them are pure Python (`py3-none-any`), Python 3.10 or newer. Licences:
see THIRD_PARTY_NOTICES.md at the top of the repository.

To move to another Textual (CI tests the control centre with exactly these):

    python3 -m venv /tmp/v && /tmp/v/bin/pip download -d new "textual==X.Y.Z" \
      --only-binary=:all: --platform any --python-version 3.14 --implementation py
    # replace the *.whl here with new/*.whl, then:
    shasum -a 256 *.whl > SHA256SUMS
