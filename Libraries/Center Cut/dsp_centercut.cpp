/*******************************************************************************
*                                                                              *
* Center Cut DSP Plugin for Winamp 2/5                                         *
* Copyright (C) 2004-2007  Moitah (moitah@yahoo.com)                           *
*                                                                              *
* This program is free software; you can redistribute it and/or modify         *
* it under the terms of the GNU General Public License as published by         *
* the Free Software Foundation; either version 2 of the License, or            *
* (at your option) any later version.                                          *
*                                                                              *
* This program is distributed in the hope that it will be useful,              *
* but WITHOUT ANY WARRANTY; without even the implied warranty of               *
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the                *
* GNU General Public License for more details.                                 *
*                                                                              *
* You should have received a copy of the GNU General Public License            *
* along with this program; if not, write to the Free Software                  *
* Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA    *
*                                                                              *
*******************************************************************************/

#include <math.h>
#include <memory>
#include "dsp_centercut.h"

bool			mInitialized = false;

const int		kWindowSize = 8192;
const int		kOverlapCount = 4;
const int		kPostWindowPower = 2;  // Maximum power including pre-window is kOverlapCount-1,
// which means this can be kOverlapCount-2 at most
const int		kHalfWindow = kWindowSize / 2;
const int		kOverlapSize = kWindowSize / kOverlapCount;

const double	twopi = 6.283185307179586476925286766559;
const double	invsqrt2 = 0.70710678118654752440084436210485;
const double	nodivbyzero = 0.000000000000001;

const int		BYTES_TO_DOUBLE = 0;
const int		DOUBLE_TO_BYTES = 1;
const int		FLOAT_TO_DOUBLE = 2;
const int		DOUBLE_TO_FLOAT = 3;

const int		mOutputSampleCount = kOverlapSize;
const int		mOutputMaxBuffers = 32;
int				mOutputReadSampleOffset;
int				mOutputBufferCount;  // How many buffers are actually in use (there may be more
// allocated than in use)
double			*mOutputBuffer[mOutputMaxBuffers];

int				mSampleRate;
bool			mOutputCenter;
bool			mBassToSides;
int				mOutputDiscardBlocks;
uint32			mInputSamplesNeeded;
uint32			mInputPos;
unsigned		mBitRev[kWindowSize];
double			mPreWindow[kWindowSize];
double			mPostWindow[kWindowSize];
double			mSineTab[kWindowSize];
double			mInput[kWindowSize][2];
double			mOverlapC[kOverlapCount-1][kOverlapSize];
double			mTempLBuffer[kWindowSize];
double			mTempRBuffer[kWindowSize];
double			mTempCBuffer[kWindowSize];


int Init_CenterCut(struct winampDSPModule *thisModule);
int ModifySamples_Sides(uint8 *samples, int sampleCount, int bitsPerSample, int chanCount, int sampleRate);
int ModifySamples_Center(uint8 *samples, int sampleCount, int bitsPerSample, int chanCount, int sampleRate);
int ModifySamples_SidesBTS(uint8 *samples, int sampleCount, int bitsPerSample, int chanCount, int sampleRate);
int ModifySamples_CenterBTS(uint8 *samples, int sampleCount, int bitsPerSample, int chanCount, int sampleRate);
int ModifySamples_Classic(uint8 *samples, int sampleCount, int bitsPerSample, int chanCount, int sampleRate);
int CenterCutProcessSamples(uint8 *inSamples, int inSampleCount, uint8 *outSamples, int bitsPerSample, int sampleRate, bool outputCenter, bool bassToSides);
void ConvertSamples(int type, uint8 *sampB, double *sampD, int sampleCount, int bitsPerSample, int chanCount);
void OutputBufferInit();
void OutputBufferFree();
void OutputBufferReadComplete();
bool OutputBufferBeginWrite();
bool BPSIsValid(int bitsPerSample);
bool CenterCut_Start();
void CenterCut_Finish();
bool CenterCut_Run();

int Init_CenterCut() 
{
	OutputBufferInit();
	CenterCut_Start();
	mInitialized = true;
	return 0;
}

int CenterCutProcessSamples(uint8 *inSamples, int inSampleCount, uint8 *outSamples, int bitsPerSample, int sampleRate, bool outputCenter, bool bassToSides) 
{
	int bytesPerSample, outSampleCount, maxOutSampleCount, copyCount;

	mSampleRate = sampleRate;
	mOutputCenter = outputCenter;
	mBassToSides = bassToSides;
	bytesPerSample = bitsPerSample / 8;
	outSampleCount = 0;
	maxOutSampleCount = inSampleCount;

	while (inSampleCount > 0) 
	{
		copyCount = min((int)mInputSamplesNeeded, inSampleCount);

		ConvertSamples(FLOAT_TO_DOUBLE, inSamples, &mInput[mInputPos][0], copyCount, bitsPerSample, 2);

		inSamples += copyCount * bytesPerSample * 2;
		inSampleCount -= copyCount;
		mInputPos = (mInputPos + copyCount) & (kWindowSize-1);
		mInputSamplesNeeded -= copyCount;

		if (mInputSamplesNeeded == 0) 
		{
			CenterCut_Run();
		}
	}

	while ((mOutputBufferCount > 0) && (outSampleCount < maxOutSampleCount)) 
	{
		double *sampD = mOutputBuffer[0];
		if (!sampD) return -1;

		copyCount = min(mOutputSampleCount - mOutputReadSampleOffset,
			maxOutSampleCount - outSampleCount);

		ConvertSamples(DOUBLE_TO_FLOAT, outSamples, sampD + (mOutputReadSampleOffset * 2), copyCount, bitsPerSample, 2);

		outSamples += copyCount * bytesPerSample * 2;
		outSampleCount += copyCount;
		mOutputReadSampleOffset += copyCount;
		if (mOutputReadSampleOffset == mOutputSampleCount) 
		{
			OutputBufferReadComplete();
		}
	}
	return outSampleCount;
}

void ConvertSamples(int type, uint8 *sampB, double *sampD, int sampleCount, int bitsPerSample, int chanCount) 
{
	const double SampleScaleInv = 32768.0;
	const double SampleScale = 1.0 / SampleScaleInv;
	const double SampleMin = -2147483648.0;
	const double SampleMax = 2147483647.0;

	int bytesPerSample, shiftCount;
	sint32 _xor;
	uint8 *max;

	bytesPerSample = (bitsPerSample + 7) / 8;
	shiftCount = (4 - bytesPerSample) * 8;
	_xor = (bytesPerSample == 1) ? (1 << 31) : 0;
	max = sampB + (sampleCount * bytesPerSample * chanCount);

	if (type == BYTES_TO_DOUBLE) 
	{
		sint32 tempI;

		while (sampB < max) {
			tempI = (*((sint32*)sampB) << shiftCount) ^ _xor;
			*sampD = (double)tempI * SampleScale;

			sampB += bytesPerSample;
			sampD += 1;
		}
	}
	else if (type == DOUBLE_TO_BYTES)
	{
		uint8 *maxw = max - 3;
		double tempD;
		uint32 tempI;

		while (sampB < max) {
			tempD = *sampD * SampleScaleInv;
			if (tempD > 0.0) {
				if (tempD > SampleMax) 
				{
					tempD = SampleMax;
				}
				tempD += 0.5;
			}
			else {
				if (tempD < SampleMin) 
				{
					tempD = SampleMin;
				}
				tempD -= 0.5;
			}
			tempI = (uint32)((sint32)tempD ^ _xor) >> shiftCount;

			if (sampB < maxw) {
				*((uint32*)sampB) = tempI;
			}
			else {
				memcpy(sampB, &tempI, bytesPerSample);
			}

			sampB += bytesPerSample;
			sampD += 1;
		}
	}
	else if (type == FLOAT_TO_DOUBLE)
	{
		float *floatArray = (float *)sampB;
		for (int i=0;i<sampleCount*chanCount;i++)
		{
			sampD[i] = (double)floatArray[i];
		}
	}
	else if (type == DOUBLE_TO_FLOAT)
	{
		float *floatArray = (float *)sampB;
		for (int i=0;i<sampleCount*chanCount;i++)
		{
			floatArray[i] = (float)sampD[i];
		}
	}
}

void OutputBufferInit() {
	for (int i = 0; i < mOutputMaxBuffers; i++) {
		mOutputBuffer[i] = 0;
	}
	mOutputBufferCount = 0;
	mOutputReadSampleOffset = 0;
}

void OutputBufferFree() {
	for (int i = 0; i < mOutputMaxBuffers; i++) {
		if (mOutputBuffer[i]) {
			delete[] mOutputBuffer[i];
			mOutputBuffer[i] = 0;
		}
	}
}

void OutputBufferReadComplete() {
	mOutputBufferCount--;
	mOutputReadSampleOffset = 0;
	if (mOutputBufferCount > 0) {
		int i;
		double *moveToEnd = mOutputBuffer[0];

		// Shift the buffers so that the current one for reading is at index 0
		for (i = 1; i < mOutputMaxBuffers; i++) {
			mOutputBuffer[i - 1] = mOutputBuffer[i];
		}
		mOutputBuffer[mOutputMaxBuffers - 1] = 0;

		// Move the previous first buffer to the end (first null pointer)
		for (i = 0; i < mOutputMaxBuffers; i++) {
			if (!mOutputBuffer[i]) {
				mOutputBuffer[i] = moveToEnd;
				break;
			}
		}
	}
}

bool OutputBufferBeginWrite() {
	if (mOutputBufferCount == mOutputMaxBuffers) {
		return false;
	}

	int i = mOutputBufferCount;
	if (!mOutputBuffer[i]) {
		// No buffer exists at this index, make a new one
		mOutputBuffer[i] = new double[mOutputSampleCount * 2];
		if (!mOutputBuffer[i]) {
			return false;
		}
	}

	mOutputBufferCount++;
	return true;
}

bool BPSIsValid(int bitsPerSample) {
	// Bits per sample must be between 8 and 32 bits, and a multiple of 8
	return (bitsPerSample >= 8) && (bitsPerSample <= 32) && ((bitsPerSample & 7) == 0);
}

unsigned IntegerLog2(unsigned v) {
	unsigned i = 0;

	while(v>1) {
		++i;
		v >>= 1;
	}

	return i;
}

unsigned RevBits(unsigned x, unsigned bits) {
	unsigned y = 0;

	while(bits--) {
		y = (y+y) + (x&1);
		x >>= 1;
	}

	return y;
}

void VDCreateRaisedCosineWindow(double *dst, int n, double power) {
	const double twopi_over_n = twopi / n;
	const double scalefac = 1.0 / n;

	for(int i=0; i<n; ++i) {
		dst[i] = scalefac * pow(0.5*(1.0 - cos(twopi_over_n * (i+0.5))), power);
	}
}

void VDCreateHalfSineTable(double *dst, int n) {
	const double twopi_over_n = twopi / n;

	for(int i=0; i<n; ++i) {
		dst[i] = sin(twopi_over_n * i);
	}
}

void VDCreateBitRevTable(unsigned *dst, int n) {
	unsigned bits = IntegerLog2(n);

	for(int i=0; i<n; ++i) {
		dst[i] = RevBits(i, bits);
	}
}

void CreatePostWindow(double *dst, int windowSize, int power) {
	const double powerIntegrals[8] = { 1.0, 1.0/2.0, 3.0/8.0, 5.0/16.0, 35.0/128.0,
		63.0/256.0, 231.0/1024.0, 429.0/2048.0 };
	const double scalefac = (double)windowSize * (powerIntegrals[1] / powerIntegrals[power+1]);

	VDCreateRaisedCosineWindow(dst, windowSize, (double)power);

	for(int i=0; i<windowSize; ++i) {
		dst[i] *= scalefac;
	}
}

bool CenterCut_Start() {
	VDCreateBitRevTable(mBitRev, kWindowSize);
	VDCreateHalfSineTable(mSineTab, kWindowSize);

	mInputSamplesNeeded = kOverlapSize;
	mInputPos = 0;

	mOutputDiscardBlocks = kOverlapCount - 1;

	memset(mInput, 0, sizeof mInput);
	memset(mOverlapC, 0, sizeof mOverlapC);

	double *tmp = new double[kWindowSize];
	if (!tmp) return false;
	VDCreateRaisedCosineWindow(tmp, kWindowSize, 1.0);
	for(unsigned i=0; i<kWindowSize; ++i) {
		// The correct Hartley<->FFT conversion is:
		//
		//	Fr(i) = 0.5(Hr(i) + Hi(i))
		//	Fi(i) = 0.5(Hr(i) - Hi(i))
		//
		// We omit the 0.5 in both the forward and reverse directions,
		// so we have a 0.25 to put here.

		mPreWindow[i] = tmp[mBitRev[i]] * 0.5 * (2.0 / (double)kOverlapCount);
	}
	delete[] tmp;

	CreatePostWindow(mPostWindow, kWindowSize, kPostWindowPower);

	return true;
}

void CenterCut_Finish() {
}

bool CenterCut_Run() 
{
	unsigned i;
	int freqBelowToSides = (int)((200.0 / ((double)mSampleRate / kWindowSize)) + 0.5);

	// copy to temporary buffer and FHT

	for(i=0; i<kWindowSize; ++i) {
		const unsigned j = mBitRev[i];
		const unsigned k = (j + mInputPos) & (kWindowSize-1);
		const double w = mPreWindow[i];

		mTempLBuffer[i] = mInput[k][0] * w;
		mTempRBuffer[i] = mInput[k][1] * w;
	}

	VDComputeFHT(mTempLBuffer, kWindowSize, mSineTab);
	VDComputeFHT(mTempRBuffer, kWindowSize, mSineTab);

	// perform stereo separation

	mTempCBuffer[0] = 0;
	mTempCBuffer[1] = 0;
	for(i=1; i<kHalfWindow; i++) {
		double lR = mTempLBuffer[i] + mTempLBuffer[kWindowSize-i];
		double lI = mTempLBuffer[i] - mTempLBuffer[kWindowSize-i];
		double rR = mTempRBuffer[i] + mTempRBuffer[kWindowSize-i];
		double rI = mTempRBuffer[i] - mTempRBuffer[kWindowSize-i];

		double sumR = lR + rR;
		double sumI = lI + rI;
		double diffR = lR - rR;
		double diffI = lI - rI;

		double sumSq = sumR*sumR + sumI*sumI;
		double diffSq = diffR*diffR + diffI*diffI;
		double alpha = 0.0;

		if (sumSq > nodivbyzero) {
			alpha = 0.5 - sqrt(diffSq / sumSq) * 0.5;
		}

		double cR = sumR * alpha;
		double cI = sumI * alpha;

		if (mBassToSides && (i < freqBelowToSides)) {
			cR = cI = 0.0;
		}

		mTempCBuffer[mBitRev[i            ]] = cR + cI;
		mTempCBuffer[mBitRev[kWindowSize-i]] = cR - cI;
	}

	// reconstitute left/right/center channels

	VDComputeFHT(mTempCBuffer, kWindowSize, mSineTab);

	// apply post-window

	for (i=0; i<kWindowSize; i++) {
		mTempCBuffer[i] *= mPostWindow[i];
	}

	// writeout

	if (mOutputDiscardBlocks > 0) {
		mOutputDiscardBlocks--;
	}
	else {
		int currentBlockIndex, nextBlockIndex, blockOffset;

		if (!OutputBufferBeginWrite()) return false;
		double *outBuffer = mOutputBuffer[mOutputBufferCount - 1];
		if (!outBuffer) return false;

		for(i=0; i<kOverlapSize; ++i) {
			double c = mOverlapC[0][i] + mTempCBuffer[i];
			double l = mInput[mInputPos+i][0] - c;
			double r = mInput[mInputPos+i][1] - c;

			if (mOutputCenter) {
				outBuffer[0] = c;
				outBuffer[1] = c;
			}
			else {
				outBuffer[0] = l;
				outBuffer[1] = r;
			}
			outBuffer += 2;

			// overlapping

			currentBlockIndex = 0;
			nextBlockIndex = 1;
			blockOffset = kOverlapSize;
			while (nextBlockIndex < kOverlapCount - 1) {
				mOverlapC[currentBlockIndex][i] = mOverlapC[nextBlockIndex][i] + mTempCBuffer[blockOffset + i];

				currentBlockIndex++;
				nextBlockIndex++;
				blockOffset += kOverlapSize;
			}
			mOverlapC[currentBlockIndex][i] = mTempCBuffer[blockOffset + i];
		}
	}

	mInputSamplesNeeded = kOverlapSize;

	return true;
}

// ---
// Remember to call the init method(s) first!
// ---
bool ExtractCenterChannel(float *samples, int numSamples, int sampleRate, bool outputCenter, bool bassToSides, float *results) 
{
	unsigned i;
	int freqBelowToSides = (int)((200.0 / ((double)mSampleRate / kWindowSize)) + 0.5);

	// copy to temporary buffer and FHT

	for(i=0; i<kWindowSize; ++i) {
		const unsigned j = mBitRev[i];
		const unsigned k = (j + mInputPos) & (kWindowSize-1);
		const double w = mPreWindow[i];

		mTempLBuffer[i] = mInput[k][0] * w;
		mTempRBuffer[i] = mInput[k][1] * w;
	}

	VDComputeFHT(mTempLBuffer, kWindowSize, mSineTab);
	VDComputeFHT(mTempRBuffer, kWindowSize, mSineTab);

	// perform stereo separation

	mTempCBuffer[0] = 0;
	mTempCBuffer[1] = 0;
	for(i=1; i<kHalfWindow; i++) {
		double lR = mTempLBuffer[i] + mTempLBuffer[kWindowSize-i];
		double lI = mTempLBuffer[i] - mTempLBuffer[kWindowSize-i];
		double rR = mTempRBuffer[i] + mTempRBuffer[kWindowSize-i];
		double rI = mTempRBuffer[i] - mTempRBuffer[kWindowSize-i];

		double sumR = lR + rR;
		double sumI = lI + rI;
		double diffR = lR - rR;
		double diffI = lI - rI;

		double sumSq = sumR*sumR + sumI*sumI;
		double diffSq = diffR*diffR + diffI*diffI;
		double alpha = 0.0;

		if (sumSq > nodivbyzero) {
			alpha = 0.5 - sqrt(diffSq / sumSq) * 0.5;
		}

		double cR = sumR * alpha;
		double cI = sumI * alpha;

		if (mBassToSides && (i < freqBelowToSides)) {
			cR = cI = 0.0;
		}

		mTempCBuffer[mBitRev[i            ]] = cR + cI;
		mTempCBuffer[mBitRev[kWindowSize-i]] = cR - cI;
	}

	// reconstitute left/right/center channels

	VDComputeFHT(mTempCBuffer, kWindowSize, mSineTab);

	// apply post-window

	for (i=0; i<kWindowSize; i++) {
		mTempCBuffer[i] *= mPostWindow[i];
	}

	// writeout

	if (mOutputDiscardBlocks > 0) {
		mOutputDiscardBlocks--;
	}
	else {
		int currentBlockIndex, nextBlockIndex, blockOffset;

		if (!OutputBufferBeginWrite()) return false;
		double *outBuffer = mOutputBuffer[mOutputBufferCount - 1];
		if (!outBuffer) return false;

		for(i=0; i<kOverlapSize; ++i) {
			double c = mOverlapC[0][i] + mTempCBuffer[i];
			double l = mInput[mInputPos+i][0] - c;
			double r = mInput[mInputPos+i][1] - c;

			if (mOutputCenter) {
				outBuffer[0] = c;
				outBuffer[1] = c;
			}
			else {
				outBuffer[0] = l;
				outBuffer[1] = r;
			}
			outBuffer += 2;

			// overlapping

			currentBlockIndex = 0;
			nextBlockIndex = 1;
			blockOffset = kOverlapSize;
			while (nextBlockIndex < kOverlapCount - 1) {
				mOverlapC[currentBlockIndex][i] = mOverlapC[nextBlockIndex][i] +
					mTempCBuffer[blockOffset + i];

				currentBlockIndex++;
				nextBlockIndex++;
				blockOffset += kOverlapSize;
			}
			mOverlapC[currentBlockIndex][i] = mTempCBuffer[blockOffset + i];
		}
	}

	mInputSamplesNeeded = kOverlapSize;

	return true;
}


void VDComputeFHT(double *A, int nPoints, const double *sinTab) 
{
	int i, n, n2, theta_inc;

	// FHT - stage 1 and 2 (2 and 4 points)

	for(i=0; i<nPoints; i+=4) {
		const double	x0 = A[i];
		const double	x1 = A[i+1];
		const double	x2 = A[i+2];
		const double	x3 = A[i+3];

		const double	y0 = x0+x1;
		const double	y1 = x0-x1;
		const double	y2 = x2+x3;
		const double	y3 = x2-x3;

		A[i]	= y0 + y2;
		A[i+2]	= y0 - y2;

		A[i+1]	= y1 + y3;
		A[i+3]	= y1 - y3;
	}

	// FHT - stage 3 (8 points)

	for(i=0; i<nPoints; i+= 8) {
		double alpha, beta;

		alpha	= A[i+0];
		beta	= A[i+4];

		A[i+0]	= alpha + beta;
		A[i+4]	= alpha - beta;

		alpha	= A[i+2];
		beta	= A[i+6];

		A[i+2]	= alpha + beta;
		A[i+6]	= alpha - beta;

		alpha	= A[i+1];

		const double beta1 = invsqrt2*(A[i+5] + A[i+7]);
		const double beta2 = invsqrt2*(A[i+5] - A[i+7]);

		A[i+1]	= alpha + beta1;
		A[i+5]	= alpha - beta1;

		alpha	= A[i+3];

		A[i+3]	= alpha + beta2;
		A[i+7]	= alpha - beta2;
	}

	n = 16;
	n2 = 8;
	theta_inc = nPoints >> 4;

	while(n <= nPoints) {
		for(i=0; i<nPoints; i+=n) {
			int j;
			int theta = theta_inc;
			double alpha, beta;
			const int n4 = n2>>1;

			alpha	= A[i];
			beta	= A[i+n2];

			A[i]	= alpha + beta;
			A[i+n2]	= alpha - beta;

			alpha	= A[i+n4];
			beta	= A[i+n2+n4];

			A[i+n4]		= alpha + beta;
			A[i+n2+n4]	= alpha - beta;

			for(j=1; j<n4; j++) {
				double	sinval	= sinTab[theta];
				double	cosval	= sinTab[theta + (nPoints>>2)];

				double	alpha1	= A[i+j];
				double	alpha2	= A[i-j+n2];
				double	beta1	= A[i+j+n2]*cosval + A[i-j+n ]*sinval;
				double	beta2	= A[i+j+n2]*sinval - A[i-j+n ]*cosval;

				theta	+= theta_inc;

				A[i+j]		= alpha1 + beta1;
				A[i+j+n2]	= alpha1 - beta1;
				A[i-j+n2]	= alpha2 + beta2;
				A[i-j+n]	= alpha2 - beta2;
			}
		}

		n *= 2;
		n2 *= 2;
		theta_inc >>= 1;
	}
}

int ModifySamples_Sides(uint8 *samples, int sampleCount, int bitsPerSample, int chanCount, int sampleRate) {
	if ((chanCount == 2) && (sampleCount > 0) && BPSIsValid(bitsPerSample) && mInitialized) {
		int outSampleCount = CenterCutProcessSamples(samples, sampleCount, samples, bitsPerSample, sampleRate, false, false);

		if (outSampleCount >= 0) {
			sampleCount = outSampleCount;
		}
	}

	return sampleCount;
}

int ModifySamples_Center(uint8 *samples, int sampleCount, int bitsPerSample, int chanCount, int sampleRate) {
	if ((chanCount == 2) && (sampleCount > 0) && BPSIsValid(bitsPerSample) && mInitialized) {
		int outSampleCount = CenterCutProcessSamples(samples, sampleCount, samples, bitsPerSample, sampleRate, true, false);

		if (outSampleCount >= 0) {
			sampleCount = outSampleCount;
		}
	}

	return sampleCount;
}

int ModifySamples_SidesBTS(uint8 *samples, int sampleCount, int bitsPerSample, int chanCount, int sampleRate) {
	if ((chanCount == 2) && (sampleCount > 0) && BPSIsValid(bitsPerSample) && mInitialized) {
		int outSampleCount = CenterCutProcessSamples(samples, sampleCount, samples, bitsPerSample, sampleRate, false, true);

		if (outSampleCount >= 0) {
			sampleCount = outSampleCount;
		}
	}

	return sampleCount;
}

int ModifySamples_CenterBTS(uint8 *samples, int sampleCount, int bitsPerSample, int chanCount, int sampleRate) {
	if ((chanCount == 2) && (sampleCount > 0) && BPSIsValid(bitsPerSample) && mInitialized) {
		int outSampleCount = CenterCutProcessSamples(samples, sampleCount, samples, bitsPerSample, sampleRate, true, true);

		if (outSampleCount >= 0) {
			sampleCount = outSampleCount;
		}
	}

	return sampleCount;
}

int ModifySamples_Classic(uint8 *samples, int sampleCount, int bitsPerSample, int chanCount, int sampleRate) {
	if ((chanCount == 2) && sampleCount && BPSIsValid(bitsPerSample)) {
		double *sampD = new double[sampleCount*chanCount];
		double *tmp = sampD;

		ConvertSamples(BYTES_TO_DOUBLE, samples, sampD, sampleCount, bitsPerSample, chanCount);

		for (int i = 0; i < sampleCount; i++) {
			double diff = (tmp[0] - tmp[1]) * 0.5;
			tmp[1] = tmp[0] = diff;
			tmp += 2;
		}

		ConvertSamples(DOUBLE_TO_BYTES, samples, sampD, sampleCount, bitsPerSample, chanCount);

		delete[] sampD;
	}

	return sampleCount;
}