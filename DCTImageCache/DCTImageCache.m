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

#import "_DCTImageCacheFetchOperation.h"
#import "_DCTImageCacheSetOperation.h"
#import "_DCTImageCacheImageOperation.h"

@implementation DCTImageCache {
	_DCTMemoryImageCache *_memoryCache;

	NSOperationQueue *_diskQueue;
	_DCTDiskImageCache *_diskCache;

	NSOperationQueue *_queue;
}

#pragma mark NSObject
/*
+ (void)initialize {
	@autoreleasepool {
		NSDate *now = [NSDate date];
		
		[self _enumerateImageCachesUsingBlock:^(DCTImageCache *imageCache, BOOL *stop) {
			
			_DCTDiskImageCache *diskCache = imageCache.diskCache;
			[diskCache enumerateKeysUsingBlock:^(NSString *key, BOOL *stop) {
			
				[diskCache fetchAttributesForImageWithKey:key size:CGSizeZero handler:^(NSDictionary *attributes) {
				
					if (!attributes) {
						[diskCache removeAllImagesForKey:key];
						return;
					}
						
					NSDate *creationDate = [attributes objectForKey:NSFileCreationDate];
					NSTimeInterval timeInterval = [now timeIntervalSinceDate:creationDate];
					
					if (timeInterval > 604800) // 7 days
						[diskCache removeAllImagesForKey:key];
				}];
			}];
		}];
	}
}
*/
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

	_diskQueue = [NSOperationQueue new];
	_diskQueue.maxConcurrentOperationCount = 1;
	_diskQueue.name = [NSString stringWithFormat:@"uk.co.danieltull.DCTImageCacheDiskQueue.%@", name];
	[_diskQueue addOperationWithBlock:^{
		NSString *path = [[[self class] _defaultCachePath] stringByAppendingPathComponent:name];
		_diskCache = [[_DCTDiskImageCache alloc] initWithPath:path];
	}];

	_queue = [NSOperationQueue new];
	_queue.maxConcurrentOperationCount = 10;
	_queue.name = [NSString stringWithFormat:@"uk.co.danieltull.DCTImageCacheQueue.%@", name];

	_name = [name copy];
	_memoryCache = [_DCTMemoryImageCache new];
	
	return self;
}

- (void)removeAllImages {
	[_memoryCache removeAllImages];
	[self _performVeryLowPriorityBlockOnDiskQueue:^{
		[_diskCache removeAllImages];
	}];
}

- (void)removeAllImagesForKey:(NSString *)key {
	[_memoryCache removeAllImagesForKey:key];
	[self _performVeryLowPriorityBlockOnDiskQueue:^{
		[_diskCache removeAllImagesForKey:key];
	}];
}

- (void)removeImageForKey:(NSString *)key size:(CGSize)size {
	[_memoryCache removeImageForKey:key size:size];
	[self _performVeryLowPriorityBlockOnDiskQueue:^{
		[_diskCache removeImageForKey:key size:size];
	}];
}

- (void)prefetchImageForKey:(NSString *)key size:(CGSize)size {
	[self _performVeryLowPriorityBlockOnDiskQueue:^{
		BOOL hasImage = [_diskCache hasImageForKey:key size:size];
		if (hasImage) return;
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
			_DCTImageCacheSetOperation *diskSaveOperation = [self _operationOfClass:[_DCTImageCacheSetOperation class] onQueue:_diskQueue withKey:key size:size];
			if (diskSaveOperation) return;
			_DCTImageCacheFetchOperation *fetchOperation = [self _operationOfClass:[_DCTImageCacheFetchOperation class] onQueue:_queue withKey:key size:size];
			if (fetchOperation) return;
			fetchOperation = [self _createFetchOperationWithKey:key size:size diskFetchOperation:nil];
			fetchOperation.queuePriority = NSOperationQueuePriorityVeryLow;
			[_queue addOperation:fetchOperation];
		});
	}];
}

- (_DCTImageCacheFetchOperation *)_createFetchOperationWithKey:(NSString *)key size:(CGSize)size diskFetchOperation:(_DCTImageCacheFetchOperation *)diskFetchOperation {

	_DCTImageCacheFetchOperation *fetchOperation = [[_DCTImageCacheFetchOperation alloc] initWithKey:key size:size block:^(void(^imageHander)(UIImage *image)) {

		UIImage *image = diskFetchOperation.fetchedImage;
		if (image) {
			imageHander(image);
			return;
		}

		self.imageFetcher(key, size, ^(UIImage *image) {

			if (!image) return;

			imageHander(image);
			if (diskFetchOperation) [_memoryCache setImage:image forKey:key size:size];
			_DCTImageCacheSetOperation *diskSave = [[_DCTImageCacheSetOperation alloc] initWithKey:key size:size image:image block:^{
				[_diskCache setImage:image forKey:key size:size];
			}];
			diskSave.queuePriority = NSOperationQueuePriorityVeryLow;
			[_diskQueue addOperation:diskSave];
		});
	}];
	return fetchOperation;
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
	_DCTImageCacheSetOperation *diskSaveOperation = [self _operationOfClass:[_DCTImageCacheSetOperation class] onQueue:_diskQueue withKey:key size:size];
	image = diskSaveOperation.image;
	if (image) {
		handler(image);
		return nil;
	}

	// Check if there's a network fetch in the queue, if there is, a disk fetch is on the disk queue, or failed.
	_DCTImageCacheFetchOperation *fetchOperation = [self _operationOfClass:[_DCTImageCacheFetchOperation class] onQueue:_queue withKey:key size:size];

	if (fetchOperation) {

		// Make sure existing disk fetch operation is very high
		_DCTImageCacheFetchOperation *diskFetchOperation = [self _operationOfClass:[_DCTImageCacheFetchOperation class] onQueue:_diskQueue withKey:key size:size];
		diskFetchOperation.queuePriority = NSOperationQueuePriorityVeryHigh;
		
	} else {
		
		_DCTImageCacheFetchOperation *diskFetchOperation = [[_DCTImageCacheFetchOperation alloc] initWithKey:key size:size block:^(void(^imageHander)(UIImage *image)) {
			UIImage *image = [_diskCache imageForKey:key size:size];
			imageHander(image);
			if (image) [_memoryCache setImage:image forKey:key size:size];
		}];
		diskFetchOperation.queuePriority = NSOperationQueuePriorityVeryHigh;

		fetchOperation = [self _createFetchOperationWithKey:key size:size diskFetchOperation:diskFetchOperation];
		fetchOperation.queuePriority = NSOperationQueuePriorityVeryHigh;
		[fetchOperation addDependency:diskFetchOperation];
		[_queue addOperation:fetchOperation];
		[_diskQueue addOperation:diskFetchOperation];
	}

	// Create a handler operation to be executed once an operation is finished
	_DCTImageCacheImageOperation *handlerOperation = [[_DCTImageCacheImageOperation alloc] initWithKey:key size:size imageHandler:handler];
	[handlerOperation addDependency:fetchOperation];
	[_queue addOperation:handlerOperation];
	return handlerOperation;
}

#pragma mark Internal

- (void)_performVeryLowPriorityBlockOnDiskQueue:(void(^)())block {
	NSBlockOperation *blockOperation = [NSBlockOperation blockOperationWithBlock:block];
	[blockOperation setQueuePriority:NSOperationQueuePriorityVeryLow];
	[_diskQueue addOperation:blockOperation];
}

- (id)_operationOfClass:(Class)class onQueue:(NSOperationQueue *)queue withKey:(NSString *)key size:(CGSize)size {

	__block id returnOperation;

	[queue.operations enumerateObjectsUsingBlock:^(_DCTImageCacheOperation *operation, NSUInteger i, BOOL *stop) {

		if (![operation isKindOfClass:class]) return;

		if (!CGSizeEqualToSize(operation.size, size)) return;
		if (![operation.key isEqualToString:key]) return;

		returnOperation = operation;
		*stop = YES;
	}];

	return returnOperation;
}

- (NSArray *)_operationsOfClass:(Class)class onQueue:(NSOperationQueue *)queue withKey:(NSString *)key size:(CGSize)size {

	NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(_DCTImageCacheOperation *operation, NSDictionary *bindings) {
		if (![operation isKindOfClass:class]) return NO;
		if (!CGSizeEqualToSize(operation.size, size)) return NO;
		return [operation.key isEqualToString:key];
	}];

	return [queue.operations filteredArrayUsingPredicate:predicate];
}


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
