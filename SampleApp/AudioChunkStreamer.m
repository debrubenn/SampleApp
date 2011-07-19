#import "AudioChunkStreamer.h"
#import <CFNetwork/CFNetwork.h>

NSString * const ACSStatusChangedNotification = @"ACSStatusChangedNotification";

@interface AudioChunkStreamer ()
@property (readwrite) AudioChunkStreamerState state;

- (void)handlePropertyChangeForFileStream:(AudioFileStreamID)inAudioFileStream
                     fileStreamPropertyID:(AudioFileStreamPropertyID)inPropertyID
                                  ioFlags:(UInt32 *)ioFlags;
- (void)handleAudioPackets:(const void *)inInputData
               numberBytes:(UInt32)inNumberBytes
             numberPackets:(UInt32)inNumberPackets
        packetDescriptions:(AudioStreamPacketDescription *)inPacketDescriptions;
- (void)handleBufferCompleteForQueue:(AudioQueueRef)inAQ
                              buffer:(AudioQueueBufferRef)inBuffer;
- (void)handlePropertyChangeForQueue:(AudioQueueRef)inAQ
                          propertyID:(AudioQueuePropertyID)inID;
- (void)handleInterruptionChangeToState:(AudioQueuePropertyID)inInterruptionState;
- (void)enqueueBuffer;
- (void)handleReadFromStream:(CFReadStreamRef)aStream
                   eventType:(CFStreamEventType)eventType;

@end

#pragma mark Audio Callback Functions

void ThePropertyListenerProc(void *                      inClientData,
                             AudioFileStreamID           inAudioFileStream,
                             AudioFileStreamPropertyID   inPropertyID,
                             UInt32 *                    ioFlags)
{	
    AudioChunkStreamer * streamer = (AudioChunkStreamer *)inClientData;
    [streamer handlePropertyChangeForFileStream:inAudioFileStream
                           fileStreamPropertyID:inPropertyID
                                        ioFlags:ioFlags];
}

void ThePacketsProc(void *                          inClientData,
                    UInt32                          inNumberBytes,
                    UInt32                          inNumberPackets,
                    const void *                    inInputData,
                    AudioStreamPacketDescription *  inPacketDescriptions)
{
    AudioChunkStreamer * streamer = (AudioChunkStreamer *)inClientData;
    [streamer handleAudioPackets:inInputData
                     numberBytes:inNumberBytes
                   numberPackets:inNumberPackets
              packetDescriptions:inPacketDescriptions];
}

void TheAudioQueueOutputCallback(void *                 inClientData, 
                                 AudioQueueRef          inAQ, 
                                 AudioQueueBufferRef    inBuffer)
{
    AudioChunkStreamer * streamer = (AudioChunkStreamer*)inClientData;
    [streamer handleBufferCompleteForQueue:inAQ
                                    buffer:inBuffer];
}

void TheAudioQueueIsRunningCallback(void *                  inUserData,
                                    AudioQueueRef           inAQ,
                                    AudioQueuePropertyID    inID)
{
    AudioChunkStreamer* streamer = (AudioChunkStreamer *)inUserData;
    [streamer handlePropertyChangeForQueue:inAQ
                                propertyID:inID];
}

void TheAudioSessionInterruptionListener(void *     inClientData,
                                         UInt32     inInterruptionState)
{
    AudioChunkStreamer * streamer = (AudioChunkStreamer *)inClientData;
    [streamer handleInterruptionChangeToState:inInterruptionState];
}

#pragma mark CFReadStream Callback Functions

void TheReadStreamCallBack(CFReadStreamRef      aStream,
                           CFStreamEventType    eventType,
                           void *               inClientInfo)
{
    AudioChunkStreamer * streamer = (AudioChunkStreamer *)inClientInfo;
    [streamer handleReadFromStream:aStream eventType:eventType];
}

@implementation AudioChunkStreamer

@synthesize state;
@synthesize httpHeaders;
@synthesize currentChunk;

- (id)init
{
    self = [super init];
    if (self != nil) {
        currentChunk = 0;
    }
    return self;
}

- (void)dealloc
{
	[self stopPlayback];
	[super dealloc];
}

- (void)alertWithTitle:(NSString*)title message:(NSString*)message
{
    UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:title
                                                     message:message
                                                    delegate:self
                                           cancelButtonTitle:NSLocalizedString(@"OK", @"")
                                           otherButtonTitles:nil] autorelease];
    [alert performSelector:@selector(show)
                  onThread:[NSThread mainThread]
                withObject:nil
             waitUntilDone:NO];
}

- (void)mainThreadStateNotification
{
    NSNotification * notification = [NSNotification notificationWithName:ACSStatusChangedNotification
                                                                  object:self];
    [[NSNotificationCenter defaultCenter] postNotification:notification];
}

- (void)setState:(AudioChunkStreamerState)aStatus
{
    @synchronized(self) {
        if (state != aStatus) {
            state = aStatus;
            if ([[NSThread currentThread] isEqual:[NSThread mainThread]]) {
                [self mainThreadStateNotification];
            } else {
                [self performSelectorOnMainThread:@selector(mainThreadStateNotification)
                                       withObject:nil
                                    waitUntilDone:NO];
            }
        }
    }
}

- (BOOL)isPlaying
{
    return state == AS_PLAYING;
}

- (BOOL)isPaused
{
    return state == AS_PAUSED;
}

- (BOOL)isWaiting
{
    return state == AS_WAITING_FOR_DATA;
}

- (BOOL)isIdle
{
    return state == AS_INITIALIZED;
}

- (BOOL)isFinishing
{
    @synchronized (self) {
        return (state != AS_INITIALIZED && stopReason == AS_STOPPING_ERROR) || ((state == AS_STOPPING || state == AS_STOPPED) && stopReason != AS_STOPPING_TEMPORARILY);
    }
}

- (BOOL)runLoopShouldExit
{
    @synchronized(self) {
        return stopReason == AS_STOPPING_ERROR || (state == AS_STOPPED && stopReason != AS_STOPPING_TEMPORARILY);
    }
}

- (void)closeChunkStream
{
    if (chunkStream) {
        CFReadStreamClose(chunkStream);
        CFRelease(chunkStream);
        chunkStream = nil;
    }
}

- (void)stopAudioQueueWithError:(NSString *)errorMsg
{
    NSLog(@"%@", errorMsg);
    @synchronized(self) {
        if (state == AS_PLAYING || state == AS_PAUSED || state == AS_BUFFERING) {
            self.state = AS_STOPPING;
            stopReason = AS_STOPPING_ERROR;
            AudioQueueStop(audioQueue, true);
        }
    }
}

- (BOOL)fetchNextChunk
{
    @synchronized(self) {
        NSAssert([[NSThread currentThread] isEqual:internalThread],
                 @"File stream download must be started on the internalThread");

        [self closeChunkStream];

        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://lamptest.freehostia.com/audiosamples/sample.php?chunk=%u", ++currentChunk]];
        CFHTTPMessageRef message= CFHTTPMessageCreateRequest(NULL, (CFStringRef)@"GET", (CFURLRef)url, kCFHTTPVersion1_1);
        chunkStream = CFReadStreamCreateForHTTPRequest(NULL, message);
        CFRelease(message);
        
        if (CFReadStreamSetProperty(chunkStream,
                                    kCFStreamPropertyHTTPShouldAutoredirect,
                                    kCFBooleanTrue) == false) {
            [self alertWithTitle:NSLocalizedStringFromTable(@"File Error", @"Errors", nil)
                         message:NSLocalizedStringFromTable(@"Unable to configure network read stream.", @"Errors", nil)];
            return NO;
        }
        
        CFDictionaryRef proxySettings = CFNetworkCopySystemProxySettings();
        CFReadStreamSetProperty(chunkStream, kCFStreamPropertyHTTPProxy, proxySettings);
        CFRelease(proxySettings);
        
        [self setState:AS_WAITING_FOR_DATA];
        
        if (!CFReadStreamOpen(chunkStream)) {
            CFRelease(chunkStream);
            [self alertWithTitle:NSLocalizedStringFromTable(@"File Error", @"Errors", nil)
                         message:NSLocalizedStringFromTable(@"Unable to configure network read stream.", @"Errors", nil)];
            return NO;
        }
        
        CFStreamClientContext context = {0, self, NULL, NULL, NULL};
        CFReadStreamSetClient(chunkStream,
                              kCFStreamEventHasBytesAvailable | kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered,
                              TheReadStreamCallBack,
                              &context);
        CFReadStreamScheduleWithRunLoop(chunkStream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
    }

    return YES;
}

- (void)startInternal
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    @synchronized(self) {
        if (state != AS_STARTING_FILE_THREAD) {
            if (state != AS_STOPPING && state != AS_STOPPED) {
                NSLog(@"Can't start audio thread in this state: %u", state);
            }
            self.state = AS_INITIALIZED;
            [pool release];
            return;
        }
        AudioSessionInitialize (NULL, NULL, TheAudioSessionInterruptionListener, self);
        UInt32 sessionCategory = kAudioSessionCategory_MediaPlayback;
        AudioSessionSetProperty (kAudioSessionProperty_AudioCategory,
                                 sizeof (sessionCategory),
                                 &sessionCategory
                                 );
        AudioSessionSetActive(true);
        pthread_mutex_init(&queueBuffersMutex, NULL);
        pthread_cond_init(&queueBufferReadyCondition, NULL);
        if (![self fetchNextChunk]) {
            goto cleanup;
        }
    }
    BOOL isRunning = YES;
    do {
        isRunning = [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
        if (buffersUsed == 0 && self.state == AS_PLAYING) {
            err = AudioQueuePause(audioQueue);
            if (err) {
                [self stopAudioQueueWithError:@"AudioQueuePause failed."];
                return;
            }
            self.state = AS_BUFFERING;
        }
    } while (isRunning && ![self runLoopShouldExit]);
	
cleanup:

    @synchronized(self) {
        [self closeChunkStream];
        if (audioFileStream) {
            err = AudioFileStreamClose(audioFileStream);
            audioFileStream = nil;
            if (err) {
                [self stopAudioQueueWithError:@"AudioFileStreamClose failed."];
            }
        }
        if (audioQueue) {
            err = AudioQueueDispose(audioQueue, true);
            audioQueue = nil;
            if (err) {
                [self stopAudioQueueWithError:@"AudioQueueDispose failed."];
            }
        }
        pthread_mutex_destroy(&queueBuffersMutex);
        pthread_cond_destroy(&queueBufferReadyCondition);
        AudioSessionSetActive(false);
        [httpHeaders release];
        httpHeaders = nil;
        bytesFilled = 0;
        packetsFilled = 0;
        packetBufferSize = 0;
        self.state = AS_INITIALIZED;
        [internalThread release];
        internalThread = nil;
    }

    [pool release];
}

- (void)startPlayback
{
    @synchronized (self) {
        if (state == AS_PAUSED) {
            [self pausePlayback];
        } else if (state == AS_INITIALIZED) {
            NSAssert([[NSThread currentThread] isEqual:[NSThread mainThread]],
                     @"Playback can only be started from the main thread.");
            notificationCenter = [[NSNotificationCenter defaultCenter] retain];
            self.state = AS_STARTING_FILE_THREAD;
            internalThread = [[NSThread alloc] initWithTarget:self
                                                     selector:@selector(startInternal)
                                                       object:nil];
            [internalThread start];
        }
    }
}

- (void)pausePlayback
{
    @synchronized(self) {
        if (state == AS_PLAYING || state == AS_WAITING_FOR_QUEUE_TO_START) {
            err = AudioQueuePause(audioQueue);
            if (err) {
                [self stopAudioQueueWithError:@"AudioQueuePause failed."];
                return;
            }
            self.state = AS_PAUSED;
        } else if (state == AS_PAUSED) {
            self.state = AS_WAITING_FOR_QUEUE_TO_START;
            err = AudioQueueStart(audioQueue, NULL);
            if (err) {
                [self stopAudioQueueWithError:@"AudioQueueStart failed."];
                return;
            }
        }
    }
}

- (void)stopPlayback {
    @synchronized(self) {
        if (audioQueue &&
            (state == AS_PLAYING || state == AS_PAUSED ||
             state == AS_BUFFERING || state == AS_WAITING_FOR_QUEUE_TO_START))
        {
            self.state = AS_STOPPING;
            stopReason = AS_STOPPING_USER_ACTION;
            err = AudioQueueStop(audioQueue, true);
            if (err) {
                [self stopAudioQueueWithError:@"AudioQueueStop failed."];
                return;
            }
        } else if (state != AS_INITIALIZED){
            self.state = AS_STOPPED;
            stopReason = AS_STOPPING_USER_ACTION;
        }
    }
    while (state != AS_INITIALIZED) {
        [NSThread sleepForTimeInterval:0.1];
    }
}

- (void)handleReadFromStream:(CFReadStreamRef)aStream
                   eventType:(CFStreamEventType)eventType
{
    if (aStream != chunkStream) {
        return;
    }
    if (eventType == kCFStreamEventErrorOccurred) {
        [self stopAudioQueueWithError:@"Stream error."];
    } else if (eventType == kCFStreamEventEndEncountered) {
        @synchronized(self) {
            if ([self isFinishing]) {
                return;
            }
            [self fetchNextChunk];
        }
    } else if (eventType == kCFStreamEventHasBytesAvailable) {
        if (!httpHeaders) {
            CFTypeRef message = CFReadStreamCopyProperty(aStream, kCFStreamPropertyHTTPResponseHeader);
            httpHeaders = (NSDictionary *)CFHTTPMessageCopyAllHeaderFields((CFHTTPMessageRef)message);
            CFRelease(message);
        }
        if (!audioFileStream) {
            // http://developer.apple.com/LIBRARY/IOS/#documentation/MusicAudio/Reference/AudioFileConvertRef/Reference/reference.html
            // Constants -> Built-In Audio File Types
            err = AudioFileStreamOpen(self, ThePropertyListenerProc, ThePacketsProc, kAudioFileAAC_ADTSType, &audioFileStream);
            if (err) {
                [self stopAudioQueueWithError:@"AudioFileStreamOpen failed."];
                return;
            }
        }
        UInt8 bytes[kAQDefaultBufSize];
        CFIndex length;
        @synchronized(self) {
            if ([self isFinishing] || !CFReadStreamHasBytesAvailable(aStream)) {
                return;
            }
            length = CFReadStreamRead(aStream, bytes, kAQDefaultBufSize);
            if (length == -1) {
                [self stopAudioQueueWithError:@"No audio data."];
                return;
            }
            if (length == 0) {
                return;
            }
        }
        if (discontinuous) {
            err = AudioFileStreamParseBytes(audioFileStream, length, bytes, kAudioFileStreamParseFlag_Discontinuity);
        } else {
            err = AudioFileStreamParseBytes(audioFileStream, length, bytes, 0);
        }
        if (err) {
            [self stopAudioQueueWithError:@"AudioFileStreamParseBytes failed."];
            return;
        }
    }
}

- (void)enqueueBuffer
{
    @synchronized(self) {
        if ([self isFinishing] || chunkStream == 0) {
            return;
        }
        inuse[fillBufferIndex] = true;
        buffersUsed++;
        AudioQueueBufferRef fillBuf = audioQueueBuffer[fillBufferIndex];
        fillBuf->mAudioDataByteSize = bytesFilled;
        if (packetsFilled) {
            err = AudioQueueEnqueueBuffer(audioQueue, fillBuf, packetsFilled, packetDescs);
        } else {
            err = AudioQueueEnqueueBuffer(audioQueue, fillBuf, 0, NULL);
        }
        if (err) {
            [self stopAudioQueueWithError:@"AudioQueueEnqueueBuffer failed."];
            return;
        }
        if (state == AS_BUFFERING || state == AS_WAITING_FOR_DATA || state == AS_FLUSHING_EOF || (state == AS_STOPPED && stopReason == AS_STOPPING_TEMPORARILY) && (state == AS_FLUSHING_EOF || buffersUsed == kNumAQBufs - 1))
        {
            if (self.state == AS_BUFFERING) {
                err = AudioQueueStart(audioQueue, NULL);
                if (err) {
                    [self stopAudioQueueWithError:@"AudioQueueStart failed."];
                    return;
                }
                self.state = AS_PLAYING;
            } else {
                self.state = AS_WAITING_FOR_QUEUE_TO_START;
                err = AudioQueueStart(audioQueue, NULL);
                if (err) {
                    [self stopAudioQueueWithError:@"AudioQueueStart failed."];
                    return;
                }
            }
        }
        if (++fillBufferIndex >= kNumAQBufs) fillBufferIndex = 0;
        bytesFilled = 0;
        packetsFilled = 0;
    }
    pthread_mutex_lock(&queueBuffersMutex); 
    while (inuse[fillBufferIndex]) {
        pthread_cond_wait(&queueBufferReadyCondition, &queueBuffersMutex);
    }
    pthread_mutex_unlock(&queueBuffersMutex);
}

- (void)createQueue
{
    err = AudioQueueNewOutput(&asbd, TheAudioQueueOutputCallback, self, NULL, NULL, 0, &audioQueue);
    if (err) {
        [self stopAudioQueueWithError:@"AudioQueueNewOutput failed."];
        return;
    }
    err = AudioQueueAddPropertyListener(audioQueue, kAudioQueueProperty_IsRunning, TheAudioQueueIsRunningCallback, self);
    if (err) {
        [self stopAudioQueueWithError:@"AudioQueueAddPropertyListener failed."];
        return;
    }
    UInt32 sizeOfUInt32 = sizeof(UInt32);
    err = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_PacketSizeUpperBound, &sizeOfUInt32, &packetBufferSize);
    if (err || packetBufferSize == 0) {
        err = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_MaximumPacketSize, &sizeOfUInt32, &packetBufferSize);
        if (err || packetBufferSize == 0) {
            packetBufferSize = kAQDefaultBufSize;
        }
    }
    for (unsigned int i = 0; i < kNumAQBufs; ++i) {
        err = AudioQueueAllocateBuffer(audioQueue, packetBufferSize, &audioQueueBuffer[i]);
        if (err) {
            [self stopAudioQueueWithError:@"AudioQueueAllocateBuffer failed."];
            return;
        }
    }
    UInt32 cookieSize;
    Boolean writable;
    OSStatus ignorableError;
    ignorableError = AudioFileStreamGetPropertyInfo(audioFileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &writable);
    if (ignorableError) {
        return;
    }
    void* cookieData = calloc(1, cookieSize);
    ignorableError = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, cookieData);
    if (ignorableError) {
        return;
    }
    ignorableError = AudioQueueSetProperty(audioQueue, kAudioQueueProperty_MagicCookie, cookieData, cookieSize);
    free(cookieData);
    if (ignorableError) {
        return;
    }
}

- (void)handlePropertyChangeForFileStream:(AudioFileStreamID)inAudioFileStream
                     fileStreamPropertyID:(AudioFileStreamPropertyID)inPropertyID
                                  ioFlags:(UInt32 *)ioFlags
{
    @synchronized(self) {
        if ([self isFinishing]) {
            return;
        }
        if (inPropertyID == kAudioFileStreamProperty_ReadyToProducePackets) {
            discontinuous = true;
        } else if (inPropertyID == kAudioFileStreamProperty_DataFormat) {
            if (asbd.mSampleRate == 0) {
                UInt32 asbdSize = sizeof(asbd);
                err = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_DataFormat, &asbdSize, &asbd);
                if (err) {
                    [self stopAudioQueueWithError:@"AudioFileStreamGetProperty failed."];
                    return;
                }
            }
        } else if (inPropertyID == kAudioFileStreamProperty_FormatList) {
            Boolean outWriteable;
            UInt32 formatListSize;
            err = AudioFileStreamGetPropertyInfo(inAudioFileStream, kAudioFileStreamProperty_FormatList, &formatListSize, &outWriteable);
            if (err) {
                [self stopAudioQueueWithError:@"AudioFileStreamGetPropertyInfo failed."];
                return;
            }
            AudioFormatListItem *formatList = malloc(formatListSize);
            err = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_FormatList, &formatListSize, formatList);
            if (err) {
                [self stopAudioQueueWithError:@"AudioFileStreamGetProperty failed."];
                return;
            }
            for (int i = 0; i * sizeof(AudioFormatListItem) < formatListSize; i += sizeof(AudioFormatListItem)) {
                AudioStreamBasicDescription pasbd = formatList[i].mASBD;
                if (pasbd.mFormatID == kAudioFormatMPEG4AAC_HE) {
#if !TARGET_IPHONE_SIMULATOR
                    asbd = pasbd;
#endif
                    break;
                }
            }
            free(formatList);
        }
    }
}

- (void)handleAudioPackets:(const void *)inInputData
               numberBytes:(UInt32)inNumberBytes
             numberPackets:(UInt32)inNumberPackets
        packetDescriptions:(AudioStreamPacketDescription *)inPacketDescriptions;
{
    @synchronized(self) {
        if ([self isFinishing]) {
            return;
        }
        if (discontinuous) {
            discontinuous = false;
        }
        if (!audioQueue) {
            [self createQueue];
        }
    }
    if (inPacketDescriptions) {
        for (int i = 0; i < inNumberPackets; ++i) {
            SInt64 packetOffset = inPacketDescriptions[i].mStartOffset;
            SInt64 packetSize   = inPacketDescriptions[i].mDataByteSize;
            size_t bufSpaceRemaining;
            @synchronized(self) {
                if ([self isFinishing]) {
                    return;
                }
                if (packetSize > packetBufferSize) {
                    [self stopAudioQueueWithError:@"Audio buffer too small."];
                }
                bufSpaceRemaining = packetBufferSize - bytesFilled;
            }
            if (bufSpaceRemaining < packetSize) {
                [self enqueueBuffer];
            }
            @synchronized(self) {
                if ([self isFinishing]) {
                    return;
                }
                if (bytesFilled + packetSize > packetBufferSize) {
                    return;
                }
                AudioQueueBufferRef fillBuf = audioQueueBuffer[fillBufferIndex];
                memcpy((char*)fillBuf->mAudioData + bytesFilled, (const char*)inInputData + packetOffset, packetSize);
                packetDescs[packetsFilled] = inPacketDescriptions[i];
                packetDescs[packetsFilled].mStartOffset = bytesFilled;
                bytesFilled += packetSize;
                packetsFilled += 1;
            }
            size_t packetsDescsRemaining = kAQMaxPacketDescs - packetsFilled;
            if (packetsDescsRemaining == 0) {
                [self enqueueBuffer];
            }
        }	
    } else {
        size_t offset = 0;
        while (inNumberBytes) {
            size_t bufSpaceRemaining = kAQDefaultBufSize - bytesFilled;
            if (bufSpaceRemaining < inNumberBytes) {
                [self enqueueBuffer];
            }
            @synchronized(self) {
                if ([self isFinishing]) {
                    return;
                }
                bufSpaceRemaining = kAQDefaultBufSize - bytesFilled;
                size_t copySize;
                if (bufSpaceRemaining < inNumberBytes) {
                    copySize = bufSpaceRemaining;
                } else {
                    copySize = inNumberBytes;
                }
                if (bytesFilled > packetBufferSize) {
                    return;
                }
                AudioQueueBufferRef fillBuf = audioQueueBuffer[fillBufferIndex];
                memcpy((char*)fillBuf->mAudioData + bytesFilled, (const char*)(inInputData + offset), copySize);
                bytesFilled += copySize;
                packetsFilled = 0;
                inNumberBytes -= copySize;
                offset += copySize;
            }
        }
    }
}

- (void)handleBufferCompleteForQueue:(AudioQueueRef)inAQ
                              buffer:(AudioQueueBufferRef)inBuffer
{
    unsigned int bufIndex = -1;
    for (unsigned int i = 0; i < kNumAQBufs; ++i) {
        if (inBuffer == audioQueueBuffer[i]) {
            bufIndex = i;
            break;
        }
    }
    if (bufIndex == -1) {
        [self stopAudioQueueWithError:@"AudioQueueBuffer mismatch."];
        pthread_mutex_lock(&queueBuffersMutex);
        pthread_cond_signal(&queueBufferReadyCondition);
        pthread_mutex_unlock(&queueBuffersMutex);
        return;
    }
    pthread_mutex_lock(&queueBuffersMutex);
    inuse[bufIndex] = false;
    buffersUsed--;
    pthread_cond_signal(&queueBufferReadyCondition);
    pthread_mutex_unlock(&queueBuffersMutex);
}

- (void)handlePropertyChangeForQueue:(AudioQueueRef)theAudioQueue
                          propertyID:(AudioQueuePropertyID)thePropertyId
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    @synchronized(self) {
        if (thePropertyId == kAudioQueueProperty_IsRunning) {
            if (state == AS_STOPPING) {
                self.state = AS_STOPPED;
            } else if (state == AS_WAITING_FOR_QUEUE_TO_START) {
                [NSRunLoop currentRunLoop];
                self.state = AS_PLAYING;
            } else {
                NSLog(@"Unexpected AudioQueue state.");
            }
        }
    }
    [pool release];
}

- (void)handleInterruptionChangeToState:(AudioQueuePropertyID)inInterruptionState 
{
    if (inInterruptionState == kAudioSessionBeginInterruption) { 
        if ([self isPlaying]) {
            [self pausePlayback];
            pausedByInterruption = YES; 
        } 
    } else if (inInterruptionState == kAudioSessionEndInterruption) {
        AudioSessionSetActive( true );
        if ([self isPaused] && pausedByInterruption) {
            [self pausePlayback]; // resume
            pausedByInterruption = NO;
        }
    }
}

@end
