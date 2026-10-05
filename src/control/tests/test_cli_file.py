"""Only the installed checkout becomes the omacvm the Bridge runs
(cli_for_bridge in src/lib/mac.sh): never another clone or worktree that
happens to run src/mac/install.sh."""
from __future__ import annotations

import os
import subprocess

SRC = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def chosen(me: str, links: list, extra: dict | None = None) -> bool:
    env = {k: v for k, v in os.environ.items() if k != "OMACVM_SET_CLI"}
    env.update(OMACVM_CLI_LINKS=" ".join(links), **(extra or {}))
    r = subprocess.run(["bash", "-c", 'source "$1/lib/mac.sh"; cli_for_bridge "$2"', "_", SRC, me], env=env)
    return r.returncode == 0


def test_only_the_linked_checkout(tmp_path):
    real = os.path.realpath(tmp_path)
    for d in ("installed", "worktree"):
        os.makedirs(f"{real}/{d}")
        open(f"{real}/{d}/omacvm", "w").close()
    os.symlink(f"{real}/installed/omacvm", f"{real}/link")
    links = [f"{real}/missing", f"{real}/link"]
    assert chosen(f"{real}/installed/omacvm", links)
    assert not chosen(f"{real}/worktree/omacvm", links)
    assert chosen(f"{real}/worktree/omacvm", links, {"OMACVM_SET_CLI": "1"})
    # No omacvm command anywhere: a clone run as ./omacvm.
    assert chosen(f"{real}/worktree/omacvm", [f"{real}/missing"])
