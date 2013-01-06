/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDImageCache.h"
#import "SDWebImageDecoder.h"
#import <CommonCrypto/CommonDigest.h>
#import "SDWebImageDecoder.h"
#import <mach/mach.h>
#import <mach/mach_host.h>

static const NSInteger kDefaultCacheMaxCacheAge = 60 * 60 * 24 * 7; // 1 week

@interface SDImageCache ()

@property (strong, nonatomic) NSCache *memCache;
@property (strong, nonatomic) NSURL *diskCacheURL;
@property (strong, nonatomic) NSURL *permanentDiskCacheURL;
@property (SDDispatchQueueSetterSementics, nonatomic) dispatch_queue_t ioQueue;

@end


@implementation SDImageCache

+ (SDImageCache *)sharedImageCache
{
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{instance = self.new;});
    return instance;
}

- (id)init
{
    return [self initWithNamespace:@"default"];
}

- (id)initWithNamespace:(NSString *)ns
{
    if ((self = [super init]))
    {
        NSString *fullNamespace = [@"com.hackemist.SDWebImageCache." stringByAppendingString:ns];

        // Create IO serial queue
        _ioQueue = dispatch_queue_create("com.hackemist.SDWebImageCache", DISPATCH_QUEUE_SERIAL);

        // Init default values
        _maxCacheAge = kDefaultCacheMaxCacheAge;

        // Init the memory cache
        _memCache = [[NSCache alloc] init];
        _memCache.name = fullNamespace;

        NSFileManager *fileManager = NSFileManager.new;

        // Init the disk cache
        NSURL *cachesDirectory = [fileManager URLForDirectory:NSCachesDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
        _diskCacheURL = [cachesDirectory URLByAppendingPathComponent:fullNamespace isDirectory:YES];
        
        // Init permanent disk cache
        NSString *permanentNamespace = [fullNamespace stringByAppendingString:@".permanent"];
        NSURL *applicationSupportDirectory = [fileManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
        _permanentDiskCacheURL = [applicationSupportDirectory URLByAppendingPathComponent:permanentNamespace isDirectory:YES];

#if TARGET_OS_IPHONE
        // Subscribe to app events
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(clearMemory)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(cleanDisk)
                                                     name:UIApplicationWillTerminateNotification
                                                   object:nil];
#endif
    }

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    SDDispatchQueueRelease(_ioQueue);
}

#pragma mark SDImageCache (private)

- (NSURL *)cacheURLForKey:(NSString *)key directory:(NSURL *)dirURL
{
    const char *str = [key UTF8String];
    unsigned char r[CC_MD5_DIGEST_LENGTH];
    CC_MD5(str, (CC_LONG)strlen(str), r);
    NSString *filename = [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
                          r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10], r[11], r[12], r[13], r[14], r[15]];
    
    return [dirURL URLByAppendingPathComponent:filename isDirectory:NO];
}


- (NSString *)cachePathForKey:(NSString *)key
{
    NSURL *cacheUrl = [self cacheURLForKey:key directory:self.diskCacheURL];
    return [cacheUrl path];
}

#pragma mark ImageCache

- (void)storeImage:(UIImage *)image imageData:(NSData *)imageData forKey:(NSString *)key toDisk:(BOOL)toDisk permanent:(BOOL)permanent
{
    if (!image || !key)
    {
        return;
    }

    [self.memCache setObject:image forKey:key cost:image.size.height * image.size.width * image.scale];

    if (toDisk)
    {
        dispatch_async(self.ioQueue, ^
        {
            NSData *data = imageData;

            if (!data)
            {
                if (image)
                {
#if TARGET_OS_IPHONE
                    data = UIImageJPEGRepresentation(image, (CGFloat)1.0);
#else
                    data = [NSBitmapImageRep representationOfImageRepsInArray:image.representations usingType: NSJPEGFileType properties:nil];
#endif
                }
            }

            if (data)
            {
                // Can't use defaultManager another thread
                NSFileManager *fileManager = NSFileManager.new;
                
                NSURL *cacheURL;
                if (permanent) {
                    cacheURL = self.permanentDiskCacheURL;
                } else {
                    cacheURL = self.diskCacheURL;
                }
                
                if (![fileManager fileExistsAtPath:[cacheURL path]])
                {
                    [fileManager createDirectoryAtURL:cacheURL withIntermediateDirectories:YES attributes:nil error:NULL];

                    if (permanent) {
                        // Mark directory for iCloud as "do not back up"
                        [cacheURL setResourceValue:[NSNumber numberWithBool:YES]
                                            forKey:NSURLIsExcludedFromBackupKey error:nil];
                    }
                }

                NSURL *cacheFileURL = [self cacheURLForKey:key directory:cacheURL];
                [fileManager createFileAtPath:[cacheFileURL path] contents:data attributes:nil];
            }
        });
    }
}

- (void)storeImage:(UIImage *)image imageData:(NSData *)imageData forKey:(NSString *)key toDisk:(BOOL)toDisk
{
    [self storeImage:image imageData:imageData forKey:key toDisk:toDisk permanent:NO];
}

- (void)storeImage:(UIImage *)image forKey:(NSString *)key
{
    [self storeImage:image imageData:nil forKey:key toDisk:YES permanent:NO];
}

- (void)storeImage:(UIImage *)image forKey:(NSString *)key toDisk:(BOOL)toDisk
{
    [self storeImage:image imageData:nil forKey:key toDisk:toDisk permanent:NO];
}

- (void)queryDiskCacheForKey:(NSString *)key done:(void (^)(UIImage *image, SDImageCacheType cacheType))doneBlock
{
    if (!doneBlock) return;

    if (!key)
    {
        doneBlock(nil, SDImageCacheTypeNone);
        return;
    }

    // First check the in-memory cache...
    UIImage *image = [self.memCache objectForKey:key];
    if (image)
    {
        doneBlock(image, SDImageCacheTypeMemory);
        return;
    }

    dispatch_async(self.ioQueue, ^
    {
        UIImage *diskImage = [UIImage decodedImageWithImage:SDScaledImageForPath(key, [NSData dataWithContentsOfURL:[self cacheURLForKey:key directory:self.diskCacheURL]])];
        
        // Check permanent cache
        if (!diskImage) {
            diskImage = [UIImage decodedImageWithImage:SDScaledImageForPath(key, [NSData dataWithContentsOfURL:[self cacheURLForKey:key directory:self.permanentDiskCacheURL]])];
        }

        if (diskImage)
        {
            [self.memCache setObject:diskImage forKey:key cost:image.size.height * image.size.width * image.scale];
        }

        dispatch_async(dispatch_get_main_queue(), ^
        {
            doneBlock(diskImage, SDImageCacheTypeDisk);
        });
    });
}

- (void)removeImageForKey:(NSString *)key
{
    [self removeImageForKey:key fromDisk:YES];
}

- (void)removeImageForKey:(NSString *)key fromDisk:(BOOL)fromDisk
{
    if (key == nil)
    {
        return;
    }

    [self.memCache removeObjectForKey:key];

    if (fromDisk)
    {
        dispatch_async(self.ioQueue, ^
        {
            [[NSFileManager defaultManager] removeItemAtURL:[self cacheURLForKey:key directory:self.diskCacheURL] error:nil];
            [[NSFileManager defaultManager] removeItemAtURL:[self cacheURLForKey:key directory:self.permanentDiskCacheURL] error:nil];
        });
    }
}

- (void)clearMemory
{
    [self.memCache removeAllObjects];
}

- (void)clearDisk
{
    dispatch_async(self.ioQueue, ^
    {
        [[NSFileManager defaultManager] removeItemAtURL:self.diskCacheURL error:nil];
        [[NSFileManager defaultManager] removeItemAtURL:self.permanentDiskCacheURL error:nil];
    });
}

- (void)cleanDisk
{
    dispatch_async(self.ioQueue, ^
    {
        NSDate *expirationDate = [NSDate dateWithTimeIntervalSinceNow:-self.maxCacheAge];
        NSDirectoryEnumerator *fileEnumerator = [[NSFileManager defaultManager] enumeratorAtURL:self.diskCacheURL
                                                                     includingPropertiesForKeys:[NSArray arrayWithObject:NSURLContentModificationDateKey]
                                                                                        options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                   errorHandler:nil];
        for (NSURL *theURL in fileEnumerator) {
            
            NSDate *modificationDate;
            [theURL getResourceValue:&modificationDate forKey:NSURLContentModificationDateKey error:NULL];
            if ([[modificationDate laterDate:expirationDate] isEqualToDate:expirationDate]) {
                [[NSFileManager defaultManager] removeItemAtURL:theURL error:nil];
            }
        }
    });
}

- (NSArray *)URLsByExcludingPersistedURLs:(NSArray *)listOfURLs
{
    NSMutableArray *notCached = [NSMutableArray array];
    
    for (id url in listOfURLs) {
        if (![self URLPersisted:url]) {
            [notCached addObject:url];
        }
    }
    
    return notCached;
}

- (BOOL)URLPersisted:(NSURL *)url
{
    if ([url isKindOfClass:[NSString class]]) {
        url = [NSURL URLWithString:(NSString *)url];
    }
    
    if (![url isKindOfClass:[NSURL class]]) {
        return NO;
    }
    
    return [self filePersistedForKey:[url absoluteString]];
}

- (BOOL)filePersistedForKey:(NSString *)key
{
    if ([[NSFileManager defaultManager] fileExistsAtPath:[[self cacheURLForKey:key directory:self.permanentDiskCacheURL] path]]){
        return YES;
    }
    return NO;
}

-(int)getSize
{
//    int size = 0;
//    NSDirectoryEnumerator *fileEnumerator = [[NSFileManager defaultManager] enumeratorAtPath:self.diskCachePath];
//    for (NSString *fileName in fileEnumerator)
//    {
//        NSString *filePath = [self.diskCachePath stringByAppendingPathComponent:fileName];
//        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil];
//        size += [attrs fileSize];
//    }
//    return size;
    return 0;
}

- (int)getDiskCount
{
//    int count = 0;
//    NSDirectoryEnumerator *fileEnumerator = [[NSFileManager defaultManager] enumeratorAtPath:self.diskCachePath];
//    for (NSString *fileName in fileEnumerator)
//    {
//        count += 1;
//    }
//    
//    return count;
    return 0;
}

@end
