#ifndef ObjCExceptionCatcher_h
#define ObjCExceptionCatcher_h

#import <Foundation/Foundation.h>
#import <PDFKit/PDFKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ObjCExceptionCatcher : NSObject

/// Executes the given block, catching any Objective-C NSException thrown.
/// Returns the result of the block, or nil if an exception was thrown.
+ (nullable id)tryExecute:(id _Nullable (NS_NOESCAPE ^)(void))block error:(__autoreleasing NSError * _Nullable * _Nullable)error;

/// Safely accesses page.attributedString, catching any internal PDFKit NSException
/// (e.g. -[__NSDictionaryM setObject:forKey:]: object cannot be nil).
+ (nullable NSAttributedString *)safeAttributedStringForPage:(nullable PDFPage *)page;

/// Safely accesses selection.attributedString, catching any internal PDFKit NSException.
+ (nullable NSAttributedString *)safeAttributedStringForSelection:(nullable PDFSelection *)selection;

@end

NS_ASSUME_NONNULL_END

#endif /* ObjCExceptionCatcher_h */
