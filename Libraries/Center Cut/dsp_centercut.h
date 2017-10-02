typedef signed long long	sint64;
typedef unsigned long long	uint64;
typedef signed int			sint32;
typedef unsigned int		uint32;
typedef signed short		sint16;
typedef unsigned short		uint16;
typedef signed char			sint8;
typedef unsigned char		uint8;

typedef sint64				int64;
typedef sint32				int32;
typedef sint16				int16;
typedef sint8				int8;

#if defined __cplusplus
extern "C" {
#endif
int CenterCutProcessSamples(uint8 *inSamples, int inSampleCount, uint8 *outSamples, int bitsPerSample, int sampleRate, bool outputCenter, bool bassToSides);
int Init_CenterCut();
void VDComputeFHT(double *A, int nPoints, const double *sinTab);
    
#if defined __cplusplus
}
#endif

static inline int min(int a, int b) { return a>b ? b : a; };
