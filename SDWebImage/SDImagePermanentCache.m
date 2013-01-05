//
//  SDImagePermanentCache.m
//  SDWebImage
//
//  Created by Egor Khmelev on 05.01.13.
//  Copyright (c) 2013 Dailymotion. All rights reserved.
//

#import "SDImagePermanentCache.h"

@implementation SDImagePermanentCache

- (id)init
{
    return [self initWithNamespace:@"permanent"];
}

- (void)cleanDisk
{
    // Do nothing, developers should take care of cache removal
}

@end
