//
//  NSURLSessionCompat.m
//  iOS 6 Compatibility shim for NSURLSession using NSURLConnection
//

#import "NSURLSessionCompat.h"

@implementation NSURLSessionConfiguration

+ (NSURLSessionConfiguration *)defaultSessionConfiguration {
    NSURLSessionConfiguration *config = [[NSURLSessionConfiguration alloc] init];
    config.timeoutIntervalForRequest = 30.0;
    config.timeoutIntervalForResource = 60.0;
    config.HTTPMaximumConnectionsPerHost = 4;
    return config;
}

+ (NSURLSessionConfiguration *)ephemeralSessionConfiguration {
    return [self defaultSessionConfiguration];
}

@end

@interface NSURLSessionDataTask () <NSURLConnectionDelegate, NSURLConnectionDataDelegate>

@property (nonatomic, strong) NSURLRequest *request;
@property (nonatomic, strong) NSURLConnection *connection;
@property (nonatomic, copy) void (^completion)(NSData *data, NSURLResponse *response, NSError *error);
@property (nonatomic, strong) NSMutableData *receivedData;
@property (nonatomic, strong) NSURLResponse *receivedResponse;
@property (nonatomic, assign) BOOL isCancelled;
@property (nonatomic, assign) BOOL isFinished;

@end

@implementation NSURLSessionDataTask

- (instancetype)initWithRequest:(NSURLRequest *)req completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completion {
    self = [super init];
    if (self) {
        _request = req;
        _completion = [completion copy];
        _receivedData = [[NSMutableData alloc] init];
    }
    return self;
}

- (NSURLRequest *)originalRequest {
    return self.request;
}

- (NSURLResponse *)response {
    return self.receivedResponse;
}

- (void)resume {
    if (self.isFinished || self.isCancelled) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.isCancelled || self.isFinished) return;
        self.connection = [[NSURLConnection alloc] initWithRequest:self.request delegate:self startImmediately:NO];
        [self.connection scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        [self.connection start];
    });
}

- (void)cancel {
    self.isCancelled = YES;
    self.isFinished = YES;
    if (self.connection) {
        [self.connection cancel];
        self.connection = nil;
    }
}

#pragma mark - NSURLConnectionDelegate

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    self.receivedResponse = response;
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    [self.receivedData appendData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    self.isFinished = YES;
    if (!self.isCancelled && self.completion) {
        void (^comp)(NSData *, NSURLResponse *, NSError *) = self.completion;
        self.completion = nil;
        comp(self.receivedData, self.receivedResponse, nil);
    }
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    self.isFinished = YES;
    if (!self.isCancelled && self.completion) {
        void (^comp)(NSData *, NSURLResponse *, NSError *) = self.completion;
        self.completion = nil;
        comp(nil, self.receivedResponse, error);
    }
}

- (void)connection:(NSURLConnection *)connection willSendRequestForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
    [challenge.sender performDefaultHandlingForAuthenticationChallenge:challenge];
}

@end

@interface NSURLSession ()
@property (nonatomic, strong, readwrite) NSURLSessionConfiguration *configuration;
@property (nonatomic, weak, readwrite) id delegate;
@property (nonatomic, strong, readwrite) NSOperationQueue *delegateQueue;
@property (nonatomic, strong) NSMutableArray *activeTasks;
@end

@implementation NSURLSession

+ (NSURLSession *)sharedSession {
    static NSURLSession *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [self sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
    });
    return shared;
}

+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration {
    return [self sessionWithConfiguration:configuration delegate:nil delegateQueue:nil];
}

+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration
                                  delegate:(id)delegate
                             delegateQueue:(NSOperationQueue *)queue {
    NSURLSession *session = [[NSURLSession alloc] init];
    session.configuration = configuration ?: [NSURLSessionConfiguration defaultSessionConfiguration];
    session.delegate = delegate;
    session.delegateQueue = queue ?: [NSOperationQueue mainQueue];
    session.activeTasks = [[NSMutableArray alloc] init];
    return session;
}

- (NSMutableURLRequest *)requestWithHeadersApplied:(NSURLRequest *)originalRequest {
    NSMutableURLRequest *req = [originalRequest mutableCopy];
    if (self.configuration.timeoutIntervalForRequest > 0) {
        req.timeoutInterval = self.configuration.timeoutIntervalForRequest;
    }
    if (self.configuration.HTTPAdditionalHeaders) {
        for (NSString *key in self.configuration.HTTPAdditionalHeaders) {
            if (![req valueForHTTPHeaderField:key]) {
                [req setValue:self.configuration.HTTPAdditionalHeaders[key] forHTTPHeaderField:key];
            }
        }
    }
    return req;
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url
                        completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    return [self dataTaskWithRequest:req completionHandler:completionHandler];
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    NSURLRequest *finalReq = [self requestWithHeadersApplied:request];
    NSURLSessionDataTask *task = [[NSURLSessionDataTask alloc] initWithRequest:finalReq completionHandler:completionHandler];
    @synchronized (self.activeTasks) {
        [self.activeTasks addObject:task];
    }
    return task;
}

- (void)finishTasksAndInvalidate {
    // Graceful teardown
}

- (void)invalidateAndCancel {
    @synchronized (self.activeTasks) {
        for (NSURLSessionDataTask *task in self.activeTasks) {
            [task cancel];
        }
        [self.activeTasks removeAllObjects];
    }
}

@end
