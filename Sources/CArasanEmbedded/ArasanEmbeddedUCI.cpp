#include "ArasanEmbeddedUCI.hpp"

#include <iostream>
#include <locale>
#include <memory>
#include <streambuf>

#include "attacks.h"
#include "bitutil.h"
#include "board.h"
#include "globals.h"
#include "options.h"
#include "protocol.h"
#include "search.h"
#include "syzygy/src/tbprobe.h"

namespace ArasanEmbedded {
namespace {

struct StreamState {
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
StreamState capture(Stream &stream) {
    return StreamState{
        stream.flags(),
        stream.precision(),
        stream.width(),
        stream.fill(),
        stream.rdstate(),
        stream.exceptions(),
        stream.getloc(),
        stream.tie(),
        stream.rdbuf(),
    };
}

template <typename Stream>
void normalize(Stream &stream) {
    stream.exceptions(std::ios_base::goodbit);
    stream.clear();
    stream.flags(std::ios_base::skipws | std::ios_base::dec);
    stream.precision(6);
    stream.width(0);
    stream.fill(' ');
    stream.imbue(std::locale::classic());
    stream.tie(nullptr);
}

template <typename Stream>
void restore(Stream &stream, const StreamState &state) noexcept {
    try {
        stream.exceptions(std::ios_base::goodbit);
        stream.clear();
        stream.rdbuf(state.buffer);
        stream.tie(state.tie);
        stream.flags(state.flags);
        stream.precision(state.precision);
        stream.width(state.width);
        stream.fill(state.fill);
        stream.imbue(state.locale);
        stream.clear(state.state);
        stream.exceptions(state.exceptions);
    } catch (...) {
        // Destruction must not terminate the host because it configured an
        // exception-throwing standard stream. The safe formatting/buffer state
        // and rdstate are restored before the exception mask can throw again.
    }
}

class ScopedStandardStreams final {
public:
    ScopedStandardStreams(std::istream &input, std::ostream &output):
        inputState_(capture(std::cin)),
        outputState_(capture(std::cout)),
        errorState_(capture(std::cerr)) {
        normalize(std::cin);
        normalize(std::cout);
        normalize(std::cerr);
        std::cin.rdbuf(input.rdbuf());
        std::cout.rdbuf(output.rdbuf());
        std::cerr.rdbuf(output.rdbuf());
    }

    ~ScopedStandardStreams() {
        try {
            std::cout.flush();
            std::cerr.flush();
        } catch (...) {
        }
        restore(std::cin, inputState_);
        restore(std::cout, outputState_);
        restore(std::cerr, errorState_);
    }

private:
    StreamState inputState_;
    StreamState outputState_;
    StreamState errorState_;
};

void releaseTablebases() noexcept {
#ifdef SYZYGY_TBS
    try {
        std::lock_guard<std::mutex> lock(globals::syzygy_lock);
        if (globals::tb_init_done()) {
            tb_free();
            globals::unloadTb();
        }
    } catch (...) {
        // Cleanup must not terminate the host process. A failure here can only
        // leave mappings resident until a later reset or process exit.
    }
#endif
}

class RuntimeCleanup final {
public:
    void prepareForGlobalsInitialization() {
        globalsMayOwnResources_ = true;
    }

    ~RuntimeCleanup() {
        releaseTablebases();
        if (globalsMayOwnResources_) {
            try {
                globals::cleanupGlobals();
            } catch (...) {
            }
            globals::gameMoves = nullptr;
            globals::eco = nullptr;
        } else {
            BitUtils::cleanup();
            Board::cleanup();
        }
    }

private:
    bool globalsMayOwnResources_ = false;
};

void resetProcessConfiguration() {
    releaseTablebases();
    globals::options = Options();
    globals::debugPrefix.clear();
    globals::nnueInitDone = false;
    globals::polling_terminated = false;
}

void initArasanEmbeddedGlobals() {
    // This package-owned initializer intentionally replaces upstream
    // globals::initGlobals() for the embedded entry point. The upstream
    // function first tries to raise the process-wide RLIMIT_STACK and calls
    // exit(-1) when a physical Apple device rejects that change. AEEngine
    // instead creates this UCI loop on a pthread with an explicit 4 MiB stack.
    //
    // Keep these non-stack initialization steps synchronized with
    // ThirdParty/Arasan/src/globals.cpp whenever the vendored engine changes.
    auto gameMoves = std::make_unique<MoveArray>();
    auto eco = std::make_unique<ECO>();

    globals::gameMoves = gameMoves.release();
    globals::eco = eco.release();
    globals::polling_terminated = false;
}

} // namespace

void RunUCI(std::istream &input, std::ostream &output) {
    ScopedStandardStreams streams(input, output);
    RuntimeCleanup cleanup;
    resetProcessConfiguration();

    BitUtils::init();
    Board::init();
    if (!globals::initOptions(false, nullptr, false, false)) {
        return;
    }
    globals::options.book.book_enabled = false;
    globals::options.book.eco_enabled = false;
    Attacks::init();
    Search::init();
    globals::gameMoves = nullptr;
    globals::eco = nullptr;
    cleanup.prepareForGlobalsInitialization();
    initArasanEmbeddedGlobals();

    {
        Board board;
        Protocol protocol(board, false, false, false, false);
        protocol.poll(globals::polling_terminated);
    }
}

} // namespace ArasanEmbedded
