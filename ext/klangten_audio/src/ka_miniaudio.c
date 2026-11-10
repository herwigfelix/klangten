/*
 * A part of Klangten. Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT).
 * GNU General Public License, version 3.
 *
 * The miniaudio implementation (David Reid, public domain or MIT-0). Its own
 * decoders and encoders are left out: FFmpeg and LAME do that here.
 */
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_ENGINE
#define MA_NO_NODE_GRAPH
#define MA_NO_RESOURCE_MANAGER
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#if defined(__APPLE__) && TARGET_OS_IPHONE
#import <AVFoundation/AVFoundation.h>
/*
 * iOS: since iOS 14 the built-in microphone of most iPhones records in
 * stereo, but only when a data source with the stereo polar pattern is
 * chosen; otherwise the input is mono and a stereo request leaves the right
 * channel empty. Called right before a stereo recording starts, while the
 * session is in playAndRecord. Leaves a headset or external microphone
 * alone. Returns 1 if stereo was chosen.
 */
int ka_ios_prefer_stereo_input(void) {
    @autoreleasepool {
        if (@available(iOS 14.0, *)) {
            AVAudioSession *session = [AVAudioSession sharedInstance];
            AVAudioSessionPortDescription *mic = nil;
            AVAudioSessionPortDescription *current = session.currentRoute.inputs.firstObject;
            NSError *err = nil;
            if (current != nil && ![current.portType isEqualToString:AVAudioSessionPortBuiltInMic]) return 0;
            for (AVAudioSessionPortDescription *port in session.availableInputs) {
                if ([port.portType isEqualToString:AVAudioSessionPortBuiltInMic]) { mic = port; break; }
            }
            if (mic == nil) return 0;
            for (AVAudioSessionDataSourceDescription *source in mic.dataSources) {
                if (![source.supportedPolarPatterns containsObject:AVAudioSessionPolarPatternStereo]) continue;
                if (![source setPreferredPolarPattern:AVAudioSessionPolarPatternStereo error:&err]) return 0;
                if (![mic setPreferredDataSource:source error:&err]) return 0;
                if (![session setPreferredInput:mic error:&err]) return 0;
                [session setPreferredInputOrientation:AVAudioStereoOrientationPortrait error:&err];
                if (session.maximumInputNumberOfChannels >= 2)
                    [session setPreferredInputNumberOfChannels:2 error:&err];
                return 1;
            }
        }
    }
    return 0;
}
#endif
