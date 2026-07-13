#pragma once

#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <ostream>
#include <streambuf>
#include <string>
#include <utility>

namespace ArasanEmbeddedBridge {

class CommandQueue final {
public:
    CommandQueue(): shutdownCommands_{"stop", "quit"} {}

    void push(std::string command) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (closed_ || shuttingDown_) {
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

    bool tryPop(std::string &command) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (commands_.empty()) {
            return false;
        }
        command = std::move(commands_.front());
        commands_.pop_front();
        return true;
    }

    // Shutdown must not wait behind an arbitrary backlog of stale work. Keep
    // only the commands needed to stop an active search, normalize Arasan's
    // worker pool, and leave UCI.
    void requestShutdown() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (closed_ || shuttingDown_) {
                return;
            }
            commands_.clear();
            // Arasan can report readyok before a newly resized worker pool has
            // fully parked. These commands are allocated with the queue and
            // swapped in without allocating during the lifecycle transition.
            commands_.swap(shutdownCommands_);
            shuttingDown_ = true;
            closed_ = true;
        }
        condition_.notify_all();
    }

    void close() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            closed_ = true;
            commands_.clear();
        }
        condition_.notify_all();
    }

private:
    std::mutex mutex_;
    std::condition_variable condition_;
    std::deque<std::string> commands_;
    std::deque<std::string> shutdownCommands_;
    bool closed_ = false;
    bool shuttingDown_ = false;
};

class QueueInputBuffer final: public std::streambuf {
public:
    explicit QueueInputBuffer(CommandQueue &queue): queue_(queue) {
        setg(placeholder_, placeholder_, placeholder_);
    }

protected:
    std::streamsize showmanyc() override {
        if (gptr() < egptr()) {
            return egptr() - gptr();
        }
        if (!queue_.tryPop(current_)) {
            return 0;
        }
        prepareCurrentCommand();
        return egptr() - gptr();
    }

    int_type underflow() override {
        if (gptr() < egptr()) {
            return traits_type::to_int_type(*gptr());
        }
        if (!queue_.pop(current_)) {
            return traits_type::eof();
        }
        prepareCurrentCommand();
        return traits_type::to_int_type(*gptr());
    }

private:
    void prepareCurrentCommand() {
        if (current_.empty() || current_.back() != '\n') {
            current_.push_back('\n');
        }
        char *start = current_.data();
        setg(start, start, start + current_.size());
    }

    CommandQueue &queue_;
    std::string current_;
    char placeholder_[1];
};

class CallbackOutputBuffer final: public std::streambuf {
public:
    using Callback = std::function<void(const std::string &)>;

    explicit CallbackOutputBuffer(Callback callback): callback_(std::move(callback)) {}

    void finish() {
        std::lock_guard<std::mutex> lock(mutex_);
        deliverLocked(std::move(line_));
        line_.clear();
    }

protected:
    int_type overflow(int_type value) override {
        if (traits_type::eq_int_type(value, traits_type::eof())) {
            return traits_type::not_eof(value);
        }
        const char character = traits_type::to_char_type(value);
        append(&character, 1);
        return traits_type::not_eof(value);
    }

    std::streamsize xsputn(const char *characters, std::streamsize count) override {
        if (count > 0) {
            append(characters, static_cast<std::size_t>(count));
        }
        return count;
    }

    // A transport flush is not a UCI record delimiter. Logical lines are
    // emitted only for a newline (or one final partial line from finish()).
    int sync() override {
        return 0;
    }

private:
    void append(const char *characters, std::size_t count) {
        std::lock_guard<std::mutex> lock(mutex_);
        for (std::size_t index = 0; index < count; ++index) {
            const char character = characters[index];
            if (character == '\r') {
                continue;
            }
            if (character == '\n') {
                if (!line_.empty()) {
                    deliverLocked(std::move(line_));
                    line_.clear();
                }
            } else {
                line_.push_back(character);
            }
        }
    }

    // The mutex remains held through callback submission so two native writers
    // cannot complete lines in one order and enqueue their callbacks in another.
    void deliverLocked(std::string line) {
        if (!line.empty() && callback_) {
            callback_(line);
        }
    }

    Callback callback_;
    std::mutex mutex_;
    std::string line_;
};

} // namespace ArasanEmbeddedBridge
