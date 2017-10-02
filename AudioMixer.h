//
//  AudioMixer.h
//  Equalizer
//
//  Created by Tomer Hadad on 5/12/16.
//  Copyright (c) 2016 Tomer Hadad. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AudioUtility.h"

@interface AudioMixer : NSObject <LiveAudioSupplier>

@property CGFloat fadeInOutTime;
@property SInt32 memoryLimit;
@property(readonly) SInt32 chunksMemoryLimit;
@property NSMutableArray *channels;
@property(nonatomic) NSArray *activeChannels;

@property(readonly) LiveAudioData liveAudioData;
@property(readonly) enum AudioSupplyMode audioSupplyMode;

- (id)init;
- (void)addChannel:(id<LiveAudioSupplier>)audioSupplier;
- (void)removeChannel:(id<LiveAudioSupplier>)audioSupplier;

@end

@interface AudioMixerChannel : NSObject

@property id<LiveAudioSupplier> audioSupplier;
@property(nonatomic) LiveAudioData liveAudioData;
@property float volume;
@property BOOL isFadingIn;
@property BOOL isFadingOut;
@property(nonatomic) BOOL isActive;
@property BOOL isDestroyed;
@property UInt64 fadeStartTime;
@property CGFloat totalFadeTimeInSeconds;

- (id)initWithAudioSupplier:(id<LiveAudioSupplier>)audioSupplier;
- (void)startFadingInWithDuration:(CGFloat)fadeTimeInSeconds;
- (void)startFadingOutWithDuration:(CGFloat)fadeTimeInSeconds;
- (void)update;

@end
