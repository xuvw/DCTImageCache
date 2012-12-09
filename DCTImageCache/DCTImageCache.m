//
//  DCTImageCache.m
//  DCTImageCache
//
//  Created by Daniel Tull on 25.05.2012.
//  Copyright (c) 2012 Daniel Tull Limited. All rights reserved.
//

#import "DCTImageCache.h"
#import "_DCTImageCacheDiskCache.h"
#import "_DCTImageCacheMemoryCache.h"
#import "_DCTImageCacheFetcher.h"
#import "_DCTImageCacheProcessManager.h"
#import "_DCTImageCacheOperation.h"

@implementation DCTImageCache {
	_DCTImageCacheMemoryCache *_memoryCache;
	_DCTImageCacheDiskCache *_diskCache;
	_DCTImageCacheFetcher *_fetcher;
}

#pragma mark DCTImageCache

+ (NSMutableDictionary *)imageCaches {
	static NSMutableDictionary *sharedInstance = nil;
	static dispatch_once_t sharedToken;
	dispatch_once(&sharedToken, ^{
		sharedInstance = [NSMutableDictionary new];
	});
	return sharedInstance;
}

+ (DCTImageCache *)defaultImageCache {
	return [self imageCacheWithName:@"DCTDefaultImageCache"];
}

+ (DCTImageCache *)imageCacheWithName:(NSString *)name {
	
	NSMutableDictionary *imageCaches = [self imageCaches];
	DCTImageCache *imageCache = [imageCaches objectForKey:name];
	if (!imageCache) {
		imageCache = [[self alloc] _initWithName:name];
		[imageCaches setObject:imageCache forKey:name];
	}
	return imageCache;
}

- (id)_initWithName:(NSString *)name {
	
	self = [self init];
	if (!self) return nil;

	NSString *path = [[[self class] _defaultCachePath] stringByAppendingPathComponent:name];
	_diskCache = [[_DCTImageCacheDiskCache alloc] initWithPath:path];
	_fetcher = [_DCTImageCacheFetcher new];
	_name = [name copy];
	_memoryCache = [_DCTImageCacheMemoryCache new];
	
	return self;
}

- (void)setImageFetcher:(id<DCTImageCacheProcess> (^)(NSString *, CGSize, id<DCTImageCacheCompletion>))imageFetcher {
	[_fetcher setImageFetcher:imageFetcher];
}

- (id<DCTImageCacheProcess> (^)(NSString *, CGSize, id<DCTImageCacheCompletion>))imageFetcher {
	return [_fetcher imageFetcher];
}

- (void)removeAllImages {
	[_memoryCache removeAllImages];
	[_diskCache removeAllImages];
}

- (void)removeAllImagesForKey:(NSString *)key {
	[_memoryCache removeAllImagesForKey:key];
	[_diskCache removeAllImagesForKey:key];
}

- (void)removeImageForKey:(NSString *)key size:(CGSize)size {
	[_memoryCache removeImageForKey:key size:size];
	[_diskCache removeImageForKey:key size:size];
}

- (void)prefetchImageForKey:(NSString *)key size:(CGSize)size {
	
	[_diskCache hasImageForKey:key size:size handler:^(BOOL hasImage) {

		if (hasImage) return;

		[_fetcher fetchImageForKey:key size:size handler:^(UIImage *image) {
			[_diskCache setImage:image forKey:key size:size];
		}];
	}];
}

- (id<DCTImageCacheProcess>)fetchImageForKey:(NSString *)key size:(CGSize)size handler:(void (^)(UIImage *))handler {

	if (handler == NULL) {
		[self prefetchImageForKey:key size:size];
		return nil;
	}
	
	// If the image exists in the memory cache, use it!
	UIImage *image = [_memoryCache imageForKey:key size:size];
	if (image) {
		handler(image);
		return nil;
	}

	// If the image is in the disk queue to be saved, pull it out and use it
	image = [_diskCache imageForKey:key size:size];
	if (image) {
		handler(image);
		return nil;
	}

	_DCTImageCacheCancelProxy *cancelProxy = [_DCTImageCacheCancelProxy new];
	cancelProxy.imageHandler = handler;
	_DCTImageCacheProcessManager *processManager = [_DCTImageCacheProcessManager new];
	[processManager addCancelProxy:cancelProxy];
	
	processManager.process = [_diskCache fetchImageForKey:key size:size handler:^(UIImage *image) {

		if (image) {
			[_memoryCache setImage:image forKey:key size:size];
			[processManager setImage:image];
			return;
		}

		processManager.process = [_fetcher fetchImageForKey:key size:size handler:^(UIImage *image) {
			[processManager setImage:image];
			[_memoryCache setImage:image forKey:key size:size];
			[_diskCache setImage:image forKey:key size:size];
		}];
	}];

	return cancelProxy;
}

#pragma mark Internal

+ (NSString *)_defaultCachePath {
	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
	return [[paths objectAtIndex:0] stringByAppendingPathComponent:NSStringFromClass(self)];
}

+ (void)_enumerateImageCachesUsingBlock:(void (^)(DCTImageCache *imageCache, BOOL *stop))block {
	NSFileManager *fileManager = [NSFileManager new];
	NSString *cachePath = [[self class] _defaultCachePath];
	NSArray *caches = [[fileManager contentsOfDirectoryAtPath:cachePath error:nil] copy];
	
	[caches enumerateObjectsUsingBlock:^(NSString *name, NSUInteger i, BOOL *stop) {
		DCTImageCache *imageCache = [DCTImageCache imageCacheWithName:name];
		block(imageCache, stop);
	}];
}

@end
