//
//  _DCTImageCache.h
//  DCTImageCache
//
//  Created by Daniel Tull on 09.12.2012.
//  Copyright (c) 2012 Daniel Tull. All rights reserved.
//

#import "DCTImageCache.h"
#import "_DCTImageCacheAttributes.h"

#if TARGET_OS_IPHONE
typedef UIImage DCTImageCacheImage;
#else
typedef NSImage DCTImageCacheImage;
#endif

typedef void (^_DCTImageCacheHasImageHandler)(BOOL, NSError *);

@interface DCTImageCache (Private)
+ (NSBundle *)_bundle;
@end
