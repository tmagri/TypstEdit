#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (nullable id)tryExecute:(id _Nullable (NS_NOESCAPE ^)(void))block error:(__autoreleasing NSError * _Nullable * _Nullable)error {
    @try {
        return block ? block() : nil;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:exception.name ?: @"ObjCException"
                                         code:-1
                                     userInfo:@{
                NSLocalizedDescriptionKey: exception.reason ?: @"Objective-C exception thrown",
                @"NSException": exception
            }];
        }
        return nil;
    }
}

+ (nullable NSAttributedString *)safeAttributedStringForPage:(PDFPage *)page {
    if (!page) {
        return nil;
    }
    @try {
        return page.attributedString;
    } @catch (NSException *exception) {
        NSLog(@"[PDFKit] Caught exception in page.attributedString: %@", exception.reason);
        return nil;
    }
}

+ (nullable NSAttributedString *)safeAttributedStringForSelection:(PDFSelection *)selection {
    if (!selection) {
        return nil;
    }
    @try {
        return selection.attributedString;
    } @catch (NSException *exception) {
        NSLog(@"[PDFKit] Caught exception in selection.attributedString: %@", exception.reason);
        return nil;
    }
}

@end
