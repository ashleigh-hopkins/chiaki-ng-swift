#import "VideoDecoderClient.h"

typedef struct {
  CNVideoSubmitResult result;
  OSStatus status;
  BOOL configuring;
} CNEncodedVideoSubmission;

@interface CNLiveEncodedVideo : NSObject
/// Decodes to 10-bit surfaces for HEVC streams. Prefer ``initWithHEVC:tenBit:``.
- (instancetype)initWithHEVC:(BOOL)hevc;
/// `tenBit` picks 10-bit decoder output, which HDR needs. SDR decodes to 8-bit so that frame
/// interpolation, which takes 8-bit frames only, can use it; an 8-bit Main stream decodes exactly.
- (instancetype)initWithHEVC:(BOOL)hevc tenBit:(BOOL)tenBit;
@property(nonatomic) BOOL hevc;
@property(nonatomic, readonly) BOOL tenBit;
@property(nonatomic, readonly) NSUInteger rebuilds;
- (CNEncodedVideoSubmission)submit:(const uint8_t *)bytes
                            length:(size_t)length
                            header:(const uint8_t *)header
                      headerLength:(size_t)headerLength
                            output:(CNVideoOutput)output;
- (void)stop;
@end
