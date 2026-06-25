#include "ArasanEmbeddedUCI.hpp"

#include <cstdlib>
#include <iostream>
#include <streambuf>

#include "attacks.h"
#include "bitutil.h"
#include "board.h"
#include "globals.h"
#include "options.h"
#include "protocol.h"
#include "search.h"

namespace ArasanEmbedded {
namespace {

class ScopedStandardStreams {
public:
    ScopedStandardStreams(std::istream &input, std::ostream &output) {
        previousInput_ = std::cin.rdbuf(input.rdbuf());
        previousOutput_ = std::cout.rdbuf(output.rdbuf());
        previousError_ = std::cerr.rdbuf(output.rdbuf());
    }

    ~ScopedStandardStreams() {
        std::cin.rdbuf(previousInput_);
        std::cout.rdbuf(previousOutput_);
        std::cerr.rdbuf(previousError_);
    }

private:
    std::streambuf *previousInput_ = nullptr;
    std::streambuf *previousOutput_ = nullptr;
    std::streambuf *previousError_ = nullptr;
};

} // namespace

void RunUCI(std::istream &input, std::ostream &output) {
    ScopedStandardStreams streams(input, output);

    BitUtils::init();
    Board::init();
    if (!globals::initOptions(false, nullptr, false, false)) {
        return;
    }
    globals::options.book.book_enabled = false;
    globals::options.book.eco_enabled = false;
    Attacks::init();
    Search::init();
    if (!globals::initGlobals()) {
        globals::cleanupGlobals();
        return;
    }

    Board board;
    Protocol protocol(board, false, false, false, false);
    protocol.poll(globals::polling_terminated);

    globals::cleanupGlobals();
}

}
