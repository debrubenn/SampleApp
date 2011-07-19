#import <UIKit/UIKit.h>

@class AudioChunkStreamer;

@interface SampleAppViewController : UIViewController {
    IBOutlet UIButton *playButton;
    IBOutlet UIActivityIndicatorView *activityIndicator;
    IBOutlet UILabel *streamerStatus;
    AudioChunkStreamer *streamer;
}
- (IBAction)playButtonPressed:(id)sender;

@end
