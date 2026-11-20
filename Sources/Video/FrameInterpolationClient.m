#import "FrameInterpolationClient.h"
#import <TargetConditionals.h>
#include <stdatomic.h>

#if TARGET_OS_SIMULATOR

@implementation CNFrameInterpolationClient {
  atomic_bool _enabled;
  atomic_bool _stopped;
  _Atomic NSUInteger _bypassed;
}

- (BOOL)supported {
  return NO;
}

- (void)setSourceFrameRate:(NSInteger)frameRate {
}

- (void)setEnabled:(BOOL)enabled {
  atomic_store_explicit(&_enabled, enabled, memory_order_relaxed);
}

- (void)offer:(CVPixelBufferRef)frame handler:(CNInterpolatedFrameHandler)handler {
  if (atomic_load_explicit(&_stopped, memory_order_relaxed)) {
    return;
  }
  atomic_fetch_add_explicit(&_bypassed, 1, memory_order_relaxed);
  handler(frame, NO);
}

- (NSDictionary<NSString *, NSNumber *> *)statistics {
  return @{
    @"supported" : @NO,
    @"enabled" : @(atomic_load_explicit(&_enabled, memory_order_relaxed)),
    @"generated" : @0,
    @"bypassed" : @(atomic_load_explicit(&_bypassed, memory_order_relaxed)),
    @"failures" : @0
  };
}

- (void)stop {
  atomic_store_explicit(&_stopped, true, memory_order_relaxed);
}

@end

#else

#import <CoreMedia/CoreMedia.h>
#import <IOSurface/IOSurfaceRef.h>
#import <VideoToolbox/VTFrameProcessor.h>
#import <VideoToolbox/VTFrameProcessor_LowLatencyFrameInterpolation.h>
#include <pthread.h>
#include <stdlib.h>
#include <time.h>

// At 1080p one interpolation takes about 15 ms on Apple silicon, close to the 16.7 ms between
// 60 fps frames, and some take longer. Two interpolations in flight keep up with the stream;
// one at a time does not.
static const NSUInteger kMaximumInFlight = 2;
// Frames waiting behind unfinished interpolations. Past this, the oldest unfinished
// interpolations are given up so that decoded frames are not held back.
static const NSUInteger kMaximumWaiting = 4;
// The longest a decoded frame waits for the frame interpolated before it, in source frame
// intervals, once a newer frame has arrived. A later interpolation is given up and the decoded
// frame goes out without it, so a busy GPU costs smoothness, not latency.
static const double kMaximumHoldIntervals = 1.5;
// A frame repeats the frame before it when their luma, sampled on a sparse grid, differs by less
// than kRepeatMean on average, and by at most a third of what the frame before differed by. A
// game running at 30 fps inside a 60 fps stream sends each picture twice: measured on a PS5, the
// differences alternate between about 0.3 and about 8, and 99.9% of neighbours are at least 3x
// apart. The relative test keeps slow or small motion at the full rate, where every frame
// differs by a similar small amount, from counting as repeats.
static const double kRepeatMean = 1.0;
static const double kRepeatRatio = 3.0;
// Frames looked back over to tell 30 fps content inside a 60 fps stream: about half of them repeat.
static const int kCadenceWindow = 24;

/// One decoded frame on its way out, with the frame interpolated before it, if any.
@interface CNInterpolationJob : NSObject {
 @public
  CVPixelBufferRef _frame;
  CVPixelBufferRef _previous;
  CVPixelBufferRef _generated;
  CNInterpolatedFrameHandler _handler;
  uint64_t _ticket;
  BOOL _pending;
  BOOL _abandoned;
  BOOL _expired;
  BOOL _generatedSent;
  // The decoded frame follows its interpolated frame by half a content interval, so that frames
  // reach the display evenly spaced instead of in pairs.
  uint64_t _paceNanoseconds;
  uint64_t _releaseAt;
}
@end

@implementation CNInterpolationJob
- (void)dealloc {
  if (_frame) {
    CVPixelBufferRelease(_frame);
  }
  if (_previous) {
    CVPixelBufferRelease(_previous);
  }
  if (_generated) {
    CVPixelBufferRelease(_generated);
  }
}
@end

/// A processor session, ended once it is replaced and its last interpolation has finished.
@interface CNInterpolationSession : NSObject {
 @public
  VTFrameProcessor *_processor;
  NSUInteger _inFlight;
  BOOL _retired;
}
@end

@implementation CNInterpolationSession
- (void)endIfIdle {
  if (_retired && _inFlight == 0 && _processor) {
    [_processor endSession];
    _processor = nil;
  }
}
@end

@implementation CNFrameInterpolationClient {
  dispatch_queue_t _queue;
  CNInterpolationSession *_session;
  VTLowLatencyFrameInterpolationConfiguration *_configuration;
  CVPixelBufferPoolRef _pool;
  CVPixelBufferRef _previous;
  NSMutableArray<CNInterpolationJob *> *_jobs;
  atomic_bool _enabled;
  BOOL _stopped;
  pthread_mutex_t _deliveryLock;
  pthread_cond_t _delivered;
  NSUInteger _delivering;
  BOOL _stopRequested;
  uint64_t _generation;
  int32_t _sourceFrameRate;
  int64_t _sequence;
  _Atomic NSUInteger _generated;
  _Atomic NSUInteger _bypassed;
  _Atomic NSUInteger _failures;
  _Atomic NSUInteger _abandoned;
  _Atomic NSUInteger _repeats;
  _Atomic NSUInteger _dropped;
  double _lastDifference;
  uint32_t _repeatHistory;
  int _cadenceFrames;
  atomic_bool _halfRate;
  BOOL _drainScheduled;
  BOOL _flushing;
}

- (instancetype)init {
  self = [super init];
  if (!self) {
    return nil;
  }
  _sourceFrameRate = 60;
  _jobs = [NSMutableArray array];
  pthread_mutex_init(&_deliveryLock, NULL);
  pthread_cond_init(&_delivered, NULL);
  _queue = dispatch_queue_create("io.github.chiaki-ng.frame-interpolation", DISPATCH_QUEUE_SERIAL);
  return self;
}

- (BOOL)supported {
  if (!VTLowLatencyFrameInterpolationConfiguration.isSupported) {
    return NO;
  }
  if (@available(macOS 27.0, iOS 27.0, *)) {
    return [VTLowLatencyFrameInterpolationConfiguration maximumDimensionForSpatialScaleFactor:1] >=
               1920 &&
           [VTLowLatencyFrameInterpolationConfiguration maximumPixelCountForSpatialScaleFactor:1] >=
               1920 * 1080;
  }
  return YES;
}

- (void)setSourceFrameRate:(NSInteger)frameRate {
  dispatch_async(_queue, ^{
    int32_t bounded = frameRate == 30 ? 30 : 60;
    if (self->_sourceFrameRate != bounded) {
      self->_sourceFrameRate = bounded;
      [self resetSession];
    }
  });
}

- (void)setEnabled:(BOOL)enabled {
  dispatch_async(_queue, ^{
    pthread_mutex_lock(&self->_deliveryLock);
    BOOL stopped = self->_stopRequested;
    pthread_mutex_unlock(&self->_deliveryLock);
    if (stopped) {
      return;
    }
    if (atomic_load_explicit(&self->_enabled, memory_order_relaxed) == enabled && !self->_stopped) {
      return;
    }
    atomic_store_explicit(&self->_enabled, enabled, memory_order_relaxed);
    self->_stopped = NO;
    [self resetSession];
  });
}

- (BOOL)beginDelivery:(uint64_t)ticket {
  pthread_mutex_lock(&_deliveryLock);
  BOOL current = !_stopRequested && ticket == _generation;
  if (current) {
    _delivering++;
  }
  pthread_mutex_unlock(&_deliveryLock);
  return current;
}

- (void)endDelivery {
  pthread_mutex_lock(&_deliveryLock);
  _delivering--;
  if (_delivering == 0) {
    pthread_cond_broadcast(&_delivered);
  }
  pthread_mutex_unlock(&_deliveryLock);
}

- (void)deliver:(CVPixelBufferRef)frame
      generated:(BOOL)generated
         ticket:(uint64_t)ticket
        handler:(CNInterpolatedFrameHandler)handler {
  if (![self beginDelivery:ticket]) {
    return;
  }
  handler(frame, generated);
  [self endDelivery];
}

// Frames leave in the order they were offered, each decoded frame after the frame interpolated
// before it. A decoded frame is never dropped, except a repeat of the frame before it while the
// stream carries 30 fps content: the interpolated frame takes its place. When an interpolation
// cannot be made or comes too late, the decoded frame is delivered without it.
- (void)offer:(CVPixelBufferRef)frame handler:(CNInterpolatedFrameHandler)handler {
  pthread_mutex_lock(&_deliveryLock);
  if (_stopRequested) {
    pthread_mutex_unlock(&_deliveryLock);
    return;
  }
  uint64_t ticket = _generation;
  pthread_mutex_unlock(&_deliveryLock);
  CNInterpolationJob *job = [CNInterpolationJob new];
  job->_frame = CVPixelBufferRetain(frame);
  job->_handler = handler;
  job->_ticket = ticket;
  dispatch_async(_queue, ^{
    [self schedule:job];
    [self abandonExpired];
    [self drain];
  });
}

- (void)schedule:(CNInterpolationJob *)job {
  CVPixelBufferRef frame = job->_frame;
  if (self->_stopped || !atomic_load_explicit(&_enabled, memory_order_relaxed) || !self.supported ||
      ![self accepts:frame]) {
    atomic_fetch_add_explicit(&_bypassed, 1, memory_order_relaxed);
    [_jobs addObject:job];
    return;
  }
  // A new size or format resets the session, which flushes the frames before this one.
  if (![self prepareFor:frame]) {
    atomic_fetch_add_explicit(&_failures, 1, memory_order_relaxed);
    [_jobs addObject:job];
    return;
  }
  double difference = _previous ? [self differenceOf:frame from:_previous] : -1;
  BOOL repeat =
      difference >= 0 && difference < kRepeatMean && difference * kRepeatRatio <= _lastDifference;
  _lastDifference = difference < 0 ? 0 : difference;
  if (repeat) {
    atomic_fetch_add_explicit(&_repeats, 1, memory_order_relaxed);
    [self noteRepeat:YES];
    if (atomic_load_explicit(&_halfRate, memory_order_relaxed)) {
      // Dropped: the frame interpolated between its neighbours is shown in its slot instead.
      atomic_fetch_add_explicit(&_dropped, 1, memory_order_relaxed);
      return;
    }
    // Interpolating towards a copy makes another copy. The frame goes out as it is, and the
    // next new frame is interpolated from the original it repeats.
    [_jobs addObject:job];
    return;
  }
  [self noteRepeat:NO];
  [_jobs addObject:job];
  if (!_previous) {
    [self replacePrevious:frame];
    return;
  }
  if (_session->_inFlight >= kMaximumInFlight) {
    atomic_fetch_add_explicit(&_bypassed, 1, memory_order_relaxed);
    [self replacePrevious:frame];
    [self abandonBeyond:kMaximumWaiting];
    return;
  }
  CVPixelBufferRef generated = NULL;
  CVReturn allocation = CVPixelBufferPoolCreatePixelBuffer(NULL, _pool, &generated);
  if (allocation != kCVReturnSuccess || !generated) {
    atomic_fetch_add_explicit(&_failures, 1, memory_order_relaxed);
    [self replacePrevious:frame];
    return;
  }
  CVBufferPropagateAttachments(frame, generated);
  CMTime previousTime = CMTimeMake(_sequence, _sourceFrameRate);
  CMTime generatedTime = CMTimeMake(_sequence * 2 + 1, _sourceFrameRate * 2);
  CMTime currentTime = CMTimeMake(_sequence + 1, _sourceFrameRate);
  _sequence++;
  VTFrameProcessorFrame *previous = [[VTFrameProcessorFrame alloc] initWithBuffer:_previous
                                                            presentationTimeStamp:previousTime];
  VTFrameProcessorFrame *current = [[VTFrameProcessorFrame alloc] initWithBuffer:frame
                                                           presentationTimeStamp:currentTime];
  VTFrameProcessorFrame *destination = [[VTFrameProcessorFrame alloc] initWithBuffer:generated
                                                               presentationTimeStamp:generatedTime];
  VTLowLatencyFrameInterpolationParameters *parameters =
      [[VTLowLatencyFrameInterpolationParameters alloc] initWithSourceFrame:current
                                                              previousFrame:previous
                                                         interpolationPhase:@[ @0.5 ]
                                                          destinationFrames:@[ destination ]];
  if (!parameters) {
    CVPixelBufferRelease(generated);
    atomic_fetch_add_explicit(&_failures, 1, memory_order_relaxed);
    [self replacePrevious:frame];
    return;
  }
  // The job keeps both source frames until the interpolation has finished with them.
  job->_previous = CVPixelBufferRetain(_previous);
  job->_generated = generated;
  job->_pending = YES;
  int32_t contentRate = [self contentFrameRate];
  job->_paceNanoseconds = NSEC_PER_SEC / (uint64_t)(contentRate * 2);
  [self replacePrevious:frame];
  CNInterpolationSession *session = _session;
  session->_inFlight++;
  [session->_processor
      processWithParameters:parameters
          completionHandler:^(id<VTFrameProcessorParameters> processed, NSError *error) {
            dispatch_async(self->_queue, ^{
              [self finish:job session:session error:error];
            });
          }];
  int64_t hold = (int64_t)(kMaximumHoldIntervals * NSEC_PER_SEC / contentRate);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, hold), _queue, ^{
    job->_expired = YES;
    [self abandonExpired];
    [self drain];
  });
}

// Gives up interpolations past their hold time, but only while a newer decoded frame waits behind
// them: waiting longer then delays that frame too. With nothing behind, the interpolation is
// still the quickest way to the next frame shown.
- (void)abandonExpired {
  CNInterpolationJob *newest = _jobs.lastObject;
  for (CNInterpolationJob *job in _jobs) {
    if (job != newest && job->_expired && job->_pending && !job->_abandoned) {
      job->_abandoned = YES;
      atomic_fetch_add_explicit(&_abandoned, 1, memory_order_relaxed);
    }
  }
}

- (void)finish:(CNInterpolationJob *)job
       session:(CNInterpolationSession *)session
         error:(NSError *)error {
  session->_inFlight--;
  [session endIfIdle];
  job->_pending = NO;
  if (error) {
    atomic_fetch_add_explicit(&_failures, 1, memory_order_relaxed);
  } else if (!job->_abandoned) {
    atomic_fetch_add_explicit(&_generated, 1, memory_order_relaxed);
  }
  if (error || job->_abandoned) {
    CVPixelBufferRelease(job->_generated);
    job->_generated = NULL;
  }
  [self drain];
}

// Gives up the oldest unfinished interpolations until at most `limit` frames wait. Their decoded
// frames go out now; the interpolated frames are discarded when they finish.
- (void)abandonBeyond:(NSUInteger)limit {
  [self drain];
  while (_jobs.count > limit) {
    // After a drain the first job is an interpolation still running, or a decoded frame held
    // back after its interpolated frame.
    CNInterpolationJob *job = _jobs.firstObject;
    if (job->_pending) {
      job->_abandoned = YES;
      atomic_fetch_add_explicit(&_abandoned, 1, memory_order_relaxed);
    } else {
      job->_releaseAt = 0;
    }
    [self drain];
  }
}

- (void)drain {
  while (_jobs.count > 0) {
    CNInterpolationJob *job = _jobs.firstObject;
    if (job->_pending && !job->_abandoned) {
      return;
    }
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (!job->_pending && job->_generated && !job->_generatedSent) {
      job->_generatedSent = YES;
      job->_releaseAt = now + job->_paceNanoseconds;
      [self deliver:job->_generated generated:YES ticket:job->_ticket handler:job->_handler];
    }
    // The decoded frame waits out its pace while the frame behind it is still being
    // interpolated, since that frame could not go out sooner anyway. It goes at once when the
    // frame behind is ready, when frames pile up, or while the session resets.
    CNInterpolationJob *next = _jobs.count > 1 ? _jobs[1] : nil;
    BOOL nextReady = next && (!next->_pending || next->_abandoned);
    BOOL paced = job->_releaseAt > now && !nextReady && _jobs.count <= 2 && !_flushing;
    if (paced) {
      [self drainAt:job->_releaseAt from:now];
      return;
    }
    [_jobs removeObjectAtIndex:0];
    [self deliver:job->_frame generated:NO ticket:job->_ticket handler:job->_handler];
  }
}

- (void)drainAt:(uint64_t)time from:(uint64_t)now {
  if (_drainScheduled) {
    return;
  }
  _drainScheduled = YES;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(time - now)), _queue, ^{
    self->_drainScheduled = NO;
    [self drain];
  });
}

// The rate of new pictures: half the stream rate while the stream repeats every other frame.
- (int32_t)contentFrameRate {
  return atomic_load_explicit(&_halfRate, memory_order_relaxed) ? _sourceFrameRate / 2
                                                                : _sourceFrameRate;
}

- (void)noteRepeat:(BOOL)repeat {
  _repeatHistory = (_repeatHistory << 1) | (repeat ? 1u : 0u);
  if (_cadenceFrames < kCadenceWindow) {
    _cadenceFrames++;
  }
  uint32_t window = _repeatHistory & ((1u << kCadenceWindow) - 1);
  int repeats = __builtin_popcount(window);
  // Entered when 40-60% of the window repeats, left only outside 30-70%, so that a few
  // misjudged frames do not switch the mode back and forth.
  BOOL halfRate = atomic_load_explicit(&_halfRate, memory_order_relaxed);
  BOOL full = _sourceFrameRate == 60 && _cadenceFrames == kCadenceWindow;
  if (!full || repeats * 10 < kCadenceWindow * 3 || repeats * 10 > kCadenceWindow * 7) {
    halfRate = NO;
  } else if (repeats * 10 >= kCadenceWindow * 4 && repeats * 10 <= kCadenceWindow * 6) {
    halfRate = YES;
  }
  atomic_store_explicit(&_halfRate, halfRate, memory_order_relaxed);
}

// The mean luma difference, in 8-bit levels, on a sparse grid of about 16 000 samples at 1080p.
// Negative when the frames cannot be compared.
- (double)differenceOf:(CVPixelBufferRef)frame from:(CVPixelBufferRef)previous {
  if (CVPixelBufferGetPixelFormatType(frame) != CVPixelBufferGetPixelFormatType(previous) ||
      CVPixelBufferGetWidth(frame) != CVPixelBufferGetWidth(previous) ||
      CVPixelBufferGetHeight(frame) != CVPixelBufferGetHeight(previous)) {
    return -1;
  }
  if (CVPixelBufferLockBaseAddress(frame, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
    return -1;
  }
  if (CVPixelBufferLockBaseAddress(previous, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
    CVPixelBufferUnlockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
    return -1;
  }
  OSType format = CVPixelBufferGetPixelFormatType(frame);
  BOOL tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
  const uint8_t *a = CVPixelBufferGetBaseAddressOfPlane(frame, 0);
  const uint8_t *b = CVPixelBufferGetBaseAddressOfPlane(previous, 0);
  size_t strideA = CVPixelBufferGetBytesPerRowOfPlane(frame, 0);
  size_t strideB = CVPixelBufferGetBytesPerRowOfPlane(previous, 0);
  size_t width = CVPixelBufferGetWidthOfPlane(frame, 0);
  size_t height = CVPixelBufferGetHeightOfPlane(frame, 0);
  uint64_t sum = 0;
  uint64_t count = 0;
  for (size_t y = 4; y < height; y += 8) {
    for (size_t x = 8; x < width; x += 16) {
      int left = tenBit ? ((const uint16_t *)(a + y * strideA))[x] >> 8 : a[y * strideA + x];
      int right = tenBit ? ((const uint16_t *)(b + y * strideB))[x] >> 8 : b[y * strideB + x];
      sum += (uint64_t)abs(left - right);
      count++;
    }
  }
  CVPixelBufferUnlockBaseAddress(previous, kCVPixelBufferLock_ReadOnly);
  CVPixelBufferUnlockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
  return count > 0 ? (double)sum / (double)count : -1;
}

- (BOOL)accepts:(CVPixelBufferRef)frame {
  size_t width = CVPixelBufferGetWidth(frame);
  size_t height = CVPixelBufferGetHeight(frame);
  if (!((width == 1920 && height == 1080) || (width == 1280 && height == 720)) ||
      !CVPixelBufferGetIOSurface(frame)) {
    return NO;
  }
  OSType format = CVPixelBufferGetPixelFormatType(frame);
  return format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
         format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
         format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
         format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
}

- (BOOL)prepareFor:(CVPixelBufferRef)frame {
  if (_previous &&
      (CVPixelBufferGetWidth(_previous) != CVPixelBufferGetWidth(frame) ||
       CVPixelBufferGetHeight(_previous) != CVPixelBufferGetHeight(frame) ||
       CVPixelBufferGetPixelFormatType(_previous) != CVPixelBufferGetPixelFormatType(frame))) {
    [self resetSession];
  }
  if (_session && _pool) {
    return YES;
  }
  _configuration = [[VTLowLatencyFrameInterpolationConfiguration alloc]
              initWithFrameWidth:CVPixelBufferGetWidth(frame)
                     frameHeight:CVPixelBufferGetHeight(frame)
      numberOfInterpolatedFrames:1];
  if (!_configuration) {
    return NO;
  }
  if (![_configuration.frameSupportedPixelFormats
          containsObject:@(CVPixelBufferGetPixelFormatType(frame))]) {
    _configuration = nil;
    return NO;
  }
  VTFrameProcessor *processor = [VTFrameProcessor new];
  NSError *error = nil;
  if (![processor startSessionWithConfiguration:_configuration error:&error]) {
    _configuration = nil;
    return NO;
  }
  NSMutableDictionary *attributes = [_configuration.destinationPixelBufferAttributes mutableCopy];
  attributes[(NSString *)kCVPixelBufferIOSurfacePropertiesKey] = @{};
  attributes[(NSString *)kCVPixelBufferMetalCompatibilityKey] = @YES;
  // Room for the interpolations in flight and the frames the surface still holds.
  NSDictionary *poolAttributes = @{(NSString *)kCVPixelBufferPoolMinimumBufferCountKey : @4};
  CVReturn result = CVPixelBufferPoolCreate(NULL, (__bridge CFDictionaryRef)poolAttributes,
                                            (__bridge CFDictionaryRef)attributes, &_pool);
  if (result != kCVReturnSuccess) {
    [processor endSession];
    _configuration = nil;
    return NO;
  }
  _session = [CNInterpolationSession new];
  _session->_processor = processor;
  return YES;
}

- (void)replacePrevious:(CVPixelBufferRef)frame {
  if (_previous) {
    CVPixelBufferRelease(_previous);
  }
  _previous = CVPixelBufferRetain(frame);
}

// Delivers every waiting decoded frame, gives up the interpolations still running and ends the
// session once they have finished.
- (void)resetSession {
  _flushing = YES;
  [self abandonBeyond:0];
  _flushing = NO;
  _repeatHistory = 0;
  _lastDifference = 0;
  _cadenceFrames = 0;
  atomic_store_explicit(&_halfRate, false, memory_order_relaxed);
  if (_session) {
    _session->_retired = YES;
    [_session endIfIdle];
    _session = nil;
  }
  _configuration = nil;
  if (_pool) {
    CFRelease(_pool);
    _pool = NULL;
  }
  if (_previous) {
    CVPixelBufferRelease(_previous);
    _previous = NULL;
  }
  _sequence = 0;
}

- (NSDictionary<NSString *, NSNumber *> *)statistics {
  return @{
    @"supported" : @(self.supported),
    @"enabled" : @(atomic_load_explicit(&_enabled, memory_order_relaxed)),
    @"generated" : @(atomic_load_explicit(&_generated, memory_order_relaxed)),
    @"bypassed" : @(atomic_load_explicit(&_bypassed, memory_order_relaxed)),
    @"failures" : @(atomic_load_explicit(&_failures, memory_order_relaxed)),
    @"abandoned" : @(atomic_load_explicit(&_abandoned, memory_order_relaxed)),
    @"repeats" : @(atomic_load_explicit(&_repeats, memory_order_relaxed)),
    @"repeatsDropped" : @(atomic_load_explicit(&_dropped, memory_order_relaxed)),
    @"halfRate" : @(atomic_load_explicit(&_halfRate, memory_order_relaxed))
  };
}

- (void)stop {
  pthread_mutex_lock(&_deliveryLock);
  if (_stopRequested) {
    pthread_mutex_unlock(&_deliveryLock);
    return;
  }
  _stopRequested = YES;
  ++_generation;
  while (_delivering > 0) {
    pthread_cond_wait(&_delivered, &_deliveryLock);
  }
  pthread_mutex_unlock(&_deliveryLock);
  dispatch_async(_queue, ^{
    self->_stopped = YES;
    [self resetSession];
  });
}

- (void)dealloc {
  // Running interpolations hold the client, so none is left here; nothing is delivered.
  [_jobs removeAllObjects];
  [self resetSession];
  pthread_cond_destroy(&_delivered);
  pthread_mutex_destroy(&_deliveryLock);
}

@end

#endif
