#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <dlfcn.h>
#include "MisoSystem.h"

int miso_security_probe(void) {
    @autoreleasepool {
        void *webdriver = dlopen("/System/Library/PrivateFrameworks/WebDriver.framework/WebDriver", RTLD_NOW);
        if (!webdriver) return 2;
        Class driver = NSClassFromString(@"WDSafariDriver");
        NSDictionary *selectors = @{
            @"authenticate-webdeveloper": @"dictionaryForAuthenticateWebDeveloperRight",
            @"is-webdeveloper": @"dictionaryForIsWebDeveloperRight",
            @"com.apple.safaridriver.allow": @"dictionaryForSafariDriverAllowRight"
        };
        NSMutableDictionary *rights = [NSMutableDictionary dictionary];
        for (NSString *key in selectors) {
            SEL selector = NSSelectorFromString(selectors[key]);
            if (![driver respondsToSelector:selector]) return 3;
            id value = ((id (*)(id, SEL))objc_msgSend)(driver, selector);
            if (![value isKindOfClass:[NSDictionary class]]) return 4;
            rights[key] = value;
        }
        void *shared = dlopen("/System/Library/PrivateFrameworks/SafariShared.framework/SafariShared", RTLD_NOW);
        if (!shared) return 5;
        bool (*allowed)(void) = dlsym(shared, "_Z21allowRemoteAutomationv");
        if (!allowed) return 6;
        void *automation = dlopen("/System/Library/PrivateFrameworks/AutomationMode.framework/AutomationMode", RTLD_NOW);
        if (!automation) return 7;
        NSString *(*cookie)(void) = dlsym(automation, "XAMAutomationModeDoesNotRequireAuthenticationFilePath");
        if (!cookie || !cookie()) return 8;
        NSDictionary *result = @{
            @"rights": rights, @"safari_remote_automation": @(allowed()),
            @"home": NSHomeDirectory(), @"automation_cookie_path": cookie()
        };
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        if (!data || fwrite(data.bytes, 1, data.length, stdout) != data.length) return 9;
        return 0;
    }
}
