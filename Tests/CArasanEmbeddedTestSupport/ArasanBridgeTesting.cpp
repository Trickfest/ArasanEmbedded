#include "ArasanBridgeTesting.h"

#include "AEEngineStreams.hpp"
#include "ArasanEmbeddedUCI.hpp"
#include "globals.h"

#include <ios>
#include <iostream>
#include <locale>
#include <condition_variable>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

using ArasanEmbeddedBridge::CallbackOutputBuffer;

namespace {

struct StreamSnapshot {
    std::ios_base::fmtflags flags;
    std::streamsize precision;
    std::streamsize width;
    char fill;
    std::ios_base::iostate state;
    std::ios_base::iostate exceptions;
    std::locale locale;
    std::ostream *tie;
    std::streambuf *buffer;
};

template <typename Stream>
StreamSnapshot capture(Stream &stream) {
    return StreamSnapshot{
        stream.flags(), stream.precision(), stream.width(), stream.fill(),
        stream.rdstate(), stream.exceptions(), stream.getloc(), stream.tie(), stream.rdbuf(),
    };
}

template <typename Stream>
bool matches(Stream &stream, const StreamSnapshot &snapshot) {
    return stream.flags() == snapshot.flags &&
        stream.precision() == snapshot.precision &&
        stream.width() == snapshot.width &&
        stream.fill() == snapshot.fill &&
        stream.rdstate() == snapshot.state &&
        stream.exceptions() == snapshot.exceptions &&
        stream.getloc() == snapshot.locale &&
        stream.tie() == snapshot.tie &&
        stream.rdbuf() == snapshot.buffer;
}

template <typename Stream>
void restore(Stream &stream, const StreamSnapshot &snapshot) {
    try {
        stream.exceptions(std::ios_base::goodbit);
        stream.clear();
        stream.rdbuf(snapshot.buffer);
        stream.tie(snapshot.tie);
        stream.flags(snapshot.flags);
        stream.precision(snapshot.precision);
        stream.width(snapshot.width);
        stream.fill(snapshot.fill);
        stream.imbue(snapshot.locale);
        stream.clear(snapshot.state);
        stream.exceptions(snapshot.exceptions);
    } catch (...) {
    }
}

template <typename Stream>
void setExceptionalState(
    Stream &stream,
    std::ios_base::iostate state,
    std::ios_base::iostate exceptions
) {
    stream.exceptions(std::ios_base::goodbit);
    stream.clear(state);
    try {
        stream.exceptions(exceptions);
    } catch (...) {
    }
}

class CommaPunctuation final: public std::numpunct<char> {
protected:
    char do_decimal_point() const override {
        return ',';
    }
};

} // namespace

bool AEOutputFlushPreservesLineForTesting(void) {
    std::vector<std::string> lines;
    CallbackOutputBuffer buffer([&](const std::string &line) {
        lines.push_back(line);
    });
    std::ostream output(&buffer);
    output << "part1" << std::flush << "part2" << std::endl;
    buffer.finish();
    return lines.size() == 1 && lines.front() == "part1part2";
}

bool AEConcurrentOutputPreservesSubmissionOrderForTesting(void) {
    std::mutex stateMutex;
    std::condition_variable stateChanged;
    bool firstCallbackEntered = false;
    bool releaseFirstCallback = false;
    std::vector<std::string> lines;

    CallbackOutputBuffer buffer([&](const std::string &line) {
        if (line == "first") {
            std::unique_lock<std::mutex> lock(stateMutex);
            firstCallbackEntered = true;
            stateChanged.notify_all();
            stateChanged.wait(lock, [&] { return releaseFirstCallback; });
        }
        std::lock_guard<std::mutex> lock(stateMutex);
        lines.push_back(line);
    });
    std::ostream firstOutput(&buffer);
    std::ostream secondOutput(&buffer);

    std::thread first([&] { firstOutput << "first\n"; });
    {
        std::unique_lock<std::mutex> lock(stateMutex);
        stateChanged.wait(lock, [&] { return firstCallbackEntered; });
    }
    std::thread second([&] { secondOutput << "second\n"; });

    {
        std::lock_guard<std::mutex> lock(stateMutex);
        releaseFirstCallback = true;
    }
    stateChanged.notify_all();
    first.join();
    second.join();
    buffer.finish();

    return lines == std::vector<std::string>{"first", "second"};
}

bool AEStandardStreamsRestoreForTesting(void) {
    const auto originalInput = capture(std::cin);
    const auto originalOutput = capture(std::cout);
    const auto originalError = capture(std::cerr);

    bool result = false;
    try {
        std::ostringstream tieTarget;
        const std::locale testLocale(std::locale::classic(), new CommaPunctuation());

        std::cin.flags(std::ios_base::hex | std::ios_base::boolalpha);
        std::cin.precision(2);
        std::cin.width(7);
        std::cin.fill('i');
        std::cin.imbue(testLocale);
        std::cin.tie(&tieTarget);
        setExceptionalState(std::cin, std::ios_base::eofbit, std::ios_base::eofbit);

        std::cout.flags(std::ios_base::hex | std::ios_base::showbase | std::ios_base::boolalpha);
        std::cout.precision(3);
        std::cout.width(8);
        std::cout.fill('o');
        std::cout.imbue(testLocale);
        std::cout.tie(&tieTarget);
        setExceptionalState(std::cout, std::ios_base::failbit, std::ios_base::failbit);

        std::cerr.flags(std::ios_base::scientific | std::ios_base::showpos);
        std::cerr.precision(4);
        std::cerr.width(9);
        std::cerr.fill('e');
        std::cerr.imbue(testLocale);
        std::cerr.tie(&tieTarget);
        setExceptionalState(std::cerr, std::ios_base::eofbit, std::ios_base::eofbit);

        const auto expectedInput = capture(std::cin);
        const auto expectedOutput = capture(std::cout);
        const auto expectedError = capture(std::cerr);

        std::istringstream input("uci\nquit\n");
        std::ostringstream output;
        ArasanEmbedded::RunUCI(input, output);

        result = matches(std::cin, expectedInput) &&
            matches(std::cout, expectedOutput) &&
            matches(std::cerr, expectedError);
    } catch (...) {
        result = false;
    }

    restore(std::cin, originalInput);
    restore(std::cout, originalOutput);
    restore(std::cerr, originalError);
    return result;
}

bool AEEmbeddedGlobalsAllocatedForTesting(void) {
    return globals::gameMoves != nullptr && globals::eco != nullptr;
}

unsigned long long AECurrentHashBytesForTesting(void) {
    return static_cast<unsigned long long>(globals::options.search.hash_table_size);
}

int AECurrentThreadCountForTesting(void) {
    return globals::options.search.ncpus;
}

bool AECurrentPositionLearningForTesting(void) {
    return globals::options.learning.position_learning;
}
