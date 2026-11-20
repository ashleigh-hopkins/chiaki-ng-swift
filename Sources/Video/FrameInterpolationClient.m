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
// before it. A decoded frame is never dropped: when its interpolation cannot be made or comes
// too late, the decoded frame is delivered without it.
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
  int64_t hold = (int64_t)(kMaximumHoldIntervals * NSEC_PER_SEC / _sourceFrameRate);
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
    // After a drain the first job is always an interpolation still running.
    CNInterpolationJob *job = _jobs.firstObject;
    job->_abandoned = YES;
    atomic_fetch_add_explicit(&_abandoned, 1, memory_order_relaxed);
    [self drain];
  }
}

- (void)drain {
  while (_jobs.count > 0) {
    CNInterpolationJob *job = _jobs.firstObject;
    if (job->_pending && !job->_abandoned) {
      return;
    }
    [_jobs removeObjectAtIndex:0];
    if (!job->_pending && job->_generated) {
      [self deliver:job->_generated generated:YES ticket:job->_ticket handler:job->_handler];
    }
    [self deliver:job->_frame generated:NO ticket:job->_ticket handler:job->_handler];
  }
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
  [self abandonBeyond:0];
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
    @"abandoned" : @(atomic_load_explicit(&_abandoned, memory_order_relaxed))
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
