#import "TsukuyomiLive2dPlugin.h"
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#include "../../src/gpu_api.h"
#include <algorithm>
#include <chrono>
#include <stdexcept>
#include <vector>

namespace {
dispatch_queue_t worker() {
  static dispatch_queue_t queue = dispatch_queue_create("space.tsukuyomi.cubism.metal", DISPATCH_QUEUE_SERIAL);
  return queue;
}
id<MTLDevice> device() {
  static id<MTLDevice> value = MTLCreateSystemDefaultDevice();
  return value;
}
void require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
double micros(std::chrono::steady_clock::time_point start) {
  return std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - start).count();
}
NSData* bytes(id value) {
  return [value isKindOfClass:FlutterStandardTypedData.class] ? [value data] : nil;
}
}

@interface TSLiveTexture : NSObject <FlutterTexture> {
@public
  const TsGpuApi* api;
  void* scene;
  int64_t textureId;
  CVPixelBufferRef front;
  CVPixelBufferPoolRef pool;
  CVMetalTextureCacheRef cache;
  id<MTLTexture> depth;
  id<MTLCommandQueue> commands;
  NSMutableArray<id<MTLTexture>>* atlases;
  int width, height;
}
- (void)close;
@end

@implementation TSLiveTexture
- (instancetype)init {
  if ((self = [super init])) { atlases = [NSMutableArray array]; }
  return self;
}
- (CVPixelBufferRef)copyPixelBuffer {
  @synchronized(self) { return front ? CVPixelBufferRetain(front) : nil; }
}
- (void)close {
  if (scene) { api->destroy(scene); scene = nullptr; }
  @synchronized(self) { if (front) { CVPixelBufferRelease(front); front = nil; } }
  if (pool) { CVPixelBufferPoolRelease(pool); pool = nil; }
  if (cache) { CFRelease(cache); cache = nil; }
  [atlases removeAllObjects]; depth = nil; commands = nil;
}
- (void)dealloc {
  // Cubism destruction is always scheduled by the plugin on the shared worker.
  if (front) CVPixelBufferRelease(front);
  if (pool) CVPixelBufferPoolRelease(pool);
  if (cache) CFRelease(cache);
}
@end

@interface TsukuyomiLive2dPlugin ()
@property(nonatomic, strong) id<FlutterTextureRegistry> registry;
@property(nonatomic, strong) NSMutableDictionary<NSNumber*, TSLiveTexture*>* scenes;
@property(nonatomic, assign) BOOL closed;
@end

@implementation TsukuyomiLive2dPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  TsukuyomiLive2dPlugin* plugin = [TsukuyomiLive2dPlugin new];
  plugin.registry = registrar.textures;
  plugin.scenes = [NSMutableDictionary dictionary];
  FlutterMethodChannel* channel = [FlutterMethodChannel methodChannelWithName:@"space.tsukuyomi/live2d_gpu"
                                                            binaryMessenger:registrar.messenger];
  [registrar addMethodCallDelegate:plugin channel:channel];
  [registrar publish:plugin];
}
- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  self.closed = YES;
  for (TSLiveTexture* s in self.scenes.allValues) {
    [self.registry unregisterTexture:s->textureId];
    dispatch_async(worker(), ^{ @autoreleasepool { [s close]; } });
  }
  [self.scenes removeAllObjects];
}
- (void)dealloc {
  // macOS also tears down a registrar without calling the iOS detach hook.
  NSArray<TSLiveTexture*>* remaining = self.scenes.allValues;
  dispatch_async(worker(), ^{ @autoreleasepool {
    for (TSLiveTexture* s in remaining) [s close];
  } });
}
- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (self.closed) { result([FlutterError errorWithCode:@"disposed" message:@"Renderer closed" details:nil]); return; }
  NSDictionary* args = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments : @{};
  if ([call.method isEqualToString:@"create"]) {
    TSLiveTexture* s = [TSLiveTexture new];
    s->textureId = [self.registry registerTexture:s];
    self.scenes[@(s->textureId)] = s;
    dispatch_async(worker(), ^{ @autoreleasepool {
      try {
        auto started = std::chrono::steady_clock::now();
        s->api = reinterpret_cast<const TsGpuApi*>([args[@"nativeApi"] unsignedLongLongValue]);
        require(s->api && s->api->version == 1, "Native GPU ABI unavailable");
        require(device() != nil, "Metal device unavailable");
        s->commands = [device() newCommandQueue];
        require(s->commands != nil, "Metal command queue unavailable");
        require(CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device(), nil, &s->cache) == kCVReturnSuccess,
                "Metal texture cache unavailable");
        NSData* moc = bytes(args[@"moc"]); NSData* physics = bytes(args[@"physics"]);
        require(moc.length > 0 && moc.length <= 64 * 1024 * 1024, "Invalid model");
        TsGpuInfo info{};
        s->scene = s->api->create((const uint8_t*)moc.bytes, (int)moc.length,
            (const uint8_t*)physics.bytes, (int)physics.length, (__bridge void*)device(), &info);
        require(s->scene != nullptr, s->api->error());
        double initialized = micros(started);
        int limit = std::clamp([args[@"maxTextureSize"] intValue], 1, 4096);
        uint64_t atlasBytes = 0;
        for (id encoded in args[@"textures"]) {
          NSData* data = bytes(encoded);
          require(data.length > 0, "Invalid atlas");
          CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, nil);
          require(source != nil, "Cannot decode atlas");
          NSDictionary* options = @{
            (id)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
            (id)kCGImageSourceThumbnailMaxPixelSize:@(limit),
            (id)kCGImageSourceShouldCacheImmediately:@YES,
          };
          CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
          CFRelease(source);
          require(image != nil, "Cannot resize atlas");
          size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
          std::vector<uint8_t> pixels(w * h * 4);
          CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
          CGContextRef context = CGBitmapContextCreate(pixels.data(), w, h, 8, w * 4, color,
              kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
          CGColorSpaceRelease(color);
          if (!context) { CGImageRelease(image); throw std::runtime_error("Cannot decode RGBA atlas"); }
          CGContextSetBlendMode(context, kCGBlendModeCopy);
          CGContextDrawImage(context, CGRectMake(0, 0, w, h), image);
          CGContextRelease(context); CGImageRelease(image);
          MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
              width:w height:h mipmapped:YES];
          desc.usage = MTLTextureUsageShaderRead;
          id<MTLTexture> texture = [device() newTextureWithDescriptor:desc];
          require(texture != nil, "Cannot allocate atlas");
          [texture replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:pixels.data() bytesPerRow:w * 4];
          id<MTLCommandBuffer> command = [s->commands commandBuffer];
          id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
          [blit generateMipmapsForTexture:texture]; [blit endEncoding];
          [command commit]; [command waitUntilCompleted];
          require(command.status == MTLCommandBufferStatusCompleted, "Atlas upload failed");
          if (!s->api->bind(s->scene, (int)s->atlases.count, (__bridge void*)texture)) throw std::runtime_error(s->api->error());
          [s->atlases addObject:texture];
          while (true) {
            atlasBytes += w * h * 4;
            if (w == 1 && h == 1) break;
            w = std::max(size_t(1), w / 2); h = std::max(size_t(1), h / 2);
          }
        }
        NSDictionary* value = @{@"textureId":@(s->textureId), @"meshCount":@(info.mesh_count),
          @"bounds":@[@(info.bounds[0]), @(info.bounds[1]), @(info.bounds[2]), @(info.bounds[3])],
          @"maxSize":@4096, @"atlasBytes":@(atlasBytes), @"backend":@"Metal",
          @"loadMetrics":@{@"native_init_ms":@(initialized / 1000), @"atlas_decode_upload_ms":@((micros(started) - initialized) / 1000)}};
        dispatch_async(dispatch_get_main_queue(), ^{ result(value); });
      } catch (const std::exception& e) {
        NSString* message = [NSString stringWithUTF8String:e.what()];
        [s close];
        dispatch_async(dispatch_get_main_queue(), ^{
          [self.scenes removeObjectForKey:@(s->textureId)];
          [self.registry unregisterTexture:s->textureId];
          result([FlutterError errorWithCode:@"gpu" message:message details:nil]);
        });
      }
    } });
    return;
  }
  TSLiveTexture* s = self.scenes[args[@"id"]];
  if (!s) { result([FlutterError errorWithCode:@"disposed" message:@"Unknown renderer" details:nil]); return; }
  if ([call.method isEqualToString:@"dispose"]) {
    [self.scenes removeObjectForKey:@(s->textureId)];
    [self.registry unregisterTexture:s->textureId];
    dispatch_async(worker(), ^{ @autoreleasepool {
      [s close]; dispatch_async(dispatch_get_main_queue(), ^{ result(nil); });
    } });
    return;
  }
  if (![call.method isEqualToString:@"frame"] && ![call.method isEqualToString:@"snapshot"]) {
    result(FlutterMethodNotImplemented); return;
  }
  dispatch_async(worker(), ^{ @autoreleasepool {
    CVPixelBufferRef buffer = nil;
    CVMetalTextureRef target = nil;
    try {
      require(s->scene != nullptr, "Renderer disposed");
      if ([call.method isEqualToString:@"snapshot"]) {
        buffer = [s copyPixelBuffer];
        require(buffer != nil, "No completed frame");
        CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
        size_t w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer);
        size_t stride = CVPixelBufferGetBytesPerRow(buffer);
        const auto* input = (const uint8_t*)CVPixelBufferGetBaseAddress(buffer);
        NSMutableData* data = [NSMutableData dataWithLength:w * h * 4];
        auto* out = (uint8_t*)data.mutableBytes;
        // Match Android's diagnostic ABI: RGBA with bottom row first.
        for (size_t y = 0; y < h; ++y) for (size_t x = 0; x < w; ++x) {
          const auto* p = input + (h - 1 - y) * stride + x * 4;
          auto* q = out + (y * w + x) * 4;
          q[0] = p[2]; q[1] = p[1]; q[2] = p[0]; q[3] = p[3];
        }
        CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(buffer); buffer = nil;
        dispatch_async(dispatch_get_main_queue(), ^{ result([FlutterStandardTypedData typedDataWithBytes:data]); });
        return;
      }
      int w = [args[@"width"] intValue], h = [args[@"height"] intValue];
      require(w > 0 && h > 0 && w <= 4096 && h <= 4096 && int64_t(w) * h <= 8000000, "Invalid output size");
      if (!s->pool || s->width != w || s->height != h) {
        if (s->pool) { CVPixelBufferPoolRelease(s->pool); s->pool = nil; }
        NSDictionary* attrs = @{(id)kCVPixelBufferWidthKey:@(w), (id)kCVPixelBufferHeightKey:@(h),
          (id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),
          (id)kCVPixelBufferMetalCompatibilityKey:@YES, (id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
        require(CVPixelBufferPoolCreate(nil, nil, (__bridge CFDictionaryRef)attrs, &s->pool) == kCVReturnSuccess,
                "Cannot allocate output pool");
        MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:w height:h mipmapped:NO];
        desc.usage = MTLTextureUsageRenderTarget; desc.storageMode = MTLStorageModePrivate;
        s->depth = [device() newTextureWithDescriptor:desc];
        require(s->depth != nil, "Cannot allocate depth target");
        s->width = w; s->height = h;
        CVMetalTextureCacheFlush(s->cache, 0);
      }
      NSDictionary* aux = @{(id)kCVPixelBufferPoolAllocationThresholdKey:@3};
      CVReturn allocation = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, s->pool, (__bridge CFDictionaryRef)aux, &buffer);
      if (allocation == kCVReturnWouldExceedAllocationThreshold) {
        dispatch_async(dispatch_get_main_queue(), ^{ result(@{@"paused":@YES}); }); return;
      }
      require(allocation == kCVReturnSuccess, "Cannot acquire output buffer");
      require(CVMetalTextureCacheCreateTextureFromImage(nil, s->cache, buffer, nil, MTLPixelFormatBGRA8Unorm, w, h, 0, &target) == kCVReturnSuccess,
              "Cannot bridge IOSurface to Metal");
      MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
      pass.colorAttachments[0].texture = CVMetalTextureGetTexture(target);
      pass.colorAttachments[0].loadAction = MTLLoadActionClear;
      pass.colorAttachments[0].storeAction = MTLStoreActionStore;
      pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
      pass.depthAttachment.texture = s->depth;
      pass.depthAttachment.loadAction = MTLLoadActionClear;
      pass.depthAttachment.storeAction = MTLStoreActionDontCare;
      pass.depthAttachment.clearDepth = 1;
      NSArray<NSString*>* ids = args[@"ids"];
      NSData* values = bytes(args[@"values"]); NSData* blends = bytes(args[@"blends"]);
      require(ids.count <= 1024 && values.length == ids.count * sizeof(double) &&
              blends.length == ids.count * sizeof(int32_t), "Invalid parameter batch");
      std::vector<const char*> names;
      for (NSString* name in ids) names.push_back(name.UTF8String);
      id<MTLCommandBuffer> command = [s->commands commandBuffer];
      TsGpuFrame frame{names.data(), (const double*)values.bytes, (const int32_t*)blends.bytes,
        (int)ids.count, w, h, [args[@"delta"] doubleValue], (__bridge void*)command, (__bridge void*)pass};
      double timing[2]{};
      if (!s->api->draw(s->scene, &frame, timing)) throw std::runtime_error(s->api->error());
      auto submitted = std::chrono::steady_clock::now();
      [command commit]; [command waitUntilCompleted];
      require(command.status == MTLCommandBufferStatusCompleted, "Metal command failed");
      double present = micros(submitted);
      CFRelease(target); target = nil;
      @synchronized(s) {
        if (s->front) CVPixelBufferRelease(s->front);
        s->front = buffer; buffer = nil;
      }
      NSDictionary* metrics = @{@"updateMicros":@(timing[0]), @"submitMicros":@(timing[1]),
        @"presentMicros":@(present), @"width":@(w), @"height":@(h)};
      dispatch_async(dispatch_get_main_queue(), ^{
        if (self.scenes[@(s->textureId)] == s) [self.registry textureFrameAvailable:s->textureId];
        result(metrics);
      });
    } catch (const std::exception& e) {
      if (target) CFRelease(target);
      if (buffer) CVPixelBufferRelease(buffer);
      NSString* message = [NSString stringWithUTF8String:e.what()];
      dispatch_async(dispatch_get_main_queue(), ^{ result([FlutterError errorWithCode:@"gpu" message:message details:nil]); });
    }
  } });
}
@end
