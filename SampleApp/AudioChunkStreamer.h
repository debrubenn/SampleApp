#import <UIKit/UIKit.h>

#include <pthread.h>
#include <AudioToolbox/AudioToolbox.h>

#define kNumAQBufs 16           // Number of audio queue buffers we allocate
#define kAQDefaultBufSize 2048  // Number of bytes in each audio queue buffer
#define kAQMaxPacketDescs 512   // Number of packet descriptions in our array

typedef enum {
    AS_INITIALIZED = 0,
    AS_STARTING_FILE_THREAD,
    AS_WAITING_FOR_DATA,
    AS_FLUSHING_EOF,
    AS_WAITING_FOR_QUEUE_TO_START,
    AS_PLAYING,
    AS_BUFFERING,
    AS_STOPPING,
    AS_STOPPED,
    AS_PAUSED
} AudioChunkStreamerState;

typedef enum {
    AS_NO_STOP = 0,
    AS_STOPPING_EOF,
    AS_STOPPING_USER_ACTION,
    AS_STOPPING_ERROR,
    AS_STOPPING_TEMPORARILY
} AudioChunkStreamerStopReason;

extern NSString * const ACSStatusChangedNotification;

@interface AudioChunkStreamer : NSObject {
    AudioQueueRef audioQueue;
    AudioFileStreamID audioFileStream;
    AudioStreamBasicDescription asbd;
    NSThread *internalThread;

    AudioQueueBufferRef audioQueueBuffer[kNumAQBufs];
    AudioStreamPacketDescription packetDescs[kAQMaxPacketDescs];
    unsigned int fillBufferIndex;
    UInt32 packetBufferSize;
    size_t bytesFilled;
    size_t packetsFilled;
    bool inuse[kNumAQBufs];
    NSInteger buffersUsed;
    NSDictionary *httpHeaders;

    AudioChunkStreamerState state;
    AudioChunkStreamerStopReason stopReason;
    OSStatus err;

    bool discontinuous;

    pthread_mutex_t queueBuffersMutex;
    pthread_cond_t queueBufferReadyCondition;

    CFReadStreamRef chunkStream;
    NSNotificationCenter *notificationCenter;

    BOOL pausedByInterruption;

    UInt64 currentChunk;
}

@property (readonly) AudioChunkStreamerState state;
@property (readonly) NSDictionary *httpHeaders;
@property (readonly) UInt64 currentChunk;

- (void)startPlayback;
- (void)stopPlayback;
- (void)pausePlayback;
- (BOOL)isPlaying;
- (BOOL)isPaused;
- (BOOL)isWaiting;
- (BOOL)isIdle;

@end






