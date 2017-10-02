//
//  AudioFile.h
//  Equalizer
//
//  Created by Tomer Hadad on 4/19/14.
//  Copyright (c) 2014 Tomer Hadad. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AudioUtility.h"
#include "AEAudioController.h"

@interface Microphone : NSObject <AEAudioReceiver, LiveAudioSupplier>
{
    LiveMicrophoneData liveMicrophoneData;
@public
    dispatch_queue_t syncQueue;
}

@property AEAudioController *audioController;

@property(readonly) LiveAudioData liveAudioData;
@property BOOL isRecording;
@property AudioStreamBasicDescription audioFormat;
@property UInt32 numOfChannels;
@property CGFloat amplitudeFactor;

@property(readonly) enum AudioSupplyMode audioSupplyMode;

-(NSError *)startRecording;
-(NSError *)stopRecording;
-(NSError *)resumeRecording;

-(id)initWithAudioController:(AEAudioController *)audioController;

@end
