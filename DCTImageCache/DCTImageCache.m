//
//  DCTImageCache.m
//  DCTImageCache
//
//  Created by Daniel Tull on 25.05.2012.
//  Copyright (c) 2012 Daniel Tull Limited. All rights reserved.
//

#import "DCTImageCache.h"
#import "_DCTDiskImageCache.h"
#import "_DCTMemoryImageCache.h"
#import "_DCTImageCacheOperation.h"
#import "NSOperationQueue+_DCTImageCache.h"

@implementation DCTImageCache {
	_DCTMemoryImageCache *_memoryCache;
	_DCTDiskImageCache *_diskCache;
	NSOperationQueue *_queue;
	NSMutableDictionary *_completions;
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
	_diskCache = [[_DCTDiskImageCache alloc] initWithPath:path];

	_queue = [NSOperationQueue new];
	_queue.maxConcurrentOperationCount = 10;
	_queue.name = [NSString stringWithFormat:@"uk.co.danieltull.DCTImageCacheQueue.%@", name];

	_completions = [NSMutableDictionary new];

	_name = [name copy];
	_memoryCache = [_DCTMemoryImageCache new];
	
	return self;
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

	_DCTImageCacheOperation *hasImage = [_diskCache hasImageOperationForKey:key size:size];
	
	_DCTImageCacheOperation *handler = [_DCTImageCacheOperation handlerOperationWithKey:key size:size handler:^(BOOL hasImage, UIImage *image) {

		if (hasImage) return;
		
		if ([_diskCache imageForKey:key size:size]) return;

		_DCTImageCacheOperation *fetchOperation = [_queue dctImageCache_operationOfType:_DCTImageCacheOperationTypeFetch withKey:key size:size];
		if (fetchOperation) return;

		fetchOperation = [_DCTImageCacheOperation fetchOperationWithKey:key size:size block:^(void(^completion)(UIImage *image)) {
			self.imageFetcher(key, size);
			[_completions setObject:completion forKey:[self _accessKeyForKey:key size:size]];
		}];
		fetchOperation.queuePriority = NSOperationQueuePriorityVeryLow;
		[_queue addOperation:fetchOperation];
	}];

	[handler addDependency:hasImage];
	[_queue addOperation:handler];
}

- (NSOperation *)fetchImageForKey:(NSString *)key size:(CGSize)size handler:(void (^)(UIImage *))handler {

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

	// Check if there's a network fetch in the queue, if there is, a disk fetch is on the disk queue, or failed.
	_DCTImageCacheOperation *fetchOperation = [_queue dctImageCache_operationOfType:_DCTImageCacheOperationTypeFetch withKey:key size:size];

	if (!fetchOperation) {

		_DCTImageCacheOperation *diskFetchOperation = [_diskCache fetchImageOperationForKey:key size:size];

		fetchOperation = [_DCTImageCacheOperation fetchOperationWithKey:key size:size block:^(void(^completion)(UIImage *image)) {
			[_completions setObject:completion forKey:[self _accessKeyForKey:key size:size]];
			self.imageFetcher(key, size);
		}];
		fetchOperation.queuePriority = NSOperationQueuePriorityVeryHigh;
		[fetchOperation addDependency:diskFetchOperation];
		[_queue addOperation:fetchOperation];

		_DCTImageCacheOperation *handlerOperation = [_DCTImageCacheOperation handlerOperationWithKey:key size:size handler:^(BOOL hasImage, UIImage *image) {
			[_memoryCache setImage:image forKey:key size:size];
		}];
		handlerOperation.queuePriority = NSOperationQueuePriorityVeryHigh;
		[handlerOperation addDependency:fetchOperation];
		[_queue addOperation:handlerOperation];
	}

	// Create a handler operation to be executed once an operation is finished
	_DCTImageCacheOperation *handlerOperation = [_DCTImageCacheOperation handlerOperationWithKey:key size:size handler:^(BOOL hasImage, UIImage *image) {
		handler(image);
	}];
	handlerOperation.queuePriority = NSOperationQueuePriorityVeryHigh;
	[handlerOperation addDependency:fetchOperation];
	[_queue addOperation:handlerOperation];

	return handlerOperation;
}

- (NSString *)_accessKeyForKey:(NSString *)key size:(CGSize)size {
	return [NSString stringWithFormat:@"%@.%@", key, NSStringFromCGSize(size)];
}

- (void)setImage:(UIImage *)image forKey:(NSString *)key size:(CGSize)size {
	NSString *accessKey = [self _accessKeyForKey:key size:size];
	void(^completion)(UIImage *image) = [_completions objectForKey:accessKey];
	if (completion != NULL) {
		completion(image);
		[_completions removeObjectForKey:accessKey];
	}
	[_diskCache setImageOperationWithImage:image forKey:key size:size];
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
