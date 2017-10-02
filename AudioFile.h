//
//  AudioFile.h
//  Equalizer
//
//  Created by Tomer Hadad on 4/19/14.
//  Copyright (c) 2014 Tomer Hadad. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AudioUtility.h"
#import "AEAudioController.h"

@protocol AudioFileDelegate<NSObject>
@optional
- (void)audioFilePlaybackFinished:(AudioFile *)audioFile;
- (void)audioFileReadingErrorOccurred:(AudioFile *)audioFile withError:(NSError *)error;
@end


@interface AudioFile : NSObject <AEAudioPlayable, LiveAudioSupplier>

@property AEAudioController *audioController;

@property NSString *title;
@property(readonly) NSURL *URL;

@property(readonly) SInt64 currentlyPlayingFrame;
@property(readonly) LiveAudioData liveAudioData;
@property(readonly) BOOL isPlaying;
@property(readonly) BOOL canPlay;

@property AudioStreamBasicDescription sourceAudioFormat;
@property AudioStreamBasicDescription playedAudioFormat;
@property NSTimeInterval durationInSeconds;
@property SInt64 totalFramesCount;

@property BOOL reverbOnPause;
@property CGFloat amplitudeFactor;
@property UInt32 fftOverlapJumpSize;
@property CGFloat timeDelay;
@property CGFloat reverbDecayTime;
@property CGFloat reverbDryWetMix;

@property(readonly) enum AudioSupplyMode audioSupplyMode;
@property BOOL isReverbrating;
@property BOOL isFinished;
@property BOOL isStopped;
@property(readonly) BOOL isStereo;
@property(readonly) BOOL isMono;

@property(nonatomic) AVAssetReader *assetReader;
@property(nonatomic) AVAssetReaderTrackOutput *samplesReader;
@property dispatch_queue_t synchronizationQueue;

@property id<AudioFileDelegate> delegate;

- (NSString *)description;

-(void)loadAudioWithURL:(NSURL *)url withCompletionCallback:(void (^)(NSError *))completion;
-(NSError *)play;
-(NSError *)stop;
-(NSError *)pause;
-(NSError *)resume;
-(void)seekToOffset:(SInt64)offset withCompletionCallback:(void (^)(NSError *))completion;

- (id)initWithDelegate:(id<AudioFileDelegate>)delegate andAudioController:(AEAudioController *)audioController;
- (id)initWithAudioController:(AEAudioController *)audioController;

@end
