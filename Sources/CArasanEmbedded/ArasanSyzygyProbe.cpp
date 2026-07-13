#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wshorten-64-to-32"
#endif

#include <cstdlib>
#include <stdexcept>

namespace {

class ArasanSyzygyFailure final: public std::runtime_error {
public:
    explicit ArasanSyzygyFailure(int status):
        std::runtime_error("Syzygy probing could not allocate or map a tablebase resource"),
        status_(status) {}

    int status() const noexcept {
        return status_;
    }

private:
    int status_;
};

[[noreturn]] void throwArasanSyzygyFailure(int status) {
    throw ArasanSyzygyFailure(status);
}

} // namespace

// Fathom is compiled into this in-process library. Its command-line-oriented
// fatal exits must become C++ failures that the owned engine-thread boundary can
// report without terminating the host application.
#define exit(status) throwArasanSyzygyFailure(status)
#include "../../ThirdParty/Arasan/src/syzygy/src/tbprobe.c"
#undef exit

#if defined(__clang__)
#pragma clang diagnostic pop
#endif
