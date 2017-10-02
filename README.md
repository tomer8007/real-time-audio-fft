# Real-time audio analysis and FFT for iOS
This library helps you visualize or process sound as it is played by providing you with a currently-played spectrum data and samples, at any given time.

# How to use
For playing audio files:
## Initialization
    NSURL *url = [[NSBundle mainBundle] URLForResource:@"My Song" withExtension:@"mp3"];
    [self.audioFile loadAudioWithURL:url withCompletionCallback:^(NSError *error)
    {
        /* check error */
        
        // Let it play...
        error = [self.audioFile play];
        
        /* check error again */
    }];`
## Getting live data
    // Later in the program, for example in your update() function...
    LiveAudioData realtimeAudioData = self.audioFile.liveAudioData;
    LiveAudioChannelData leftChannel = realtimeAudioData.channel1;
    
    if (leftChannel.containsData)
    {
        // Get realtime frequencies data and waveform as pure float arrays
        float (*fftResults)[CHUNK_SIZE] = (float (*)[CHUNK_SIZE])leftChannel.fftResults.data;
        float *waveform = leftChannel.samples.data;
        UInt64 numFFTChunksAvailable = leftChannel.fftResults.numChunksAvailable;
        UInt64 numSamplesAvailable = leftChannel.samples.numSamplesAvailable;
        
        // Process the spectrum or the samples in various ways,
        // e.g drawing them to screen to create audio visualizations
        
        int frequency = 70;
        int bin = FrequencyToBinIndex(frequency, self.audioFile.playedAudioFormat.mSampleRate, CHUNK_SIZE);
        float bassMagnitudeInChannel1 = fftResults[0][bin];
        int height = bassMagnitudeInChannel1 / 2;
        self.band1.frame = CGRectMake(50, 500 - height, 15, height);
        
        // etc.
    }

