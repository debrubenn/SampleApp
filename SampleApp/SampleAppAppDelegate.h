#import <UIKit/UIKit.h>

@class SampleAppViewController;

@interface SampleAppAppDelegate : NSObject <UIApplicationDelegate> {

}

@property (nonatomic, retain) IBOutlet UIWindow *window;

@property (nonatomic, retain) IBOutlet SampleAppViewController *viewController;

@end
