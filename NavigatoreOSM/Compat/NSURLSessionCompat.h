//
//  NSURLSessionCompat.h
//  iOS 6 Compatibility shim for NSURLSession using NSURLConnection
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, NSURLSessionAuthChallengeDisposition) {
    NSURLSessionAuthChallengeUseCredential = 0,
    NSURLSessionAuthChallengePerformDefaultHandling = 1,
    NSURLSessionAuthChallengeCancelAuthenticationChallenge = 2,
    NSURLSessionAuthChallengeRejectProtectionSpace = 3
};

@class NSURLSession;
@class NSURLSessionDataTask;
@class NSURLSessionConfiguration;

@protocol NSURLSessionDelegate <NSObject>
@optional
- (void)URLSession:(NSURLSession *)session didBecomeInvalidWithError:(NSError *)error;
@end

@protocol NSURLSessionTaskDelegate <NSURLSessionDelegate>
@end

@protocol NSURLSessionDataDelegate <NSURLSessionTaskDelegate>
@end

@interface NSURLSessionConfiguration : NSObject

@property (nonatomic, copy) NSDictionary *HTTPAdditionalHeaders;
@property (nonatomic, assign) NSTimeInterval timeoutIntervalForRequest;
@property (nonatomic, assign) NSTimeInterval timeoutIntervalForResource;
@property (nonatomic, assign) NSInteger HTTPMaximumConnectionsPerHost;

+ (NSURLSessionConfiguration *)defaultSessionConfiguration;
+ (NSURLSessionConfiguration *)ephemeralSessionConfiguration;

@end

@interface NSURLSessionDataTask : NSObject

@property (nonatomic, readonly) NSURLRequest *originalRequest;
@property (nonatomic, readonly) NSURLResponse *response;
@property (nonatomic, readonly) NSError *error;

- (void)resume;
- (void)cancel;

@end

@interface NSURLSession : NSObject

@property (nonatomic, strong, readonly) NSURLSessionConfiguration *configuration;
@property (nonatomic, weak, readonly) id delegate;
@property (nonatomic, strong, readonly) NSOperationQueue *delegateQueue;

+ (NSURLSession *)sharedSession;
+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration;
+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration
                                  delegate:(id)delegate
                             delegateQueue:(NSOperationQueue *)queue;

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url
                        completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler;

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler;

- (void)finishTasksAndInvalidate;
- (void)invalidateAndCancel;

@end
