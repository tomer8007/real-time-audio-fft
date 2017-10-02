//
//  AudioFile.m
//  Equalizer
//
//  Created by Tomer Hadad on 4/19/14.
//  Copyright (c) 2014 Tomer Hadad. All rights reserved.
//

#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <AudioToolbox/AudioToolbox.h>
#import "Configuration.h"
#import "AudioFile.h"
#import "AEBlockChannel.h"
#import "AppDelegate.h"
#import "AEBlockScheduler.h"
#include <mach/mach_time.h>

@interface AudioFile ()

@property NSURL *URL;
@property BOOL isPlaying;

@end

@implementation AudioFile
{
    @private
    TPCircularBuffer toPlayBuffer;
    TPCircularBuffer toProcessBuffer;
    volatile BOOL shouldFillBuffersAsync;
    volatile BOOL isFillingBuffers;
    AVAssetReaderStatus assetReaderStatus;
    AEAudioUnitFilter *reverb;
    uint64_t reverbStartTime;
    CircularAudioStorage processedAudioData;
    
    float *currentBlock;
    size_t currentBlockSize;
    UInt32 currentBlockOffset;
    volatile CMSampleBufferRef currentBlockRef;
}

- (id)init
{
    self = [self initWithAudioController:[AudioFile sharedPlayOnlyAudioController]];
    return self;
}

- (id)initWithDelegate:(id<AudioFileDelegate>)delegate
{
    self = [self initWithDelegate:delegate andAudioController:[AudioFile sharedPlayOnlyAudioController]];
    return self;
}

- (id)initWithDelegate:(id<AudioFileDelegate>)delegate andAudioController:(AEAudioController *)audioController
{
    self = [self initWithAudioController:audioController];
    self.delegate = delegate;
    return self;
}

+ (AEAudioController *)sharedPlayOnlyAudioController
{
    static AEAudioController *controller = nil;
    if (controller == nil)
    {
        controller = [[AEAudioController alloc] initWithAudioDescription:[AEAudioController nonInterleavedFloatStereoAudioDescription] inputEnabled:NO];
        controller.useMeasurementMode = YES;
        controller.automaticLatencyManagement = YES;
        controller.inputGain = 1.0f;
        controller.preferredBufferDuration = 512.0/44100.0;
    }
    return controller;
}

- (id)initWithAudioController:(AEAudioController *)audioController
{
    self.audioController = audioController;
    
    self.reverbOnPause = YES;
    
    self.timeDelay = 0.1345;
    self.fftOverlapJumpSize = 512;
    self.synchronizationQueue = dispatch_queue_create("audioProcessQueue", DISPATCH_QUEUE_CONCURRENT);
    
    UInt32 samplesBufferSize = CHUNK_SIZE * 16 * sizeof(float);
    UInt32 fftResultsBufferSize = samplesBufferSize * CHUNK_SIZE / self.fftOverlapJumpSize;
    
    AudioStreamInit(&self->processedAudioData.channel1, samplesBufferSize, fftResultsBufferSize, &self->processedAudioData);
    AudioStreamInit(&self->processedAudioData.channel2, samplesBufferSize, fftResultsBufferSize, &self->processedAudioData);
    AudioStreamInit(&self->processedAudioData.extractedChannel, samplesBufferSize, fftResultsBufferSize, &self->processedAudioData);
    
    TPCircularBufferInit(&toPlayBuffer, samplesBufferSize * 2);
    TPCircularBufferInit(&toProcessBuffer, fftResultsBufferSize * 2);
    
    [self.audioController addChannels:@[self]];
    
    CenterCut_Init();
    
    currentBlock = NULL; currentBlockSize = 0; currentBlockOffset = 0; currentBlockRef = NULL;
    
    NSError *error = NULL;
    reverb = [[AEAudioUnitFilter alloc] initWithComponentDescription:AEAudioComponentDescriptionMake(kAudioUnitManufacturer_Apple, kAudioUnitType_Effect, kAudioUnitSubType_Reverb2) audioController:self.audioController error:&error];
    
    if (reverb && self.reverbOnPause)
    {
        self.reverbDecayTime = 3.5f;
        
        // Begin filtering
        [self.audioController addFilter:reverb toChannel:self];
    }
    
    return self;
}

-(void)loadAudioWithURL:(NSURL *)url withCompletionCallback:(void (^)(NSError *))completion
{
    if (url == nil)
    {
        completion([NSError errorWithDomain:@"URL is empty!" code:0 userInfo:nil]);
    }
    
    self.URL = url;
    
    if (self.isPlaying && self.reverbOnPause)
        [self turnReverbOn];
    
    if (self.isPlaying || isFillingBuffers) [self stopSynchronously];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^
    {
        AudioStreamBasicDescription format;
        NSError *error = [self initializeReaderWithURL:url andTimeRange:nil resultFormat:&format];
        if (error)
            completion(error);
        else
        {
            self.sourceAudioFormat = format;
            self.playedAudioFormat = self.audioController.audioDescription;
            
            self.isFinished = NO;
            self.isStopped = NO;
            LiveAudioDataReset(&self->processedAudioData);
            
            [self startFillingBufferAsync]; // start reading samples
            
            // wait until the buffer contains some audio
            uint64_t timeout = machToMiliseconds(mach_absolute_time()) + 500;
            while (self->processedAudioData.channel1.samples.circularBuffer.fillCount < CHUNK_SIZE * 1 * sizeof(float) &&
                   isFillingBuffers && machToMiliseconds(mach_absolute_time()) < timeout) {}
            
            if (self->processedAudioData.channel1.samples.circularBuffer.fillCount < CHUNK_SIZE * 1 * sizeof(float) && machToMiliseconds(mach_absolute_time()) > timeout)
            {
                [self.assetReader cancelReading];
                completion([NSError errorWithDomain:@"Could not read the audio file fast enough" code:0 userInfo:nil]);
            }
            else
            {
                if (!self.audioController.running)
                {
                    [self.audioController start:&error];
                    if (error) completion(error);
                }
                completion(nil); // OK
            }
        }
        
    });
}

- (NSError *)initializeReaderWithURL:(NSURL *)url andTimeRange:(CMTimeRange *)timeRange resultFormat:(AudioStreamBasicDescription *)format
{
    NSError *error;
    
    NSDictionary* outputSettingsDict = [[NSDictionary alloc] initWithObjectsAndKeys:
                                        [NSNumber numberWithInt:kAudioFormatLinearPCM],AVFormatIDKey,
                                        [NSNumber numberWithInt:32],AVLinearPCMBitDepthKey,
                                        [NSNumber numberWithBool:NO],AVLinearPCMIsBigEndianKey,
                                        [NSNumber numberWithBool:YES],AVLinearPCMIsFloatKey,
                                        [NSNumber numberWithBool:NO],AVLinearPCMIsNonInterleaved,
                                        [NSNumber numberWithFloat:44100.0],AVSampleRateKey,
                                        [NSNumber numberWithInt:2],AVNumberOfChannelsKey,
                                    nil];
    
    AVURLAsset *asset = [[AVURLAsset alloc] initWithURL:url options:[NSDictionary dictionary]];
    
    if ([asset tracksWithMediaType:AVMediaTypeAudio].count == 0)
        return [NSError errorWithDomain:@"No tracks available!" code:0 userInfo:nil];
    AVAssetTrack* track = [[asset tracksWithMediaType:AVMediaTypeAudio] objectAtIndex:0];
    
    self.totalFramesCount = CMTimeConvertScale(asset.duration, 44100, kCMTimeRoundingMethod_RoundHalfAwayFromZero).value;
    self.durationInSeconds = (double)asset.duration.value / asset.duration.timescale;
    //self.samplesReader.supportsRandomAccess = YES; // TODO: check this thing
    self.assetReader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (error) return error;
    self.samplesReader = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:outputSettingsDict];
    
    if ([self.assetReader canAddOutput:self.samplesReader] && self.assetReader.outputs.count == 0)
        [self.assetReader addOutput:self.samplesReader];
    else
        return [NSError errorWithDomain:@"Can't add an output to the asset reader." code:0 userInfo:nil];
    if (timeRange)
        self.assetReader.timeRange = *timeRange;
    BOOL success = [self.assetReader startReading];
    if (!success)
    {
        return [NSError errorWithDomain:@"Couldn't start reading!" code:self.assetReader.status userInfo:nil];
    }
    
    if (format)
    {
        *format = *CMAudioFormatDescriptionGetStreamBasicDescription((__bridge CMAudioFormatDescriptionRef)[track.formatDescriptions objectAtIndex:0]);
    }
    
    assetReaderStatus = AVAssetReaderStatusReading;
    
    currentBlockSize = 0;
    currentBlockRef = NULL;
    
    return nil;
}

static OSStatus renderCallback(__unsafe_unretained id channel, __unsafe_unretained AEAudioController *audioController, const AudioTimeStamp *time, UInt32 frames, AudioBufferList *audio)
{
    __unsafe_unretained AudioFile *THIS = channel;
    
    if (!THIS->_isPlaying) return noErr;
    
    int32_t avaliableBytes = 0;
    float *samples = (float *)TPCircularBufferTail(&THIS->toPlayBuffer, &avaliableBytes);
    UInt32 numFramesToPass = (UInt32)MIN(avaliableBytes / audio->mNumberBuffers / sizeof(float), frames);
    
    if (audio->mNumberBuffers == 2)
    {
        SplitStereoSamples(samples, numFramesToPass * 2, (float *)audio->mBuffers[0].mData, (float *)audio->mBuffers[1].mData);
        audio->mBuffers[0].mDataByteSize = numFramesToPass * sizeof(float);
        audio->mBuffers[1].mDataByteSize = numFramesToPass * sizeof(float);
        //NSLog(@"time: %f, passing frames #%lld-%lld for playing",machToMiliseconds(mach_absolute_time())/1000.0f, THIS.currentlyPlayingFrame,THIS.currentlyPlayingFrame+numFramesToPass);
    }
    else if (audio->mNumberBuffers == 1)
    {
        memcpy(audio->mBuffers[0].mData, (void *)samples, numFramesToPass * sizeof(float));
        audio->mBuffers[0].mDataByteSize = numFramesToPass * sizeof(float);
    }
    
    TPCircularBufferConsume(&THIS->toPlayBuffer, numFramesToPass * audio->mNumberBuffers * sizeof(float));

    THIS->processedAudioData.currentlyPlayingFrame += numFramesToPass;
    
    if (THIS->toPlayBuffer.fillCount == 0 && THIS.assetReader.status == AVAssetReaderStatusCompleted)
    {
        THIS->_isPlaying = NO;
        [THIS performSelectorOnMainThread:@selector(playbackFinished) withObject:nil waitUntilDone:NO];
    }
    
    return noErr;
}

uint64_t starttime = 0;

- (void)startFillingBufferAsync
{
    if (isFillingBuffers)
    {
        NSLog(@"can't startFillingBufferAsync because it was called while already filling!");
        return;
    }
    [self clearBuffers];
    shouldFillBuffersAsync = YES;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^
    {
        [self audioPullLoop];
        
        // the audio loop has stopped. chechking if it failed
        if (self.assetReader.status == AVAssetReaderStatusFailed)
        {
            NSLog(@"assetReaderStatus is AVAssetReaderStatusFailed after audioPullLoop");
            [self.delegate audioFileReadingErrorOccurred:self withError:[NSError errorWithDomain:@"AVAssetReaderStatusFailed" code:0 userInfo:nil]];
        }
        else if (self.assetReader.status == AVAssetReaderStatusCancelled)
        {
            NSLog(@"assetReaderStatus is AVAssetReaderStatusCancelled after audioPullLoop");
            [self.delegate audioFileReadingErrorOccurred:self withError:[NSError errorWithDomain:@"AVAssetReaderStatusCancelled" code:0 userInfo:nil]];
        }
    });
    uint64_t timeout = machToMiliseconds(mach_absolute_time()) + 500;
    while (!isFillingBuffers && machToMiliseconds(mach_absolute_time()) < timeout) {}

}

// What we want to have is an FFT of the future at any given moment.
// That means we have to first read a large-enough chunk of audio, process it, and let it play.

- (BOOL)audioPullLoop
{
    isFillingBuffers = YES;
    [[NSThread currentThread] setName:@"Audio Pull Thread"];
    
    UInt32 numSamplesToRead = 4096;
    if (!assetReaderStatus == AVAssetReaderStatusReading)
    {
        NSLog(@"can't start audioPullLoop because assetReaderStatus is not AVAssetReaderStatusReading");
        return NO;
    }
    if (!isThereEnoughPlaceToWrite(&toProcessBuffer, numSamplesToRead * sizeof(float)))
    {
        NSLog(@"can't start audioPullLoop because toProcessBuffer already has some data filled");
        return NO;
    }
    
    while (assetReaderStatus == AVAssetReaderStatusReading && shouldFillBuffersAsync)
    {
        if (isThereEnoughPlaceToWrite(&toProcessBuffer, numSamplesToRead * sizeof(float)))
        {
            UInt32 numSamplesRead = 0;
            float *samples = [self readSamplesFromFile:numSamplesToRead numSamplesRead:&numSamplesRead];
            if (!samples) break;
            
            // process audio here to make it sound
            
            /*float extractedChannel[numSamplesRead];
            CenterCut(samples, numSamplesRead, extractedChannel, self.playedAudioFormat.mSampleRate, false, false);
            samples = extractedChannel;*/
            
            TPCircularBufferProduceBytes(&toProcessBuffer, samples, numSamplesRead * sizeof(float));
            [self processLiveAudio]; // Empties the toProcess buffer
        }
        
    }
    isFillingBuffers = NO;
    
    return YES;

}

- (void)processLiveAudio
{
    // As long as we can we read new samples from the hard disk and add them to the toProcess buffer.
    
    // Samples from the toProcess buffer will be pulled to the processedAudioData and to the toPlay buffer
    // whenever possible, in this method.
    
    while (toProcessBuffer.fillCount >= CHUNK_SIZE * 2 * sizeof(float) && shouldFillBuffersAsync)
    {
        int avaiableBytes = 0;
        float *samples = (float *)TPCircularBufferTail(&toProcessBuffer, &avaiableBytes);
        
        UInt32 numSamplesToProcessPerChannel = CHUNK_SIZE;
        UInt32 numSamplesToProcess = numSamplesToProcessPerChannel * 2;
        
        // if there is not enough space to store the samples, it means that there's too much
        // future data. we'll wait for the playing point to proceed
        if (!canAddToLiveAudioData(&self->processedAudioData, numSamplesToProcessPerChannel) ||
            !isThereEnoughPlaceToWrite(&toPlayBuffer, numSamplesToProcess * sizeof(float)))
            continue;
        
        BOOL success = NO;
        
        // -- Center Channel Extration ---
        // takes ~36 ms on device, so we'll see how it can be optimized.
        
        /*
         float extractedChannel[numSamplesToProcessPerChannel*2], samples1[numSamplesToProcessPerChannel], samples2[numSamplesToProcessPerChannel];
        CenterCut(samples, numSamplesToProcessPerChannel*2, extractedChannel, self.playedAudioFormat.mSampleRate, true, false);
        SplitStereoSamples(extractedChannel, numSamplesToProcessPerChannel*2, samples1, samples2);
        success = AddAudioToLiveStream(samples1, numSamplesToProcessPerChannel, &self->processedAudioData.extractedChannel);
         */
        
        
        // Process the samples, store the result and send to play
        success = AddStereoAudioToLiveStream(samples, numSamplesToProcessPerChannel, &processedAudioData);
        if (success && !self.isStopped)
        {
            TPCircularBufferProduceBytes(&toPlayBuffer, samples, numSamplesToProcess * sizeof(float));
            TPCircularBufferConsume(&toProcessBuffer, numSamplesToProcess * sizeof(float));
        }
        
    }

}

- (void)stopFillingBufferAsync
{
    shouldFillBuffersAsync = NO;
}

-(void)seekToOffset:(SInt64)offset withCompletionCallback:(void (^)(NSError *))completion
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^
    {
        if (offset >= self.totalFramesCount)
        {
            [self playbackFinished];
            completion(nil);
        }
        
        self.isFinished = NO;
        
        NSError *error;
        BOOL wasPlaying = self.isPlaying;
        
        [self stopFillingBufferAsync];
        while (isFillingBuffers) {}
        
        CMTimeRange timeRange = CMTimeRangeMake(CMTimeMake(offset, self.playedAudioFormat.mSampleRate), kCMTimePositiveInfinity);
        error = [self setReaderToTimeRange:&timeRange]; if (error) completion(error); // takes ~18 ms (or 44 ms ?!)
        
        self.isPlaying = NO;
        [self clearBuffers];
        self->processedAudioData.currentlyPlayingFrame = self.assetReader.timeRange.start.value;
        AudioStreamSetBuffersOffset(&self->processedAudioData.channel1, self.assetReader.timeRange.start.value);
        AudioStreamSetBuffersOffset(&self->processedAudioData.channel2, self.assetReader.timeRange.start.value);
        AudioStreamSetBuffersOffset(&self->processedAudioData.extractedChannel, self.assetReader.timeRange.start.value);
        
        [self startFillingBufferAsync];
        
        if (wasPlaying) [self play];
        
        completion(nil);
    });
}

- (NSError *)setReaderToTimeRange:(CMTimeRange *)timeRange
{
    if (!self.assetReader.asset) return [NSError errorWithDomain:@"asset is empty" code:0 userInfo:nil];
        
    NSError *error;
    self.assetReader = [[AVAssetReader alloc] initWithAsset:self.assetReader.asset error:&error];
    if (error) return error;
    self.samplesReader = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:[[self.assetReader.asset tracksWithMediaType:AVMediaTypeAudio] objectAtIndex:0] outputSettings:self.samplesReader.outputSettings];
    [self.assetReader addOutput:self.samplesReader];
    if (timeRange)
        self.assetReader.timeRange = *timeRange;
    BOOL success = [self.assetReader startReading];
    if (!success)
    {
        return [NSError errorWithDomain:@"Couldn't start reading!" code:self.assetReader.status userInfo:nil];
    }
    
    assetReaderStatus = AVAssetReaderStatusReading;
    
    currentBlockSize = 0;
    currentBlockRef = NULL;
    currentBlock = NULL;
    
    return nil;
}

- (void)turnRevernOnWithWetFactor:(CGFloat)wetFactor
{
    LiveSamples samples = self.liveAudioData.channel1.samples;
    float avarage = samples.data != NULL ? AvaragePowerForSamples(samples.data, MIN((int)samples.numSamplesAvailable, 4096)) : 0.0f;
    self.reverbDryWetMix = (1.0 -avarage) * 8;
    if (avarage < 0.1) self.reverbDryWetMix = 20.0;
    self.reverbDryWetMix *= wetFactor;
    reverbStartTime = mach_absolute_time();
    self.isReverbrating = YES;
    
    // stopping the reverb after a while
    dispatch_queue_t backgroundQ = dispatch_queue_create("backgroundDelay", NULL);
    dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, self.reverbDecayTime * NSEC_PER_SEC);
    dispatch_after(delay, backgroundQ, ^(void)
                   {
                       CGFloat timeSinceReverb = machToMiliseconds(mach_absolute_time() - reverbStartTime) / 1000.0;
                       if (timeSinceReverb > self.reverbDecayTime)
                       {
                           [self turnReverbOff];
                           if (self.isStopped) [self.audioController removeChannels:@[self]];
                       }
                   });
}

- (void)turnReverbOn
{
    [self turnRevernOnWithWetFactor:1.0];
}

- (void)turnReverbOff
{
    reverbStartTime = 0;
    self.reverbDryWetMix = 0.0;
    self.isReverbrating = NO;
}

-(NSError *)play
{
    if (!self.canPlay) return [NSError errorWithDomain:@"Audio must be initialized" code:0 userInfo:nil];
    
    if (![self.audioController.channels containsObject:self])
    {
        [[NSOperationQueue mainQueue] addOperationWithBlock:^
         {
             [self.audioController addChannels:@[self]];
             [self.audioController addFilter:reverb toChannel:self];
         }];
    }
    
    if (self.isStopped) [self clearBuffers];
    if (!isFillingBuffers) [self startFillingBufferAsync];
    self.isPlaying = YES;
    self.isStopped = NO;

    if (self.reverbOnPause)
        [self turnReverbOff];
    
    return nil;
}

-(NSError *)resume
{
    return [self play];
}

-(NSError *)pause
{
    if (!self.isPlaying) return nil;
    if (self.reverbOnPause) [self turnReverbOn];
    self.isPlaying = NO;
    
    return nil;
}

-(NSError *)stop
{
    if (!self.isPlaying)
    {
        [[NSOperationQueue mainQueue] addOperationWithBlock:^
         {
             [self.audioController removeChannels:@[self]];
         }];
    }
    
    if (self.reverbOnPause && self.isPlaying) [self turnRevernOnWithWetFactor:2];
    usleep(0.07 * 1000000);
    self.isPlaying = NO;
    [self stopFillingBufferAsync];
    self.isStopped = YES;
    
    /*id<AEAudioReceiver> receiver = [AEBlockAudioReceiver audioReceiverWithBlock:^(...){....}];
    [[AppDelegate sharedDelegate].audioController addOutputReceiver:receiver forChannel:self];*/
    
    return nil;
}

-(NSError *)stopSynchronously
{
    uint64_t timeout = machToMiliseconds(mach_absolute_time()) + 500;
    self.isPlaying = NO;
    self.isStopped = YES;
    
    [self stopFillingBufferAsync]; while (isFillingBuffers && machToMiliseconds(mach_absolute_time()) < timeout) {}
    [self clearBuffers];
    [self.audioController removeChannels:@[self]];
    
    return nil;
}

-(void)playbackFinished
{
    [self stopSynchronously];
    self.isFinished = YES;
    self.isPlaying = NO;
    if ([self.delegate respondsToSelector:@selector(audioFilePlaybackFinished:)])
    {
        [self.delegate audioFilePlaybackFinished:self];
    }
}

- (LiveAudioData)liveAudioData
{
    NSUInteger delayOffset = TimeToSampleTime(self.timeDelay, self.playedAudioFormat.mSampleRate);
    LiveAudioData audioData;
    audioData.timeInFrames = self.currentlyPlayingFrame + delayOffset;
    audioData.channel1 = [self getAudioDataForFrame:audioData.timeInFrames andChannel:&self->processedAudioData.channel1];
    audioData.channel2 = [self getAudioDataForFrame:audioData.timeInFrames andChannel:&self->processedAudioData.channel2];
    
    return audioData;
}

- (LiveAudioChannelData)getAudioDataForFrame:(SInt64)frameOffsetFromFile andChannel:(CircularAudioStream *)stream
{
    LiveAudioChannelData audioData;
    
    /*if (self.isReverbrating)
    {
        CGFloat timeSinceReverb = machToMiliseconds(mach_absolute_time() - reverbStartTime) / 1000.0;
        frameOffsetFromFile += TimeToSampleTime(timeSinceReverb, self.playedAudioFormat.mSampleRate);
    }*/
    
    SInt32 offset = (SInt32)(frameOffsetFromFile - stream->samples.offset);
    SInt32 fftOffset = (SInt32)((frameOffsetFromFile - stream->fftResults.offset) / self->processedAudioData.fftOverlapJumpSize * CHUNK_SIZE);
    if (offset < 0 || offset * sizeof(float) > stream->samples.circularBuffer.fillCount || fftOffset < 0 || fftOffset * sizeof(float) > stream->fftResults.circularBuffer.fillCount)
    {
        //NSLog(@"Requested time is outside the currently stored buffer");
        return (LiveAudioChannelData){NO, 0,0};
    }
    
    int availableBytes = 0;
    float *samples = (float *)TPCircularBufferTail(&stream->samples.circularBuffer, &availableBytes);
    SInt32 availableSamples = availableBytes / sizeof(float) - offset;
    LiveSamples liveSamples = (LiveSamples){frameOffsetFromFile, &samples[offset], availableSamples};
    float *fftResults = (float *)TPCircularBufferTail(&stream->fftResults.circularBuffer, &availableBytes);
    SInt32 availableChunks = availableBytes / CHUNK_SIZE / sizeof(float) - fftOffset / CHUNK_SIZE;
    LiveFFTResults liveFFTResults = (LiveFFTResults){frameOffsetFromFile, &fftResults[fftOffset], availableChunks};
    
    audioData.containsData = availableSamples > 0 || availableChunks > 0;
    audioData.samples = liveSamples;
    audioData.fftResults = liveFFTResults;
    
    return audioData;
}

- (NSString *)description
{
    return [NSString stringWithFormat: @"Title: %@, isPlaying: %@, currentlyPlayingFrame: %lld", self.title, self.isPlaying ? @"YES" : @"NO", self.currentlyPlayingFrame];
}

- (SInt64)currentlyPlayingFrame
{
    return self->processedAudioData.currentlyPlayingFrame;
}

- (void)setFftOverlapJumpSize:(UInt32)fftOverlapJumpSize
{
    self->processedAudioData.fftOverlapJumpSize = fftOverlapJumpSize;
}

- (UInt32)fftOverlapJumpSize
{
    return self->processedAudioData.fftOverlapJumpSize;
}

- (CGFloat)amplitudeFactor
{
    return self->processedAudioData.amplitudeFactor;
}

- (void)setAmplitudeFactor:(CGFloat)amplitudeFactor
{
    self->processedAudioData.amplitudeFactor = amplitudeFactor;
}

- (enum AudioSupplyMode)audioSupplyMode
{
    //if (!self.liveAudioData.channel1.containsData) return AudioSupplyMode_NotSupplying;
    if (!self.isPlaying && !self.isReverbrating) return AudioSupplyMode_NotSupplying;
    if (!self.isPlaying && self.isReverbrating) return AudioSupplyMode_Secondary;
    
    return AudioSupplyMode_Regular;
}

SInt64 mach_to_sampleTime(UInt64 machTime)
{
    mach_timebase_info_data_t timeBaseInfo;
    mach_timebase_info(&timeBaseInfo);
    double miliseconds = machToMiliseconds(machTime-starttime);
    SInt64 sampleTime = miliseconds / 1000.0 * 44100.0;
    return sampleTime;
}

- (void)clearBuffers
{
    dispatch_barrier_sync(self.synchronizationQueue, ^
    {
        TPCircularBufferClear(&toPlayBuffer);
        TPCircularBufferClear(&toProcessBuffer);
        TPCircularBufferClear(&self->processedAudioData.channel1.samples.circularBuffer);
        TPCircularBufferClear(&self->processedAudioData.channel1.fftResults.circularBuffer);
        TPCircularBufferClear(&self->processedAudioData.channel2.samples.circularBuffer);
        TPCircularBufferClear(&self->processedAudioData.channel2.fftResults.circularBuffer);
        TPCircularBufferClear(&self->processedAudioData.extractedChannel.samples.circularBuffer);
        TPCircularBufferClear(&self->processedAudioData.extractedChannel.fftResults.circularBuffer);
    });
}

- (float *)readSamplesFromFile:(UInt32)numSamplesToRead numSamplesRead:(UInt32 *)numSamplesRead
{
    if (numSamplesToRead <= 0) numSamplesToRead = self.isStereo ? CHUNK_SIZE * 4 * 2 : CHUNK_SIZE * 4;
    if (currentBlockOffset >= currentBlockSize)
    {
        if (currentBlockRef)
        {
            CFRelease(currentBlockRef);
            currentBlockRef = NULL;
        }
        
        if (self.assetReader.status == AVAssetReaderStatusReading)
            currentBlockRef = [self.samplesReader copyNextSampleBuffer];
        
        assetReaderStatus = self.assetReader.status;
        
        if (currentBlockRef == NULL)
        {
            if (assetReaderStatus == AVAssetReaderStatusFailed)
            {
                NSLog(@"Failed to read samples! error = %@",[self.assetReader.error description]);
                [self.delegate audioFileReadingErrorOccurred:self withError:self.assetReader.error];
            }
            else if (assetReaderStatus == AVAssetReaderStatusUnknown)
            {
                NSLog(@"Unknown status when trying to read samples. error: %@",[self.assetReader.error description]);
                [self.delegate audioFileReadingErrorOccurred:self withError:self.assetReader.error];
            }
        
            return NULL;
        }
    
        CMBlockBufferRef buffer = CMSampleBufferGetDataBuffer(currentBlockRef);
        size_t numBytesRead;
        OSStatus err = CMBlockBufferGetDataPointer(buffer, 0, NULL, &numBytesRead, (char **)&currentBlock);
        
        if (err != noErr )
        {
            NSLog(@"Can't get data pointer to samples data. error code = %d",(int)err);
            [self.delegate audioFileReadingErrorOccurred:self withError:[NSError errorWithDomain:@"Can't get data pointer to samples data" code:err userInfo:nil]];
            return NULL;
        }
        
        currentBlockSize = numBytesRead / sizeof(float);
        currentBlockOffset = 0;
    }
    
    float *data = currentBlock + currentBlockOffset;
    *numSamplesRead = MIN(numSamplesToRead,(UInt32)(currentBlockSize - currentBlockOffset));
    currentBlockOffset+= *numSamplesRead;
    return data;

}

- (void)setReverbDecayTime:(CGFloat)reverbDecayTime
{
    if (!reverb) return;
    AudioUnitSetParameter(reverb.audioUnit,kReverb2Param_DecayTimeAt0Hz,kAudioUnitScope_Global,0,reverbDecayTime,0);
    AudioUnitSetParameter(reverb.audioUnit,kReverb2Param_DecayTimeAtNyquist,kAudioUnitScope_Global,0,reverbDecayTime,0);
}

-(CGFloat)reverbDecayTime
{
    if (!reverb) return 0;
    AudioUnitParameterValue value;
    AudioUnitGetParameter(reverb.audioUnit, kReverb2Param_DecayTimeAt0Hz, kAudioUnitScope_Global, 0, &value);
    return value;
}

- (void)setReverbDryWetMix:(CGFloat)reverbDryWetMix
{
    if (!reverb) return;
    AudioUnitSetParameter(reverb.audioUnit,kReverb2Param_DryWetMix,kAudioUnitScope_Global,0,reverbDryWetMix,0);
}

- (CGFloat)reverbDryWetMix
{
    if (!reverb) return 0;
    AudioUnitParameterValue value;
    AudioUnitGetParameter(reverb.audioUnit, kReverb2Param_DryWetMix, kAudioUnitScope_Global, 0, &value);
    return value;
}

- (BOOL)isStereo
{
    return self.sourceAudioFormat.mChannelsPerFrame == 2;
}

- (BOOL)isMono
{
    return self.sourceAudioFormat.mChannelsPerFrame == 1;
}

- (BOOL)canPlay
{
    return self.samplesReader && self.assetReader && self.URL;
}

-(AEAudioControllerRenderCallback)renderCallback
{
    return &renderCallback;
}

-(void)dealloc
{
    if (self->processedAudioData.channel1.samples.circularBuffer.buffer)
    {
        TPCircularBufferCleanup(&self->processedAudioData.channel1.samples.circularBuffer);
        TPCircularBufferCleanup(&self->processedAudioData.channel1.fftResults.circularBuffer);
        TPCircularBufferCleanup(&self->processedAudioData.channel2.samples.circularBuffer);
        TPCircularBufferCleanup(&self->processedAudioData.channel2.fftResults.circularBuffer);
    }
    if ([self.audioController.channels containsObject:self])
    {
        [self.audioController removeChannels:@[self]];
    }
}

@end
