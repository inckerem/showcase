#ifndef SHOWCASE_VIDEO_IN_CAR_H
#define SHOWCASE_VIDEO_IN_CAR_H

#import <Foundation/Foundation.h>

/* Private messages on the existing service/app Unix socket. */
#define MSG_CAR_VIDEO_COMMAND 0x0D
#define MSG_CAR_VIDEO_REPLY 0x0E
#define CAR_VIDEO_MAX_MESSAGE (60 * 1024)

static inline NSData *car_video_encode(NSDictionary *message) {
    return [NSPropertyListSerialization dataWithPropertyList:message
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
}

static inline NSDictionary *car_video_decode(NSData *data) {
    if (data.length == 0 || data.length > CAR_VIDEO_MAX_MESSAGE) return nil;
    id value = [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:NULL error:NULL];
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

#endif
