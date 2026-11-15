// SGLyricsClip.h says what this draws. The words are laid out once per clip and only the backdrop moves,
// so an animated clip costs a scaled image draw and an encode a frame.
#import <Accelerate/Accelerate.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreText/CoreText.h>
#import "Core/SGLog.h"
#import "SGLyricsClip.h"

// The lock screen fills the screen with a 3:4 clip, so a phone's taller screen cuts its sides off: the
// words keep to this middle share of the width. The center of the words sits this far down, clear of
// the clock above and the controls below.
// ponytail: guessed from the screen's shape, not measured on a lock screen; tune both on a device.
static const CGFloat kColumn = 0.56;
static const CGFloat kCentreY = 0.5;
// The words' size as a share of the width, made smaller down to kSmallest of it while they run taller
// than kTallest of the height.
static const CGFloat kFont = 0.05;
static const CGFloat kSmallest = 0.6;
static const CGFloat kTallest = 0.4;
static const CGFloat kNextAlpha = 0.4;
// A still is one frame held this long; an animated clip breathes once over kLoopSeconds, which is all it
// plays before the lock screen loops it.
static const int32_t kStillSeconds = 2;
static const int32_t kLoopSeconds = 4;
static const int32_t kFPS = 15;   // the breath is slow; at 24 a line took about 4 s to write on the CPU
static const CGFloat kBreath = 0.06;   // how much bigger the cover grows at the top of a breath
// Over moving artwork, judged on bright, busy and dark clips in harness/lyrics-clip: the picture is dimmed by
// kMotionDim, and by kBandDim where the words sit, fading between the two over kBandReach of the height above
// and below the middle, so white in it stays under 0.4 of the words' white there; behind the words it is
// blurred, a tent kSoftWidth of the width across, so its edges do not cross the letters; the words carry a
// tight dark shadow kShadowBlur of the font size wide, and the dimmed lines are kMotionNextAlpha white.
static const CGFloat kMotionDim = 0.25, kBandDim = 0.6, kBandReach = 0.3, kSoftWidth = 0.06;
static const CGFloat kShadowAlpha = 0.9, kShadowBlur = 0.15, kMotionNextAlpha = 0.55;
// A faster video keeps only this many frames a second: each costs a draw on the CPU.
static const double kMotionFPS = 30;

CGSize SGLyricsClipSize(CGFloat pixels) {
    CGFloat width = MAX(floor(pixels / 16) * 16, 16);
    return CGSizeMake(width, round(width * 4 / 3 / 16) * 16);
}

static CGContextRef newContext(CGSize size, void *data, size_t bytesPerRow) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(data, (size_t)size.width, (size_t)size.height, 8, bytesPerRow, space,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    return context;
}

// The width the cover is blurred at, before it is drawn at the clip's size.
static const CGFloat kBackdropWidth = 128;

CGImageRef SGLyricsClipBackdrop(CGImageRef cover, CGSize size) {
    CGContextRef context = newContext(size, NULL, 0);
    CGRect bounds = {CGPointZero, size};
    CGContextSetRGBFillColor(context, 0.11, 0.11, 0.12, 1);
    CGContextFillRect(context, bounds);
    if (cover) {
        static CIContext *renderer;
        static dispatch_once_t once;
        // On the CPU: the lock screen asks while Spotify is in the background, where GPU work gets it killed.
        dispatch_once(&once, ^{ renderer = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES}]; });
        // Blurred small and drawn large: a blur this wide looks the same either way, and on the CPU at full size it
        // took 12 to 20 s for a song's first line.
        CGSize small = CGSizeMake(kBackdropWidth, round(kBackdropWidth * size.height / size.width));
        // Filled the way the lock screen fills the screen, the square cover's sides overflowing.
        CIImage *image = [CIImage imageWithCGImage:cover];
        CGFloat scale = MAX(small.width / image.extent.size.width, small.height / image.extent.size.height);
        image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
        image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation((small.width - image.extent.size.width) / 2,
                                                                                 (small.height - image.extent.size.height) / 2)];
        // Clamped first, so the blur does not pull the dark in from past the edges.
        image = [[image imageByClampingToExtent] imageByApplyingGaussianBlurWithSigma:small.width * 0.05];
        CGImageRef blurred = [renderer createCGImage:image fromRect:(CGRect){CGPointZero, small}];
        CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
        if (blurred) CGContextDrawImage(context, bounds, blurred);
        CGImageRelease(blurred);
        // Darkened, so white words read over a light cover.
        CGContextSetRGBFillColor(context, 0, 0, 0, 0.45);
        CGContextFillRect(context, bounds);
    }
    CGImageRef backdrop = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return backdrop;
}

static NSAttributedString *wordsAt(NSString *previous, NSString *line, NSString *next, CGFloat fontSize, CGFloat dimAlpha) {
    CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, fontSize, NULL);
    CGFloat spacing = fontSize * 0.6;
    CTParagraphStyleSetting settings[] = {
        {kCTParagraphStyleSpecifierParagraphSpacingBefore, sizeof(spacing), &spacing},
    };
    CTParagraphStyleRef paragraph = CTParagraphStyleCreate(settings, 1);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat white[] = {1, 1, 1, 1}, dim[] = {1, 1, 1, dimAlpha};
    CGColorRef lit = CGColorCreate(space, white), unlit = CGColorCreate(space, dim);
    NSMutableAttributedString *words = [NSMutableAttributedString new];
    NSDictionary *base = @{(id)kCTFontAttributeName: (__bridge id)font, (id)kCTParagraphStyleAttributeName: (__bridge id)paragraph};
    NSString *texts[] = {previous, line, next};
    for (int i = 0; i < 3; i++) {
        if (!texts[i].length) continue;
        NSMutableDictionary *attributes = [base mutableCopy];
        attributes[(id)kCTForegroundColorAttributeName] = (__bridge id)(i == 1 ? lit : unlit);
        NSString *text = words.length ? [@"\n" stringByAppendingString:texts[i]] : texts[i];
        [words appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attributes]];
    }
    CFRelease(font);
    CFRelease(paragraph);
    CGColorRelease(lit);
    CGColorRelease(unlit);
    CGColorSpaceRelease(space);
    return words;
}

// The words alone on a clear image the size of the clip, nil when there are none. Over moving artwork they
// carry a shadow, the dimmed lines are less dim, and the image is only the words' box, which `drawn` gets
// the place of in the clip.
static CGImageRef newWords(NSString *previous, NSString *line, NSString *next, CGSize size, CGRect *drawn, CGFloat *scrollDistance) CF_RETURNS_RETAINED {
    if (!previous.length && !line.length && !next.length) return NULL;
    CGFloat width = round(size.width * kColumn);
    CGFloat fontSize = size.width * kFont;
    CTFramesetterRef setter = NULL;
    CGSize fits = CGSizeZero;
    // A long line is set smaller until the two lines fit; past the smallest size it runs taller.
    for (CGFloat scale = 1; scale >= kSmallest - 0.01; scale -= 0.1) {
        if (setter) CFRelease(setter);
        setter = CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)wordsAt(previous, line, next, fontSize * scale, drawn ? kMotionNextAlpha : kNextAlpha));
        fits = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRangeMake(0, 0), NULL, CGSizeMake(width, CGFLOAT_MAX), NULL);
        if (fits.height <= size.height * kTallest) break;
    }
    CGFloat height = ceil(fits.height) + 1;
    // Core Graphics counts up from the bottom.
    CGRect box = CGRectMake(round((size.width - width) / 2), round(size.height * (1 - kCentreY) - height / 2), width, height);
    CGPathRef path = CGPathCreateWithRect(box, NULL);
    CTFrameRef frame = CTFramesetterCreateFrame(setter, CFRangeMake(0, 0), path, NULL);
    CGContextRef context = newContext(size, NULL, 0);
    if (drawn) {
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGFloat shade[] = {0, 0, 0, kShadowAlpha};
        CGColorRef color = CGColorCreate(space, shade);
        CGContextSetShadowWithColor(context, CGSizeZero, fontSize * kShadowBlur, color);
        CGColorRelease(color);
        CGColorSpaceRelease(space);
    }
    // For moving lyrics, find the baseline of the current paragraph and the next one. Moving the
    // rendered word image by this exact distance brings the next line into the current line's place.
    if (scrollDistance) {
        *scrollDistance = 0;
        if (line.length && next.length) {
            CFArrayRef frameLines = CTFrameGetLines(frame);
            CFIndex count = CFArrayGetCount(frameLines);
            CGPoint *origins = count ? calloc((size_t)count, sizeof(CGPoint)) : NULL;
            if (origins) {
                CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), origins);
                CFIndex currentIndex = -1, nextIndex = -1;
                CFIndex currentStart = (CFIndex)(previous.length ? previous.length + 1 : 0);
                CFIndex nextStart = currentStart + (CFIndex)line.length + 1;
                for (CFIndex i = 0; i < count; i++) {
                    CFRange range = CTLineGetStringRange((CTLineRef)CFArrayGetValueAtIndex(frameLines, i));
                    if (currentIndex < 0 && range.location <= currentStart && range.location + range.length > currentStart) currentIndex = i;
                    if (nextIndex < 0 && range.location <= nextStart && range.location + range.length > nextStart) nextIndex = i;
                }
                if (currentIndex >= 0 && nextIndex > currentIndex)
                    *scrollDistance = MAX(0, origins[currentIndex].y - origins[nextIndex].y);
                free(origins);
            }
        }
    }
    CTFrameDraw(frame, context);
    CGImageRef words = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (drawn) {
        // Out to the shadow's reach, inside the clip; an image is cut from the top, Core Graphics counts from the bottom.
        *drawn = CGRectIntersection(CGRectIntegral(CGRectInset(box, -fontSize, -fontSize)), (CGRect){CGPointZero, size});
        CGImageRef cut = CGImageCreateWithImageInRect(words, CGRectMake(drawn->origin.x, size.height - CGRectGetMaxY(*drawn),
                                                                        drawn->size.width, drawn->size.height));
        CGImageRelease(words);
        words = cut;
    }
    CFRelease(frame);
    CGPathRelease(path);
    CFRelease(setter);
    return words;
}

// A frame `phase` of the way through the loop, 0 to 1, into `context`.
static void drawFrame(CGContextRef context, CGImageRef backdrop, CGImageRef words, CGSize size, double phase) {
    CGFloat grow = kBreath * (1 - cos(2 * M_PI * phase)) / 2;
    CGRect bounds = {CGPointZero, size};
    CGContextDrawImage(context, CGRectInset(bounds, -size.width * grow / 2, -size.height * grow / 2), backdrop);
    if (words) CGContextDrawImage(context, bounds, words);
}

CGImageRef SGLyricsClipFrame(CGImageRef backdrop, NSString *line, NSString *next, CGSize size) {
    CGImageRef words = newWords(nil, line, next, size, NULL, NULL);
    CGContextRef context = newContext(size, NULL, 0);
    drawFrame(context, backdrop, words, size, 0);
    CGImageRef frame = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    CGImageRelease(words);
    return frame;
}

BOOL SGLyricsClipWrite(NSURL *file, CGImageRef backdrop, NSString *line, NSString *next, CGSize size, SGLyricsClipStyle style) {
    // Written beside the file and moved over it once whole, so a clip cut off halfway is never found.
    NSURL *partial = [file URLByAppendingPathExtension:@"partial"];
    [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:partial fileType:AVFileTypeMPEG4 error:nil];
    if (!writer) return NO;
    int32_t frames = style == SGLyricsClipAnimated ? kLoopSeconds * kFPS : 1;
    CMTime length = CMTimeMake(style == SGLyricsClipAnimated ? kLoopSeconds : kStillSeconds, 1);
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(size.width),
        AVVideoHeightKey: @(size.height),
        AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @(2000000), AVVideoMaxKeyFrameIntervalKey: @(kFPS)},
    }];
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
        sourcePixelBufferAttributes:@{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(size.width),
            (id)kCVPixelBufferHeightKey: @(size.height),
        }];
    if (![writer canAddInput:input]) return NO;
    [writer addInput:input];
    if (![writer startWriting]) return NO;
    [writer startSessionAtSourceTime:kCMTimeZero];
    CGImageRef words = newWords(nil, line, next, size, NULL, NULL);
    BOOL ok = YES;
    for (int32_t i = 0; i < frames && ok; i++) {
        while (!input.readyForMoreMediaData && writer.status == AVAssetWriterStatusWriting) [NSThread sleepForTimeInterval:0.002];
        CVPixelBufferRef buffer = NULL;
        ok = writer.status == AVAssetWriterStatusWriting && adaptor.pixelBufferPool
            && CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &buffer) == kCVReturnSuccess;
        if (!ok) break;
        CVPixelBufferLockBaseAddress(buffer, 0);
        CGContextRef context = newContext(size, CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetBytesPerRow(buffer));
        drawFrame(context, backdrop, words, size, (double)i / frames);
        CGContextRelease(context);
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        ok = [adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake(i, kFPS)];
        CVPixelBufferRelease(buffer);
    }
    CGImageRelease(words);
    if (!ok) {
        [writer cancelWriting];
        return NO;
    }
    [input markAsFinished];
    // The last frame, or a still's only one, is held to the end of the loop.
    [writer endSessionAtSourceTime:length];
    dispatch_semaphore_t written = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(written); }];
    dispatch_semaphore_wait(written, DISPATCH_TIME_FOREVER);
    if (writer.status != AVAssetWriterStatusCompleted) {
        SGLog(@"lock lyrics: still writer finish failed output=%@ status=%ld error=%@", file.lastPathComponent, (long)writer.status, writer.error ?: @"none");
        return NO;
    }
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    NSError *moveError = nil;
    BOOL moved = [NSFileManager.defaultManager moveItemAtURL:partial toURL:file error:&moveError];
    NSDictionary *attributes = moved ? [NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil] : nil;
    SGLog(@"lock lyrics: motion writer finished output=%@ moved=%@ bytes=%@ move-error=%@", file.lastPathComponent, moved ? @"YES" : @"NO", attributes[NSFileSize] ?: @0, moveError ?: @"none");
    return moved;
}

// Over moving artwork. The video is read as BGRA, the dimming and the words are drawn into each frame where
// it lies, at the video's own size, and the encoder cuts the 3:4 middle out as SGMotionClip.m's cut does,
// so the picture is never scaled on the CPU: a frame costs a fill, a gradient and one image draw.

typedef struct {
    CGSize stored, cut;   // the video's size, and the 3:4 middle of it the clip keeps
    double length;        // the video's, in seconds
} Motion;

// The video's track, nil when it has none or a transform turns it.
static AVAssetTrack *motionTrack(AVURLAsset *asset, Motion *motion) {
    __block AVAssetTrack *track = nil;
    dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
    __block NSError *trackError = nil;
    [asset loadTracksWithMediaType:AVMediaTypeVideo completionHandler:^(NSArray<AVAssetTrack *> *tracks, NSError *error) {
        track = tracks.firstObject;
        trackError = error;
        dispatch_semaphore_signal(loaded);
    }];
    dispatch_semaphore_wait(loaded, DISPATCH_TIME_FOREVER);
    if (!track) {
        SGLog(@"lock lyrics: motion track load failed file=%@ error=%@", asset.URL.lastPathComponent, trackError ?: @"no video track");
        return nil;
    }
    if (!CGAffineTransformIsIdentity(track.preferredTransform)) {
        SGLog(@"lock lyrics: motion track rejected file=%@ reason=preferred-transform transform=%@", asset.URL.lastPathComponent, NSStringFromCGAffineTransform(track.preferredTransform));
        return nil;
    }
    // shortcut: a turned video (none seen among Canvases or Apple Music's covers) falls back to the blurred
    // cover; drawing the words turned with it is the step up if one turns up.
    if (!track || !CGAffineTransformIsIdentity(track.preferredTransform)) return nil;
    // Whole pixels: the decoded frames are, and drawOver checks each against this.
    CGSize stored = CGSizeMake(round(track.naturalSize.width), round(track.naturalSize.height));
    double length = CMTimeGetSeconds(track.timeRange.duration);
    if (stored.width < 16 || stored.height < 16 || !(length > 0)) {
        SGLog(@"lock lyrics: motion track rejected file=%@ size=%.0fx%.0f duration=%.3f", asset.URL.lastPathComponent, stored.width, stored.height, length);
        return nil;
    }
    CGSize cut = stored.width / stored.height > 0.75 ? CGSizeMake(stored.height * 0.75, stored.height)
                                                     : CGSizeMake(stored.width, stored.width / 0.75);
    // H.264 takes even sides, rounded down so the cut stays inside the picture.
    *motion = (Motion){stored, CGSizeMake(floor(cut.width / 2) * 2, floor(cut.height / 2) * 2), length};
    return track;
}

// The cut's place in the stored frame, which Core Graphics counts from the bottom; it is the middle, so the
// same from the top.
static CGRect cutIn(Motion motion) {
    return CGRectMake(round((motion.stored.width - motion.cut.width) / 2), round((motion.stored.height - motion.cut.height) / 2),
                      motion.cut.width, motion.cut.height);
}

// What is drawn over every frame of a clip, made once for it.
typedef struct {
    CGImageRef words;     // the words' box, NULL for none
    CGRect drawn;         // where it goes in the cut
    CGFloat scrollDistance; // baseline distance from the sung line to the next one
    uint16_t *keep;       // how much of the picture each row of the cut keeps, of 256, from the top: the dimming
    CGRect soft;          // the rows behind the words, across the cut, in the stored frame
    uint8_t *blurred;     // those rows blurred, NULL with no words
    uint16_t *feather;    // how much of the blurred rows each row takes, of 256, fading in and out at the top and bottom
} Over;

// How dark row `y` of `height` (from the top) is made: kBandDim across the middle 40% of the band about the
// words, kMotionDim past it, straight between.
static CGFloat dimAt(size_t y, size_t height) {
    CGFloat reach = height * kBandReach, t = (y - (height * kCentreY - reach)) / (2 * reach);
    if (t <= 0 || t >= 1) return kMotionDim;
    CGFloat edge = MIN(MIN(t, 1 - t) / 0.3, 1);
    return kMotionDim + (kBandDim - kMotionDim) * edge;
}

static Over makeOver(Motion motion, NSString *previous, NSString *line, NSString *next) {
    Over over = {0};
    over.words = newWords(previous, line, next, motion.cut, &over.drawn, &over.scrollDistance);
    size_t rows = (size_t)motion.cut.height;
    over.keep = malloc(rows * sizeof(uint16_t));
    for (size_t y = 0; y < rows; y++) over.keep[y] = (uint16_t)round(256 * (1 - dimAt(y, rows)));
    if (!over.words) return over;
    CGRect cut = cutIn(motion);
    // Blur the whole path the words travel through, not just their starting position.
    CGRect swept = CGRectUnion(over.drawn, CGRectOffset(over.drawn, 0, over.scrollDistance));
    swept = CGRectIntersection(swept, (CGRect){CGPointZero, motion.cut});
    over.soft = CGRectMake(cut.origin.x, cut.origin.y + swept.origin.y, cut.size.width, swept.size.height);
    // Faded over the margin newWords leaves about the words, a font size, so every line is on blurred picture.
    size_t width = (size_t)over.soft.size.width, height = (size_t)over.soft.size.height;
    size_t fade = MAX(MIN((size_t)(motion.cut.width * kFont), height / 2), 1);
    over.blurred = malloc(width * height * 4);
    over.feather = malloc(height * sizeof(uint16_t));
    for (size_t y = 0; y < height; y++) over.feather[y] = (uint16_t)(256 * MIN(1.0, MIN(y, height - 1 - y) / (double)fade));
    return over;
}

static void freeOver(Over over) {
    CGImageRelease(over.words);
    free(over.keep);
    free(over.blurred);
    free(over.feather);
}

// The softening, the dimming and the words, drawn into `buffer`, a BGRA frame of the video: the rows behind
// the words blurred (Accelerate's tent blur) and faded in, every row of the cut darkened by its share in one
// pass, and one image the size of the words. All on the CPU. NO, with the frame left as it is, for a frame of
// another size or format than the track states, so the clip is not written without its words.
static BOOL drawOver(CVPixelBufferRef buffer, Motion motion, Over over, double elapsed, double scrollStart, double scrollDuration) {
    CVPixelBufferLockBaseAddress(buffer, 0);
    uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(buffer);
    CGRect cut = cutIn(motion);
    // Every write below is placed by the track's natural size, which the file states: a decoded frame of another
    // size or format is left as it is rather than written past its end.
    size_t frameWidth = CVPixelBufferGetWidth(buffer), frameHeight = CVPixelBufferGetHeight(buffer);
    CGRect frame = CGRectMake(0, 0, frameWidth, frameHeight);
    if (!base || CVPixelBufferIsPlanar(buffer) || CVPixelBufferGetPixelFormatType(buffer) != kCVPixelFormatType_32BGRA
        || frameWidth != (size_t)motion.stored.width || frameHeight != (size_t)motion.stored.height || bytesPerRow < frameWidth * 4
        || !CGRectContainsRect(frame, cut) || (over.blurred && !CGRectContainsRect(frame, over.soft))) {
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        return NO;
    }
    if (over.blurred) {
        // An image counts its rows from the top, Core Graphics from the bottom.
        size_t top = (size_t)(motion.stored.height - CGRectGetMaxY(over.soft)), height = (size_t)over.soft.size.height;
        size_t width = (size_t)over.soft.size.width, rowBytes = width * 4;
        uint8_t *rows = base + top * bytesPerRow + (size_t)over.soft.origin.x * 4;
        vImage_Buffer from = {rows, height, width, bytesPerRow}, to = {over.blurred, height, width, rowBytes};
        uint32_t kernel = (uint32_t)(width * kSoftWidth) | 1;
        if (vImageTentConvolve_ARGB8888(&from, &to, NULL, 0, 0, kernel, kernel, NULL, kvImageEdgeExtend) == kvImageNoError) {
            for (size_t y = 0; y < height; y++) {
                uint8_t *sharp = rows + y * bytesPerRow;
                const uint8_t *soft = over.blurred + y * rowBytes;
                uint16_t share = over.feather[y];
                if (share == 256) memcpy(sharp, soft, rowBytes);
                else if (share) for (size_t i = 0; i < rowBytes; i++) sharp[i] += (uint8_t)(((soft[i] - sharp[i]) * share) >> 8);
            }
        }
    }
    // Blue and red, then green, each scaled in its own lane of the pixel; alpha is left as it is.
    size_t top = (size_t)cut.origin.y, width = (size_t)cut.size.width;
    for (size_t y = 0; y < (size_t)cut.size.height; y++) {
        uint32_t *pixel = (uint32_t *)(base + (top + y) * bytesPerRow) + (size_t)cut.origin.x, keep = over.keep[y];
        for (size_t x = 0; x < width; x++) {
            uint32_t v = pixel[x];
            pixel[x] = (((v & 0x00FF00FFu) * keep >> 8) & 0x00FF00FFu) | (((v & 0x0000FF00u) * keep >> 8) & 0x0000FF00u) | (v & 0xFF000000u);
        }
    }
    if (over.words) {
        CGContextRef context = newContext(motion.stored, base, bytesPerRow);
        // Smoothly move the next lyric into the sung line's place. The final second of the clip
        // is held still so the lock screen can replace this artwork at the lyric boundary.
        double t = scrollDuration > 0 ? MIN(MAX((elapsed - scrollStart) / scrollDuration, 0), 1) : 0;
        CGFloat progress = (CGFloat)(t * t * (3 - 2 * t));
        CGRect destination = CGRectOffset(over.drawn, cut.origin.x, cut.origin.y + over.scrollDistance * progress);
        CGContextDrawImage(context, destination, over.words);
        CGContextRelease(context);
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return YES;
}

// Each frame of the video from `from` seconds (taken round its length) for `seconds`, round its end as often
// as needed, timed from 0, to `each`, which returns NO to stop. NO when a read failed.
static BOOL eachFrame(AVURLAsset *asset, AVAssetTrack *track, Motion motion, double from, double seconds,
                      BOOL (^each)(CMSampleBufferRef sample)) {
    int32_t scale = 600;   // a tick that 24, 25, 30 and 60 fps all land on
    double at = fmod(MAX(from, 0), motion.length), done = 0;
    // When the next frame is due: kMotionFPS on a schedule, so a 60 fps video keeps every other frame.
    double due = 0;
    while (seconds - done > 0.01) {
        double take = MIN(motion.length - at, seconds - done);
        AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
        AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:@{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        }];
        // Copies, so drawing into one never touches a frame the decoder still refers to.
        output.alwaysCopiesSampleData = YES;
        if (!reader) {
            SGLog(@"lock lyrics: frame reader creation failed file=%@ at=%.3f", asset.URL.lastPathComponent, at);
            return NO;
        }
        if (![reader canAddOutput:output]) {
            SGLog(@"lock lyrics: frame reader cannot add output file=%@ status=%ld error=%@", asset.URL.lastPathComponent, (long)reader.status, reader.error ?: @"none");
            return NO;
        }
        [reader addOutput:output];
        reader.timeRange = CMTimeRangeMake(CMTimeMakeWithSeconds(at, scale), CMTimeMakeWithSeconds(take, scale));
        if (![reader startReading]) {
            SGLog(@"lock lyrics: frame reader start failed file=%@ at=%.3f take=%.3f status=%ld error=%@", asset.URL.lastPathComponent, at, take, (long)reader.status, reader.error ?: @"none");
            return NO;
        }
        NSUInteger segmentFrames = 0;
        CMSampleBufferRef sample;
        while ((sample = [output copyNextSampleBuffer])) {
            // The first frame may start before `at`; it shows from the start of this stretch.
            CMTime time = CMTimeMakeWithSeconds(done + MAX(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) - at, 0), scale);
            CMSampleBufferRef timed = NULL;
            CMSampleTimingInfo timing = {kCMTimeInvalid, time, kCMTimeInvalid};
            BOOL keep = CMTimeGetSeconds(time) >= due - 0.002 && CMTimeGetSeconds(time) < done + take
                && CMSampleBufferGetImageBuffer(sample)
                && CMSampleBufferCreateCopyWithNewTiming(NULL, sample, 1, &timing, &timed) == noErr;
            CFRelease(sample);
            if (!keep) continue;
            // A jump in the video (its loop) starts the schedule again rather than keeping a burst of frames.
            due = due + 1.0 / kMotionFPS < CMTimeGetSeconds(time) ? CMTimeGetSeconds(time) + 0.5 / kMotionFPS : due + 1.0 / kMotionFPS;
            segmentFrames++;
            BOOL more = each(timed);
            CFRelease(timed);
            if (!more) {
                [reader cancelReading];
                return YES;
            }
        }
        if (reader.status != AVAssetReaderStatusCompleted) {
            SGLog(@"lock lyrics: frame reader ended abnormally file=%@ at=%.3f take=%.3f frames=%lu status=%ld error=%@", asset.URL.lastPathComponent, at, take, (unsigned long)segmentFrames, (long)reader.status, reader.error ?: @"none");
            return NO;
        }
        if (segmentFrames == 0) {
            SGLog(@"lock lyrics: frame reader produced no usable frames file=%@ at=%.3f take=%.3f", asset.URL.lastPathComponent, at, take);
            return NO;
        }
        done += take;
        at = 0;
    }
    return YES;
}

CGImageRef SGLyricsClipMotionFrame(NSURL *motionFile, NSString *previous, NSString *line, NSString *next, double from) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:motionFile options:nil];
    Motion motion;
    AVAssetTrack *track = motionTrack(asset, &motion);
    if (!track) return NULL;
    Over over = makeOver(motion, previous, line, next);
    __block CGImageRef frame = NULL;
    eachFrame(asset, track, motion, from, motion.length, ^BOOL(CMSampleBufferRef sample) {
        CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sample);
        if (!drawOver(buffer, motion, over, 0, 0, 0)) return NO;
        CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
        CGContextRef context = newContext(motion.stored, CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetBytesPerRow(buffer));
        CGImageRef whole = CGBitmapContextCreateImage(context);
        CGContextRelease(context);
        CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
        frame = CGImageCreateWithImageInRect(whole, cutIn(motion));
        CGImageRelease(whole);
        return NO;
    });
    freeOver(over);
    return frame;
}

BOOL SGLyricsClipWriteOverMotion(NSURL *file, NSURL *motionFile, NSString *previous, NSString *line, NSString *next,
                                 double from, double seconds) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:motionFile options:nil];
    Motion motion;
    AVAssetTrack *track = motionTrack(asset, &motion);
    if (!track) return NO;
    // Remember whether the song's lyric interval hit the eight-second cap before the
    // Canvas duration shortened the clip. A shorter Canvas must not re-enable scrolling.
    BOOL longLineClip = seconds >= 7.99;
    double requestedSeconds = seconds;
    // No longer than the video, which is then written whole and loops as it was made to.
    seconds = MIN(seconds, motion.length);
    NSURL *partial = [file URLByAppendingPathExtension:@"partial"];
    [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:partial fileType:AVFileTypeMPEG4 error:nil];
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(motion.cut.width),
        AVVideoHeightKey: @(motion.cut.height),
        AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
        // As SGMotionClip.m's cut: about 2 Mbit/s at a Canvas's 720 x 960.
        AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @(motion.cut.width * motion.cut.height * 3)},
    }];
    if (!writer) {
        SGLog(@"lock lyrics: motion writer creation failed output=%@ error=%@", file.lastPathComponent, writer.error ?: @"none");
        return NO;
    }
    if (![writer canAddInput:input]) {
        SGLog(@"lock lyrics: motion writer cannot add input output=%@ status=%ld error=%@", file.lastPathComponent, (long)writer.status, writer.error ?: @"none");
        return NO;
    }
    [writer addInput:input];
    if (![writer startWriting]) {
        SGLog(@"lock lyrics: motion writer start failed output=%@ status=%ld error=%@", file.lastPathComponent, (long)writer.status, writer.error ?: @"none");
        return NO;
    }
    [writer startSessionAtSourceTime:kCMTimeZero];
    Over over = makeOver(motion, previous, line, next);
    if (!over.keep || (line.length && !over.words)) {
        SGLog(@"lock lyrics: overlay preparation incomplete output=%@ keep=%@ words=%@ line=%lu next=%lu", file.lastPathComponent, over.keep ? @"YES" : @"NO", over.words ? @"YES" : @"NO", (unsigned long)line.length, (unsigned long)next.length);
    }
    // Mirror the existing timing calculation for diagnostics; the frame-writing path below keeps its own
    // original calculation so this instrumentation does not change how a frame is drawn.
    double loggedLyricDuration = MAX(seconds - 1.0, 0);
    double loggedScrollDuration = longLineClip ? 0 : MIN(0.45, loggedLyricDuration);
    double loggedScrollStart = MAX(loggedLyricDuration - loggedScrollDuration, 0);
    NSString *scrollReason = !line.length ? @"no-current-line"
        : !next.length ? @"no-next-line"
        : over.scrollDistance <= 0 ? @"no-next-baseline"
        : loggedScrollDuration <= 0 ? (longLineClip ? @"eight-second-clip" : @"no-scroll-window")
        : @"scheduled";
    SGLog(@"lock lyrics: scroll plan %@: seconds=%.3f requested=%.3f from=%.3f motion=%.3f current=%@ next=%@ distance=%.2f start=%.3f duration=%.3f reason=%@",
          file.lastPathComponent, seconds, requestedSeconds, from, motion.length, line.length ? @"YES" : @"NO",
          next.length ? @"YES" : @"NO", over.scrollDistance, loggedScrollStart, loggedScrollDuration, scrollReason);
    __block BOOL ok = YES, any = NO;
    __block NSUInteger frameCount = 0;
    __block double firstProgressAt = -1, lastElapsed = -1, lastProgress = 0;
    BOOL read = eachFrame(asset, track, motion, from, seconds, ^BOOL(CMSampleBufferRef sample) {
        double elapsed = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
        double progress = loggedScrollDuration > 0 ? MIN(MAX((elapsed - loggedScrollStart) / loggedScrollDuration, 0), 1) : 0;
        if (progress > 0 && firstProgressAt < 0) firstProgressAt = elapsed;
        lastElapsed = elapsed;
        lastProgress = progress;
        // Keep the lyric still for most of its line, then move it into the next line's place
        // just before the artwork changes. The final second is the existing hand-off allowance.
        // Eight-second clips may loop before a long line changes, so leave those stationary.
        double lyricDuration = MAX(seconds - 1.0, 0);
        double scrollDuration = longLineClip ? 0 : MIN(0.45, lyricDuration);
        double scrollStart = MAX(lyricDuration - scrollDuration, 0);
        CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sample);
        if (!drawOver(pixelBuffer, motion, over, elapsed, scrollStart, scrollDuration)) {
            SGLog(@"lock lyrics: overlay draw failed output=%@ frame=%lu pts=%.3f size=%zux%zu format=%u planar=%@ base=%@", file.lastPathComponent, (unsigned long)frameCount, elapsed, CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), (unsigned int)CVPixelBufferGetPixelFormatType(pixelBuffer), CVPixelBufferIsPlanar(pixelBuffer) ? @"YES" : @"NO", CVPixelBufferGetBaseAddress(pixelBuffer) ? @"YES" : @"NO");
            ok = NO;
            return NO;
        }
        while (!input.readyForMoreMediaData && writer.status == AVAssetWriterStatusWriting) [NSThread sleepForTimeInterval:0.002];
        ok = writer.status == AVAssetWriterStatusWriting && [input appendSampleBuffer:sample];
        any = YES;
        if (ok) frameCount++;
        else SGLog(@"lock lyrics: motion writer append failed output=%@ frame=%lu pts=%.3f status=%ld error=%@", file.lastPathComponent, (unsigned long)frameCount, elapsed, (long)writer.status, writer.error ?: @"not-writing");
        return ok;
    });
    freeOver(over);
    SGLog(@"lock lyrics: scroll output %@: read=%@ writer=%@ frames=%lu first-progress=%.3f last-pts=%.3f last-progress=%.3f",
          file.lastPathComponent, read ? @"YES" : @"NO", ok ? @"YES" : @"NO", (unsigned long)frameCount,
          firstProgressAt, lastElapsed, lastProgress);
    if (!read || !ok || !any) {
        SGLog(@"lock lyrics: motion encode aborted output=%@ read=%@ append=%@ any=%@ frames=%lu writer-status=%ld reader-error-or-state=%@", file.lastPathComponent, read ? @"YES" : @"NO", ok ? @"YES" : @"NO", any ? @"YES" : @"NO", (unsigned long)frameCount, (long)writer.status, writer.error ?: @"see frame-reader log");
        [writer cancelWriting];
        return NO;
    }
    [input markAsFinished];
    [writer endSessionAtSourceTime:CMTimeMakeWithSeconds(seconds, 600)];
    dispatch_semaphore_t written = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(written); }];
    dispatch_semaphore_wait(written, DISPATCH_TIME_FOREVER);
    if (writer.status != AVAssetWriterStatusCompleted) {
        SGLog(@"lock lyrics: motion writer finish failed output=%@ status=%ld error=%@", file.lastPathComponent, (long)writer.status, writer.error ?: @"none");
        return NO;
    }
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    NSError *moveError = nil;
    BOOL moved = [NSFileManager.defaultManager moveItemAtURL:partial toURL:file error:&moveError];
    NSDictionary *attributes = moved ? [NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil] : nil;
    SGLog(@"lock lyrics: motion writer finished output=%@ moved=%@ bytes=%@ move-error=%@", file.lastPathComponent, moved ? @"YES" : @"NO", attributes[NSFileSize] ?: @0, moveError ?: @"none");
    return moved;
}

NSString *SGLyricsClipLook(NSURL *motion, SGLyricsClipStyle style) {
    if (!motion) return [NSString stringWithFormat:@"%ld", (long)style];
    NSString *name = motion.lastPathComponent.stringByDeletingPathExtension;
    return [NSString stringWithFormat:@"m%@s%ld", name.length > 16 ? [name substringToIndex:16] : name, (long)style];
}
