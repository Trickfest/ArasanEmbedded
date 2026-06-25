#import "AEEngine.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <future>
#include <memory>
#include <mutex>
#include <ostream>
#include <streambuf>
#include <string>
#include <thread>

#include "ArasanEmbeddedUCI.hpp"

namespace {

class CommandQueue {
public:
    void push(std::string command) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (closed_) {
                return;
            }
            commands_.push_back(std::move(command));
        }
        condition_.notify_one();
    }

    bool pop(std::string &command) {
        std::unique_lock<std::mutex> lock(mutex_);
        condition_.wait(lock, [&] { return closed_ || !commands_.empty(); });
        if (commands_.empty()) {
            return false;
        }
        command = std::move(commands_.front());
        commands_.pop_front();
        return true;
    }

    void close() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            closed_ = true;
        }
        condition_.notify_all();
    }

private:
    std::mutex mutex_;
    std::condition_variable condition_;
    std::deque<std::string> commands_;
    bool closed_ = false;
};

class QueueInputBuffer: public std::streambuf {
public:
    explicit QueueInputBuffer(CommandQueue &queue): queue_(queue) {
        setg(placeholder_, placeholder_, placeholder_);
    }

protected:
    int_type underflow() override {
        if (gptr() < egptr()) {
            return traits_type::to_int_type(*gptr());
        }

        if (!queue_.pop(current_)) {
            return traits_type::eof();
        }

        if (current_.empty() || current_.back() != '\n') {
            current_.push_back('\n');
        }

        char *start = current_.data();
        setg(start, start, start + current_.size());
        return traits_type::to_int_type(*gptr());
    }

private:
    CommandQueue &queue_;
    std::string current_;
    char placeholder_[1];
};

class CallbackOutputBuffer: public std::streambuf {
public:
    using Callback = std::function<void(const std::string &)>;

    explicit CallbackOutputBuffer(Callback callback): callback_(std::move(callback)) {}

protected:
    int_type overflow(int_type value) override {
        if (traits_type::eq_int_type(value, traits_type::eof())) {
            return traits_type::not_eof(value);
        }

        const char character = traits_type::to_char_type(value);
        if (character == '\r') {
            return traits_type::not_eof(value);
        }

        if (character == '\n') {
            flushLine();
        } else {
            line_.push_back(character);
        }
        return traits_type::not_eof(value);
    }

    int sync() override {
        flushLine();
        return 0;
    }

private:
    void flushLine() {
        if (line_.empty()) {
            return;
        }
        if (callback_) {
            callback_(line_);
        }
        line_.clear();
    }

    Callback callback_;
    std::string line_;
};

std::mutex gActiveEngineMutex;
bool gActiveEngine = false;

} // namespace

@interface AEEngine ()
@property(nonatomic, copy) AELineHandler lineHandler;
@end

@implementation AEEngine {
    std::unique_ptr<CommandQueue> _queue;
    std::unique_ptr<std::thread> _thread;
    std::mutex _sendMutex;
    std::atomic<bool> _running;
    std::promise<void> _donePromise;
    std::future<void> _doneFuture;
}

- (instancetype)initWithLineHandler:(AELineHandler)handler {
    self = [super init];
    if (self) {
        _lineHandler = [handler copy];
        _running.store(false);
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)isRunning {
    return _running.load();
}

- (BOOL)startEngine {
    if (_running.load()) {
        return NO;
    }

    {
        std::lock_guard<std::mutex> lock(gActiveEngineMutex);
        if (gActiveEngine) {
            return NO;
        }
        gActiveEngine = true;
    }

    _queue = std::make_unique<CommandQueue>();
    _donePromise = std::promise<void>();
    _doneFuture = _donePromise.get_future();
    _running.store(true);

    __weak __typeof__(self) weakSelf = self;
    _thread = std::make_unique<std::thread>([weakSelf] {
        @autoreleasepool {
            [weakSelf runEngineLoop];
        }
    });

    return YES;
}

- (void)sendCommand:(NSString *)command {
    if (!_running.load() || command.length == 0) {
        return;
    }

    std::lock_guard<std::mutex> lock(_sendMutex);
    if (_queue) {
        _queue->push(std::string(command.UTF8String));
    }
}

- (void)stop {
    const bool wasRunning = _running.exchange(false);
    if (!wasRunning) {
        return;
    }

    {
        std::lock_guard<std::mutex> lock(_sendMutex);
        if (_queue) {
            _queue->push("stop");
            _queue->push("quit");
            _queue->close();
        }
    }

    if (_thread && _thread->joinable()) {
        if (_doneFuture.valid()
            && _doneFuture.wait_for(std::chrono::seconds(3)) == std::future_status::timeout) {
            _thread->detach();
        } else {
            _thread->join();
        }
    }

    _thread.reset();
    _queue.reset();
}

- (void)runEngineLoop {
    auto handler = self.lineHandler;
    CallbackOutputBuffer::Callback callback;
    if (handler) {
        callback = [handler](const std::string &line) {
            NSString *value = [[NSString alloc] initWithBytes:line.data()
                                                       length:line.size()
                                                     encoding:NSUTF8StringEncoding];
            if (value) {
                handler(value);
            }
        };
    }

    QueueInputBuffer inputBuffer(*_queue);
    CallbackOutputBuffer outputBuffer(std::move(callback));
    std::istream input(&inputBuffer);
    std::ostream output(&outputBuffer);

    ArasanEmbedded::RunUCI(input, output);

    if (_queue) {
        _queue->close();
    }
    _donePromise.set_value();
    {
        std::lock_guard<std::mutex> lock(gActiveEngineMutex);
        gActiveEngine = false;
    }
}

@end
