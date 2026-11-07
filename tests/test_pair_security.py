"""Run the pairing regression harness against the real C implementation."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PairSecurityTests(unittest.TestCase):
    def test_pairing_regressions(self):
        with tempfile.TemporaryDirectory(prefix='showcase-pair-security-') as directory:
            binary = Path(directory) / 'pair-test'
            subprocess.run([
                'clang', '-O1', '-g', '-fsanitize=address,undefined',
                str(ROOT/'tests/test_pair_security.c'),
                str(ROOT/'source/vendor/monocypher/monocypher.c'),
                str(ROOT/'source/vendor/monocypher/monocypher-ed25519.c'),
                str(ROOT/'source/vendor/libtommath/tommath.c'),
                '-framework', 'Security', '-o', str(binary),
            ], check=True)
            for case in ('tlv', 'signature', 'state', 'valid', 'corrupt'):
                with self.subTest(case=case):
                    subprocess.run([str(binary), case], check=True)


if __name__ == '__main__':
    unittest.main()
