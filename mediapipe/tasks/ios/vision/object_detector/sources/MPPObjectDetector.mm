// Copyright 2023 The MediaPipe Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import "mediapipe/tasks/ios/vision/object_detector/sources/MPPObjectDetector.h"

#import "mediapipe/tasks/ios/common/utils/sources/MPPCommonUtils.h"
#import "mediapipe/tasks/ios/common/utils/sources/NSString+Helpers.h"
#import "mediapipe/tasks/ios/core/sources/MPPTaskInfo.h"
#import "mediapipe/tasks/ios/vision/core/sources/MPPVisionPacketCreator.h"
#import "mediapipe/tasks/ios/vision/core/sources/MPPVisionTaskRunner.h"
#import "mediapipe/tasks/ios/vision/object_detector/utils/sources/MPPObjectDetectorOptions+Helpers.h"
#import "mediapipe/tasks/ios/vision/object_detector/utils/sources/MPPObjectDetectorResult+Helpers.h"

namespace {
using ::mediapipe::NormalizedRect;
using ::mediapipe::Packet;
using ::mediapipe::Timestamp;
using ::mediapipe::tasks::core::PacketMap;
using ::mediapipe::tasks::core::PacketsCallback;
}  // namespace

static NSString *const kDetectionsStreamName = @"detections_out";
static NSString *const kDetectionsTag = @"DETECTIONS";
static NSString *const kImageInStreamName = @"image_in";
static NSString *const kImageOutStreamName = @"image_out";
static NSString *const kImageTag = @"IMAGE";
static NSString *const kNormRectStreamName = @"norm_rect_in";
static NSString *const kNormRectTag = @"NORM_RECT";
static NSString *const kTaskGraphName = @"mediapipe.tasks.vision.ObjectDetectorGraph";
static NSString *const kTaskName = @"objectDetector";

#define InputPacketMap(imagePacket, normalizedRectPacket) \
  {                                                       \
    {kImageInStreamName.cppString, imagePacket}, {        \
      kNormRectStreamName.cppString, normalizedRectPacket \
    }                                                     \
  }

@interface MPPObjectDetector () {
  /** iOS Vision Task Runner */
  MPPVisionTaskRunner *_visionTaskRunner;
  dispatch_queue_t _callbackQueue;
}
@property(nonatomic, weak) id<MPPObjectDetectorLiveStreamDelegate> objectDetectorLiveStreamDelegate;
@end

@implementation MPPObjectDetector

- (void)processLiveStreamResult:(absl::StatusOr<PacketMap>)liveStreamResult {
  if (![self.objectDetectorLiveStreamDelegate
          respondsToSelector:@selector(objectDetector:
                                 didFinishDetectionWithResult:timestampInMilliseconds:error:)]) {
    return;
  }

  NSError *callbackError = nil;
  if (![MPPCommonUtils checkCppError:liveStreamResult.status() toError:&callbackError]) {
    dispatch_async(_callbackQueue, ^{
      [self.objectDetectorLiveStreamDelegate objectDetector:self
                               didFinishDetectionWithResult:nil
                                    timestampInMilliseconds:Timestamp::Unset().Value()
                                                      error:callbackError];
    });
    return;
  }

  PacketMap &outputPacketMap = liveStreamResult.value();
  if (outputPacketMap[kImageOutStreamName.cppString].IsEmpty()) {
    return;
  }

  MPPObjectDetectorResult *result = [MPPObjectDetectorResult
      objectDetectorResultWithDetectionsPacket:outputPacketMap[kDetectionsStreamName.cppString]];

  NSInteger timeStampInMilliseconds =
      outputPacketMap[kImageOutStreamName.cppString].Timestamp().Value() /
      kMicroSecondsPerMilliSecond;
  dispatch_async(_callbackQueue, ^{
    [self.objectDetectorLiveStreamDelegate objectDetector:self
                             didFinishDetectionWithResult:result
                                  timestampInMilliseconds:timeStampInMilliseconds
                                                    error:callbackError];
  });
}

- (instancetype)initWithOptions:(MPPObjectDetectorOptions *)options error:(NSError **)error {
  self = [super init];
  if (self) {
    MPPTaskInfo *taskInfo = [[MPPTaskInfo alloc]
        initWithTaskGraphName:kTaskGraphName
                 inputStreams:@[
                   [NSString stringWithFormat:@"%@:%@", kImageTag, kImageInStreamName],
                   [NSString stringWithFormat:@"%@:%@", kNormRectTag, kNormRectStreamName]
                 ]
                outputStreams:@[
                  [NSString stringWithFormat:@"%@:%@", kDetectionsTag, kDetectionsStreamName],
                  [NSString stringWithFormat:@"%@:%@", kImageTag, kImageOutStreamName]
                ]
                  taskOptions:options
           enableFlowLimiting:options.runningMode == MPPRunningModeLiveStream
                        error:error];

    if (!taskInfo) {
      return nil;
    }

    PacketsCallback packetsCallback = nullptr;

    if (options.objectDetectorLiveStreamDelegate) {
      _objectDetectorLiveStreamDelegate = options.objectDetectorLiveStreamDelegate;

      // Create a private serial dispatch queue in which the delegate method will be called
      // asynchronously. This is to ensure that if the client performs a long running operation in
      // the delegate method, the queue on which the C++ callbacks is invoked is not blocked and is
      // freed up to continue with its operations.
      _callbackQueue = dispatch_queue_create(
          [MPPVisionTaskRunner uniqueDispatchQueueNameWithSuffix:kTaskName], NULL);

      // Capturing `self` as weak in order to avoid `self` being kept in memory
      // and cause a retain cycle, after self is set to `nil`.
      MPPObjectDetector *__weak weakSelf = self;
      packetsCallback = [=](absl::StatusOr<PacketMap> liveStreamResult) {
        [weakSelf processLiveStreamResult:liveStreamResult];
      };
    }

    _visionTaskRunner =
        [[MPPVisionTaskRunner alloc] initWithCalculatorGraphConfig:[taskInfo generateGraphConfig]
                                                       runningMode:options.runningMode
                                                   packetsCallback:std::move(packetsCallback)
                                                             error:error];

    if (!_visionTaskRunner) {
      return nil;
    }
  }

  return self;
}

- (instancetype)initWithModelPath:(NSString *)modelPath error:(NSError **)error {
  MPPObjectDetectorOptions *options = [[MPPObjectDetectorOptions alloc] init];

  options.baseOptions.modelAssetPath = modelPath;

  return [self initWithOptions:options error:error];
}

- (std::optional<PacketMap>)inputPacketMapWithMPPImage:(MPPImage *)image
                               timestampInMilliseconds:(NSInteger)timestampInMilliseconds
                                                 error:(NSError **)error {
  std::optional<NormalizedRect> rect =
      [_visionTaskRunner normalizedRectWithImageOrientation:image.orientation
                                                  imageSize:CGSizeMake(image.width, image.height)
                                                      error:error];
  if (!rect.has_value()) {
    return std::nullopt;
  }

  Packet imagePacket = [MPPVisionPacketCreator createPacketWithMPPImage:image
                                                timestampInMilliseconds:timestampInMilliseconds
                                                                  error:error];
  if (imagePacket.IsEmpty()) {
    return std::nullopt;
  }

  Packet normalizedRectPacket =
      [MPPVisionPacketCreator createPacketWithNormalizedRect:rect.value()
                                     timestampInMilliseconds:timestampInMilliseconds];

  PacketMap inputPacketMap = InputPacketMap(imagePacket, normalizedRectPacket);
  return inputPacketMap;
}

- (nullable MPPObjectDetectorResult *)detectInImage:(MPPImage *)image
                                   regionOfInterest:(CGRect)roi
                                              error:(NSError **)error {
  std::optional<NormalizedRect> rect =
      [_visionTaskRunner normalizedRectWithImageOrientation:image.orientation
                                                  imageSize:CGSizeMake(image.width, image.height)
                                                      error:error];
  if (!rect.has_value()) {
    return nil;
  }

  Packet imagePacket = [MPPVisionPacketCreator createPacketWithMPPImage:image error:error];
  if (imagePacket.IsEmpty()) {
    return nil;
  }

  Packet normalizedRectPacket =
      [MPPVisionPacketCreator createPacketWithNormalizedRect:rect.value()];

  PacketMap inputPacketMap = InputPacketMap(imagePacket, normalizedRectPacket);

  std::optional<PacketMap> outputPacketMap = [_visionTaskRunner processImagePacketMap:inputPacketMap
                                                                                error:error];
  if (!outputPacketMap.has_value()) {
    return nil;
  }

  return [MPPObjectDetectorResult
      objectDetectorResultWithDetectionsPacket:outputPacketMap
                                                   .value()[kDetectionsStreamName.cppString]];
}

- (nullable MPPObjectDetectorResult *)detectInImage:(MPPImage *)image error:(NSError **)error {
  return [self detectInImage:image regionOfInterest:CGRectZero error:error];
}

- (nullable MPPObjectDetectorResult *)detectInVideoFrame:(MPPImage *)image
                                 timestampInMilliseconds:(NSInteger)timestampInMilliseconds
                                                   error:(NSError **)error {
  std::optional<PacketMap> inputPacketMap = [self inputPacketMapWithMPPImage:image
                                                     timestampInMilliseconds:timestampInMilliseconds
                                                                       error:error];
  if (!inputPacketMap.has_value()) {
    return nil;
  }

  std::optional<PacketMap> outputPacketMap =
      [_visionTaskRunner processVideoFramePacketMap:inputPacketMap.value() error:error];

  if (!outputPacketMap.has_value()) {
    return nil;
  }

  return [MPPObjectDetectorResult
      objectDetectorResultWithDetectionsPacket:outputPacketMap
                                                   .value()[kDetectionsStreamName.cppString]];
}

- (BOOL)detectAsyncInImage:(MPPImage *)image
    timestampInMilliseconds:(NSInteger)timestampInMilliseconds
                      error:(NSError **)error {
  std::optional<PacketMap> inputPacketMap = [self inputPacketMapWithMPPImage:image
                                                     timestampInMilliseconds:timestampInMilliseconds
                                                                       error:error];
  if (!inputPacketMap.has_value()) {
    return NO;
  }

  return [_visionTaskRunner processLiveStreamPacketMap:inputPacketMap.value() error:error];
}

@end
