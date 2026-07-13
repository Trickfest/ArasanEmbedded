#import "AEEngine.h"

#include <atomic>
#include <cctype>
#include <condition_variable>
#include <cstdint>
#include <exception>
#include <fstream>
#include <istream>
#include <memory>
#include <mutex>
#include <new>
#include <pthread.h>
#include <string>
#include <utility>
#include <vector>

#import <dispatch/dispatch.h>

#include "AEEngineStreams.hpp"
#include "ArasanEmbeddedUCI.hpp"

using namespace ArasanEmbeddedBridge;

namespace {

constexpr std::size_t kMaximumCommandBytes = 1024 * 1024;
constexpr std::size_t kRequiredEngineStackBytes = 4 * 1024 * 1024;
constexpr std::size_t kRequiredNNUEBytes = 25'024'576;
constexpr char kCanonicalNNUEOptionPrefix[] = "setoption name NNUE file value ";
char kCallbackQueueSpecificKey;

class ActiveEngineRegistry final {
public:
    bool claim(const void *owner) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (owner_ != nullptr) {
            return false;
        }
        owner_ = owner;
        return true;
    }

    void release(const void *owner) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (owner_ == owner) {
            owner_ = nullptr;
        }
    }

private:
    std::mutex mutex_;
    const void *owner_ = nullptr;
};

ActiveEngineRegistry &activeEngineRegistry() {
    static ActiveEngineRegistry registry;
    return registry;
}

enum class Lifecycle {
    idle,
    running,
    stopping,
    finished,
    stopped,
};

enum class CommandValidation {
    accepted,
    ignored,
    rejected,
};

bool startsWithNNUEFileOption(const std::string &command) {
    std::string normalized;
    normalized.reserve(command.size());
    bool pendingSpace = false;
    for (const unsigned char character : command) {
        if (std::isspace(character)) {
            pendingSpace = !normalized.empty();
            continue;
        }
        if (pendingSpace) {
            normalized.push_back(' ');
            pendingSpace = false;
        }
        normalized.push_back(static_cast<char>(std::tolower(character)));
    }

    constexpr char prefix[] = "setoption name nnue file";
    return normalized == prefix ||
        (normalized.size() > sizeof(prefix) - 1 &&
         normalized.compare(0, sizeof(prefix) - 1, prefix) == 0 &&
         normalized[sizeof(prefix) - 1] == ' ');
}

bool startsWithThreadsOption(const std::string &command) {
    std::string normalized;
    normalized.reserve(command.size());
    bool pendingSpace = false;
    for (const unsigned char character : command) {
        if (std::isspace(character)) {
            pendingSpace = !normalized.empty();
            continue;
        }
        if (pendingSpace) {
            normalized.push_back(' ');
            pendingSpace = false;
        }
        normalized.push_back(static_cast<char>(std::tolower(character)));
    }

    constexpr char prefix[] = "setoption name threads";
    return normalized == prefix ||
        (normalized.size() > sizeof(prefix) - 1 &&
         normalized.compare(0, sizeof(prefix) - 1, prefix) == 0 &&
         normalized[sizeof(prefix) - 1] == ' ');
}

bool validateStartupNNUEOption(const std::string &command, std::string &reason) {
    if (command.compare(0,
                        sizeof(kCanonicalNNUEOptionPrefix) - 1,
                        kCanonicalNNUEOptionPrefix) != 0) {
        reason = "startup NNUE option must use the canonical setoption form";
        return false;
    }

    const std::string path = command.substr(sizeof(kCanonicalNNUEOptionPrefix) - 1);
    if (path.empty() || std::isspace(static_cast<unsigned char>(path.back()))) {
        reason = "startup NNUE path is empty or ends in whitespace";
        return false;
    }

    std::ifstream input(path, std::ios::binary | std::ios::ate);
    if (!input || input.tellg() != static_cast<std::streamoff>(kRequiredNNUEBytes)) {
        reason = "startup NNUE file is missing or incompatible";
        return false;
    }
    input.seekg(0);
    char header[4] {};
    input.read(header, sizeof(header));
    if (!input || header[0] != 'A' || header[1] != 'R' ||
        header[2] != 'A' || static_cast<unsigned char>(header[3]) != 0x08) {
        reason = "startup NNUE file is missing or incompatible";
        return false;
    }
    return true;
}

CommandValidation validateCommand(NSString *command,
                                  bool allowNNUEFileOption,
                                  std::string &normalized,
                                  std::string &rejectionReason) {
    if (command.length == 0) {
        return CommandValidation::ignored;
    }

    const NSUInteger byteCount = [command lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (byteCount == 0 || byteCount > kMaximumCommandBytes) {
        rejectionReason = byteCount > kMaximumCommandBytes
            ? "command exceeds 1 MiB"
            : "command is not UTF-8";
        return CommandValidation::rejected;
    }

    NSData *data = [command dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
    if (!data) {
        rejectionReason = "command is not UTF-8";
        return CommandValidation::rejected;
    }

    normalized.assign(static_cast<const char *>(data.bytes), data.length);
    if (!normalized.empty() && normalized.back() == '\n') {
        normalized.pop_back();
        if (!normalized.empty() && normalized.back() == '\r') {
            normalized.pop_back();
        }
    }
    if (normalized.empty()) {
        return CommandValidation::ignored;
    }
    if (normalized.find('\0') != std::string::npos) {
        rejectionReason = "command contains NUL";
        return CommandValidation::rejected;
    }
    if (normalized.find('\n') != std::string::npos || normalized.find('\r') != std::string::npos) {
        rejectionReason = "command contains more than one line";
        return CommandValidation::rejected;
    }
    if (!allowNNUEFileOption && startsWithNNUEFileOption(normalized)) {
        rejectionReason = "change NNUE files through ArasanEngine.Configuration and a fresh engine";
        return CommandValidation::rejected;
    }
    if (allowNNUEFileOption && startsWithNNUEFileOption(normalized) &&
        !validateStartupNNUEOption(normalized, rejectionReason)) {
        return CommandValidation::rejected;
    }
    if (startsWithThreadsOption(normalized)) {
        rejectionReason = "the embedded wrapper fixes Arasan Threads at 1 for safe teardown";
        return CommandValidation::rejected;
    }
    return CommandValidation::accepted;
}

class EngineState final: public std::enable_shared_from_this<EngineState> {
public:
    explicit EngineState(AELineHandler handler):
        handler_([handler copy]),
        callbackQueue_(dispatch_queue_create("com.arasanembedded.AEEngine.callback",
                                             DISPATCH_QUEUE_SERIAL)) {
        dispatch_queue_set_specific(callbackQueue_, &kCallbackQueueSpecificKey, this, nullptr);
    }

    ~EngineState() {
        stop();
        try {
            finishCallbackDelivery();
        } catch (...) {
        }
    }

    bool start(NSArray<NSString *> *commands) noexcept {
        try {
            return startImpl(commands);
        } catch (...) {
            deliverStartFailure("could not allocate or validate native startup state");
            return false;
        }
    }

    bool startImpl(NSArray<NSString *> *commands) {
        if (!reapFinishedRun()) {
            return false;
        }

        std::vector<std::string> initialCommands;
        initialCommands.reserve(commands.count);
        bool hasStartupNNUE = false;
        for (NSString *command in commands) {
            std::string normalized;
            std::string rejectionReason;
            const auto validation = validateCommand(command, true, normalized, rejectionReason);
            if (validation == CommandValidation::rejected) {
                deliverStartFailure(rejectionReason);
                return false;
            }
            if (validation == CommandValidation::accepted) {
                hasStartupNNUE = hasStartupNNUE || startsWithNNUEFileOption(normalized);
                initialCommands.push_back(std::move(normalized));
            }
        }
        if (!hasStartupNNUE || initialCommands.size() < 2 ||
            initialCommands.front() != "uci" ||
            !startsWithNNUEFileOption(initialCommands[1])) {
            deliverStartFailure(
                "startup must begin with uci followed by one validated NNUE file option"
            );
            return false;
        }

        const auto self = shared_from_this();
        std::unique_lock<std::mutex> lifecycleLock(lifecycleMutex_);
        if (lifecycle_ != Lifecycle::idle && lifecycle_ != Lifecycle::stopped) {
            return false;
        }
        if (!activeEngineRegistry().claim(this)) {
            lifecycleLock.unlock();
            deliverStartFailure("another ArasanEngine instance is already active");
            return false;
        }
        ownsActiveLease_.store(true);

        std::shared_ptr<CommandQueue> queue;
        try {
            queue = std::make_shared<CommandQueue>();
            for (auto &command : initialCommands) {
                queue->push(std::move(command));
            }
        } catch (...) {
            releaseActiveLease();
            lifecycleLock.unlock();
            deliverStartFailure("could not allocate native engine state");
            return false;
        }

        const std::uint64_t generation = ++generationCounter_;
        activeCallbackGeneration_.store(generation);
        queue_ = queue;
        lifecycle_ = Lifecycle::running;

        auto *context = new (std::nothrow) ThreadContext{self, queue, generation};
        if (!context) {
            rollbackFailedStartLocked(queue);
            lifecycleLock.unlock();
            deliverStartFailure("could not allocate engine thread context");
            return false;
        }

        pthread_attr_t attributes;
        int status = pthread_attr_init(&attributes);
        const bool attributesInitialized = status == 0;
        if (status == 0) {
            status = pthread_attr_setstacksize(&attributes, kRequiredEngineStackBytes);
        }
        if (status == 0) {
            status = pthread_create(&engineThread_, &attributes, &EngineState::threadEntry, context);
        }
        if (attributesInitialized && pthread_attr_destroy(&attributes) != 0 && status == 0) {
            // Attribute destruction does not affect the successfully created thread.
        }

        if (status != 0) {
            delete context;
            rollbackFailedStartLocked(queue);
            lifecycleLock.unlock();
            deliverStartFailure("could not create a 4 MiB Arasan engine thread");
            return false;
        }

        hasEngineThread_ = true;
        lifecycleLock.unlock();
        return true;
    }

    void sendCommand(NSString *command) noexcept {
        try {
            sendCommandImpl(command);
        } catch (...) {
            deliverWrapperErrorNoThrow(
                "could not allocate or validate the UCI command",
                activeCallbackGeneration_.load()
            );
        }
    }

    void sendCommandImpl(NSString *command) {
        std::string normalized;
        std::string rejectionReason;
        std::uint64_t generation = 0;

        {
            std::lock_guard<std::mutex> lock(lifecycleMutex_);
            if (lifecycle_ != Lifecycle::running || !queue_) {
                return;
            }
            const auto validation = validateCommand(command, false, normalized, rejectionReason);
            if (validation == CommandValidation::accepted) {
                queue_->push(std::move(normalized));
                return;
            }
            if (validation == CommandValidation::ignored) {
                return;
            }
            generation = activeCallbackGeneration_.load();
        }

        deliverWrapperError(rejectionReason, generation);
    }

    void stop() noexcept {
        try {
            stopImpl();
        } catch (...) {
        }
    }

    void stopImpl() {
        pthread_t thread {};
        bool shouldJoin = false;

        {
            std::unique_lock<std::mutex> lock(lifecycleMutex_);
            if (lifecycle_ == Lifecycle::idle || lifecycle_ == Lifecycle::stopped) {
                lock.unlock();
                drainCallbacks();
                return;
            }
            if (lifecycle_ == Lifecycle::stopping) {
                lifecycleChanged_.wait(lock, [&] { return lifecycle_ != Lifecycle::stopping; });
                lock.unlock();
                drainCallbacks();
                return;
            }

            if (queue_) {
                queue_->requestShutdown();
            }
            lifecycle_ = Lifecycle::stopping;
            if (hasEngineThread_) {
                thread = engineThread_;
                hasEngineThread_ = false;
                shouldJoin = true;
            }
        }

        if (shouldJoin && !pthread_equal(thread, pthread_self())) {
            pthread_join(thread, nullptr);
        }

        activeCallbackGeneration_.store(0);
        releaseActiveLease();
        {
            std::lock_guard<std::mutex> lock(lifecycleMutex_);
            queue_.reset();
            lifecycle_ = Lifecycle::stopped;
        }
        lifecycleChanged_.notify_all();
        drainCallbacks();
    }

    bool isRunning() const {
        std::lock_guard<std::mutex> lock(lifecycleMutex_);
        return lifecycle_ == Lifecycle::running;
    }

    std::size_t engineThreadStackSize() const {
        return engineThreadStackSize_.load();
    }

private:
    struct ThreadContext {
        std::shared_ptr<EngineState> state;
        std::shared_ptr<CommandQueue> queue;
        std::uint64_t generation;
    };

    static void *threadEntry(void *rawContext) noexcept {
        std::unique_ptr<ThreadContext> context(static_cast<ThreadContext *>(rawContext));
        try {
            @autoreleasepool {
                context->state->engineThreadStackSize_.store(pthread_get_stacksize_np(pthread_self()));
                context->state->runEngineLoop(context->queue, context->generation);
            }
        } catch (...) {
            context->state->deliverWrapperErrorNoThrow(
                "native engine thread failed before initialization",
                context->generation
            );
            context->state->finishEngineRunNoThrow(context->queue);
        }
        context->state->releaseActiveLeaseNoThrow();
        return nullptr;
    }

    void runEngineLoop(const std::shared_ptr<CommandQueue> &queue,
                       std::uint64_t generation) noexcept {
        std::unique_ptr<CallbackOutputBuffer> outputBuffer;
        try {
            outputBuffer = std::make_unique<CallbackOutputBuffer>(
                [weakState = weak_from_this(), generation](const std::string &line) {
                    if (auto state = weakState.lock()) {
                        state->deliverLine(line, generation);
                    }
                }
            );
            QueueInputBuffer inputBuffer(*queue);
            std::istream input(&inputBuffer);
            std::ostream output(outputBuffer.get());
            ArasanEmbedded::RunUCI(input, output);
        } catch (const std::exception &error) {
            finishOutputNoThrow(outputBuffer.get());
            outputBuffer.reset();
            try {
                deliverWrapperError(
                    std::string("native engine failure: ") + error.what(),
                    generation
                );
            } catch (...) {
                deliverWrapperErrorNoThrow("native engine failure", generation);
            }
        } catch (...) {
            finishOutputNoThrow(outputBuffer.get());
            outputBuffer.reset();
            deliverWrapperErrorNoThrow("unknown native engine failure", generation);
        }
        finishOutputNoThrow(outputBuffer.get());
        finishEngineRunNoThrow(queue);
    }

    void finishOutputNoThrow(CallbackOutputBuffer *outputBuffer) noexcept {
        if (!outputBuffer) {
            return;
        }
        try {
            outputBuffer->finish();
        } catch (...) {
        }
    }

    void finishEngineRunNoThrow(const std::shared_ptr<CommandQueue> &queue) noexcept {
        try {
            queue->close();
        } catch (...) {
        }
        try {
            std::lock_guard<std::mutex> lock(lifecycleMutex_);
            if (lifecycle_ == Lifecycle::running) {
                lifecycle_ = Lifecycle::finished;
            }
        } catch (...) {
        }
        lifecycleChanged_.notify_all();
    }

    bool reapFinishedRun() {
        pthread_t thread {};
        bool shouldJoin = false;
        {
            std::unique_lock<std::mutex> lock(lifecycleMutex_);
            if (lifecycle_ == Lifecycle::stopping) {
                return false;
            }
            if (lifecycle_ != Lifecycle::finished) {
                return true;
            }
            lifecycle_ = Lifecycle::stopping;
            if (hasEngineThread_) {
                thread = engineThread_;
                hasEngineThread_ = false;
                shouldJoin = true;
            }
        }
        if (shouldJoin && !pthread_equal(thread, pthread_self())) {
            pthread_join(thread, nullptr);
        }
        activeCallbackGeneration_.store(0);
        {
            std::lock_guard<std::mutex> lock(lifecycleMutex_);
            queue_.reset();
            lifecycle_ = Lifecycle::stopped;
        }
        lifecycleChanged_.notify_all();
        drainCallbacks();
        return true;
    }

    // lifecycleMutex_ must be held.
    void rollbackFailedStartLocked(const std::shared_ptr<CommandQueue> &queue) {
        queue->close();
        activeCallbackGeneration_.store(0);
        releaseActiveLease();
        queue_.reset();
        lifecycle_ = Lifecycle::stopped;
        lifecycleChanged_.notify_all();
    }

    void releaseActiveLease() {
        if (ownsActiveLease_.exchange(false)) {
            activeEngineRegistry().release(this);
        }
    }

    void releaseActiveLeaseNoThrow() noexcept {
        try {
            releaseActiveLease();
        } catch (...) {
        }
    }

    void deliverWrapperError(const std::string &reason, std::uint64_t generation) {
        deliverLine("info string ArasanEmbedded error: " + reason, generation);
    }

    void deliverWrapperErrorNoThrow(const char *reason, std::uint64_t generation) noexcept {
        try {
            deliverWrapperError(reason, generation);
        } catch (...) {
        }
    }

    void deliverStartFailure(const std::string &reason) noexcept {
        try {
            deliverWrapperError(reason, 0);
        } catch (...) {
        }
        try {
            drainCallbacks();
        } catch (...) {
        }
    }

    void deliverLine(const std::string &line, std::uint64_t generation) {
        AELineHandler handler;
        {
            std::lock_guard<std::mutex> lock(handlerMutex_);
            handler = [handler_ copy];
        }
        if (!handler) {
            return;
        }

        NSString *value = [[NSString alloc] initWithBytes:line.data()
                                                   length:line.size()
                                                 encoding:NSUTF8StringEncoding];
        if (!value) {
            return;
        }

        std::weak_ptr<EngineState> weakState = weak_from_this();
        dispatch_async(callbackQueue_, ^{
            @autoreleasepool {
                auto state = weakState.lock();
                if (!state) {
                    return;
                }
                if (generation != 0 && state->activeCallbackGeneration_.load() != generation) {
                    return;
                }
                handler(value);
            }
        });
    }

    void drainCallbacks() {
        if (dispatch_get_specific(&kCallbackQueueSpecificKey) == this) {
            return;
        }
        dispatch_sync(callbackQueue_, ^{});
    }

    void finishCallbackDelivery() {
        activeCallbackGeneration_.store(0);
        drainCallbacks();
        std::lock_guard<std::mutex> lock(handlerMutex_);
        handler_ = nil;
    }

    AELineHandler handler_;
    std::mutex handlerMutex_;
    dispatch_queue_t callbackQueue_;

    mutable std::mutex lifecycleMutex_;
    std::condition_variable lifecycleChanged_;
    Lifecycle lifecycle_ = Lifecycle::idle;
    std::shared_ptr<CommandQueue> queue_;
    pthread_t engineThread_ {};
    bool hasEngineThread_ = false;
    std::uint64_t generationCounter_ = 0;
    std::atomic<std::uint64_t> activeCallbackGeneration_ {0};
    std::atomic<bool> ownsActiveLease_ {false};
    std::atomic<std::size_t> engineThreadStackSize_ {0};
};

} // namespace

@implementation AEEngine {
    std::shared_ptr<EngineState> _state;
}

- (instancetype)initWithLineHandler:(AELineHandler)handler {
    self = [super init];
    if (self) {
        try {
            _state = std::make_shared<EngineState>(handler);
        } catch (...) {
            return nil;
        }
    }
    return self;
}

- (void)dealloc {
    [self stop];
    _state.reset();
}

- (BOOL)isRunning {
    try {
        return _state && _state->isRunning();
    } catch (...) {
        return NO;
    }
}

- (NSUInteger)engineThreadStackSize {
    return _state ? _state->engineThreadStackSize() : 0;
}

- (BOOL)startEngine {
    return [self startEngineWithCommands:@[]];
}

- (BOOL)startEngineWithCommands:(NSArray<NSString *> *)commands {
    NSArray<NSString *> *snapshot = nil;
    @try {
        snapshot = [commands copy];
        for (id command in snapshot) {
            if (![command isKindOfClass:NSString.class]) {
                return NO;
            }
        }
    } @catch (NSException *) {
        return NO;
    }
    try {
        return _state && _state->start(snapshot);
    } catch (...) {
        return NO;
    }
}

- (void)sendCommand:(NSString *)command {
    NSString *snapshot = nil;
    @try {
        if (![command isKindOfClass:NSString.class]) {
            return;
        }
        snapshot = [command copy];
    } @catch (NSException *) {
        return;
    }
    try {
        if (_state) {
            _state->sendCommand(snapshot);
        }
    } catch (...) {
    }
}

- (void)stop {
    try {
        if (_state) {
            _state->stop();
        }
    } catch (...) {
    }
}

@end
