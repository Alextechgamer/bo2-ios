#pragma once
#include "dw_online.h"

namespace bo2::net {
// The 32-bit Windows sockaddr_in starts with a little-endian address family.
// Port and address use network order. Copy fields, never cast guest memory.
template<class ReadByte>
bool readGuestAddress(uint32_t pointer, int32_t length, Address &address, ReadByte read) {
    if (!pointer || length < 16 || pointer > UINT32_MAX - 15) {
        fail(10014);
        return false;
    }
    if (read(pointer) != 2 || read(pointer + 1) != 0) {
        fail(10047);
        return false;
    }
    Address decoded{};
    decoded.port = uint16_t((uint16_t(read(pointer + 2)) << 8) | read(pointer + 3));
    for (unsigned offset = 4; offset < 8; ++offset)
        decoded.ip = (decoded.ip << 8) | read(pointer + offset);
    address = decoded;
    return true;
}
}
