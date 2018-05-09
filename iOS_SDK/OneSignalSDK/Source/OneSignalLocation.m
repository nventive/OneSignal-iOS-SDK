/**
 * Modified MIT License
 *
 * Copyright 2016 OneSignal
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * 1. The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * 2. All copies of substantial portions of the Software may only be used in connection
 * with services provided by OneSignal.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

#import <UIKit/UIKit.h>

#import "OneSignalLocation.h"
#import "OneSignalHelper.h"
#import "OneSignal.h"
#import "OneSignalClient.h"
#import "Requests.h"

@interface OneSignal ()
void onesignal_Log(ONE_S_LOG_LEVEL logLevel, NSString* message);
+ (NSString *)mEmailUserId;
+ (NSString*)mUserId;
+ (NSString *)mEmailAuthToken;
@end

@implementation OneSignalLocation

os_last_location *lastLocation;
bool initialLocationSent = false;
UIBackgroundTaskIdentifier fcTask;

static id locationManager = nil;
static id significantLocationManager = nil;
static bool started = false;
static bool hasDelayed = false;

// CoreLocation must be statically linked for geotagging to work on iOS 6 and possibly 7.
// plist NSLocationUsageDescription (iOS 6 & 7) and NSLocationWhenInUseUsageDescription (iOS 8+) keys also required.

// Suppressing undeclared selector warnings
// NSClassFromString and performSelector are used so OneSignal does not depend on CoreLocation to link the app.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wundeclared-selector"
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"


NSObject *_mutexObjectForLastLocation;
+(NSObject*)mutexObjectForLastLocation {
    if (!_mutexObjectForLastLocation)
        _mutexObjectForLastLocation = [NSObject alloc];
    return _mutexObjectForLastLocation;
}

static OneSignalLocation* singleInstance = nil;
+(OneSignalLocation*) sharedInstance {
    @synchronized( singleInstance ) {
        if( !singleInstance ) {
            singleInstance = [[OneSignalLocation alloc] init];
        }
    }
    
    return singleInstance;
}

+ (os_last_location*)lastLocation {
    return lastLocation;
}
+ (void)clearLastLocation {
    @synchronized(OneSignalLocation.mutexObjectForLastLocation) {
        lastLocation = nil;
    }
}

+ (void) getLocation:(bool)prompt {
    if (hasDelayed)
        [OneSignalLocation internalGetLocation:prompt];
    else {
        // Delay required for locationServicesEnabled and authorizationStatus return the correct values when CoreLocation is not statically linked.
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, 2.0 * NSEC_PER_SEC);
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void) {
            hasDelayed = true;
            [OneSignalLocation internalGetLocation:prompt];
        });
    }
    
    //Listen to app going to and from background
}

+ (void) beginTask {
    fcTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        [OneSignalLocation endTask];
    }];
}

+ (void) endTask {
    [[UIApplication sharedApplication] endBackgroundTask: fcTask];
    fcTask = UIBackgroundTaskInvalid;
}

+ (void) internalGetLocation:(bool)prompt {
    if (started)
        return;
    
    id clLocationManagerClass = NSClassFromString(@"CLLocationManager");
    
    // Check for location in plist
    if (![clLocationManagerClass performSelector:@selector(locationServicesEnabled)])
        return;
    
    if ([clLocationManagerClass performSelector:@selector(authorizationStatus)] == 0 && !prompt)
        return;
    
    locationManager = [[clLocationManagerClass alloc] init];
    [locationManager setValue:[self sharedInstance] forKey:@"delegate"];
    [locationManager setValue:@"kCLLocationAccuracyNearestTenMeter" forKey:@"desiredAccuracy"];
    [locationManager setValue:@YES forKey:@"pausesLocationUpdatesAutomatically"];
    [locationManager setValue:@100 forKey:@"distanceFilter"];
    
    significantLocationManager = [[clLocationManagerClass alloc] init];
    [significantLocationManager setValue:[self sharedInstance] forKey:@"delegate"];
    
    float deviceOSVersion = [[[UIDevice currentDevice] systemVersion] floatValue];
    if (deviceOSVersion >= 8.0) {
        
        //Check info plist for request descriptions
        //LocationAlways > LocationWhenInUse > No entry (Log error)
        //Location Always requires: Location Background Mode + NSLocationAlwaysUsageDescription
        NSArray* backgroundModes = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"UIBackgroundModes"];
        NSString* alwaysDescription = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSLocationAlwaysUsageDescription"] ?: [[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSLocationAlwaysAndWhenInUseUsageDescription"];
        if(backgroundModes && [backgroundModes containsObject:@"location"] && alwaysDescription) {
            [locationManager performSelector:@selector(requestAlwaysAuthorization)];
            [significantLocationManager performSelector:@selector(requestAlwaysAuthorization)];
            if (deviceOSVersion >= 9.0) {
                [locationManager setValue:@YES forKey:@"allowsBackgroundLocationUpdates"];
                [significantLocationManager setValue:@YES forKey:@"allowsBackgroundLocationUpdates"];
            }
        }
        
        else if([[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSLocationWhenInUseUsageDescription"]) {
            [locationManager performSelector:@selector(requestWhenInUseAuthorization)];
            [significantLocationManager performSelector:@selector(requestWhenInUseAuthorization)];
        }
        
        else onesignal_Log(ONE_S_LL_ERROR, @"Include a privacy NSLocationAlwaysUsageDescription or NSLocationWhenInUseUsageDescription in your info.plist to request location permissions.");
    }
    
    // iOS 6 and 7 prompts for location here.
    [locationManager performSelector:@selector(startUpdatingLocation)];
    
    // Enable significant location changes monitoring to relaunch the app if swipped up when receiving a new location
    [significantLocationManager performSelector:@selector(startMonitoringSignificantLocationChanges)];
    
    started = true;
}

#pragma mark CLLocationManagerDelegate

- (void)locationManager:(id)manager didUpdateLocations:(NSArray *)locations {
    
    // return if the user has not granted privacy permissions
    if ([OneSignal requiresUserPrivacyConsent])
        return;
    
    id location = locations.lastObject;
    
    SEL cord_selector = NSSelectorFromString(@"coordinate");
    os_location_coordinate cords;
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[[location class] instanceMethodSignatureForSelector:cord_selector]];
    
    [invocation setTarget:locations.lastObject];
    [invocation setSelector:cord_selector];
    [invocation invoke];
    [invocation getReturnValue:&cords];
    
    NSLog(@"OneSignal - New location: %f, %f", cords.latitude, cords.longitude);
    
    @synchronized(OneSignalLocation.mutexObjectForLastLocation) {
        if (!lastLocation)
            lastLocation = (os_last_location*)malloc(sizeof(os_last_location));
        
        lastLocation->verticalAccuracy = [[location valueForKey:@"verticalAccuracy"] doubleValue];
        lastLocation->horizontalAccuracy = [[location valueForKey:@"horizontalAccuracy"] doubleValue];
        lastLocation->cords = cords;
    }
    
    [OneSignalLocation sendLocation];
}

-(void)locationManager:(id)manager didFailWithError:(NSError *)error {
    [OneSignal onesignal_Log:ONE_S_LL_ERROR message:[NSString stringWithFormat:@"CLLocationManager did fail with error: %@", error]];
}

+ (void)sendLocation {
    
    // return if the user has not granted privacy permissions
    if ([OneSignal requiresUserPrivacyConsent])
        return;
    
    @synchronized(OneSignalLocation.mutexObjectForLastLocation) {
        if (!lastLocation || ![OneSignal mUserId]) return;
        
        initialLocationSent = YES;
        
        NSMutableDictionary *requests = [NSMutableDictionary new];
        
        if ([OneSignal mEmailUserId])
            requests[@"email"] = [OSRequestSendLocation withUserId:[OneSignal mEmailUserId] appId:[OneSignal app_id] location:lastLocation networkType:[OneSignalHelper getNetType] backgroundState:([UIApplication sharedApplication].applicationState != UIApplicationStateActive) emailAuthHashToken:[OneSignal mEmailAuthToken]];
        
        requests[@"push"] = [OSRequestSendLocation withUserId:[OneSignal mUserId] appId:[OneSignal app_id] location:lastLocation networkType:[OneSignalHelper getNetType] backgroundState:([UIApplication sharedApplication].applicationState != UIApplicationStateActive) emailAuthHashToken:nil];
        
        [OneSignalClient.sharedClient executeSimultaneousRequests:requests withSuccess:nil onFailure:nil];
    }
}


#pragma clang diagnostic pop
#pragma GCC diagnostic pop

@end
