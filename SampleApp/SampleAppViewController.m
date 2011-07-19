#import "SampleAppViewController.h"
#import "AudioChunkStreamer.h"

@implementation SampleAppViewController

- (void)setButtonImage:(UIImage *)image
{
    if (!image) {
        [playButton setImage:[UIImage imageNamed:@"play.png"]
                    forState:0];
    } else {
        [playButton setImage:image
                    forState:0];
    }
}

- (void)destroyStreamer
{
    if (streamer) {
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:ACSStatusChangedNotification
                                                      object:streamer];
        [streamer stopPlayback];
        [streamer release];
        streamer = nil;
    }
}

- (void)createStreamer
{
    if (streamer) {
        return;
    }
    [self destroyStreamer];
    streamer = [[AudioChunkStreamer alloc] init];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playbackStateChanged:)
                                                 name:ACSStatusChangedNotification
                                               object:streamer];
}

- (void)dealloc
{
    [self destroyStreamer];
    [playButton release];
    [activityIndicator release];
    [streamerStatus release];
    [super dealloc];
}

- (void)didReceiveMemoryWarning
{
    // Releases the view if it doesn't have a superview.
    [super didReceiveMemoryWarning];
    
    // Release any cached data, images, etc that aren't in use.
}

#pragma mark - View lifecycle

/*
 // Implement viewDidLoad to do additional setup after loading the view, typically from a nib.
 - (void)viewDidLoad
 {
 [super viewDidLoad];
 }
 */

- (void)viewDidUnload
{
    [playButton release];
    playButton = nil;
    [activityIndicator release];
    activityIndicator = nil;
    [streamerStatus release];
    streamerStatus = nil;
    [super viewDidUnload];
    // Release any retained subviews of the main view.
    // e.g. self.myOutlet = nil;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
    // Return YES for supported orientations
    return (interfaceOrientation == UIInterfaceOrientationPortrait);
}

- (IBAction)playButtonPressed:(id)sender
{
    if ([playButton.currentImage isEqual:[UIImage imageNamed:@"play.png"]]) {
        [self createStreamer];
        [self setButtonImage:[UIImage imageNamed:@"pause.png"]];
        [streamer startPlayback];
    } else {
        [streamer pausePlayback];
    }
}

- (void)playbackStateChanged:(NSNotification *)aNotification
{
    if ([streamer isWaiting]) {
        [activityIndicator startAnimating];
        streamerStatus.text = [NSString stringWithFormat:@"Playing chunk %u", streamer.currentChunk];
    } else {
        [activityIndicator stopAnimating];
        if ([streamer isPlaying]) {
            [self setButtonImage:[UIImage imageNamed:@"pause.png"]];
        } else if ([streamer isPaused]) {
            [self setButtonImage:[UIImage imageNamed:@"play.png"]];
        }
    }
}

@end
