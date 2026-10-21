"""scripts/check_licenses.py must accept permissive licenses and reject copyleft ones (docs/adr/0001)."""
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "check_licenses", Path(__file__).resolve().parents[2] / "scripts" / "check_licenses.py")
cl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cl)


def test_permissive_expressions_pass():
    for expr in ("MIT", "MIT OR Apache-2.0", "Apache-2.0 WITH LLVM-exception", "(MIT OR Apache-2.0) AND Unicode-3.0",
                 "MIT/Apache-2.0", "BSD-3-Clause", "ISC", "Zlib", "Unlicense OR MIT", "MPL-2.0", "Apache-2.0+"):
        assert cl.allowed(expr), expr


def test_copyleft_is_rejected():
    for expr in ("GPL-3.0-only", "GPL-2.0-or-later", "AGPL-3.0", "LGPL-2.1-or-later", "MIT AND GPL-3.0-only",
                 "GPL-3.0-only OR LGPL-3.0-only", "CC-BY-NC-4.0", "", "SSPL-1.0"):
        assert not cl.allowed(expr), expr


def test_one_permissive_alternative_is_enough_for_or():
    assert cl.allowed("GPL-3.0-only OR MIT")
    assert not cl.allowed("GPL-3.0-only AND MIT")
