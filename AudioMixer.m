//
//  AudioMixer.m
//  Equalizer
//
//  Created by Tomer Hadad on 5/12/16.
//  Copyright (c) 2016 Tomer Hadad. All rights reserved.
//

#import "AudioMixer.h"

@implementation AudioMixer
{
    LiveAudioData mixedAudioData;
    float *mixedFFTResults1;
    float *mixedSamples1;
    float *mixedFFTResults2;
    float *mixedSamples2;
}

@synthesize memoryLimit = _memoryLimit;

- (id)init
{
    self.channels = [[NSMutableArray alloc] init];
    
    self.memoryLimit = 2048;
    self.fadeInOutTime = 0.3f;
    
    LiveAudioDataEmpty(&mixedAudioData);
    
    return self;
}

- (void)addChannel:(id<LiveAudioSupplier>)audioSupplier
{
    AudioMixerChannel *channel = [[AudioMixerChannel alloc] initWithAudioSupplier:audioSupplier];
    [channel startFadingInWithDuration:self.fadeInOutTime];
    [self.channels addObject:channel];
}

- (void)removeChannel:(id<LiveAudioSupplier>)audioSupplier
{
    for (AudioMixerChannel *channel in self.channels)
    {
        if (channel.audioSupplier == audioSupplier)
        {
            [channel startFadingOutWithDuration:self.fadeInOutTime];
        }
    }
}

- (LiveAudioData)liveAudioData
{
    [self cleanup];
    
    /*if (self.activeChannels.count == 1)
    {
        return ((AudioMixerChannel *)self.activeChannels.firstObject).liveAudioData;
    }*/

    mixedAudioData.channel1.fftResults.numChunksAvailable = [self numChunksAvailableForChannelID:1];
    mixedAudioData.channel1.samples.numSamplesAvailable = [self numSamplesAvailableForChannelID:1];
    mixedAudioData.channel2.fftResults.numChunksAvailable = [self numChunksAvailableForChannelID:2];
    mixedAudioData.channel2.samples.numSamplesAvailable = [self numSamplesAvailableForChannelID:2];
    
    LiveAudioDataEmpty(&mixedAudioData);
    for (AudioMixerChannel *channel in self.channels)
    {
        [channel update];
        if (!channel.isActive) continue;
        
        LiveAudioData audioData = channel.liveAudioData;
        mixedAudioData.timeInFrames = audioData.timeInFrames != 0 ? audioData.timeInFrames : mixedAudioData.timeInFrames;
        mixedAudioData.channel1.containsData |= audioData.channel1.containsData;
        mixedAudioData.channel2.containsData |= audioData.channel2.containsData;
        
        [self mixSamples:audioData.channel1.samples forChannel:1 withVolume:channel.volume];
        [self mixFFTResults:audioData.channel1.fftResults forChannel:1 withVolume:channel.volume];
        [self mixSamples:audioData.channel2.samples forChannel:2 withVolume:channel.volume];
        [self mixFFTResults:audioData.channel2.fftResults forChannel:2 withVolume:channel.volume];
    }
    
    return mixedAudioData;
}

- (void)mixSamples:(LiveSamples)samples1 forChannel:(SInt32)channelID withVolume:(float)volume
{
    UInt64 numSamples = channelID == 1 ? mixedAudioData.channel1.samples.numSamplesAvailable : mixedAudioData.channel2.samples.numSamplesAvailable;
    
    if (numSamples > samples1.numSamplesAvailable || numSamples > self.memoryLimit)
        numSamples = MIN(self.memoryLimit,samples1.numSamplesAvailable);
    
    float modifiedSamples[numSamples];
    AmplitudeFactor(samples1.data, numSamples, volume, modifiedSamples);
    float *mixed = channelID == 1 ? mixedSamples1 : mixedSamples2;
    Mix(modifiedSamples, mixed, mixed, numSamples);
    if (channelID == 1) mixedAudioData.channel1.samples.numSamplesAvailable = numSamples;
    else if (channelID == 2) mixedAudioData.channel2.samples.numSamplesAvailable = numSamples;

}

- (void)mixFFTResults:(LiveFFTResults)fftResults1 forChannel:(SInt32)channelID withVolume:(float)volume
{
    UInt64 numChunks = channelID == 1 ? mixedAudioData.channel1.fftResults.numChunksAvailable : mixedAudioData.channel2.fftResults.numChunksAvailable;
    
    if (numChunks > fftResults1.numChunksAvailable || numChunks > self.chunksMemoryLimit)
        numChunks = MIN(self.chunksMemoryLimit,fftResults1.numChunksAvailable);
    
    float (*mixedFFTResults)[CHUNK_SIZE] = channelID == 1 ? (float (*)[CHUNK_SIZE])mixedFFTResults1 : (float (*)[CHUNK_SIZE])mixedFFTResults2;
    float (*fftResultsData)[CHUNK_SIZE] = (float (*)[CHUNK_SIZE])fftResults1.data;
    for (int i=0;i<numChunks;i++)
    {
        float modifiedChunk[CHUNK_SIZE];
        AmplitudeFactor(fftResultsData[i], CHUNK_SIZE, volume, modifiedChunk);
        Mix(mixedFFTResults[i], modifiedChunk, mixedFFTResults[i], CHUNK_SIZE);
    }
    if (channelID == 1) mixedAudioData.channel1.fftResults.numChunksAvailable = numChunks;
    else if (channelID == 2) mixedAudioData.channel2.fftResults.numChunksAvailable = numChunks;
}

-(SInt64)numChunksAvailableForChannelID:(UInt32)channelID
{
    SInt64 min = 0;
    for (AudioMixerChannel *channel in self.channels)
    {
        if (!channel.isActive) continue;
        
        LiveAudioData audioData = channel.liveAudioData;
        SInt64 numChunksAvailable = channelID == 1 ? audioData.channel1.fftResults.numChunksAvailable : audioData.channel2.fftResults.numChunksAvailable;
        if (numChunksAvailable > self.chunksMemoryLimit) numChunksAvailable = self.chunksMemoryLimit;
        if (min == 0 || numChunksAvailable < min) min = numChunksAvailable;
    }
    
    return min;
}

- (SInt64)numSamplesAvailableForChannelID:(UInt32)channelID
{
    SInt64 min = 0;
    for (AudioMixerChannel *channel in self.channels)
    {
        if (!channel.isActive) continue;
        
        LiveAudioData audioData = channel.liveAudioData;
        SInt64 numSamplesAvailable = channelID == 1 ? audioData.channel1.samples.numSamplesAvailable : audioData.channel2.samples.numSamplesAvailable;
        if (numSamplesAvailable > self.memoryLimit) numSamplesAvailable = self.memoryLimit;
        if (min == 0 || numSamplesAvailable < min) min = numSamplesAvailable;
    }
    
    return min;
}

- (NSArray *)activeChannels
{
    NSMutableArray *result = [[NSMutableArray alloc] init];
    for (AudioMixerChannel *channel in self.channels)
    {
        if (channel.isActive) [result addObject:channel];
    }
    return [result copy];
}

- (enum AudioSupplyMode)audioSupplyMode
{
    // return regular if at least one chnanel is active
    
    for (AudioMixerChannel *channel in self.channels)
    {
        if (channel.isActive)
        {
            return AudioSupplyMode_Regular;
        }
    }
    return AudioSupplyMode_NotSupplying;
}

- (SInt32)memoryLimit
{
    return _memoryLimit;
}

- (void)setMemoryLimit:(SInt32)memoryLimit
{
    _memoryLimit = memoryLimit;
    
    SInt32 storedSamples = memoryLimit;
    SInt32 storedChunks = self.chunksMemoryLimit;
    
    mixedFFTResults1 = realloc(mixedFFTResults1, sizeof(float[storedChunks][CHUNK_SIZE]));
    mixedSamples1 = realloc(mixedSamples1, sizeof(float[storedSamples]));
    mixedFFTResults2 = realloc(mixedFFTResults2, sizeof(float[storedChunks][CHUNK_SIZE]));
    mixedSamples2 = realloc(mixedSamples2, sizeof(float[storedSamples]));
    
    mixedAudioData.channel1.fftResults.data = mixedFFTResults1;
    mixedAudioData.channel1.samples.data = mixedSamples1;
    mixedAudioData.channel2.fftResults.data = mixedFFTResults2;
    mixedAudioData.channel2.samples.data = mixedSamples2;
}

- (SInt32)chunksMemoryLimit
{
    return self.memoryLimit / 400;
}

- (void)cleanup
{
    NSMutableArray *toDelete= [NSMutableArray array];
    for (AudioMixerChannel *channel in self.channels)
    {
        if (channel.isDestroyed) [toDelete addObject:channel];
    }
    [self.channels removeObjectsInArray:toDelete];
}

- (void)dealloc
{
    free(mixedFFTResults1);
    free(mixedSamples1);
    free(mixedFFTResults2);
    free(mixedSamples2);
}

/*- (LiveAudioData)liveAudioData
{
    return (LiveAudioData){0,0,0};
}*/

@end

@implementation AudioMixerChannel

@synthesize liveAudioData = _liveAudioData;

- (id)initWithAudioSupplier:(id<LiveAudioSupplier>)audioSupplier
{
    self = [super init];
    self.audioSupplier = audioSupplier;
    self.volume = 1.0f;
    self.isDestroyed = NO;
    return self;
}

- (void)startFadingInWithDuration:(CGFloat)fadeTimeInSeconds
{
    self.volume = 0.0;
    self.fadeStartTime = mach_absolute_time();
    self.totalFadeTimeInSeconds = fadeTimeInSeconds;
    self.isFadingIn = YES;
}

- (void)startFadingOutWithDuration:(CGFloat)fadeTimeInSeconds
{
    self.fadeStartTime = mach_absolute_time();
    self.totalFadeTimeInSeconds = fadeTimeInSeconds;
    self.isFadingOut = YES;
}

- (void)update
{
    CGFloat secondsIntoFade = machToMiliseconds(mach_absolute_time() - self.fadeStartTime) / 1000.0;
    if (secondsIntoFade > self.totalFadeTimeInSeconds) secondsIntoFade = self.totalFadeTimeInSeconds;
    
    if (self.isFadingIn)
    {
        CGFloat initialSpeed = 2*1.0f/self.totalFadeTimeInSeconds * 10/11; // must be |initialSpeed| > initialVolume / totalFadeTime
        CGFloat acceleration = -2*1.0 / powf(self.totalFadeTimeInSeconds,2) * 9 /11;
        self.volume = initialSpeed*secondsIntoFade + 0.5 * acceleration*powf(secondsIntoFade, 2);
        if (self.volume >= 1.0)
        {
            self.volume = 1.0f;
            self.isFadingIn = NO;
        }
    }
    if (self.isFadingOut)
    {
        CGFloat initialSpeed = 2*-1.0f/self.totalFadeTimeInSeconds * 10/11;
        CGFloat acceleration = -2*-1.0 / powf(self.totalFadeTimeInSeconds,2) * 9 /11;
        self.volume = 1.0 + initialSpeed*secondsIntoFade + 0.5 * acceleration*powf(secondsIntoFade, 2);
        if (self.volume <= 0.0)
        {
            self.volume = 0.0f;
            self.isFadingOut = NO;
            self.isDestroyed = YES;
        }
    }
}

- (LiveAudioData)liveAudioData
{
    LiveAudioData audioData = self.audioSupplier.liveAudioData;
    //if (self.audioSupplier.audioSupplyMode == AudioSupplyMode_Regular && audioData.channel1.fftResults.numChunksAvailable > 0)
    if (audioData.channel1.containsData || true)
    {
        _liveAudioData = audioData;
    }
    
    return _liveAudioData;
}

- (BOOL)isActive
{
    return self.liveAudioData.channel1.containsData;
    //return (self.isFadingIn || self.isFadingOut || self.audioSupplier.audioSupplyMode == AudioSupplyMode_Regular) && self.liveAudioData.channel1.containsData;
}

@end
