//
//  SampleAppAppDelegate.h
//  SampleApp
//
//  Created by User on 19.07.11.
//  Copyright 2011 __MyCompanyName__. All rights reserved.
//

#import <UIKit/UIKit.h>

@class SampleAppViewController;

@interface SampleAppAppDelegate : NSObject <UIApplicationDelegate> {

}

@property (nonatomic, retain) IBOutlet UIWindow *window;

@property (nonatomic, retain) IBOutlet SampleAppViewController *viewController;

@end
