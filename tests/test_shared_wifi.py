"""Exercise actual Wi-Fi mode persistence and interface-selection code on macOS."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
app = (root / 'source/Showcase.m').read_text()
service = (root / 'source/carplay_services.m').read_text()
mode = app[app.index('static BOOL showcase_use_existing_wifi(void)'):app.index('/* Returns the network that was left')]
model = app[app.index('@interface Car : NSObject'):app.index('/* ═══════════════════════════════════════════════════════════════\n * VideoView')]

objc = r'''
#import <Foundation/Foundation.h>
#import <assert.h>
#define SHARED_WIFI_KEY @"useExistingWiFi"
#define UI_USER_INTERFACE_IDIOM() 1
#define UIUserInterfaceIdiomPad 1
#define L(x) (x)
#define ip_log(...) ((void)0)
@interface MockDefaults : NSObject
@property(nonatomic,strong) NSMutableDictionary *store;
+ (instancetype)standardUserDefaults;
- (id)objectForKey:(NSString *)key;
- (NSString *)stringForKey:(NSString *)key;
- (NSArray *)arrayForKey:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key;
- (void)setObject:(id)value forKey:(NSString *)key;
- (void)setBool:(BOOL)value forKey:(NSString *)key;
- (BOOL)synchronize;
@end
@implementation MockDefaults
+ (instancetype)standardUserDefaults { static MockDefaults *d; static dispatch_once_t once; dispatch_once(&once, ^{d=[MockDefaults new];d.store=[NSMutableDictionary new];}); return d; }
- (id)objectForKey:(NSString *)key { return self.store[key]; }
- (NSString *)stringForKey:(NSString *)key { return self.store[key]; }
- (NSArray *)arrayForKey:(NSString *)key { return self.store[key]; }
- (BOOL)boolForKey:(NSString *)key { return [self.store[key] boolValue]; }
- (void)setObject:(id)value forKey:(NSString *)key { self.store[key]=value; }
- (void)setBool:(BOOL)value forKey:(NSString *)key { self.store[key]=@(value); }
- (BOOL)synchronize { return YES; }
@end
#define NSUserDefaults MockDefaults
''' + mode + '\n' + model + r'''
int main(void) { @autoreleasepool {
    MockDefaults *d=[MockDefaults standardUserDefaults];
    [d setObject:@"Router A" forKey:@"apSSID"];
    [d setObject:@"router-pass" forKey:@"apPassword"];
    CarStore *store=[CarStore new];
    assert(showcase_use_existing_wifi());
    assert([store.apSSID isEqualToString:@"Router A"]);
    assert(validateNetworkSSID(@"abc") == nil);
    assert(validateNetworkSSID(@"") != nil);
    assert(validateNetworkPassword(@"1234567") != nil);
    assert(validateNetworkPassword(@"12345678") == nil);
    [store selectExistingWiFi:NO];
    assert(!showcase_use_existing_wifi());
    assert([store.apSSID isEqualToString:@"Router A"]);
    assert([store.apPassword isEqualToString:@"router-pass"]);
    assert(validateNetworkSSID(@"abc") != nil);
    [store setAPSSID:@"Hotspot A" password:@"hotspot-pass"];
    [store selectExistingWiFi:YES];
    assert([store.apSSID isEqualToString:@"Router A"]);
    assert([store.apPassword isEqualToString:@"router-pass"]);
    [store setAPSSID:@"Router B" password:@"new-router-pass"];
    [store selectExistingWiFi:NO];
    assert([store.apSSID isEqualToString:@"Hotspot A"]);
    CarStore *restored=[CarStore new];
    assert([restored.apPassword isEqualToString:@"hotspot-pass"]);
    [restored selectExistingWiFi:YES];
    assert([restored.apSSID isEqualToString:@"Router B"]);
    assert([restored.apPassword isEqualToString:@"new-router-pass"]);
    assert(validateNetworkPassword([@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0]) != nil);
    assert(validateNetworkSSID([@"a" stringByPaddingToLength:33 withString:@"a" startingAtIndex:0]) != nil);
    [d.store removeAllObjects];
    CarStore *fresh=[CarStore new];
    assert(showcase_use_existing_wifi() && ![fresh apReady]);
    [fresh selectExistingWiFi:NO];
    assert(!showcase_use_existing_wifi() && ![fresh apReady]);
    [fresh selectExistingWiFi:YES];
    assert(showcase_use_existing_wifi() && ![fresh apReady]);
    puts("PASS: explicit Wi-Fi modes, legacy migration, separate credentials, restart");
} return 0; }
'''

function = service[service.index('static uint32_t wifi_ipv4_addr(void)'):service.index('static void local_mdns_target_name')]
c = r'''
#include <arpa/inet.h>
#include <sys/socket.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <stdbool.h>
#include <string.h>
#include <assert.h>
#include <stdio.h>
static bool g_shared_wifi;
static char g_wifi_interface[IFNAMSIZ];
static struct ifaddrs *fixture;
static int fake_getifaddrs(struct ifaddrs **out) { *out=fixture; return 0; }
static void fake_freeifaddrs(struct ifaddrs *p) { (void)p; }
#define getifaddrs fake_getifaddrs
#define freeifaddrs fake_freeifaddrs
''' + function + r'''
int main(void) {
    struct sockaddr_in a={0}, b={0}; a.sin_family=b.sin_family=AF_INET;
    inet_pton(AF_INET,"172.20.10.1",&a.sin_addr);
    inet_pton(AF_INET,"192.168.8.2",&b.sin_addr);
    struct ifaddrs lan={0}, ap={0};
    ap.ifa_name="bridge100"; ap.ifa_flags=IFF_UP; ap.ifa_addr=(void *)&a; ap.ifa_next=&lan;
    lan.ifa_name="en0"; lan.ifa_flags=IFF_UP; lan.ifa_addr=(void *)&b; fixture=&ap;
    g_shared_wifi=true; strcpy(g_wifi_interface,"en0");
    assert(wifi_ipv4_addr()==b.sin_addr.s_addr);
    lan.ifa_flags=0; assert(wifi_ipv4_addr()==INADDR_ANY);
    strcpy(g_wifi_interface,"en1"); assert(wifi_ipv4_addr()==INADDR_ANY);
    g_shared_wifi=false; strcpy(g_wifi_interface,"bridge100");
    assert(wifi_ipv4_addr()==a.sin_addr.s_addr);
    puts("PASS: mDNS address follows selected interface and never falls back to hotspot in shared mode");
}
'''
with tempfile.TemporaryDirectory(prefix='showcase-wifi-test-') as tmp:
    tmp = Path(tmp)
    (tmp / 'mode.m').write_text(objc)
    subprocess.run(['clang', '-fobjc-arc', '-framework', 'Foundation', str(tmp/'mode.m'), '-o', str(tmp/'mode')], check=True)
    subprocess.run([str(tmp/'mode')], check=True)
    (tmp/'address.c').write_text(c)
    subprocess.run(['clang', str(tmp/'address.c'), '-o', str(tmp/'address')], check=True)
    subprocess.run([str(tmp/'address')], check=True)
