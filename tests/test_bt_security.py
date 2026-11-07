"""Compile the real argument and iAP2 frame code into small native harnesses."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'source/carplay_bt.m').read_text()


class BluetoothSecurityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='showcase-bt-security-')
        root = Path(cls.tmp.name)
        args_code = SOURCE[SOURCE.index('static char kDeviceName'):SOURCE.index('/* ══════════════════════════════════════════════════\n *  AirPlay receiver identity')]
        args_code = args_code[0:args_code.index('static const uint8_t kWifiSecurityType')] + '\n' + args_code[args_code.index('static int parse_args'):]
        (root/'args.c').write_text('#include <stdio.h>\n#include <string.h>\n#include <unistd.h>\n#include <errno.h>\n' + args_code + r'''
int main(int argc, char **argv) {
    if (parse_args(argc, argv)) return 2;
    printf("%s\n%zu\n", kWifiSSID, strlen(kWifiPassword));
    return 0;
}
''')
        subprocess.run(['clang', '-fsanitize=address,undefined', str(root/'args.c'), '-o', str(root/'args')], check=True)
        frame_code = SOURCE[SOURCE.index('static uint8_t iap2_rx[65535]'):SOURCE.index('static void handler(uint8_t type')]
        params_code = SOURCE[SOURCE.index('static bool valid_control_params'):SOURCE.index('static void handle_ctrl_msg')]
        (root/'frame.c').write_text(r'''
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <assert.h>
static uint8_t iap2_detect[]={0xff,0x55,0x02,0x00,0xee,0x10};
static int iap2_detected,link_established, delivered, sent;
static uint8_t my_initial_psn,my_next_psn,peer_psn;
static uint8_t ck(uint8_t *d,int l) { uint8_t sum=0; for(int i=0;i<l;i++) sum+=d[i]; return (uint8_t)(0-sum); }
static void send_syn(void){} static void send_ack(void){sent++;}
static void reset_wireless_handoff_state(void){}
static void handle_ctrl_msg(uint16_t id,uint8_t *p,int n){(void)p;(void)n;assert(id==0x5702);delivered++;}
''' + params_code + frame_code + r'''
int main(void) {
    uint8_t valid[]={0,5,0,0,42}, invalid[]={0,6,0,0,42};
    assert(valid_control_params(valid,5)); assert(!valid_control_params(invalid,5));
    assert(!valid_control_params(valid,3));
    uint8_t frame[]={0xff,0x5a,0,16,0x40,1,1,1,0,0x40,0x40,0,6,0x57,0x02,0};
    frame[8]=ck(frame,8); frame[15]=ck(frame+9,6); link_established=1;
    receive_iap2(frame,3); assert(delivered==0);
    receive_iap2(frame+3,13); assert(delivered==1);
    uint8_t pair[32]; memcpy(pair,frame,16); memcpy(pair+16,frame,16);
    receive_iap2(pair,32); assert(delivered==3);
    frame[12]=50; frame[15]=ck(frame+9,6);
    receive_iap2(frame,16); assert(delivered==3);
    frame[12]=6; frame[15]=0; receive_iap2(frame,16); assert(delivered==3);
    return 0;
}
''')
        subprocess.run(['clang', '-fsanitize=address,undefined', str(root/'frame.c'), '-o', str(root/'frame')], check=True)
        cls.args, cls.frame = root/'args', root/'frame'

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_args(self, args, data=b''):
        return subprocess.run([str(self.args), *args], input=data, capture_output=True)

    def test_stdin_password_and_legacy(self):
        for password in (b'12345678', b'x'*63):
            p = self.run_args(['--ssid', 'router', '--pass-stdin', 'ignored'], password)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(p.stdout, b'router\n%d\n' % len(password))
        self.assertEqual(self.run_args(['--ssid', 'router', '--pass', 'legacy']).returncode, 0)

    def test_invalid_credentials_fail_closed(self):
        for password in (b'', b'x'*64, b'ab\0cd'):
            self.assertNotEqual(self.run_args(['--ssid', 'router', '--pass-stdin', 'ignored'], password).returncode, 0)
        for args in ([], ['--ssid', 'router'], ['--pass', '12345678'],
                     ['--ssid', 'router', '--pass-stdin'],
                     ['--ssid', 'router', '--pass', 'x'*64]):
            self.assertNotEqual(self.run_args(args).returncode, 0)

    def test_fragmented_coalesced_and_invalid_frames(self):
        subprocess.run([str(self.frame)], check=True)


if __name__ == '__main__':
    unittest.main()
